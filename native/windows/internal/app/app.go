// Package app wires the host pieces together and implements the actions in
// the IPC contract.
//
// The apply pipeline is the most safety-sensitive code in the host:
//  1. validate the candidate config with `sing-box check` (structural sanity);
//  2. write it to a versioned file and keep the previous one recoverable;
//  3. start/restart the core with it;
//  4. health-check the controller endpoint;
//  5. on failure, reapply the previous config and report the real reason.
//
// Step 5 is what makes a bad node edit non-destructive: the user ends up
// connected to whatever worked before, with a message explaining why the new
// config was rejected.
package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"clash-halo/native/windows/internal/apply"
	"clash-halo/native/windows/internal/autolaunch"
	"clash-halo/native/windows/internal/configstore"
	"clash-halo/native/windows/internal/connapi"
	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/core"
	"clash-halo/native/windows/internal/corelife"
	"clash-halo/native/windows/internal/elevate"
	"clash-halo/native/windows/internal/logs"
	"clash-halo/native/windows/internal/state"
	"clash-halo/native/windows/internal/sysproxy"
	"clash-halo/native/windows/internal/tunadmin"
	"clash-halo/native/windows/internal/tunconfig"
	"clash-halo/native/windows/internal/tunservice"
)

// Paths is the host's on-disk layout under %LOCALAPPDATA%\clash-halo.
type Paths struct {
	Root     string
	Configs  string
	Logs     string
	Core     string
	Snapshot string
	HostLog  string
	// TunService is the one-time-installed service binary, expected beside the
	// core. It is only used by the install/uninstall actions; normal TUN use
	// goes through the pipe that binary serves.
	TunService string
	// TunConfigs holds the runtime config for TUN mode. Keeping it in a
	// subdirectory means the "newest .json" fallback in activeConfigPath can
	// never mistake it for the user's config and start a tun inbound without
	// elevation.
	TunConfigs string
	// HostExe is the running host binary. Needed by the startup entry, which
	// must name an absolute path rather than rely on the shell's PATH.
	HostExe string
}

// DefaultPaths derives the layout from a base directory.
func DefaultPaths(base string, coreExe string) Paths {
	return Paths{
		Root:       base,
		Configs:    filepath.Join(base, "configs"),
		Logs:       filepath.Join(base, "logs"),
		Core:       coreExe,
		Snapshot:   filepath.Join(base, "runtime.json"),
		HostLog:    filepath.Join(base, "logs", "host.log"),
		TunService: filepath.Join(filepath.Dir(coreExe), "halo-tun-service.exe"),
		TunConfigs: filepath.Join(base, "configs", "tun"),
		HostExe:    hostExecutable(),
	}
}

// hostExecutable resolves this process's own binary path.
//
// os.Executable rather than a passed-in string: the host may be started from a
// shortcut, from the UI, or by Windows at login, and only the process itself
// knows where it actually lives.
func hostExecutable() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return exe
}

// App is the host application.
type App struct {
	Paths       Paths
	HostVersion string
	Store       *state.Store
	Supervisor  *core.Supervisor
	Log         *logs.Rotating
	Redactor    *logs.Redactor
	Proxy       *sysproxy.Manager
	// TUN state. tunMu serialises enable/disable so two concurrent enables
	// cannot race the same adapter. The LocalSystem service is the only
	// backend; tunSession says whether this host has an enable in flight or a
	// running core, which is what disable, shutdown and uninstall act on.
	tunMu        sync.Mutex
	tunOptions   tunconfig.Options
	tunSession   bool
	// startElevated launches the elevated service installer.
	// Production leaves it nil and uses elevate.Start; tests replace it, because
	// the real launcher raises a UAC prompt and a unit test must never do that.
	startElevated func(exePath string, args []string) (*elevate.Process, error)
	// tunAlive is the liveness check for the core pid the service reports.
	// Nil means tunsup.ProcessState; tests replace it because their stub
	// status names a pid that is not a real process.
	tunAlive func(int) bool
	// validateCore runs `sing-box check` on a config. Nil means core.Validate;
	// tests replace it to count how many documents one apply validates.
	validateCore func(corePath, configPath string) error
	// startNormalCore launches the ordinary (non-TUN) core. Nil means
	// Supervisor.Start; tests replace it so restoring the core can be observed
	// without spawning sing-box — the port-exclusion rule is about whether the
	// start is attempted at all.
	startNormalCore func(configPath string) (int, error)
	// disableSystemProxy is the registry half of "turn the system proxy off".
	// Nil means the real restore; tests replace it because writing HKCU\…\
	// Internet Settings during a unit test would touch the developer's machine.
	disableSystemProxy func() (bool, *contract.ErrorObj)
	// tunServiceAPI talks to the installed Windows service; it is the only TUN
	// backend.
	tunServiceAPI tunServiceAPI
	// tunInstalled reads the on-disk service description. Nil means
	// tunservice.Installed. Tests replace it so a service installed on the
	// developer machine cannot silently route a test through the real service.
	tunInstalled func() (tunservice.Config, bool)
	// tunLostSince is when the service first became unreachable during a
	// session. A restart is expected to be brief; only a lasting loss is a
	// failure.
	tunLostSince time.Time
	// runTunServiceInstallerFn replaces the elevated installer launch in
	// tests. Nil means elevate.Start.
	runTunServiceInstallerFn func(args []string) (int, error)
	// tunCoreHash caches the local core's digest for the service update check.
	tunCoreHashOnce sync.Once
	tunCoreHash     string

	mu sync.Mutex
	// applyMu serialises config application so two concurrent applies cannot
	// interleave file writes and core restarts.
	applyMu sync.Mutex

	// conn owns the Clash API client, its loopback rule and the endpoint
	// cache. Those used to live here and were read by both the poll and the
	// tray's close-all action; moving them out keeps the cache's mutex in the
	// package that owns the data.
	conn *connapi.Service

	eventSink func(event string, data any)
	// configs owns the config files and the live hash/version bookkeeping.
	configs *configstore.Store
	// life owns the normal core start/stop/resume state machine.
	life *corelife.Lifecycle
	// applier owns the validate/promote/restart/rollback pipeline.
	applier *apply.Applier
	// tunAdmin owns TUN service installation/status/removal.
	tunAdmin *tunadmin.Manager

	// trayMu guards the compact node catalogue the tray menu renders. The tray
	// rebuilds its menu from this on every right click, so the read path must be
	// cheap and the slice must never be mutated in place.
	trayMu sync.Mutex
	tray   TrayCatalog

	// clients is the number of connected UI windows. The tray uses it to decide
	// whether a menu action can be delivered to a running UI or has to open one
	// first — switching a node from the tray should not pop the window when the
	// window is already there.
	clientsMu sync.Mutex
	clients   int

	// speed test state
	speedMu      sync.Mutex
	speedCancel  chan struct{}
	speedRunning bool
	speedTaskID  string
	speedDone    chan struct{}
	// speedWG lets Shutdown wait for an in-flight task so the process never
	// exits (or a temp directory is removed) while a probe is still writing.
	speedWG sync.WaitGroup

	quitOnce sync.Once
	quitCh   chan struct{}
}

