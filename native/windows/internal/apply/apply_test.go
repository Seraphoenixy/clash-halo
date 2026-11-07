package apply

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
)

type fakeConfigs struct {
	candidate string
	hash      string
	candErr   *contract.ErrorObj
	active    string
	current   string
	promoted  int
	version   int
}

func (f *fakeConfigs) Candidate(string, string) (string, string, *contract.ErrorObj) {
	if f.candErr != nil {
		return "", "", f.candErr
	}
	return f.candidate, f.hash, nil
}

func (f *fakeConfigs) Promote(string) error {
	f.promoted++
	f.current = f.candidate
	return nil
}

func (f *fakeConfigs) ActivePath() string  { return f.active }
func (f *fakeConfigs) CurrentPath() string { return f.current }
func (f *fakeConfigs) Hash() string        { return "old" }
func (f *fakeConfigs) Version() int        { return f.version }

func (f *fakeConfigs) SetVersion(_ string, v int) { f.version = v }

type fakeStore struct{ snap state.Snapshot }

func (f *fakeStore) Snapshot() state.Snapshot { return f.snap }

func (f *fakeStore) Update(fn func(*state.Snapshot)) (state.Snapshot, error) {
	fn(&f.snap)
	return f.snap, nil
}

type fakeSupervisor struct {
	running bool
	pid     int
	startErr error
	stops   int
	starts  int
}

func (f *fakeSupervisor) Start(string) (int, error) {
	f.starts++
	if f.startErr != nil {
		return 0, f.startErr
	}
	f.running = true
	return f.pid, nil
}

func (f *fakeSupervisor) Stop() error {
	f.stops++
	f.running = false
	return nil
}

func (f *fakeSupervisor) Running() bool { return f.running }
func (f *fakeSupervisor) Pid() int      { return f.pid }

type fakeLog struct{ lines int }

func (f *fakeLog) Writef(string, ...any) { f.lines++ }

type fakeRedactor struct{ secrets []string }

func (f *fakeRedactor) Set(secrets ...string) { f.secrets = secrets }

type harness struct {
	configs *fakeConfigs
	store   *fakeStore
	super   *fakeSupervisor
	deps    Deps
	health  error
	validate error
	rollbacks int
	repointed int
	reloadCalls int
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dir := t.TempDir()
	candidate := filepath.Join(dir, "candidate.json")
	if err := os.WriteFile(candidate, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := &harness{
		configs: &fakeConfigs{candidate: candidate, hash: strings.Repeat("a", 64), active: "previous", version: 2},
		store:   &fakeStore{},
		super:   &fakeSupervisor{pid: 99},
	}
	h.deps = Deps{
		Configs:    h.configs,
		Store:      h.store,
		Supervisor: h.super,
		Log:        &fakeLog{},
		Redactor:   &fakeRedactor{},
		CorePath:   "sing-box.exe",
		ReconcileTun: func() {},
		ReloadTun: func(string, string, int) *contract.ErrorObj {
			h.reloadCalls++
			return nil
		},
		Validate: func(string, string) error { return h.validate },
		Rollback: func(string, string, int) error {
			h.rollbacks++
			return nil
		},
		HealthCheck: func(string, string) error { return h.health },
		RepointSystemProxy: func(string) { h.repointed++ },
	}
	return h
}

func TestApplyRejectsAnEmptyConfig(t *testing.T) {
	h := newHarness(t)
	_, errObj := New(h.deps).Apply(Params{Config: "  "})
	if errObj == nil || errObj.Code != contract.ErrBadRequest {
		t.Fatalf("got %v", errObj)
	}
}

func TestApplyPromotesStartsAndCommits(t *testing.T) {
	h := newHarness(t)
	_, errObj := New(h.deps).Apply(Params{Config: "{}", ConfigHash: h.configs.hash})
	if errObj != nil {
		t.Fatalf("Apply: %v", errObj)
	}
	if h.configs.promoted != 1 || h.super.starts != 1 || h.repointed != 1 {
		t.Fatalf("promoted=%d starts=%d repointed=%d", h.configs.promoted, h.super.starts, h.repointed)
	}
	if h.configs.version != 3 {
		t.Fatalf("version = %d, want previous+1", h.configs.version)
	}
	if h.store.snap.ConfigHash == "" || h.store.snap.CoreState != state.CoreRunning {
		t.Fatalf("snapshot = %+v", h.store.snap)
	}
}

func TestApplyValidationFailureLeavesTheLiveConfigAlone(t *testing.T) {
	h := newHarness(t)
	h.validate = errors.New("bad config")
	_, errObj := New(h.deps).Apply(Params{Config: "{}"})
	if errObj == nil || errObj.Code != contract.ErrConfigInvalid {
		t.Fatalf("got %v", errObj)
	}
	if h.configs.promoted != 0 || h.super.starts != 0 {
		t.Fatal("a rejected config must not be promoted or started")
	}
}

func TestApplyStartFailureRollsBack(t *testing.T) {
	h := newHarness(t)
	h.super.startErr = errors.New("bind failed")
	_, errObj := New(h.deps).Apply(Params{Config: "{}"})
	if errObj == nil || errObj.Code != contract.ErrConfigApply {
		t.Fatalf("got %v", errObj)
	}
	if h.rollbacks != 1 {
		t.Fatalf("rollbacks = %d", h.rollbacks)
	}
}

func TestApplyHealthFailureStopsAndRollsBack(t *testing.T) {
	h := newHarness(t)
	h.health = errors.New("no controller")
	_, errObj := New(h.deps).Apply(Params{Config: "{}"})
	if errObj == nil || errObj.Code != contract.ErrHealthCheck {
		t.Fatalf("got %v", errObj)
	}
	if h.super.stops == 0 || h.rollbacks != 1 {
		t.Fatalf("stops=%d rollbacks=%d", h.super.stops, h.rollbacks)
	}
}

func TestApplyInTunModeReloadsInsteadOfPromoting(t *testing.T) {
	h := newHarness(t)
	h.store.snap.TunState = state.TunEnabled
	_, errObj := New(h.deps).Apply(Params{Config: "{}", StartCore: boolPtr(true)})
	if errObj != nil {
		t.Fatalf("Apply: %v", errObj)
	}
	if h.reloadCalls != 1 {
		t.Fatalf("reloadCalls = %d", h.reloadCalls)
	}
	if h.configs.promoted != 0 || h.super.starts != 0 {
		t.Fatal("the TUN path must not promote or start the normal core")
	}
}

func boolPtr(v bool) *bool { return &v }
