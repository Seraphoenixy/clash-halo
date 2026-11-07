package corelife

import (
	"errors"
	"testing"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/core"
	"clash-halo/native/windows/internal/state"
)

type fakeSupervisor struct {
	startPID   int
	startErr   error
	stopErr    error
	starts     int
	stops      int
	lastExit   string
	backoff    int
	lastConfig string
}

func (f *fakeSupervisor) Start(configPath string) (int, error) {
	f.starts++
	f.lastConfig = configPath
	return f.startPID, f.startErr
}

func (f *fakeSupervisor) Stop() error {
	f.stops++
	return f.stopErr
}

func (f *fakeSupervisor) LastExit() string { return f.lastExit }

func (f *fakeSupervisor) ResetBackoff() { f.backoff++ }

type fakeStore struct {
	snap    state.Snapshot
	updates int
}

func (f *fakeStore) Snapshot() state.Snapshot { return f.snap }

func (f *fakeStore) Update(fn func(*state.Snapshot)) (state.Snapshot, error) {
	fn(&f.snap)
	f.updates++
	return f.snap, nil
}

type fakeConfigs struct{ path string }

func (f fakeConfigs) ActivePath() string { return f.path }

type fakeLog struct{ lines int }

func (f *fakeLog) Writef(string, ...any) { f.lines++ }

func newLife(sup *fakeSupervisor, store *fakeStore, configs fakeConfigs, tun bool) *Lifecycle {
	return New(sup, store, configs, &fakeLog{}, func() bool { return tun })
}

func TestStartUpdatesTheSnapshot(t *testing.T) {
	sup := &fakeSupervisor{startPID: 4242}
	store := &fakeStore{}
	life := newLife(sup, store, fakeConfigs{path: `C:\cfg\active.json`}, false)

	got, errObj := life.Start()
	if errObj != nil {
		t.Fatalf("Start: %v", errObj)
	}
	if got.(map[string]any)["corePid"] != 4242 {
		t.Fatalf("result = %v", got)
	}
	if store.snap.CoreState != state.CoreRunning || store.snap.CorePID != 4242 || !store.snap.CoreWanted {
		t.Fatalf("snapshot = %+v", store.snap)
	}
	if sup.lastConfig == "" {
		t.Fatal("the active config was not passed to the supervisor")
	}
}

func TestStartIsRefusedWhileTunOwnsTheMachine(t *testing.T) {
	sup := &fakeSupervisor{}
	life := newLife(sup, &fakeStore{}, fakeConfigs{path: "x"}, true)

	_, errObj := life.Start()
	if errObj == nil || errObj.Code != contract.ErrCoreAlreadyRunning {
		t.Fatalf("got %v, want already_running", errObj)
	}
	if sup.starts != 0 {
		t.Fatal("the supervisor must not be started while TUN is enabled")
	}
}

func TestStartFailureMarksTheCoreFailed(t *testing.T) {
	sup := &fakeSupervisor{startErr: errors.New("boom")}
	store := &fakeStore{}
	life := newLife(sup, store, fakeConfigs{path: "x"}, false)

	_, errObj := life.Start()
	if errObj == nil || errObj.Code != contract.ErrConfigApply {
		t.Fatalf("got %v", errObj)
	}
	if store.snap.CoreState != state.CoreFailed || store.snap.LastErrorCode != contract.ErrConfigApply {
		t.Fatalf("snapshot = %+v", store.snap)
	}
}

func TestStartAlreadyRunningIsNotAnErrorState(t *testing.T) {
	sup := &fakeSupervisor{startErr: core.ErrAlreadyRunning}
	store := &fakeStore{}
	life := newLife(sup, store, fakeConfigs{path: "x"}, false)

	_, errObj := life.Start()
	if errObj == nil || errObj.Code != contract.ErrCoreAlreadyRunning {
		t.Fatalf("got %v", errObj)
	}
	if store.updates != 0 {
		t.Fatalf("already running must not write a failure state (%d updates)", store.updates)
	}
}

func TestStopClearsTheWantedFlag(t *testing.T) {
	sup := &fakeSupervisor{}
	store := &fakeStore{}
	life := newLife(sup, store, fakeConfigs{}, false)

	if _, errObj := life.Stop(); errObj != nil {
		t.Fatalf("Stop: %v", errObj)
	}
	if store.snap.CoreState != state.CoreStopped || store.snap.CoreWanted {
		t.Fatalf("snapshot = %+v", store.snap)
	}
}

func TestStopWhenNotRunningIsReported(t *testing.T) {
	sup := &fakeSupervisor{stopErr: core.ErrNotRunning}
	life := newLife(sup, &fakeStore{}, fakeConfigs{}, false)

	_, errObj := life.Stop()
	if errObj == nil || errObj.Code != contract.ErrCoreNotRunning {
		t.Fatalf("got %v", errObj)
	}
}

func TestResumeRespectsIntentAndMissingConfig(t *testing.T) {
	t.Run("not wanted", func(t *testing.T) {
		sup := &fakeSupervisor{}
		life := newLife(sup, &fakeStore{}, fakeConfigs{path: "x"}, false)
		life.Resume()
		if sup.starts != 0 {
			t.Fatal("a core the user stopped must stay stopped")
		}
	})

	t.Run("wanted and configured", func(t *testing.T) {
		sup := &fakeSupervisor{startPID: 7}
		store := &fakeStore{snap: state.Snapshot{CoreWanted: true}}
		life := newLife(sup, store, fakeConfigs{path: "x"}, false)
		life.Resume()
		if sup.starts != 1 || store.snap.CorePID != 7 {
			t.Fatalf("starts=%d snapshot=%+v", sup.starts, store.snap)
		}
	})

	t.Run("wanted but config deleted", func(t *testing.T) {
		sup := &fakeSupervisor{}
		store := &fakeStore{snap: state.Snapshot{CoreWanted: true, ConfigVersion: 3}}
		life := newLife(sup, store, fakeConfigs{}, false)
		life.Resume()
		if sup.starts != 0 {
			t.Fatal("a missing config must not start anything")
		}
		if store.snap.LastErrorCode != contract.ErrConfigInvalid {
			t.Fatalf("snapshot = %+v", store.snap)
		}
	})
}