// New builds an app.
func New(paths Paths, hostVersion string) (*App, error) {
	for _, dir := range []string{paths.Root, paths.Configs, paths.Logs, paths.TunConfigs} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, err
		}
	}
	redactor := logs.NewRedactor()
	hostLog, err := logs.Open(logs.DefaultOptions(paths.HostLog, redactor))
	if err != nil {
		return nil, err
	}
	store, err := state.Open(paths.Snapshot, hostVersion, paths.Core)
	if err != nil {
		return nil, err
	}
	a := &App{
		Paths:       paths,
		HostVersion: hostVersion,
		Store:       store,
		Log:         hostLog,
		Redactor:    redactor,
		Proxy:       sysproxy.New(),
		quitCh:      make(chan struct{}),
		// A nil map accepts reads but panics on assignment, so the first probe
		// that passed `sing-box check` killed the host ("assignment to entry in
		// nil map") instead of caching its verdict. Declaring the field is not
		// initialization; every UDP / proxy-latency / download probe writes here.
	}
	a.Supervisor = core.New(core.Options{
		CorePath:  paths.Core,
		ConfigDir: paths.Root,
		Log:       hostLog,
		OnExit:    a.onCoreExit,
	})
	// The connection API only needs to know which config is live; the app
	// keeps deciding that (supervisor vs TUN service).
	a.conn = connapi.New(a, hostLog.Writef)
	a.configs = configstore.New(paths.Configs)
	a.life = corelife.New(a.Supervisor, a.Store, a.configs, hostLog, func() bool {
		return a.Store.Snapshot().TunState == state.TunEnabled
	})
	a.applier = apply.New(apply.Deps{
		Configs:            a.configs,
		Store:              a.Store,
		Supervisor:         a.Supervisor,
		Log:                hostLog,
		Redactor:           redactor,
		CorePath:           paths.Core,
		ReconcileTun:       a.reconcileTunLocked,
		ReloadTun:          a.reloadTunConfig,
		Validate:           a.validateConfig,
		Rollback:           a.rollback,
		HealthCheck:        a.healthCheck,
		RepointSystemProxy: a.repointSystemProxy,
	})
	a.tunAdmin = tunadmin.New(tunadmin.Deps{
		ServicePath: func() string { return a.Paths.TunService },
		CorePath:    func() string { return a.Paths.Core },
		DataDir:     func() string { return a.Paths.Root },
		LogsDir:     func() string { return a.Paths.Logs },
		Log:         hostLog,
		Active: func() bool {
			s := a.Store.Snapshot()
			return s.TunState == state.TunEnabled || s.TunState == state.TunPending
		},
		Ping:           a.tunServicePing,
		Installed:      a.installedTunService,
		MarkTun:        a.markTun,
		RefreshSupport: a.refreshTunSupport,
		DisableTun: func() *contract.ErrorObj {
			_, e := a.SetTun(false)
			return e
		},
		RunInstaller: a.runTunServiceInstaller,
		Backend: func() string {
			a.tunMu.Lock()
			defer a.tunMu.Unlock()
			if a.tunSession {
				return "service"
			}
			return "none"
		},
		ClearBackend: func() {
			a.tunMu.Lock()
			a.tunSession = false
			a.tunMu.Unlock()
		},
	})
	// The pipe is derived from the data directory, exactly as the installer
	// computed it: two installations never reach each other's service.
	a.tunServiceAPI = tunservice.NewClient(tunservice.PipeNameFor(paths.Root), 3*time.Second)
	// Support is decided by what is actually on disk, so the UI never offers a
	// TUN switch that could only fail.
	a.refreshTunSupport()
	// Both capability flags must be published before the first snapshot, or the
	// UI cannot tell "unsupported" from "not yet known". System proxy support was
	// only ever written inside a *successful* apply, so a fresh install reported
	// `supported:false` — and the overview then showed "当前系统不支持自动设置"
	// with the switch permanently disabled, which makes the feature unusable on
	// exactly the first run where the user wants it.
	a.refreshSystemProxySupport()
	// The registry is the truth for auto-start, not the last snapshot: the user
	// can remove the entry from Task Manager's startup tab at any time, and a
	// snapshot that still claims "enabled" would then be lying.
	a.refreshAutoLaunch()
	return a, nil
}

// refreshAutoLaunch reconciles the snapshot with the actual startup entry.
func (a *App) refreshAutoLaunch() {
	enabled, command := autolaunch.Status()
	// An entry pointing at a binary that no longer exists (an older install
	// directory) is not "enabled" in any useful sense.
	if enabled && !autolaunch.Matches(command, a.Paths.HostExe) {
		enabled = false
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.AutoLaunch = enabled
	})
}

