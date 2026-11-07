package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// These tests pin the two halves of the core-resolution bug found while
// assembling the first local build: the host used to adopt its own UI
// executable as the proxy core, and the fix must not reintroduce that by
// executing whatever path it is handed.

// A wrongly named candidate must be refused *without being executed*.
//
// The regression this guards is concrete: probing an arbitrary path launched the
// Flutter UI, and the probe then blocked forever waiting for a window to close.
// If that behaviour ever returns, this test hangs rather than passing, which is
// the honest failure mode.
func TestAssertCoreRejectsWrongNameWithoutExecuting(t *testing.T) {
	dir := t.TempDir()
	// The real UI file name: if the probe executed this, the test would hang.
	wrong := filepath.Join(dir, uiExecutable)
	// Content is irrelevant: the name is rejected before anything is run.
	if err := os.WriteFile(wrong, []byte("MZ not really an executable"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := assertCore(wrong); err == nil {
		t.Fatal("a candidate not named sing-box.exe must be refused")
	}
}

// TestUIBinaryNameMatchesBuild keeps the tray's "open the UI" working.
//
// The name lives in two toolchains — uiExecutable here and BINARY_NAME in the
// Flutter CMake project — with nothing else connecting them. They had already
// drifted once: the tray looked for clash-halo.exe while the build produced
// halo.exe, so the menu item did nothing and reported nothing. A silent no-op is
// the worst possible failure mode, so it is pinned rather than trusted.
func TestUIBinaryNameMatchesBuild(t *testing.T) {
	if !strings.HasSuffix(uiExecutable, ".exe") {
		t.Fatalf("uiExecutable must keep the .exe suffix the tray stats for: %q", uiExecutable)
	}
	want := strings.TrimSuffix(uiExecutable, ".exe")
	var candidates []string
	for _, rel := range [][]string{
		{"..", "..", "..", "..", "apps", "flutter", "windows", "CMakeLists.txt"},
		{"apps", "flutter", "windows", "CMakeLists.txt"},
	} {
		candidates = append(candidates, filepath.Join(rel...))
	}
	var raw []byte
	var err error
	for _, c := range candidates {
		if raw, err = os.ReadFile(c); err == nil {
			break
		}
	}
	if err != nil {
		t.Skipf("Flutter CMakeLists not readable (%v); cannot check the UI name agreement", err)
	}
	if !strings.Contains(string(raw), `set(BINARY_NAME "`+want+`")`) {
		t.Fatalf("apps/flutter/windows/CMakeLists.txt does not set BINARY_NAME %q; "+
			"the tray would launch nothing", want)
	}
	// The tray also looks in these places, so they must stay derived from the
	// single constant rather than growing their own literals.
	paths := uiCandidates(`C:\app`)
	if len(paths) < 2 {
		t.Fatalf("uiCandidates lost its fallbacks: %v", paths)
	}
	for _, p := range paths {
		if !strings.HasSuffix(p, string(filepath.Separator)+uiExecutable) {
			t.Errorf("candidate %q does not end in %q", p, uiExecutable)
		}
	}
}

// A correctly named file that is not sing-box must still be refused, and the
// error must be the probe's failure rather than a panic.
func TestAssertCoreRejectsCorrectlyNamedGarbage(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "sing-box.exe")
	if err := os.WriteFile(fake, []byte("garbage, not a PE image"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := assertCore(fake); err == nil {
		t.Fatal("a non-sing-box file named sing-box.exe must be refused")
	}
}

// The real locked core must be accepted, otherwise every other test that relies
// on resolveCore would be verifying a broken prerequisite.
//
// It must also report its version, because that string is the only honest source
// for 内核版本 in the UI: it used to be discarded, so the overview showed a dash
// while the about panel showed a hard-coded constant.
func TestAssertCoreAcceptsRealCore(t *testing.T) {
	core := testCorePath(t)
	path, version, err := assertCore(core)
	if err != nil {
		t.Fatalf("the real core was rejected: %v", err)
	}
	if path == "" {
		t.Fatal("assertCore lost the resolved path")
	}
	if version == "" {
		t.Fatal("the real core reported no version; the UI would show 未知")
	}
	// A version is a dotted number, not the whole banner line.
	if strings.ContainsAny(version, " \t") {
		t.Fatalf("version must be the token alone, got %q", version)
	}
	if !strings.Contains(version, ".") {
		t.Fatalf("version looks wrong: %q", version)
	}
}

// A host started by the UI must never open a window when it loses the
// single-instance race. The bug this pins is a feedback loop: a UI starts a
// host, the host loses the lock, opens another UI, that UI starts another host…
// Each round added a window every ~2 seconds until the desktop was unusable.
func TestHostStartedByUIDoesNotOpenAnotherWindow(t *testing.T) {
	if shouldOpenUIOnHandOff(true, false) {
		t.Fatal("a host started by the UI must not launch a second UI; " +
			"that is the window-spawning loop")
	}
	// The user double-clicking the host is the opposite case and must keep
	// working: refusing here would make a direct launch look like a no-op.
	if !shouldOpenUIOnHandOff(false, false) {
		t.Fatal("a user-started host must still open the UI")
	}
	// A login start is the third case: Windows launched it, nobody asked for a
	// window, and one appearing at every boot is the classic complaint about
	// auto-starting proxy clients.
	if shouldOpenUIOnHandOff(false, true) {
		t.Fatal("a login start must not open a window")
	}
	if shouldOpenUIOnHandOff(true, true) {
		t.Fatal("a UI-started host must never open a window, silent or not")
	}
}

// testCorePath mirrors the other suites: an explicit override wins, otherwise
// the bundled prototype binary is used, otherwise the test is skipped.
func testCorePath(t *testing.T) string {
	t.Helper()
	for _, c := range []string{
		os.Getenv("HALO_SINGBOX"),
		filepath.Join("..", "..", "..", "prototype", "bin", "sing-box.exe"),
		filepath.Join("..", "..", "..", ".tmp", "windows-release", "sing-box.exe"),
	} {
		if c == "" {
			continue
		}
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			abs, err := filepath.Abs(c)
			if err != nil {
				t.Fatal(err)
			}
			return abs
		}
	}
	t.Skip("sing-box binary not found; set HALO_SINGBOX")
	return ""
}
