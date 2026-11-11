package app

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/elevate"
	"clash-halo/native/windows/internal/state"
	"clash-halo/native/windows/internal/tunservice"
	"clash-halo/native/windows/internal/tunsup"
)

// newTunTestApp builds an app whose service binary exists.
//
// The service is never executed: every test injects a fake pipe client and
// stubs the elevated installer. The file only has to exist so tunAvailable
// reports the layout as installable.
func newTunTestApp(t *testing.T) *App {
	t.Helper()
	core := testCorePath(t)
	paths := DefaultPaths(t.TempDir(), core)
	paths.TunService = filepath.Join(t.TempDir(), "halo-tun-service.exe")
	if err := os.WriteFile(paths.TunService, []byte("fake"), 0o600); err != nil {
		t.Fatalf("stage service binary: %v", err)
	}
	a, err := New(paths, "test")
	if err != nil {
		t.Fatalf("app.New: %v", err)
	}
	a.tunInstalled = func() (tunservice.Config, bool) { return tunservice.Config{}, false }
	// The fake service reports the test process's pid, which is alive; tests
	// that need "the core died" replace this.
	a.tunAlive = func(pid int) bool { return pid != 0 }
	// Never touch the developer's real proxy registry from these tests.
	a.clearStaleProxy = func(string) (bool, error) { return false, nil }
	t.Cleanup(a.Shutdown)
	return a
}

// seedActiveConfig applies a config without starting a core, so TUN has
// something to inject a tun inbound into.
func seedActiveConfig(t *testing.T, a *App) {
	t.Helper()
	_, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config":    validConfig,
		"startCore": false,
	})
	if errObj != nil {
		t.Fatalf("seeding config failed: %v (%s)", errObj, errObj.Detail)
	}
}

func TestTunOfferedWhenServicePresent(t *testing.T) {
	a := newTunTestApp(t)
	snap := a.Store.Snapshot()
	if !snap.TunSupported {
		t.Fatal("TUN must be offered when the service binary is beside the core")
	}
	if snap.TunState != state.TunDisabled {
		t.Fatalf("tun state = %s, want disabled", snap.TunState)
	}
	if snap.TunMessage != "" {
		t.Fatalf("unexpected message on a healthy install: %q", snap.TunMessage)
	}
}

// Without the service binary there is no second elevated path: the switch must
// report why instead of offering an enable that can only fail.
func TestTunUnavailableWithoutServiceBinary(t *testing.T) {
	a := newTunTestApp(t)
	a.Paths.TunService = filepath.Join(t.TempDir(), "does-not-exist.exe")
	a.refreshTunSupport()
	snap := a.Store.Snapshot()
	if snap.TunSupported {
		t.Fatal("TUN must not be offered without the service binary")
	}
	if snap.TunState != state.TunUnsupported {
		t.Fatalf("tun state = %s, want unsupported", snap.TunState)
	}
	if !strings.Contains(snap.TunMessage, "服务程序") {
		t.Fatalf("message = %q, want the missing service named", snap.TunMessage)
	}
}

// Enabling with nothing to run must not cost the user a UAC prompt.
func TestTunEnableWithoutActiveConfigFailsBeforeInstall(t *testing.T) {
	a := newTunTestApp(t)
	a.runTunServiceInstallerFn = func([]string) (int, error) {
		t.Fatal("the installer was requested for a request that could not succeed")
		return 0, nil
	}
	_, errObj := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true})
	if errObj == nil {
		t.Fatal("enabling with no config must fail")
	}
	if errObj.Code != contract.ErrConfigInvalid {
		t.Fatalf("code = %s, want %s", errObj.Code, contract.ErrConfigInvalid)
	}
}

func TestTunEnableRejectsBadOptions(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	a.runTunServiceInstallerFn = func([]string) (int, error) {
		t.Fatal("the installer was requested for options that could not work")
		return 0, nil
	}
	for _, params := range []map[string]any{
		{"enabled": true, "stack": "definitely-not-a-stack"},
		{"enabled": true, "mtu": 100},
		{"enabled": true, "address": "not-a-cidr"},
		{"enabled": true, "adapterName": "bad|name"},
	} {
		_, errObj := request(t, a, contract.ActionTunSetEnabled, params)
		if errObj == nil {
			t.Fatalf("params %v must be refused", params)
		}
		if errObj.Code != contract.ErrConfigInvalid {
			t.Fatalf("params %v: code = %s", params, errObj.Code)
		}
	}
}

