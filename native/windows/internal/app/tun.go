package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
	"clash-halo/native/windows/internal/tunconfig"
	"clash-halo/native/windows/internal/tunservice"
	"clash-halo/native/windows/internal/tunsup"
)

// TUN mode runs the same active config in a LocalSystem service.
//
// The service is installed once, with a single UAC prompt on the first enable,
// and every later enable goes through its control pipe. It stages a protected
// copy of the core and the config, so the unelevated host never hands a
// user-writable file to an elevated process.
//
// Everything the UI shows about TUN is a settled state: a refused prompt, a
// failed adapter and a running tunnel are distinguishable rather than collapsed
// into "error".

// tunServiceAPI is the subset of the service client the host uses. Defining it
// here keeps the TUN state machine testable without a real pipe.
type tunServiceAPI interface {
	Ping(ctx context.Context) (tunservice.PingResult, error)
	Status(ctx context.Context) (tunsup.Status, error)
	Start(ctx context.Context, configPath string, hostPID int) (tunsup.Status, error)
	Stop(ctx context.Context) (tunsup.Status, error)
}

// tunParams is the request for tun.setEnabled.
type tunParams struct {
	Enabled     bool   `json:"enabled"`
	AdapterName string `json:"adapterName,omitempty"`
	Stack       string `json:"stack,omitempty"`
	Address     string `json:"address,omitempty"`
	MTU         int    `json:"mtu,omitempty"`
	// AutoRoute and StrictRoute are pointers so an explicit false is
	// distinguishable from "not specified". strict_route makes the core install
	// firewall rules, which is worth being able to turn off deliberately.
	AutoRoute   *bool `json:"autoRoute,omitempty"`
	StrictRoute *bool `json:"strictRoute,omitempty"`
}

// tunWait is how long an enable waits for the service to report a settled
// state.
//
// The budget is deliberately generous: the first enable can raise a UAC prompt
// that sits on screen while the user reads it, and giving up early would report
// a failure for a prompt that was about to be accepted.
func (a *App) tunWait() time.Duration {
	return 90 * time.Second
}

func (a *App) tunRuntimeConfigPath() string {
	return filepath.Join(a.Paths.TunConfigs, "runtime.json")
}

// tunAvailable reports whether TUN can be attempted here.
//
// The service brings its own approved core, so a reachable or installed service
// is enough; otherwise the binaries needed for the first install must be on
// disk.
func (a *App) tunAvailable() (bool, string) {
	if _, ok := a.tunServicePing(400 * time.Millisecond); ok {
		return true, ""
	}
	// A service that is installed but momentarily unreachable is still a
	// supported path: enabling it repairs/starts the service. Treating this as
	// "not installed" would disable the switch on a machine that has the
	// service.
	if cfg, ok := a.installedTunService(); ok &&
		strings.EqualFold(filepath.Clean(cfg.DataDir), filepath.Clean(a.Paths.Root)) {
		return true, ""
	}
	if _, err := os.Stat(a.Paths.Core); err != nil {
		return false, "找不到内核程序 " + filepath.Base(a.Paths.Core)
	}
	// The installer ships the service; its presence is enough for the first
	// enable to install/update it.
	if _, err := os.Stat(a.Paths.TunService); err != nil {
		return false, "找不到 TUN 服务程序 " + filepath.Base(a.Paths.TunService) +
			"；请重新安装应用"
	}
	return true, ""
}

// tunServicePing reports whether a compatible service is reachable.
func (a *App) tunServicePing(timeout time.Duration) (tunservice.PingResult, bool) {
	if a.tunServiceAPI == nil {
		return tunservice.PingResult{}, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	ping, err := a.tunServiceAPI.Ping(ctx)
	if err != nil || ping.Protocol != tunservice.ProtocolVersion {
		return tunservice.PingResult{}, false
	}
	return ping, true
}

// tunServiceForStart returns the client when the service can be used.
func (a *App) tunServiceForStart() (tunServiceAPI, bool) {
	if _, ok := a.tunServicePing(500 * time.Millisecond); !ok {
		return nil, false
	}
	return a.tunServiceAPI, true
}

// refreshTunSupport records whether TUN can be attempted at all.
func (a *App) refreshTunSupport() {
	ok, why := a.tunAvailable()
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunSupported = ok
		if !ok {
			s.TunState = state.TunUnsupported
			s.TunMessage = why
			return
		}
		if s.TunState == state.TunUnsupported {
			s.TunState = state.TunDisabled
			s.TunMessage = ""
		}
	})
}