// refreshSystemProxySupport publishes the platform capability.
//
// Separate from the apply path on purpose: capability and state are different
// facts, and conflating them is what hid the switch behind a flag only a
// successful write could set.
func (a *App) refreshSystemProxySupport() {
	supported := sysproxy.Supported()
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.SystemProxy.Supported = supported
		if supported && s.SystemProxy.Endpoint == "" {
			s.SystemProxy.Endpoint = defaultProxyEndpoint
		}
	})
}

// defaultProxyEndpoint is the mixed inbound the config generator uses, so the
// field is populated before the user has applied anything.
const defaultProxyEndpoint = "127.0.0.1:7890"

// SetEventSink installs the broadcast hook (the IPC server).
func (a *App) SetEventSink(fn func(event string, data any)) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.eventSink = fn
}

func (a *App) emit(event string, data any) {
	a.mu.Lock()
	sink := a.eventSink
	a.mu.Unlock()
	if sink != nil {
		sink(event, data)
	}
}

// QuitCh is closed when the host should exit.
func (a *App) QuitCh() <-chan struct{} { return a.quitCh }

// RequestQuit asks the host to shut down gracefully.
func (a *App) RequestQuit() {
	a.quitOnce.Do(func() { close(a.quitCh) })
}

// ActiveConfig returns the config path the host would run right now, so the
// tray can start the core without guessing.
func (a *App) ActiveConfig() string { return a.activeConfigPath() }

// OnClientCount reacts to UI windows connecting or closing.
//
// The plan requires subscription refresh and other UI-driven work to stop once
// the last window closes, while the proxy itself keeps running. The host tracks
// this so it can suspend those timers rather than run them blind.
func (a *App) OnClientCount(count int) {
	a.clientsMu.Lock()
	a.clients = count
	a.clientsMu.Unlock()
	if count == 0 {
		a.speedMu.Lock()
		if a.speedCancel != nil {
			close(a.speedCancel)
			a.speedCancel = nil
		}
		a.speedMu.Unlock()
	}
	a.Log.Writef("[host] ui clients=%d", count)
	// Every Store.Update already broadcasts state.changed through the
	// subscription installed in main.go, so the handler adds nothing here — it
	// only produced a second, identical frame per change, which the UI parsed
	// and rendered twice per transition.
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.SubscriptionRun = count > 0
	})
}

// SetCoreVersion records the version string the core binary reported when the
// host probed it at startup.
//
// This is the only honest source for 「内核版本」: querying it here means the
// number belongs to the file that is actually on disk, so an upgraded
// sing-box.exe shows its new version and a replaced-with-garbage core shows
// unknown instead of a hard-coded constant.
//
// An empty version is recorded as empty rather than guessed. The UI renders
// that as 「未知」, which is a truthful answer; the previous behaviour showed a
// dash on the overview and a constant on the about panel, so the two disagreed
// about the same process.
func (a *App) SetCoreVersion(version string) {
	if a.Store == nil {
		return
	}
	if _, err := a.Store.Update(func(s *state.Snapshot) {
		s.CoreVersion = version
	}); err != nil {
		a.Log.Writef("[host] 记录内核版本失败: %v", err)
		return
	}
	a.Log.Writef("[host] 内核版本=%s", version)
}

// onCoreExit runs after an unexpected core exit: it updates state and schedules
// a bounded restart.
func (a *App) onCoreExit(restarts int, reason string) {
	// The Update itself notifies subscribers, which is what tells the UI.
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.CoreState = state.CoreFailed
		s.CorePID = 0
		s.CoreRestarts = restarts
		s.LastErrorCode = contract.ErrCoreNotRunning
		s.LastErrorMsg = reason
	})
}

