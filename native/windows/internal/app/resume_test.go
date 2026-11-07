package app

import (
	"testing"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
)

// resumeConfig is a real, working config: the resume path must be proven against
// a core that actually starts, not against a file that merely exists.
const resumeConfig = `{
  "log": {"level": "warn"},
  "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 17896}],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}`

// The bug this pins: every host launch began with the core off, even though the
// user had applied a node and never asked for a stop. Nothing in the snapshot
// recorded the intent, so there was nothing to resume from.
func TestResumeCoreStartsWhatWasRunningLastSession(t *testing.T) {
	a := newTestApp(t)
	if _, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config":    resumeConfig,
		"startCore": false,
	}); errObj != nil {
		t.Fatalf("apply failed: %v", errObj)
	}

	// Simulate what a restart does to the snapshot while keeping the intent.
	if _, err := a.Store.Update(func(s *state.Snapshot) {
		s.CoreState = state.CoreStopped
		s.CorePID = 0
		s.CoreWanted = true
	}); err != nil {
		t.Fatal(err)
	}

	a.ResumeCore()
	snap := a.Store.Snapshot()
	if snap.CoreState != state.CoreRunning || snap.CorePID == 0 {
		t.Fatalf("core was not resumed: %+v", snap)
	}
	if !a.Supervisor.Running() {
		t.Fatal("supervisor does not agree that the core is running")
	}
	// The whole point of the fix: the core comes back, the system proxy does not.
	if snap.SystemProxy.Enabled {
		t.Fatal("resuming the core must not turn the system proxy on")
	}
}

// A core the user stopped must stay stopped. Restoring it would make the stop
// button look broken: the next launch would undo the instruction.
func TestResumeCoreDoesNothingWhenNotWanted(t *testing.T) {
	a := newTestApp(t)
	if _, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config":    resumeConfig,
		"startCore": false,
	}); errObj != nil {
		t.Fatalf("apply failed: %v", errObj)
	}
	if _, err := a.Store.Update(func(s *state.Snapshot) { s.CoreWanted = false }); err != nil {
		t.Fatal(err)
	}

	a.ResumeCore()
	if a.Supervisor.Running() {
		t.Fatal("an unwanted core was started anyway")
	}
}

// stopping the core has to clear the intent, or the next launch resurrects it.
func TestCoreStopClearsResumeIntent(t *testing.T) {
	a := newTestApp(t)
	if _, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config":    resumeConfig,
		"startCore": true,
	}); errObj != nil {
		t.Fatalf("apply failed: %v (%s)", errObj, errObj.Detail)
	}
	if !a.Store.Snapshot().CoreWanted {
		t.Fatal("applying a config that starts the core should record the intent")
	}
	if _, errObj := request(t, a, contract.ActionCoreStop, nil); errObj != nil {
		t.Fatalf("stop failed: %v", errObj)
	}
	if a.Store.Snapshot().CoreWanted {
		t.Fatal("an explicit stop must clear the intent, or the core comes back")
	}
}

// If a config that *used* to exist is gone, resume says so instead of failing
// silently and leaving the UI to explain a core that never appears.
func TestResumeCoreReportsMissingConfig(t *testing.T) {
	a := newTestApp(t)
	if _, err := a.Store.Update(func(s *state.Snapshot) {
		s.CoreWanted = true
		// Evidence that a config really was applied once. Without this the
		// situation is a fresh install, which is covered by the next test.
		s.ConfigVersion = 3
		s.ConfigHash = "deadbeef"
	}); err != nil {
		t.Fatal(err)
	}
	a.ResumeCore()
	snap := a.Store.Snapshot()
	if snap.CoreState == state.CoreRunning {
		t.Fatalf("a core without a config must not claim to be running: %+v", snap)
	}
	if snap.LastErrorCode != contract.ErrConfigInvalid {
		t.Fatalf("expected a config_invalid explanation, got %q (%q)",
			snap.LastErrorCode, snap.LastErrorMsg)
	}
}

// A fresh install has no config because none was ever made. Reporting
// "配置已不存在" there would be an error the user cannot act on, on the very
// first launch, before they have done anything wrong.
func TestResumeCoreIsQuietWhenNothingWasEverApplied(t *testing.T) {
	a := newTestApp(t)
	if _, err := a.Store.Update(func(s *state.Snapshot) { s.CoreWanted = true }); err != nil {
		t.Fatal(err)
	}
	a.ResumeCore()
	snap := a.Store.Snapshot()
	if snap.CoreState == state.CoreRunning {
		t.Fatalf("nothing to run: %+v", snap)
	}
	if snap.LastErrorCode != "" {
		t.Fatalf("a first launch must not report a missing config: %q (%q)",
			snap.LastErrorCode, snap.LastErrorMsg)
	}
}

// The settings toggle is not a kill switch: turning it off must leave a running
// core alone and only change what happens next launch.
func TestCoreResumeSetDoesNotTouchTheRunningCore(t *testing.T) {
	a := newTestApp(t)
	if _, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config":    resumeConfig,
		"startCore": true,
	}); errObj != nil {
		t.Fatalf("apply failed: %v (%s)", errObj, errObj.Detail)
	}
	if !a.Supervisor.Running() {
		t.Fatal("precondition: the core should be running")
	}

	if _, errObj := request(t, a, contract.ActionCoreResumeSet, map[string]any{
		"enabled": false,
	}); errObj != nil {
		t.Fatalf("coreResume.set failed: %v", errObj)
	}
	if !a.Supervisor.Running() {
		t.Fatal("turning the setting off must not stop the core that is already up")
	}
	if a.Store.Snapshot().CoreWanted {
		t.Fatal("the setting should be recorded as off")
	}
}