// markTun records a TUN transition. The Update itself notifies subscribers
// (main.go installs the state.changed broadcast), so no extra event is sent.
func (a *App) markTun(st state.TunState, message string, pid int, adapter string, elevated bool) {
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = st
		s.TunMessage = message
		s.TunPID = pid
		s.TunAdapter = adapter
		s.TunElevated = elevated
	})
}

// tunResult is the action's result payload.
func (a *App) tunResult(s state.Snapshot) map[string]any {
	return map[string]any{
		"tunState":    s.TunState,
		"tunMessage":  s.TunMessage,
		"tunPid":      s.TunPID,
		"tunAdapter":  s.TunAdapter,
		"tunElevated": s.TunElevated,
	}
}

// tunFail publishes the failure before returning it, so the UI's snapshot and
// the command's error never disagree.
func (a *App) tunFail(code, message, detail string) *contract.ErrorObj {
	// A failed enable or reload leaves no backend owning the session.
	a.tunSession = false
	a.tunLostSince = time.Time{}
	reason := detail
	if reason == "" {
		reason = message
	}
	a.markTun(state.TunFailed, reason, 0, "", false)
	// Enabling TUN stops the normal core, so a failure here — most often a
	// refused UAC prompt — would otherwise leave the user with no proxy at all.
	// That is a worse outcome than the TUN they declined.
	a.restoreNormalCore()
	a.Log.Writef("[host] tun failed code=%s detail=%s", code, detail)
	return &contract.ErrorObj{Code: code, Message: message, Detail: detail}
}

// restoreNormalCore brings the unelevated core back after a TUN session ends or
// fails to start.
//
// The condition is "the user relies on a proxy", not "the system proxy is on".
// TUN is itself a traffic path, so someone who uses only TUN has the system
// proxy off; keying restoration on the system proxy left them with no core at
// all when the tunnel ended. CoreWanted is the recorded intent to keep the core
// running: apply and core.start set it, core.stop clears it.
func (a *App) restoreNormalCore() {
	if a.Supervisor.Running() {
		return
	}
	snap := a.Store.Snapshot()
	if !a.shouldRestoreCore(snap) {
		return
	}
	// A tunnel that is up already owns the mixed inbound port. Starting the
	// ordinary core then makes it fail to bind 127.0.0.1:7890 and exit after
	// zero seconds — observed seven times in a row while TUN was working, each
	// time reported to the user as "代理内核崩溃". The two cores are mutually
	// exclusive by design; the ordinary one comes back when the tunnel ends.
	if a.tunnelOccupiesInboundLocked(snap) {
		a.Log.Writef("[host] TUN 正在接管流量，普通内核保持停止")
		return
	}
	cfg := a.activeConfigPath()
	if cfg == "" {
		return
	}
	pid, err := a.startNormalCoreForTest(cfg)
	if err != nil {
		a.Log.Writef("[host] 恢复普通内核失败: %v", err)
		return
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.CoreState = state.CoreRunning
		s.CorePID = pid
	})
	a.Log.Writef("[host] 普通内核已恢复 pid=%d", pid)
}

// startNormalCoreForTest runs the injectable start, falling back to the
// supervisor. Named for its seam rather than for tests: production never sets
// the field, so the fallback is the only path it takes.
func (a *App) startNormalCoreForTest(configPath string) (int, error) {
	if a.startNormalCore != nil {
		return a.startNormalCore(configPath)
	}
	return a.Supervisor.Start(configPath)
}