// Shutdown stops the core, restores the system proxy if it is still ours, and
// flushes logs. It is safe to call twice.
func (a *App) Shutdown() {
	a.Log.Writef("[host] shutting down")
	// Cancel and drain any running probe before touching the log or core so
	// no goroutine writes after the host's state is finalised.
	a.speedMu.Lock()
	if a.speedCancel != nil {
		close(a.speedCancel)
		a.speedCancel = nil
	}
	a.speedMu.Unlock()
	done := make(chan struct{})
	go func() { a.speedWG.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		a.Log.Writef("[host] 测速任务未在 3 秒内结束，继续退出")
	}
	// TUN first: its elevated core owns routes and an adapter, and it must be
	// gone before the host claims it stopped the proxy.
	a.shutdownTun()
	_ = a.Supervisor.Stop()
	snap := a.Store.Snapshot()
	if snap.SystemProxy.Enabled && snap.SystemProxy.Restorable {
		restored, err := a.Proxy.RestoreIfUnchanged(
			sysproxy.State{
				Enable: snap.SystemProxy.AppliedProxyEnable != 0,
				Server: snap.SystemProxy.AppliedValue,
			},
			sysproxy.State{
				Enable: snap.SystemProxy.PreviousEnable != 0,
				Server: snap.SystemProxy.PreviousValue,
			},
		)
		if err != nil {
			a.Log.Writef("[host] 恢复系统代理失败: %v", err)
		} else if !restored {
			a.Log.Writef("[host] 系统代理已被其他程序修改，保留当前值不恢复")
		}
	}
	_ = a.Log.Close()
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

// Dispatch implements ipc.Handler.
func (a *App) Dispatch(req *contract.Request) (any, *contract.ErrorObj) {
	a.Log.Writef("[host] action=%s id=%s", req.Action, req.ID)
	switch req.Action {
	case contract.ActionHostStatus:
		return a.hostStatus(), nil
	case contract.ActionSnapshotGet:
		return a.snapshot(), nil
	case contract.ActionHostShutdown:
		// Do not quit here. The IPC server calls AfterReply once the "quitting"
		// acknowledgement has been written, which is what the caller waits for;
		// triggering it inside the handler closed the pipe underneath the reply.
		return map[string]any{"quitting": true}, nil
	case contract.ActionCoreStart:
		return a.coreStart()
	case contract.ActionCoreStop:
		return a.coreStop()
	case contract.ActionCoreRestart:
		return a.coreRestart()
	case contract.ActionConfigApply:
		return a.configApply(req)
	case contract.ActionNodeSelect:
		return a.nodeSelect(req)
	case contract.ActionProxySetMode:
		return a.proxySetMode(req)
	case contract.ActionTrayPublish:
		return a.trayPublish(req)
	case contract.ActionConnectionsList:
		return a.connectionsList(req)
	case contract.ActionConnectionsClose:
		return a.connectionsClose(req)
	case contract.ActionSystemProxy:
		return a.systemProxySet(req)
	case contract.ActionAutoLaunchSet:
		return a.autoLaunchSet(req)
	case contract.ActionCoreResumeSet:
		return a.coreResumeSet(req)
	case contract.ActionTunSetEnabled:
		return a.tunSetEnabled(req)
	case contract.ActionTunServiceStatus:
		return a.tunServiceStatus()
	case contract.ActionTunServiceInstall:
		return a.tunServiceInstall()
	case contract.ActionTunServiceUninstall:
		return a.tunServiceUninstall()
	case contract.ActionSpeedtest:
		return a.speedtestStart(req)
	case contract.ActionTaskCancel:
		return a.taskCancel(req)
	case contract.ActionLogTail:
		return a.logTail(req)
	default:
		return nil, &contract.ErrorObj{
			Code:    contract.ErrUnknownAction,
			Message: "未知操作",
			Detail:  req.Action,
		}
	}
}

// snapshot returns the current state with the live log size folded in.
//
// The stored LogBytes would otherwise be a stale value from the last write,
// and a UI that sizes its log pane from it would show an empty log while the
// file clearly has content.
func (a *App) snapshot() state.Snapshot {
	// A tunnel that died is only visible through the service's status, so the
	// snapshot is where it gets folded back in.
	a.reconcileTun()
	snap := a.Store.Snapshot()
	if size := a.Log.TotalSize(); size != snap.LogBytes {
		snap.LogBytes = size
	}
	return snap
}

func (a *App) hostStatus() any {
	a.reconcileTun()
	snap := a.Store.Snapshot()
	return map[string]any{
		"hostVersion":  a.HostVersion,
		"coreState":    snap.CoreState,
		"corePid":      snap.CorePID,
		"coreRestarts": snap.CoreRestarts,
		"coreVersion":  snap.CoreVersion,
		"singboxPath":  snap.SingboxPath,
		"logBytes":     a.Log.TotalSize(),
		"stateVersion": snap.StateVersion,
		"tunState":     snap.TunState,
		"tunSupported": snap.TunSupported,
		"systemProxy":  snap.SystemProxy.Enabled,
	}
}

// ---------------------------------------------------------------------------
// Core lifecycle
// ---------------------------------------------------------------------------

// coreStart holds the TUN hand-over gate; the decision state machine lives in
// corelife.Lifecycle.
func (a *App) coreStart() (any, *contract.ErrorObj) {
	a.tunMu.Lock()
	defer a.tunMu.Unlock()
	return a.life.Start()
}

func (a *App) coreStop() (any, *contract.ErrorObj) {
	return a.life.Stop()
}

func (a *App) coreRestart() (any, *contract.ErrorObj) {
	// The restart writes the same state applyConfig does, so it must hold the
	// same lock. The tray used to stop and start the supervisor directly,
	// which let a tray restart interleave with an apply and left the live
	// config and the recorded configVersion disagreeing.
	a.applyMu.Lock()
	defer a.applyMu.Unlock()
	configPath := a.activeConfigPath()
	if configPath == "" {
		return nil, contract.NewError(contract.ErrConfigInvalid, "没有可用的配置")
	}
	_ = a.Supervisor.Stop()
	// Stop returns after the child is gone, so the listening sockets are
	// already released. The 400 ms sleep that used to sit here was a guess
	// that only made every restart slower.
	return a.coreStart()
}

// RestartCore is the tray's entry point. It must go through coreRestart so the
// applyMu invariant also holds for the tray, not only for IPC.
func (a *App) RestartCore() *contract.ErrorObj {
	_, errObj := a.coreRestart()
	return errObj
}

// ResumeCore starts the core when the last session left it running.
//
// Every host launch used to begin with the core off, even when a node had been
// applied and the user had never asked for it to stop: the snapshot's
// coreState is deliberately reset to "stopped" on load (a dead process must not
// be reported as live), and nothing recorded the *intent* that survived the
// reset. The result was a proxy that had to be switched on by hand after every
// restart, which is not what "the app remembers my setup" means to a user.
//
// What this deliberately does *not* do:
//
//   - It does not touch the system proxy. Writing a machine-wide setting is a
//     side effect with a real cost if it goes wrong, and silently re-doing it
//     at startup — possibly right after a crash that left the registry
//     half-written — is not a decision to make on the user's behalf. The core
//     comes back; taking over traffic stays an explicit act.
//   - It does not start TUN, which needs an elevation prompt that cannot be
//     answered at boot.
//   - It does not fight the user: coreWanted is cleared by coreStop, so a core
//     that was stopped on purpose stays stopped.
//
// A failure here is reported through the snapshot and the log rather than
// returned, because the host must still come up: the UI needs to connect so it
// can show the error instead of the two processes deadlocking on startup.
func (a *App) ResumeCore() { a.life.Resume() }

func (a *App) activeConfigPath() string {
	return a.configs.ActivePath()
}

// ---------------------------------------------------------------------------
// Config apply
// ---------------------------------------------------------------------------

// configApply is the only place that writes a live config.
func (a *App) configApply(req *contract.Request) (any, *contract.ErrorObj) {
	var p apply.Params
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	return a.applyConfig(p)
}

// validateConfig runs the core's structural check on one document. Split from
// core.Validate so a test can count how many documents one apply validates.
func (a *App) validateConfig(corePath, configPath string) error {
	if a.validateCore != nil {
		return a.validateCore(corePath, configPath)
	}
	return core.Validate(corePath, configPath)
}

// applyConfig runs the apply pipeline from decoded parameters. It is split
// from the request decoding so node.select can hand its params straight
// through: re-marshalling them into a fresh frame made the host parse a
// potentially frame-sized config payload three times for one command.
// applyConfig takes the two locks and hands the pipeline to the apply domain.
// The lock order is applyMu -> tunMu, matching the TUN hand-over paths.
func (a *App) applyConfig(p apply.Params) (any, *contract.ErrorObj) {
	a.applyMu.Lock()
	defer a.applyMu.Unlock()
	a.tunMu.Lock()
	defer a.tunMu.Unlock()
	return a.applier.Apply(p)
}

func (a *App) writeCandidate(config string, claimedHash string) (string, string, *contract.ErrorObj) {
	return a.configs.Candidate(config, claimedHash)
}

// promoteConfig renames the validated candidate into place.
func (a *App) promoteConfig(candidate string) error {
	return a.configs.Promote(candidate)
}

func (a *App) rollback(path, hash string, version int) error {
	if path == "" {
		// First-ever apply: there is nothing to go back to, so the honest
		// end state is "the core is stopped", not "some other config runs".
		_ = a.Supervisor.Stop()
		a.configs.Clear()
		a.configs.ClearActiveFile()
		return nil
	}
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("回退配置不存在: %w", err)
	}
	if err := configstore.CopyFile(path, filepath.Join(a.Paths.Configs, "active.json")); err != nil {
		return fmt.Errorf("回退写入失败: %w", err)
	}
	if _, err := a.Supervisor.Start(filepath.Join(a.Paths.Configs, "active.json")); err != nil {
		return fmt.Errorf("回退后核心启动失败: %w", err)
	}
	a.configs.SetVersion(hash, version)
	a.Log.Writef("[host] config rolled back to %s", hash)
	return nil
}