func TestTunEnableUsesService(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	a.tunServiceAPI = svc
	a.startElevated = func(string, []string) (*elevate.Process, error) {
		t.Fatal("the service path must not raise a UAC prompt")
		return nil, nil
	}

	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable failed: %v", e)
	}
	snap := a.Store.Snapshot()
	if snap.TunState != state.TunEnabled || snap.TunAdapter != "clash-halo-svc" || !snap.TunElevated {
		t.Fatalf("snapshot = %+v", snap)
	}
	if !a.tunSession {
		t.Fatal("a successful enable must mark the service session live")
	}
	if starts, _ := svc.counts(); starts != 1 {
		t.Fatalf("starts = %d", starts)
	}
	raw, err := os.ReadFile(a.tunRuntimeConfigPath())
	if err != nil || !strings.Contains(string(raw), `"type":"tun"`) {
		t.Fatalf("runtime config was not staged for the service: %v", err)
	}

	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": false}); e != nil {
		t.Fatalf("disable failed: %v", e)
	}
	if _, stops := svc.counts(); stops != 1 {
		t.Fatalf("stops = %d", stops)
	}
	if got := a.Store.Snapshot().TunState; got != state.TunDisabled {
		t.Fatalf("state = %s", got)
	}
	if a.tunSession {
		t.Fatal("a successful disable must clear the service session")
	}
}

// Shutting the host down must stop the elevated core, so logging out never
// leaves one behind.
func TestShutdownStopsTun(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	a.tunServiceAPI = svc
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable failed: %v", e)
	}
	a.shutdownTun()
	if _, stops := svc.counts(); stops != 1 {
		t.Fatalf("stops = %d, want the service asked to stop", stops)
	}
	if a.tunSession {
		t.Fatal("shutdown must clear the session")
	}
}

// A refused UAC prompt must not leave the user without a proxy.
//
// Enabling TUN stops the normal core first, so the failure path has to bring it
// back; otherwise declining the prompt would silently kill the user's proxy.
func TestRefusedPromptRestoresNormalCore(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	// The core is only restarted when the user is relying on the proxy, which a
	// live system proxy signals. Setting the flag directly keeps this test from
	// writing the real registry.
	_, _ = a.Store.Update(func(s *state.Snapshot) { s.SystemProxy.Enabled = true })

	svc := &fakeTunService{}
	svc.setReachable(false)
	a.tunServiceAPI = svc
	a.startElevated = func(string, []string) (*elevate.Process, error) {
		return nil, elevate.ErrCanceled
	}
	_, errObj := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true})
	if errObj == nil || errObj.Code != contract.ErrElevationDenied {
		t.Fatalf("error = %+v, want a refused authorization", errObj)
	}
	if !a.Supervisor.Running() {
		t.Fatal("the normal core was not restored, leaving the user with no proxy")
	}
}

// TUN is itself a traffic path: someone who used only TUN has the system proxy
// off, and ending TUN must still bring the core back when they had asked for a
// running core.
func TestShouldRestoreCore(t *testing.T) {
	a := newTunTestApp(t)
	if a.shouldRestoreCore(a.Store.Snapshot()) {
		t.Fatal("a fresh snapshot must not start a core")
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) { s.CoreWanted = true })
	if !a.shouldRestoreCore(a.Store.Snapshot()) {
		t.Fatal("coreWanted must be enough to restore the core")
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.CoreWanted = false
		s.SystemProxy.Enabled = true
	})
	if !a.shouldRestoreCore(a.Store.Snapshot()) {
		t.Fatal("an enabled system proxy must restore the core")
	}
}