// tunnelOccupiesInboundLocked reports whether a live tunnel is holding the
// mixed inbound, which is what makes a second core unable to start.
//
// Only "pending" and "enabled" count: a failed tunnel has released the port,
// and treating it as occupied would leave the user with no proxy at all after
// a refused authorization. The caller holds tunMu (or is the only writer).
func (a *App) tunnelOccupiesInboundLocked(snap state.Snapshot) bool {
	switch snap.TunState {
	case state.TunEnabled:
	case state.TunPending:
	default:
		return false
	}
	// "Enabled" with a dead backend is a stale record; the port is free.
	return a.backendAliveLocked()
}

// shouldRestoreCore reports whether ending TUN should bring the ordinary core
// back. Split out so the decision is testable without starting a real process.
func (a *App) shouldRestoreCore(s state.Snapshot) bool {
	return s.SystemProxy.Enabled || s.CoreWanted
}

// reconcileTun folds a change in the service's state into the snapshot.
//
// Nothing pushes state changes from the service, and nothing else polls it after
// a successful enable. Without this, a TUN core that died minutes later would
// keep being reported as enabled until the user happened to toggle it — the UI
// would show a tunnel that is not there.
func (a *App) reconcileTun() {
	// An in-flight enable or disable owns the transition; never block a
	// snapshot for the length of a UAC prompt.
	if !a.tunMu.TryLock() {
		return
	}
	defer a.tunMu.Unlock()
	a.reconcileTunLocked()
}

// reconcileTunLocked folds the service's state into the snapshot.
func (a *App) reconcileTunLocked() {
	if a.Store.Snapshot().TunState != state.TunEnabled {
		return
	}
	a.reconcileServiceLocked()
}

// reconcileServiceLocked folds the service's state into the snapshot.
//
// A service restart is brief (the SCM recovery policy waits seconds), so an
// unreachable pipe is not a failure until it has lasted. When it does last, the
// core is gone: the service's job object dies with the service.
func (a *App) reconcileServiceLocked() {
	if a.tunServiceAPI == nil {
		a.endTunLocked(state.TunFailed, "TUN 服务未配置")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 700*time.Millisecond)
	st, err := a.tunServiceAPI.Status(ctx)
	cancel()
	if err != nil {
		if a.tunLostSince.IsZero() {
			a.tunLostSince = time.Now()
			a.Log.Writef("[host] TUN 服务暂时不可达: %v", err)
			return
		}
		if time.Since(a.tunLostSince) < 15*time.Second {
			return
		}
		a.endTunLocked(state.TunFailed, "TUN 服务不可达，内核已停止")
		return
	}
	a.tunLostSince = time.Time{}
	switch st.State {
	case tunsup.StateRunning:
		if !a.tunCoreAlive(st.PID) {
			a.endTunLocked(state.TunFailed, "TUN 内核已退出")
			return
		}
		snap := a.Store.Snapshot()
		if snap.TunPID != st.PID || snap.TunAdapter != st.Adapter {
			// The service may have retried with a fresh adapter name.
			a.markTunRunning(st)
		}
	case tunsup.StateFailed, tunsup.StateStopped:
		next, msg := state.TunDisabled, ""
		if st.State == tunsup.StateFailed {
			next, msg = state.TunFailed, st.Message
		}
		a.endTunLocked(next, msg)
	}
}

// endTunLocked records that the tunnel is gone and gives ordinary proxy mode
// back when the user was relying on it. The caller holds tunMu.
func (a *App) endTunLocked(next state.TunState, msg string) {
	a.tunSession = false
	a.tunLostSince = time.Time{}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = next
		s.TunMessage = msg
		s.TunPID = 0
		s.TunAdapter = ""
		s.TunElevated = false
		if !a.Supervisor.Running() {
			s.CoreState = state.CoreStopped
			s.CorePID = 0
		}
	})
	a.restoreNormalCore()
	a.Log.Writef("[host] TUN 状态已同步为 %s: %s", next, msg)
}

func (a *App) tunSetEnabled(req *contract.Request) (any, *contract.ErrorObj) {
	var p tunParams
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	// One mutation at a time: enabling twice concurrently would race the same
	// adapter.
	a.tunMu.Lock()
	defer a.tunMu.Unlock()
	if !p.Enabled {
		return a.tunDisable()
	}
	return a.tunEnable(p)
}