func (a *App) healthCheck(controller, secret string) error {
	if controller == "" {
		// Without a controller the strongest honest claim is "the core did not
		// die on startup". A config that parses but aborts immediately (a
		// missing node credential, for example) is still caught here.
		time.Sleep(600 * time.Millisecond)
		if !a.Supervisor.Running() {
			return fmt.Errorf("核心启动后立即退出: %s", a.Supervisor.LastExit())
		}
		a.Supervisor.ResetBackoff()
		return nil
	}
	// The controller address comes from the UI's config, so it is untrusted
	// input used to build a request that also carries the API secret. Refusing
	// anything but loopback keeps a config from turning the host into a client
	// for an arbitrary LAN/Internet endpoint.
	if !connapi.IsLoopbackAddress(controller) {
		return fmt.Errorf("控制接口不是回环地址，已拒绝探测: %s", controller)
	}
	// The controller opens a moment after the process starts; probing once
	// would produce a false "invalid config" rejection on a slow start.
	deadline := time.Now().Add(6 * time.Second)
	var last error
	for time.Now().Before(deadline) {
		if !a.Supervisor.Running() {
			return fmt.Errorf("核心启动后立即退出: %s", a.Supervisor.LastExit())
		}
		if err := core.HealthCheck(controller, secret, 2*time.Second); err == nil {
			last = nil
			break
		} else {
			last = err
		}
		time.Sleep(250 * time.Millisecond)
	}
	if last != nil {
		return last
	}
	// The controller responding proves the core parsed the config and opened
	// its inbound; reset the failure budget so a later crash gets a fresh
	// chance rather than inheriting the previous backoff.
	a.Supervisor.ResetBackoff()
	return nil
}

func (a *App) nodeSelect(req *contract.Request) (any, *contract.ErrorObj) {
	var p struct {
		Config     string   `json:"config"`
		ConfigHash string   `json:"configHash"`
		NodeID     string   `json:"nodeId"`
		NodeName   string   `json:"nodeName"`
		Mode       string   `json:"mode"`
		Controller string   `json:"controller"`
		APISecret  string   `json:"apiSecret"`
		Secrets    []string `json:"secrets"`
	}
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	// node.select is config.apply with selection metadata; keeping one
	// implementation avoids two divergent apply paths. The decoded params go
	// straight to applyConfig — serialising them back into a request frame so
	// it could be decoded again cost a full copy of the config per switch.
	return a.applyConfig(apply.Params{
		Config:      p.Config,
		ConfigHash:  p.ConfigHash,
		NodeID:      p.NodeID,
		NodeName:    p.NodeName,
		Mode:        p.Mode,
		Controller:  p.Controller,
		APISecret:   p.APISecret,
		Secrets:     p.Secrets,
		RestartOnly: true,
	})
}

type modeParams struct {
	Mode string `json:"mode"`
}

func (a *App) proxySetMode(req *contract.Request) (any, *contract.ErrorObj) {
	var p modeParams
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	if e := a.SwitchMode(p.Mode); e != nil {
		return nil, e
	}
	return map[string]any{"mode": p.Mode}, nil
}

// SwitchMode records the routing intent in the snapshot.
//
// Note what this deliberately does *not* do: it does not rewrite the running
// config. The route rules are generated in Dart (packages/config) from the node
// plus the routing settings, and the host would have to duplicate that
// generator to rebuild them here. The UI therefore re-applies the config after
// the mode changes (AppController.setMode); the tray call is the same
// two-step, with the UI doing the second step.
//
// Exported because the tray menu switches modes directly.
func (a *App) SwitchMode(mode string) *contract.ErrorObj {
	switch state.ProxyMode(mode) {
	case state.ModeRule, state.ModeGlobal, state.ModeDirect:
	default:
		return &contract.ErrorObj{
			Code: contract.ErrBadRequest, Message: "未知的路由模式", Detail: mode,
		}
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) { s.Mode = state.ProxyMode(mode) })
	return nil
}

// ---------------------------------------------------------------------------
// Tray catalogue
// ---------------------------------------------------------------------------

// TrayNode is the compact node record the tray menu needs.
//
// The host deliberately does not own the node database — Dart does — so the UI
// publishes a stripped copy over IPC (tray.publish). Only an id, a display name
// and the subscription group cross the boundary: no credentials, no addresses,
// nothing that would make the host's memory a second copy of the user's
// secrets.
type TrayNode struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Group string `json:"group"`
}