// fakeTunService is the service side of the state machine without a pipe.
type fakeTunService struct {
	mu        sync.Mutex
	status    tunsup.Status
	starts    int
	stops     int
	configs   []string
	startErr  error
	pingErr   error
	statusErr error
	pingFail  bool
	pingHash  string
	// runtimeStale mimics a service installed before the core's companion files
	// were staged. The default reports the current set, so tests that do not
	// care about the upgrade path keep seeing a healthy service.
	runtimeStale bool
}

func (f *fakeTunService) Ping(context.Context) (tunservice.PingResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.pingErr != nil {
		return tunservice.PingResult{}, f.pingErr
	}
	if f.pingFail {
		return tunservice.PingResult{}, fmt.Errorf("no service")
	}
	runtime := tunservice.CoreRuntimeVersion
	if f.runtimeStale {
		runtime = tunservice.CoreRuntimeVersion - 1
	}
	return tunservice.PingResult{
		Protocol:    tunservice.ProtocolVersion,
		Version:     "test",
		CoreSHA256:  f.pingHash,
		CoreRuntime: runtime,
	}, nil
}

func (f *fakeTunService) Status(context.Context) (tunsup.Status, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.statusErr != nil {
		return tunsup.Status{}, f.statusErr
	}
	return f.status, nil
}

func (f *fakeTunService) Start(_ context.Context, configPath string, hostPID int) (tunsup.Status, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.startErr != nil {
		return tunsup.Status{}, f.startErr
	}
	f.starts++
	f.configs = append(f.configs, configPath)
	f.status = tunsup.Status{
		V: tunsup.StatusVersion, State: tunsup.StateRunning,
		PID: os.Getpid(), Adapter: "clash-halo-svc", Elevated: true,
		HostPID: hostPID, Message: "TUN 已启用",
	}
	return f.status, nil
}

func (f *fakeTunService) Stop(context.Context) (tunsup.Status, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stops++
	f.status = tunsup.Status{V: tunsup.StatusVersion, State: tunsup.StateStopped}
	return f.status, nil
}

func (f *fakeTunService) setReachable(reachable bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pingFail = !reachable
}

func (f *fakeTunService) setStatus(st tunsup.Status, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status, f.statusErr = st, err
}

func (f *fakeTunService) counts() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.starts, f.stops
}

func TestTunServiceReloadsOnNodeSelect(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	a.tunServiceAPI = svc
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	if _, e := request(t, a, contract.ActionNodeSelect, map[string]any{
		"config": validConfig + "\n", "nodeId": "new-node",
	}); e != nil {
		t.Fatalf("node select: %v", e)
	}
	if starts, _ := svc.counts(); starts != 2 {
		t.Fatalf("starts = %d, want the service to reload the core", starts)
	}
	if got := a.Store.Snapshot().TunState; got != state.TunEnabled {
		t.Fatalf("state = %s", got)
	}
}

func TestTunServiceFailureFoldsIntoSnapshot(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	a.tunServiceAPI = svc
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	svc.setStatus(tunsup.Status{
		V: tunsup.StatusVersion, State: tunsup.StateFailed, Message: "TUN 内核已退出",
	}, nil)
	_ = a.snapshot()
	snap := a.Store.Snapshot()
	if snap.TunState != state.TunFailed || snap.TunMessage != "TUN 内核已退出" {
		t.Fatalf("snapshot = %+v", snap)
	}
	if a.tunSession {
		t.Fatal("a failed tunnel must clear the service session")
	}
}

// A service restart is brief; a lost pipe must not flip the UI to failed
// immediately. A lasting loss must.
func TestTunServiceUnreachableIsToleratedThenFailed(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	a.tunServiceAPI = svc
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	svc.setStatus(tunsup.Status{}, fmt.Errorf("pipe gone"))
	_ = a.snapshot()
	if got := a.Store.Snapshot().TunState; got != state.TunEnabled {
		t.Fatalf("a brief outage flipped the state to %s", got)
	}
	// Simulate the outage having lasted past the grace period.
	a.tunLostSince = time.Now().Add(-16 * time.Second)
	_ = a.snapshot()
	snap := a.Store.Snapshot()
	if snap.TunState != state.TunFailed || !strings.Contains(snap.TunMessage, "不可达") {
		t.Fatalf("snapshot = %+v", snap)
	}
}