// SetTun toggles TUN with the default adapter settings, for callers that have
// no parameters to pass — the tray menu. The IPC path keeps its own decoder
// because the settings page can override adapter name, stack, address and MTU.
func (a *App) SetTun(enabled bool) (any, *contract.ErrorObj) {
	a.tunMu.Lock()
	defer a.tunMu.Unlock()
	if !enabled {
		return a.tunDisable()
	}
	return a.tunEnable(tunParams{Enabled: true})
}

// tunTakesOverSystemProxy clears the Windows proxy setting once the tunnel is
// carrying traffic.
//
// The two settings are one choice, not two: only one core runs, and both its
// inbound paths point at the same local port. Leaving the system proxy ticked
// while TUN is up produced a UI claiming two active traffic paths when there is
// one, and a user who then turned the system proxy off could not tell what they
// had just changed. Turning TUN on therefore turns the system proxy off, the way
// a single radio group would behave.
//
// Failure here must not fail the enable: the tunnel is already up and working,
// and the caller has asked for TUN, not for proxy bookkeeping.
func (a *App) tunTakesOverSystemProxy() {
	if !a.Store.Snapshot().SystemProxy.Enabled {
		return
	}
	if _, errObj := a.disableSystemProxyLocked(); errObj != nil {
		a.Log.Writef("[host] TUN 已启用，但关闭系统代理失败: %s", errObj.Message)
		return
	}
	a.Log.Writef("[host] TUN 已接管流量，系统代理已关闭")
}

// tunCoreAlive reports whether pid names the running TUN core.
//
// "Unknown" counts as alive on purpose. A service-owned core runs as
// LocalSystem, so an unprivileged host is refused PROCESS_QUERY_LIMITED_
// INFORMATION; treating that refusal as death tore down a healthy tunnel. The
// service reports State=Running, and the exit path is covered by the service's
// own host watchdog and by `ping`/`status` failing outright.
func (a *App) tunCoreAlive(pid int) bool {
	if a.tunAlive != nil {
		return a.tunAlive(pid)
	}
	return tunsup.ProcessState(pid) != tunsup.ProcessGone
}

func (a *App) tunEnable(p tunParams) (any, *contract.ErrorObj) {
	if ok, why := a.tunAvailable(); !ok {
		return nil, a.tunFail(contract.ErrTunUnavailable, "TUN 模式当前不可用", why)
	}
	snap := a.Store.Snapshot()
	if snap.TunState == state.TunEnabled {
		if a.backendAliveLocked() {
			return a.tunResult(snap), nil
		}
		// "Enabled" with no live backend is a stale record, most often left by
		// a service restart. Returning success here told the user TUN was on
		// while nothing carried traffic.
		a.Log.Writef("[host] TUN 记录为已启用但实际已失效，重新建立")
		a.releaseBackendLocked()
	}
	active := a.activeConfigPath()
	if active == "" {
		return nil, a.tunFail(contract.ErrConfigInvalid,
			"没有可用的配置", "请先应用节点或订阅，再启用 TUN")
	}
	base, err := os.ReadFile(active)
	if err != nil {
		return nil, a.tunFail(contract.ErrConfigInvalid,
			"无法读取当前配置", err.Error())
	}

	opts := tunconfig.DefaultOptions()
	if p.AdapterName != "" {
		opts.AdapterName = p.AdapterName
	}
	if p.Stack != "" {
		opts.Stack = p.Stack
	}
	if p.Address != "" {
		opts.Address = p.Address
	}
	if p.MTU != 0 {
		opts.MTU = p.MTU
	}
	if p.AutoRoute != nil {
		opts.AutoRoute = *p.AutoRoute
	}
	if p.StrictRoute != nil {
		opts.StrictRoute = *p.StrictRoute
	}
	runtimeJSON, errObj := a.buildTunConfig(base, opts)
	if errObj != nil {
		return nil, a.tunFail(errObj.Code, errObj.Message, errObj.Detail)
	}

	// The service is the only path: it stages a protected copy of the core and
	// the config, and the first enable installs it with one UAC prompt.
	serviceState, detail := a.ensureTunService()
	switch serviceState {
	case "ready":
		result, errObj := a.tunEnableViaService(a.tunServiceAPI, runtimeJSON, opts)
		if errObj == nil {
			a.tunTakesOverSystemProxy()
		}
		return result, errObj
	case "denied":
		return nil, a.tunFail(contract.ErrElevationDenied, "管理员授权被取消", detail)
	case "failed":
		return nil, a.tunFail(contract.ErrTunUnavailable, "TUN 服务不可用", detail)
	}
	// "absent": the service binary is missing from this layout. tunAvailable
	// normally caught that before the prompt, so this is a race, not a path.
	return nil, a.tunFail(contract.ErrTunUnavailable, "TUN 不可用",
		"当前目录缺少 "+filepath.Base(a.Paths.TunService)+"；请重新安装应用")
}