// TrayProfile is one subscription, as the tray's 订阅 submenu shows it.
type TrayProfile struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// TrayCatalog is the published node list plus which one is active.
//
// The tray mirrors Clash Verge Rev's menu, which offers subscriptions and proxy
// groups as their own submenus. The host cannot derive either from the nodes it
// was handed — a node knows its group name but not whether that group is a
// subscription the user can switch to — so the UI publishes both explicitly.
type TrayCatalog struct {
	Nodes         []TrayNode    `json:"nodes"`
	ActiveNodeID  string        `json:"activeNodeId"`
	Profiles      []TrayProfile `json:"profiles"`
	ActiveProfile string        `json:"activeProfileId"`
}

// CoreLogPath is where the core writes its own stdout/stderr. The tray's
// 内核日志 entry opens it, so the location must have exactly one definition.
func (a *App) CoreLogPath() string { return filepath.Join(a.Paths.Root, "core-output.log") }

// CloseAllConnections drops every live connection through the Clash API.
//
// Exposed because the tray offers 关闭所有连接: an empty id means "all" to the
// API, and the tray must reach the same implementation the connections page uses
// rather than a second copy of the request.
func (a *App) CloseAllConnections() (any, *contract.ErrorObj) {
	return a.closeConnections("")
}

// RequestProfileSwitch asks the UI to make profileID the active subscription.
//
// Same reasoning as RequestNodeSwitch: choosing a subscription means generating
// a new config from that subscription's nodes, and the generator is in Dart.
func (a *App) RequestProfileSwitch(profileID string) error {
	if profileID == "" {
		return errors.New("缺少订阅 ID")
	}
	return a.writeTrayRequest(map[string]any{
		"action":    "selectProfile",
		"profileId": profileID,
	})
}

// SetTrayCatalog replaces the tray's copy of the node list.
func (a *App) SetTrayCatalog(c TrayCatalog) {
	a.trayMu.Lock()
	a.tray = c
	a.trayMu.Unlock()
}

// TrayCatalog returns the last published catalogue. The tray calls this on
// every right click, so it returns a copy rather than handing out the live
// slice the publish handler may be replacing.
func (a *App) TrayCatalog() TrayCatalog {
	a.trayMu.Lock()
	defer a.trayMu.Unlock()
	// A copy, not the live value: the tray builds a menu from this on another
	// goroutine while the UI may be publishing a replacement.
	return TrayCatalog{
		Nodes:         append([]TrayNode(nil), a.tray.Nodes...),
		ActiveNodeID:  a.tray.ActiveNodeID,
		Profiles:      append([]TrayProfile(nil), a.tray.Profiles...),
		ActiveProfile: a.tray.ActiveProfile,
	}
}

func (a *App) trayPublish(req *contract.Request) (any, *contract.ErrorObj) {
	var p TrayCatalog
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	// A subscription with thousands of nodes would make the tray menu useless
	// and slow to build, so the catalogue is capped. The UI shows the full list;
	// the tray is a shortcut, not a second browser.
	const maxTrayNodes = 60
	if len(p.Nodes) > maxTrayNodes {
		p.Nodes = p.Nodes[:maxTrayNodes]
	}
	a.SetTrayCatalog(p)
	return map[string]any{"count": len(p.Nodes)}, nil
}

// RequestNodeSwitch asks the UI to switch to nodeID.
//
// The host cannot do this itself: turning a node into a sing-box document is
// Dart's job (packages/config), and duplicating the generator in Go would be a
// second source of truth for the most safety-sensitive output in the app. So
// the tray writes a request the UI consumes on its next start and broadcasts
// the same payload for a UI that is already running.
func (a *App) RequestNodeSwitch(nodeID string) error {
	if nodeID == "" {
		return errors.New("缺少节点 ID")
	}
	return a.writeTrayRequest(map[string]any{
		"action": "selectNode",
		"nodeId": nodeID,
	})
}

// RequestModeSwitch asks the UI to switch routing mode.
//
// Same reasoning as [RequestNodeSwitch]: the route rules live in the generated
// document, so changing the mode here alone would flip a field in the snapshot
// while traffic kept following the old rules — a menu that says 全局 while the
// proxy is still rule-based is worse than one that does nothing.
func (a *App) RequestModeSwitch(mode string) error {
	switch state.ProxyMode(mode) {
	case state.ModeRule, state.ModeGlobal, state.ModeDirect:
	default:
		return fmt.Errorf("未知的路由模式: %s", mode)
	}
	return a.writeTrayRequest(map[string]any{
		"action": "setMode",
		"mode":   mode,
	})
}

// UIClients reports how many UI windows are connected right now.
func (a *App) UIClients() int {
	a.clientsMu.Lock()
	defer a.clientsMu.Unlock()
	return a.clients
}

// writeTrayRequest persists a request for the UI and broadcasts it.
//
// The file is what makes the tray work with no window open at all: the next UI
// to start reads it. The broadcast is the fast path for a window that is already
// running. Both carry `requestedAtMs` so a stale file left behind by a crash is
// ignored instead of silently switching the user's node on an unrelated launch.
func (a *App) writeTrayRequest(payload map[string]any) error {
	payload["requestedAtMs"] = time.Now().UnixMilli()
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(filepath.Join(a.Paths.Root, "tray-request.json"), body); err != nil {
		return err
	}
	a.emit(contract.EventTrayCommand, payload)
	return nil
}

