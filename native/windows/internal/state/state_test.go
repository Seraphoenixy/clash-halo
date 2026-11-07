package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestOpenCreatesDefaults(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(filepath.Join(dir, "runtime.json"), "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	snap := s.Snapshot()
	if snap.CoreState != CoreStopped {
		t.Fatalf("core state = %s", snap.CoreState)
	}
	// Auto-launch must default off: starting the proxy at login without
	// consent is exactly what the plan forbids.
	if snap.AutoLaunch {
		t.Fatal("autoLaunch must default to false")
	}
	if snap.TunSupported {
		t.Fatal("TUN must not be advertised as supported")
	}
	if snap.SystemProxy.Enabled {
		t.Fatal("system proxy must default to off")
	}
	if snap.StateVersion != 1 {
		t.Fatalf("initial version = %d", snap.StateVersion)
	}
}

func TestUpdatePersistsAndBumpsVersion(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	s, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	var seen []Snapshot
	s.Subscribe(func(snap Snapshot) { seen = append(seen, snap) })
	next, err := s.Update(func(snap *Snapshot) {
		snap.CoreState = CoreRunning
		snap.CorePID = 42
		snap.ActiveNodeName = "香港 01"
	})
	if err != nil {
		t.Fatalf("persist failed: %v", err)
	}
	if next.StateVersion != 2 {
		t.Fatalf("version = %d", next.StateVersion)
	}
	if len(seen) != 1 || seen[0].CorePID != 42 {
		t.Fatalf("listener not notified correctly: %+v", seen)
	}
	// Reload from disk in a fresh store.
	s2, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	if got := s2.Snapshot(); got.ActiveNodeName != "香港 01" || got.StateVersion != 2 {
		t.Fatalf("reloaded snapshot = %+v", got)
	}
	// A previously running core is not trusted after a restart.
	if s2.Snapshot().CoreState != CoreStopped || s2.Snapshot().CorePID != 0 {
		t.Fatalf("stale running state must not survive: %+v", s2.Snapshot())
	}
}

func TestCorruptSnapshotIsQuarantinedNotFatal(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatalf("corrupt snapshot must not be fatal: %v", err)
	}
	if s.Snapshot().CoreState != CoreStopped {
		t.Fatal("must fall back to stopped")
	}
	if s.Snapshot().SystemProxy.Enabled {
		t.Fatal("must not claim a proxy write we cannot prove")
	}
	entries, _ := os.ReadDir(dir)
	found := false
	for _, e := range entries {
		if filepath.Ext(e.Name()) != ".json" {
			found = true
		}
	}
	if !found {
		t.Fatal("corrupt file should be preserved for diagnosis")
	}
}

func TestSystemProxyRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	s, _ := Open(path, "1.0.0", "sing-box.exe")
	_, err := s.Update(func(snap *Snapshot) {
		snap.SystemProxy = SystemProxy{
			Supported: true, Enabled: true, Restorable: true,
			Endpoint: "127.0.0.1:7890", AppliedValue: "127.0.0.1:7890",
			AppliedProxyEnable: 1, PreviousValue: "proxy.corp:8080", PreviousEnable: 1,
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	s2, _ := Open(path, "1.0.0", "sing-box.exe")
	got := s2.Snapshot().SystemProxy
	// Restore metadata must survive, because it is the only record of what
	// the user had before us.
	if got.PreviousValue != "proxy.corp:8080" || got.PreviousEnable != 1 {
		t.Fatalf("previous proxy state lost: %+v", got)
	}
}

func TestSnapshotJSONFieldNames(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(filepath.Join(dir, "r.json"), "1.0.0", "sing-box.exe")
	b, err := json.Marshal(s.Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	// These names are read by Dart; a rename here silently breaks the UI.
	for _, key := range []string{
		"stateVersion", "coreState", "corePid", "activeNodeId", "activeNodeName",
		"mode", "configVersion", "configHash", "systemProxy", "tunState",
		"tunSupported", "autoLaunch", "coreWanted", "hostVersion", "singboxPath",
		"logBytes",
	} {
		if _, ok := m[key]; !ok {
			t.Fatalf("snapshot missing %q", key)
		}
	}
}

func TestConcurrentUpdatesRaceFree(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(filepath.Join(dir, "r.json"), "1.0.0", "sing-box.exe")
	done := make(chan struct{})
	for i := 0; i < 8; i++ {
		go func(i int) {
			defer func() { done <- struct{}{} }()
			for j := 0; j < 20; j++ {
				_, _ = s.Update(func(snap *Snapshot) { snap.CoreRestarts = i*20 + j })
			}
		}(i)
	}
	for i := 0; i < 8; i++ {
		<-done
	}
	if s.StateVersion() < 100 {
		t.Fatalf("version = %d, expected >= 100", s.StateVersion())
	}
}

// The core's *intent* has to survive a restart even though its *state* must not.
//
// These two facts used to be conflated: load() reset coreState to stopped (a
// dead process must not be reported as live) and threw away the only evidence
// that the user wanted a proxy, so every launch began with the core off.
func TestCoreWantedSurvivesRestartWhileStateDoesNot(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	s, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(func(snap *Snapshot) {
		snap.CoreWanted = true
		snap.CoreState = CoreRunning
		snap.CorePID = 99
	}); err != nil {
		t.Fatal(err)
	}

	s2, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	got := s2.Snapshot()
	if got.CoreState != CoreStopped || got.CorePID != 0 {
		t.Fatalf("a restarted host must not claim a live core: %+v", got)
	}
	if !got.CoreWanted {
		t.Fatal("the intent to run was lost across the restart")
	}
}

// An explicit stop must stay stopped. This is the difference between "the host
// restarted" and "the user turned it off".
func TestExplicitStopClearsCoreWanted(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	s, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(func(snap *Snapshot) { snap.CoreWanted = false }); err != nil {
		t.Fatal(err)
	}
	s2, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	if s2.Snapshot().CoreWanted {
		t.Fatal("a core the user stopped must not come back on its own")
	}
}

// A snapshot written before the field existed carries no intent. Adopting
// "it was running" is what keeps an upgrade from silently disabling the restore
// for every existing user; a file that *does* say false is respected, which is
// what the previous test pins.
func TestLegacySnapshotWithoutCoreWantedInfersIntent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	legacy := `{"stateVersion":7,"coreState":"running","corePid":123,"mode":"rule"}`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	got := s.Snapshot()
	if !got.CoreWanted {
		t.Fatal("a legacy snapshot that was running should imply the intent to run")
	}
	if got.CoreState != CoreStopped {
		t.Fatalf("the state must still be reset: %+v", got)
	}
}

// And a legacy snapshot that was already stopped must not invent intent.
func TestLegacyStoppedSnapshotDoesNotWantCore(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	legacy := `{"stateVersion":7,"coreState":"stopped","mode":"rule"}`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	if s.Snapshot().CoreWanted {
		t.Fatal("a legacy snapshot that was stopped must not want a core")
	}
}

// A clean shutdown stops the core and persists coreState=stopped, so an install
// that was proxying happily right up to an upgrade looks the same as one where
// the user pressed stop. An applied config is what tells them apart: without
// this rule the restore step would silently stay off for everyone who upgraded.
func TestLegacyCleanShutdownWithAppliedConfigStillWantsCore(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	legacy := `{"stateVersion":12,"coreState":"stopped","corePid":0,` +
		`"configVersion":4,"configHash":"abc123","mode":"rule"}`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	if !s.Snapshot().CoreWanted {
		t.Fatal("an install with an applied config should want its core back")
	}
}

// An explicit false must survive, even with an applied config: the user pressed
// stop and the upgrade must not interpret that as "they forgot".
func TestExplicitCoreWantedFalseOverridesAppliedConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	current := `{"stateVersion":13,"coreState":"stopped","coreWanted":false,` +
		`"configVersion":4,"configHash":"abc123"}`
	if err := os.WriteFile(path, []byte(current), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(path, "1.0.0", "sing-box.exe")
	if err != nil {
		t.Fatal(err)
	}
	if s.Snapshot().CoreWanted {
		t.Fatal("an explicit stop must not be overridden by the migration rule")
	}
}