// tunEnableViaService starts the core through the installed service.
func (a *App) tunEnableViaService(client tunServiceAPI, runtimeJSON []byte, opts tunconfig.Options) (any, *contract.ErrorObj) {
	if errObj := a.writeTunConfig(runtimeJSON); errObj != nil {
		return nil, a.tunFail(errObj.Code, errObj.Message, errObj.Detail)
	}
	a.markTun(state.TunPending, "等待 TUN 服务启动内核", 0, "", false)
	if a.Supervisor.Running() {
		_ = a.Supervisor.Stop()
	}
	ctx, cancel := context.WithTimeout(context.Background(), a.tunWait())
	defer cancel()
	st, err := client.Start(ctx, a.tunRuntimeConfigPath(), os.Getpid())
	if err != nil {
		return nil, a.tunFail(contract.ErrTunUnavailable, "TUN 服务未能启动内核", err.Error())
	}
	if st.State != tunsup.StateRunning {
		return nil, a.tunFail(contract.ErrTunUnavailable, "TUN 内核启动失败", st.Message)
	}
	a.tunOptions = opts
	a.tunSession = true
	a.tunLostSince = time.Time{}
	a.markTunRunning(st)
	return a.tunResult(a.Store.Snapshot()), nil
}

// backendAliveLocked reports whether the service still has a live core. Caller
// holds tunMu.
func (a *App) backendAliveLocked() bool {
	if a.tunServiceAPI == nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 700*time.Millisecond)
	defer cancel()
	st, err := a.tunServiceAPI.Status(ctx)
	return err == nil && st.State == tunsup.StateRunning && a.tunCoreAlive(st.PID)
}

// releaseBackendLocked ends the service session without touching snapshot
// state. Caller holds tunMu.
func (a *App) releaseBackendLocked() {
	if a.tunServiceAPI != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_, _ = a.tunServiceAPI.Stop(ctx)
		cancel()
	}
	a.tunSession = false
	a.tunLostSince = time.Time{}
}

// buildTunConfig injects the tun inbound. It does not touch the disk.
func (a *App) buildTunConfig(base []byte, opts tunconfig.Options) ([]byte, *contract.ErrorObj) {
	runtimeJSON, err := tunconfig.Inject(base, opts)
	if err != nil {
		return nil, &contract.ErrorObj{Code: contract.ErrConfigInvalid, Message: "无法生成 TUN 配置", Detail: err.Error()}
	}
	// The user's log level is kept. Forcing INFO here made the elevated core
	// write two lines per proxied connection to tun-core.log; readiness is
	// detected from the adapter instead of from a log line.
	return runtimeJSON, nil
}

// writeTunConfig replaces the runtime document the service reads.
//
// The service stages its own protected copy and runs `sing-box check` there, so
// validating here would run the same ~1 MB check twice and delay the switch by
// about a second.
func (a *App) writeTunConfig(runtimeJSON []byte) *contract.ErrorObj {
	path := a.tunRuntimeConfigPath()
	candidate := path + ".candidate"
	defer os.Remove(candidate)
	if err := os.WriteFile(candidate, runtimeJSON, 0o600); err != nil {
		return &contract.ErrorObj{Code: contract.ErrInternal, Message: "无法写入 TUN 运行配置", Detail: err.Error()}
	}
	if err := os.Rename(candidate, path); err != nil {
		return &contract.ErrorObj{Code: contract.ErrInternal, Message: "无法替换 TUN 运行配置", Detail: err.Error()}
	}
	return nil
}