func TestTunServiceInstallInvokesInstaller(t *testing.T) {
	a := newTunTestApp(t)
	var got []string
	a.runTunServiceInstallerFn = func(args []string) (int, error) {
		got = args
		return 0, nil
	}
	if _, e := request(t, a, contract.ActionTunServiceInstall, nil); e != nil {
		t.Fatalf("install: %v", e)
	}
	joined := strings.Join(got, " ")
	for _, want := range []string{"--install", "--app-dir", "--data-dir"} {
		if !strings.Contains(joined, want) {
			t.Errorf("installer args missing %q: %v", want, got)
		}
	}
}

func TestTunServiceInstallRefusedWhileEnabled(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	a.tunServiceAPI = svc
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	defer a.tunDisable()
	if _, e := request(t, a, contract.ActionTunServiceInstall, nil); e == nil || e.Code != contract.ErrNotReady {
		t.Fatalf("install while TUN is enabled = %+v", e)
	}
}

func TestTunServiceUninstallStopsTunFirst(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	a.tunServiceAPI = svc
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	var got []string
	a.runTunServiceInstallerFn = func(args []string) (int, error) {
		got = args
		return 0, nil
	}
	if _, e := request(t, a, contract.ActionTunServiceUninstall, nil); e != nil {
		t.Fatalf("uninstall: %v", e)
	}
	if strings.Join(got, " ") != "--uninstall" {
		t.Fatalf("installer args = %v", got)
	}
	if _, stops := svc.counts(); stops != 1 {
		t.Fatalf("stops = %d; uninstall must stop the tunnel first", stops)
	}
	if got := a.Store.Snapshot().TunState; got != state.TunDisabled {
		t.Fatalf("state = %s", got)
	}
}

func TestTunServiceStatusReportsBackend(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	a.tunServiceAPI = &fakeTunService{}
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	payload, errObj := request(t, a, contract.ActionTunServiceStatus, nil)
	if errObj != nil {
		t.Fatalf("status: %v", errObj)
	}
	st, ok := payload.(tunServiceState)
	if !ok {
		t.Fatalf("payload type = %T", payload)
	}
	if st.Backend != "service" {
		t.Fatalf("backend = %q", st.Backend)
	}
}

// The first enable installs the service; the package installer does not. This
// is the one authorization the feature costs, and later enables reuse it.
func TestFirstTunEnableInstallsService(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	svc.setReachable(false)
	a.tunServiceAPI = svc
	installs := 0
	a.runTunServiceInstallerFn = func(args []string) (int, error) {
		installs++
		if !strings.Contains(strings.Join(args, " "), "--install") {
			t.Errorf("unexpected installer args: %v", args)
		}
		svc.setReachable(true)
		return 0, nil
	}

	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	if installs != 1 {
		t.Fatalf("installer ran %d times", installs)
	}
	if starts, _ := svc.counts(); starts != 1 {
		t.Fatalf("service starts = %d", starts)
	}
	if got := a.Store.Snapshot().TunState; got != state.TunEnabled {
		t.Fatalf("state = %s", got)
	}
	if !a.tunSession {
		t.Fatal("the service session was not recorded")
	}

	// Every later enable must not run the installer again.
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": false}); e != nil {
		t.Fatalf("disable: %v", e)
	}
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("second enable: %v", e)
	}
	if installs != 1 {
		t.Fatalf("installer ran again on the second enable: %d", installs)
	}
}

// A cancelled first-time authorization is a choice, not a failure to fall back
// from: asking again for the elevated installer would show two prompts for one
// action.
func TestFirstTunEnableCancelledKeepsTunOff(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{}
	svc.setReachable(false)
	a.tunServiceAPI = svc
	launches := 0
	a.startElevated = func(string, []string) (*elevate.Process, error) {
		launches++
		return nil, elevate.ErrCanceled
	}
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e == nil || e.Code != contract.ErrElevationDenied {
		t.Fatalf("error = %+v", e)
	}
	if launches != 1 {
		t.Fatalf("elevated launches = %d; the installer should have been the only elevation", launches)
	}
	if got := a.Store.Snapshot().TunState; got == state.TunEnabled {
		t.Fatal("a cancelled install must not report TUN as enabled")
	}
}