// writeFileAtomic writes body to path through a sibling temp file and a rename,
// so a reader can never observe a half-written file.
func writeFileAtomic(path string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ---------------------------------------------------------------------------
// System proxy
// ---------------------------------------------------------------------------

type sysProxyParams struct {
	Enabled  bool   `json:"enabled"`
	Endpoint string `json:"endpoint"`
}

func (a *App) systemProxySet(req *contract.Request) (any, *contract.ErrorObj) {
	var p sysProxyParams
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	return a.SetSystemProxy(p.Enabled, p.Endpoint)
}

// SetSystemProxy enables or disables the Windows proxy.
//
// Exported and separated from the IPC handler because the tray menu needs the
// same behaviour: two implementations of "point Windows at the core" would drift
// apart, and the restore bookkeeping is subtle enough that a second copy is a bug
// waiting to happen.
func (a *App) SetSystemProxy(enabled bool, endpoint ...string) (any, *contract.ErrorObj) {
	if !sysproxy.Supported() {
		return nil, contract.NewError(contract.ErrUnsupported, "当前系统不支持自动设置系统代理")
	}
	target := ""
	if len(endpoint) > 0 {
		target = endpoint[0]
	}
	if !enabled {
		restored, errObj := a.disableSystemProxyLocked()
		if errObj != nil {
			return nil, errObj
		}
		return map[string]any{
			"enabled":  false,
			"restored": restored,
			"note":     noteRestore(restored),
		}, nil
	}
	// Fall back to the endpoint recorded in the snapshot when the caller did not
	// supply one (the tray menu), then to the mixed-inbound default.
	if target == "" {
		target = a.Store.Snapshot().SystemProxy.Endpoint
	}
	if target == "" {
		target = defaultProxyEndpoint
	}
	// Turning the system proxy on is choosing ordinary proxy mode, which means
	// stopping the tunnel: one core runs, and TUN holding the inbound is what
	// made a second core die on the port. The reverse direction lives in
	// tunTakesOverSystemProxy.
	//
	// Done before the registry write so a refused stop leaves the user's proxy
	// setting untouched instead of pointing at a tunnel that is still running.
	leftTunnel, errObj := a.leaveTunForProxyMode()
	if errObj != nil {
		return nil, errObj
	}
	previous, applied, err := a.Proxy.Apply(target)
	if err != nil {
		return nil, &contract.ErrorObj{
			Code: contract.ErrSystemProxy, Message: "设置系统代理失败", Detail: err.Error(),
		}
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.SystemProxy = state.SystemProxy{
			Supported:          true,
			Enabled:            true,
			Restorable:         true,
			Endpoint:           target,
			AppliedValue:       applied.Server,
			AppliedProxyEnable: 1,
			PreviousValue:      previous.Server,
			PreviousEnable:     boolInt(previous.Enable),
		}
	})
	if leftTunnel {
		return map[string]any{
			"enabled":  true,
			"endpoint": target,
			"note":     "已切换回普通代理，TUN 已关闭",
		}, nil
	}
	return map[string]any{"enabled": true, "endpoint": target}, nil
}

// leaveTunForProxyMode stops the tunnel so the ordinary core can own the
// inbound. Returns whether a tunnel was actually stopped.
//
// Called from the system-proxy switch, which does not hold tunMu; SetTun takes
// it itself. Going the other way (TUN taking over from the system proxy) is in
// tunTakesOverSystemProxy and must not call back here: tunEnable already holds
// tunMu.
func (a *App) leaveTunForProxyMode() (bool, *contract.ErrorObj) {
	snap := a.Store.Snapshot()
	if snap.TunState != state.TunEnabled && snap.TunState != state.TunPending {
		return false, nil
	}
	if _, errObj := a.SetTun(false); errObj != nil {
		return false, errObj
	}
	a.Log.Writef("[host] 已切换回普通代理模式，TUN 已关闭")
	return true, nil
}

// disableSystemProxyLocked clears the Windows proxy setting and the recorded
// state. "Locked" names the caller's expectation, not a lock this takes: it is
// the half of SetSystemProxy that TUN also needs, so enabling TUN can drop the
// system proxy without re-entering the public entry point.
//
// Turning it off restores the previous value only if nobody else has touched it
// since; otherwise the current value is preserved.
func (a *App) disableSystemProxyLocked() (bool, *contract.ErrorObj) {
	if a.disableSystemProxy != nil {
		return a.disableSystemProxy()
	}
	snap := a.Store.Snapshot()
	restored, err := a.Proxy.RestoreIfUnchanged(
		sysproxy.State{
			Enable: snap.SystemProxy.AppliedProxyEnable != 0,
			Server: snap.SystemProxy.AppliedValue,
		},
		sysproxy.State{
			Enable: snap.SystemProxy.PreviousEnable != 0,
			Server: snap.SystemProxy.PreviousValue,
		},
	)
	if err != nil {
		return false, &contract.ErrorObj{
			Code: contract.ErrSystemProxy, Message: "恢复系统代理失败", Detail: err.Error(),
		}
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.SystemProxy.Enabled = false
		s.SystemProxy.Restorable = false
		s.SystemProxy.AppliedValue = ""
		s.SystemProxy.AppliedProxyEnable = 0
	})
	return restored, nil
}

// autoLaunchSet registers or removes the per-user startup entry.
// The snapshot carried an `autoLaunch` field from the beginning with nothing
// behind it, so the settings page could only ever print "已关闭（默认）": a
// setting the user can see and never change. The host owns the registry write
// because the UI has no business knowing where Windows keeps startup items, and
// because the value must name the host binary, whose path only the host knows.
func (a *App) autoLaunchSet(req *contract.Request) (any, *contract.ErrorObj) {
	var p struct {
		Enabled bool `json:"enabled"`
	}
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	exe := a.Paths.HostExe
	if p.Enabled {
		// --silent: starting with Windows should restore the proxy and show the
		// tray icon, not throw a window in the user's face at login.
		command, err := autolaunch.Enable(autolaunch.Spec{
			Executable: exe,
			DataDir:    a.Paths.Root,
			ExtraArgs:  []string{"--silent-start"},
		})
		if err != nil {
			return nil, &contract.ErrorObj{
				Code:    contract.ErrInternal,
				Message: "启用开机自启失败",
				Detail:  err.Error(),
			}
		}
		a.Log.Writef("[host] 开机自启已启用: %s", command)
	} else {
		if err := autolaunch.Disable(); err != nil {
			return nil, &contract.ErrorObj{
				Code:    contract.ErrInternal,
				Message: "关闭开机自启失败",
				Detail:  err.Error(),
			}
		}
		a.Log.Writef("[host] 开机自启已关闭")
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.AutoLaunch = p.Enabled
	})
	return map[string]any{"enabled": p.Enabled}, nil
}