// reloadTunConfig hands the new runtime config to the service. The active base
// config is committed only after the new core is ready.
func (a *App) reloadTunConfig(config, candidate string, previousPID int) *contract.ErrorObj {
	return a.reloadTunViaService(config, candidate)
}

// reloadTunViaService asks the service for a new core. The service stops the
// old core first, so a failure here leaves no tunnel; tunFail restores the
// ordinary core and the old active config stays on disk.
func (a *App) reloadTunViaService(config, candidate string) *contract.ErrorObj {
	runtimeJSON, errObj := a.buildTunConfig([]byte(config), a.tunOptions)
	if errObj != nil {
		return errObj
	}
	if errObj := a.writeTunConfig(runtimeJSON); errObj != nil {
		return errObj
	}
	client, ok := a.tunServiceForStart()
	if !ok {
		return a.tunFail(contract.ErrConfigApply, "TUN 服务不可达", "无法重新加载 TUN 配置")
	}
	ctx, cancel := context.WithTimeout(context.Background(), a.tunWait())
	defer cancel()
	st, err := client.Start(ctx, a.tunRuntimeConfigPath(), os.Getpid())
	if err != nil {
		return a.tunFail(contract.ErrConfigApply, "重新加载 TUN 配置失败", err.Error())
	}
	if st.State != tunsup.StateRunning {
		return a.tunFail(contract.ErrConfigApply, "重新加载 TUN 配置失败", st.Message)
	}
	if err := a.promoteConfig(candidate); err != nil {
		return a.tunFail(contract.ErrConfigApply, "保存 TUN 配置失败", err.Error())
	}
	a.markTunRunning(st)
	a.Log.Writef("[host] tun service reloaded pid=%d adapter=%s", st.PID, st.Adapter)
	return nil
}

func (a *App) markTunRunning(st tunsup.Status) {
	a.markTun(state.TunEnabled, "TUN 已启用", st.PID, st.Adapter, st.Elevated)
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.CoreState = state.CoreRunning
		// The elevated core is not the supervisor's child, so corePid would be
		// a lie; tunPid already carries the real process id.
		s.CorePID = 0
		s.LastErrorCode = ""
		s.LastErrorMsg = ""
	})
	a.Log.Writef("[host] tun enabled adapter=%s pid=%d elevated=%v", st.Adapter, st.PID, st.Elevated)
}

func (a *App) tunDisable() (any, *contract.ErrorObj) {
	snap := a.Store.Snapshot()
	if snap.TunState == state.TunDisabled && !a.tunSession {
		return a.tunResult(snap), nil
	}
	if a.tunServiceAPI != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		_, err := a.tunServiceAPI.Stop(ctx)
		cancel()
		if err != nil {
			// The service's job object still kills the core if the service
			// itself is gone, so this is a diagnostic, not a stuck state.
			a.Log.Writef("[host] 停止 TUN 服务内核失败: %v", err)
		}
	}
	a.tunSession = false
	a.tunLostSince = time.Time{}
	a.markTun(state.TunDisabled, "", 0, "", false)
	a.restoreNormalCore()
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		if !a.Supervisor.Running() {
			s.CoreState = state.CoreStopped
			s.CorePID = 0
		}
	})
	a.Log.Writef("[host] tun disabled")
	return a.tunResult(a.Store.Snapshot()), nil
}

// shutdownTun stops TUN during host shutdown so a logout never leaves an
// elevated core behind.
func (a *App) shutdownTun() {
	a.tunMu.Lock()
	defer a.tunMu.Unlock()
	if !a.tunSession {
		return
	}
	a.Log.Writef("[host] 正在停止 TUN")
	if a.tunServiceAPI != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_, err := a.tunServiceAPI.Stop(ctx)
		cancel()
		if err != nil {
			a.Log.Writef("[host] 关闭 TUN 服务内核失败: %v", err)
		}
	}
	a.tunSession = false
	a.tunLostSince = time.Time{}
}