// A layout without the service binary must fail with a path to recover, not
// silently keep an elevated code path around.
func TestTunWithoutServiceBinaryIsUnavailable(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	a.Paths.TunService = filepath.Join(t.TempDir(), "does-not-exist.exe")
	_, errObj := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true})
	if errObj == nil || errObj.Code != contract.ErrTunUnavailable {
		t.Fatalf("error = %+v, want tun_unavailable", errObj)
	}
	if !strings.Contains(errObj.Detail, "重新安装") {
		t.Fatalf("detail = %q, want the recovery step", errObj.Detail)
	}
}

// An app update ships a new core. The installed service keeps its own approved
// copy, so the next enable has to refresh it with one authorization.
func TestTunServiceUpdatesWhenCoreChanges(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{pingHash: strings.Repeat("d", 64)}
	a.tunServiceAPI = svc
	installs := 0
	a.runTunServiceInstallerFn = func(args []string) (int, error) {
		installs++
		svc.pingHash = a.localCoreSHA256()
		return 0, nil
	}
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	if installs != 1 {
		t.Fatalf("installs = %d, want the service core refreshed", installs)
	}
	if got := a.Store.Snapshot().TunState; got != state.TunEnabled {
		t.Fatalf("state = %s", got)
	}
}

func TestTunServiceNotReinstalledWhenCoreMatches(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	svc := &fakeTunService{pingHash: a.localCoreSHA256()}
	a.tunServiceAPI = svc
	installs := 0
	a.runTunServiceInstallerFn = func(args []string) (int, error) {
		installs++
		return 0, nil
	}
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	if installs != 0 {
		t.Fatalf("installs = %d, want none", installs)
	}
}

// A service installed before the runtime files were staged has the right core
// but no libcronet.dll beside it. Its core hash still matches, so only the
// runtime version reveals the gap; without this the enable proceeded and the
// core failed at the first check with "cronet: library not found".
func TestTunServiceRefreshedWhenCoreRuntimeMissing(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	// Same core as the app, but a service from before the runtime was staged.
	svc := &fakeTunService{
		pingHash:     a.localCoreSHA256(),
		runtimeStale: true,
	}
	a.tunServiceAPI = svc
	installs := 0
	a.runTunServiceInstallerFn = func(args []string) (int, error) {
		installs++
		svc.mu.Lock()
		svc.runtimeStale = false
		svc.mu.Unlock()
		return 0, nil
	}
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable: %v", e)
	}
	if installs != 1 {
		t.Fatalf("installs = %d, want the missing runtime repaired", installs)
	}
	if got := a.Store.Snapshot().TunState; got != state.TunEnabled {
		t.Fatalf("state = %s", got)
	}
}

// While a tunnel is carrying traffic it owns the mixed inbound, so starting the
// ordinary core makes it fail to bind 127.0.0.1:7890 and exit after zero
// seconds. Observed seven times in a row, each reported to the user as a
// crashed proxy core while the tunnel was in fact working.
//
// This drives restoreNormalCore itself rather than the predicate: a predicate
// test passes with the guard removed from the caller, which is the bug.
func TestRestoreNormalCoreDeclinesWhileTunnelHoldsThePort(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)
	_, _ = a.Store.Update(func(s *state.Snapshot) { s.CoreWanted = true })

	starts := 0
	a.startNormalCore = func(string) (int, error) {
		starts++
		return 9000 + starts, nil
	}

	// No tunnel: the ordinary core is wanted and must be started.
	a.restoreNormalCore()
	if starts != 1 {
		t.Fatalf("starts = %d, want the core restored when no tunnel is up", starts)
	}

	// A live tunnel owns the port.
	a.tunServiceAPI = &fakeTunService{status: tunsup.Status{
		State: tunsup.StateRunning, PID: 4242, Adapter: "clash-halo",
	}}
	a.tunAlive = func(int) bool { return true }
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = state.TunEnabled
		s.TunPID = 4242
		s.CoreState = state.CoreStopped
		s.CorePID = 0
	})
	a.restoreNormalCore()
	if starts != 1 {
		t.Fatalf("starts = %d: the second core would fail to bind the port the tunnel holds", starts)
	}

	// Pending counts too: the service is already launching that core.
	_, _ = a.Store.Update(func(s *state.Snapshot) { s.TunState = state.TunPending })
	a.restoreNormalCore()
	if starts != 1 {
		t.Fatalf("starts = %d: a starting tunnel also holds the port", starts)
	}

	// A failed tunnel released it. Holding on here would leave the user with no
	// proxy at all after a refused authorization.
	a.tunServiceAPI = &fakeTunService{pingFail: true, statusErr: fmt.Errorf("gone")}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = state.TunFailed
		s.TunPID = 0
	})
	a.restoreNormalCore()
	if starts != 2 {
		t.Fatalf("starts = %d, want the core restored after the tunnel failed", starts)
	}
}

