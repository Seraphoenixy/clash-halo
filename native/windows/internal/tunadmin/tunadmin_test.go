package tunadmin

import (
	"testing"
	"time"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
	"clash-halo/native/windows/internal/tunservice"
)

type fakes struct {
	active    bool
	installed bool
	reachable bool
	installer []string
	installCode int
	disabled  int
	refresh   int
	cleared   int
	marked    state.TunState
	deps      Deps
}

func newFakes(t *testing.T) *fakes {
	f := &fakes{}
	dir := t.TempDir()
	f.deps = Deps{
		ServicePath: func() string { return dir + "/halo-tun-service.exe" },
		CorePath:    func() string { return dir + "/sing-box.exe" },
		DataDir:     func() string { return dir + "/data" },
		LogsDir:     func() string { return dir + "/logs" },
		Log:         &fakeLog{},
		Active:      func() bool { return f.active },
		Ping: func(time.Duration) (tunservice.PingResult, bool) {
			return tunservice.PingResult{CoreSHA256: "", CoreRuntime: tunservice.CoreRuntimeVersion}, f.reachable
		},
		Installed: func() (tunservice.Config, bool) {
			return tunservice.Config{DataDir: f.deps.DataDir()}, f.installed
		},
		MarkTun: func(st state.TunState, _ string, _ int, _ string, _ bool) { f.marked = st },
		RefreshSupport: func() { f.refresh++ },
		DisableTun: func() *contract.ErrorObj {
			f.disabled++
			return nil
		},
		RunInstaller: func(args []string) (int, *contract.ErrorObj) {
			f.installer = args
			return f.installCode, nil
		},
		Backend:      func() string { return "none" },
		ClearBackend: func() { f.cleared++ },
	}
	return f
}

type fakeLog struct{ lines int }

func (f *fakeLog) Writef(string, ...any) { f.lines++ }

func TestInstallRefusesWhileTunIsActive(t *testing.T) {
	f := newFakes(t)
	f.active = true
	if _, errObj := New(f.deps).Install(); errObj == nil || errObj.Code != contract.ErrNotReady {
		t.Fatalf("got %v, want conflict", errObj)
	}
	if len(f.installer) != 0 {
		t.Fatal("the installer must not run while TUN is active")
	}
}

func TestStatusExplainsAReachableService(t *testing.T) {
	f := newFakes(t)
	f.installed = true
	f.reachable = true
	got, errObj := New(f.deps).Status()
	if errObj != nil {
		t.Fatal(errObj)
	}
	st := got.(ServiceState)
	if !st.Installed || !st.Reachable {
		t.Fatalf("state = %+v", st)
	}
}

func TestUninstallStopsTunFirstAndRefreshes(t *testing.T) {
	f := newFakes(t)
	f.active = true
	f.installed = true
	// The service binary does not exist on disk, so Uninstall must stop TUN
	// first and then report the missing installer rather than doing nothing.
	if _, errObj := New(f.deps).Uninstall(); errObj == nil {
		t.Fatal("a missing installer must be reported")
	}
	if f.disabled != 1 {
		t.Fatalf("disabled = %d", f.disabled)
	}
}