// coreResumeSet stores whether the next launch should start the core again.
//
// Turning it off is not the same as stopping the core now: the running process
// is left alone, and only the *next* launch changes. Conflating the two would
// make a settings toggle silently kill the user's proxy.
func (a *App) coreResumeSet(req *contract.Request) (any, *contract.ErrorObj) {
	var p struct {
		Enabled bool `json:"enabled"`
	}
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) { s.CoreWanted = p.Enabled })
	a.Log.Writef("[host] 启动时恢复内核已%s", map[bool]string{true: "启用", false: "关闭"}[p.Enabled])
	return map[string]any{"enabled": p.Enabled}, nil
}

func noteRestore(restored bool) string {
	if restored {
		return "已恢复之前的系统代理设置"
	}
	return "系统代理已被其他程序修改，已保留当前值"
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

type logTailParams struct {
	Lines    int   `json:"lines"`
	MaxBytes int64 `json:"maxBytes"`
}

func (a *App) logTail(req *contract.Request) (any, *contract.ErrorObj) {
	var p logTailParams
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	// Tail only the host log. The core's own output lives in a sibling file
	// and is exposed separately so a chatty core cannot bury host events that
	// explain why something failed.
	path := a.Paths.HostLog
	lines, err := logs.Tail(path, p.Lines, p.MaxBytes)
	if err != nil {
		return nil, &contract.ErrorObj{
			Code: contract.ErrInternal, Message: "读取日志失败", Detail: err.Error(),
		}
	}
	out := make([]map[string]any, 0, len(lines))
	for _, l := range lines {
		// `seq` is the line's byte offset in the file, so it is stable across
		// polls. It used to be absent, which left the log page deduplicating on
		// `atMs + text`; `atMs` was the file's modification time on every line,
		// so a single append shifted every row's time and the overlap search
		// could no longer recognise what it had already shown.
		out = append(out, map[string]any{
			"seq":  l.Seq,
			"atMs": l.AtMs,
			"text": l.Text,
		})
	}
	return map[string]any{
		"lines":    out,
		"logBytes": a.Log.TotalSize(),
	}, nil
}

// ---------------------------------------------------------------------------
// Speed test (isolated probe)
// ---------------------------------------------------------------------------

type speedParams struct {
	TaskID string `json:"taskId"`
	// Metric selects what is measured: tcp, proxy_latency or download. It is
	// explicit rather than inferred so a caller cannot silently get a
	// throughput probe when it asked for a latency number.
	Metric      string   `json:"metric"`
	Endpoints   []string `json:"endpoints"`
	NodeIDs     []string `json:"nodeIds"`
	URL         string   `json:"url"`
	TimeoutMs   int      `json:"timeoutMs"`
	Concurrency int      `json:"concurrency"`
	Configs     []string `json:"configs"`
}

func (a *App) speedtestStart(req *contract.Request) (any, *contract.ErrorObj) {
	var p speedParams
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	if len(p.Configs) > 0 {
		p.Endpoints = make([]string, len(p.Configs))
	}
	if len(p.Endpoints) == 0 {
		return nil, contract.NewError(contract.ErrBadRequest, "endpoints 不能为空")
	}
	a.speedMu.Lock()
	if a.speedRunning {
		a.speedMu.Unlock()
		return nil, contract.NewError(contract.ErrBusy, "已有测速任务在运行")
	}
	a.speedRunning = true
	cancel := make(chan struct{})
	a.speedCancel = cancel
	a.speedTaskID = p.TaskID
	a.speedDone = make(chan struct{})
	a.speedWG.Add(1)
	a.speedMu.Unlock()

	_, _ = a.Store.Update(func(s *state.Snapshot) { s.SpeedTestRunning = true })
	a.emit(contract.EventTaskStarted, map[string]any{
		"taskId": p.TaskID, "count": len(p.Endpoints),
	})
	go a.runSpeedTest(p, cancel)
	return map[string]any{"taskId": p.TaskID, "accepted": true}, nil
}

func (a *App) runSpeedTest(p speedParams, cancel chan struct{}) {
	defer a.speedWG.Done()
	defer func() {
		a.speedMu.Lock()
		_, _ = a.Store.Update(func(s *state.Snapshot) { s.SpeedTestRunning = false })
		a.speedRunning = false
		a.speedCancel = nil
		a.speedTaskID = ""
		close(a.speedDone)
		a.speedDone = nil
		a.speedMu.Unlock()
	}()
	results := a.runProbes(p, cancel)
	event := map[string]any{
		"taskId": p.TaskID, "results": results,
	}
	select {
	case <-cancel:
		event["canceled"] = true
	default:
	}
	a.emit(contract.EventTaskFinished, event)
}

func (a *App) taskCancel(req *contract.Request) (any, *contract.ErrorObj) {
	var p struct {
		TaskID string `json:"taskId"`
	}
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	a.speedMu.Lock()
	if !a.speedRunning || a.speedTaskID != p.TaskID {
		a.speedMu.Unlock()
		return nil, contract.NewError(contract.ErrNotFound, "找不到指定的测速任务")
	}
	done := a.speedDone
	if a.speedCancel != nil {
		close(a.speedCancel)
		a.speedCancel = nil
	}
	a.speedMu.Unlock()
	// Acknowledge only after the old batch has released its slot.
	<-done
	return map[string]any{"taskId": p.TaskID, "canceled": true}, nil
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// jsonMarshal is a thin alias so app.go need not import encoding/json just for
// one call.
func jsonMarshal(v any) ([]byte, error) { return marshalJSON(v) }

// SortedIDs is a deterministic helper for stable output in tests.
func SortedIDs(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