func TestTunClearsStaleSystemProxy(t *testing.T) {
	a := newTunTestApp(t)
	called := 0
	a.clearStaleProxy = func(endpoint string) (bool, error) {
		called++
		if endpoint != "127.0.0.1:7890" {
			t.Fatalf("endpoint = %q", endpoint)
		}
		return true, nil
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = state.TunEnabled
		s.SystemProxy = state.SystemProxy{
			Supported: true,
			Enabled:   false,
			Endpoint:  "127.0.0.1:7890",
		}
	})

	a.tunTakesOverSystemProxy()

	if called != 1 {
		t.Fatalf("clear calls = %d, want 1", called)
	}
	if a.Store.Snapshot().SystemProxy.Enabled {
		t.Fatal("stale proxy must be recorded as off")
	}
}

// One core runs, and both switches aim at it. Turning either on must turn the
// other off, or the UI claims two active traffic paths while one port is bound.
func TestSystemProxyAndTunAreMutuallyExclusive(t *testing.T) {
	a := newTunTestApp(t)
	seedActiveConfig(t, a)

	// Stand-in for the registry write: records that it ran, fails never.
	disabled := 0
	a.disableSystemProxy = func() (bool, *contract.ErrorObj) {
		disabled++
		_, _ = a.Store.Update(func(s *state.Snapshot) {
			s.SystemProxy.Enabled = false
			s.SystemProxy.Restorable = false
			s.SystemProxy.AppliedValue = ""
			s.SystemProxy.AppliedProxyEnable = 0
		})
		return true, nil
	}

	// Drive TUN through the in-process service stub: this machine may have a
	// real service installed, and a test must not depend on that.
	svc := &fakeTunService{}
	a.tunServiceAPI = svc
	a.runTunServiceInstallerFn = func([]string) (int, error) { return 0, nil }

	// --- TUN takes over from an enabled system proxy ---
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.SystemProxy = state.SystemProxy{
			Supported: true, Enabled: true, Restorable: true,
			Endpoint: "127.0.0.1:7890",
		}
	})
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true}); e != nil {
		t.Fatalf("enable TUN: %v", e)
	}
	if disabled != 1 {
		t.Fatalf("disableSystemProxy calls = %d, want the system proxy turned off once", disabled)
	}
	if a.Store.Snapshot().SystemProxy.Enabled {
		t.Fatal("TUN is up; the system proxy must not stay enabled")
	}

	// --- The system proxy takes over from TUN ---
	started := 0
	a.startNormalCore = func(string) (int, error) {
		started++
		return 7000 + started, nil
	}
	a.tunServiceAPI = nil
	if _, e := a.SetSystemProxy(true); e != nil {
		t.Fatalf("enable system proxy: %v", e)
	}
	snap := a.Store.Snapshot()
	if snap.TunState != state.TunDisabled {
		t.Fatalf("TUN state = %s, want it stopped when the system proxy is chosen", snap.TunState)
	}
	if !snap.SystemProxy.Enabled {
		t.Fatal("the system proxy was requested and must be on")
	}
}
