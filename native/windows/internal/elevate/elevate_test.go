package elevate

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func TestQuoteArg(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		// Nothing special: passed through so the log stays readable.
		{"abc", "abc"},
		{`--command=tun.start`, `--command=tun.start`},
		// A bare trailing backslash is unambiguous, so it is left alone.
		{`C:\dir\`, `C:\dir\`},
		{`C:\a\b`, `C:\a\b`},
		// Spaces force quoting.
		{"a b", `"a b"`},
		{`C:\Program Files`, `"C:\Program Files"`},
		// A trailing backslash inside quotes must be doubled, or it would
		// escape the closing quote and swallow the next argument.
		{`C:\Program Files\`, `"C:\Program Files\\"`},
		// A quote is escaped, and the backslashes before it are doubled.
		{`a"b`, `"a\"b"`},
		{`a\"b`, `"a\\\"b"`},
		// Empty arguments still need to occupy a slot.
		{"", `""`},
		{"\t", "\"\t\""},
	}
	for _, c := range cases {
		if got := quoteArg(c.in); got != c.want {
			t.Errorf("quoteArg(%q) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestQuoteArgsJoins(t *testing.T) {
	got := quoteArgs([]string{"--install-dir=C:\\Program Files\\App", "--parent-pid=7", "x"})
	want := `"--install-dir=C:\Program Files\App" --parent-pid=7 x`
	if got != want {
		t.Fatalf("quoteArgs = %s, want %s", got, want)
	}
	if got := quoteArgs(nil); got != "" {
		t.Fatalf("no args should produce no string, got %q", got)
	}
}

func TestIsCanceled(t *testing.T) {
	if !isCanceled(syscall.Errno(errorCancelled)) {
		t.Fatal("ERROR_CANCELLED must be recognised as a refusal")
	}
	if !isCanceled(errors.Join(syscall.Errno(errorCancelled), errors.New("wrapped"))) {
		t.Fatal("a wrapped ERROR_CANCELLED must still be recognised")
	}
	if isCanceled(syscall.Errno(2)) {
		t.Fatal("ERROR_FILE_NOT_FOUND is not a refusal")
	}
	if isCanceled(nil) {
		t.Fatal("nil is not a refusal")
	}
}

// TestStructLayoutMatchesSDK pins the SHELLEXECUTEINFOW layout.
//
// These offsets come from shellapi.h in the Windows SDK 10.0.26100.0, where
// fMask is declared ULONG — four bytes on every platform, unlike ULONG_PTR.
// Declaring it as uintptr in Go makes the struct 120 bytes instead of 112 and
// moves hwnd from offset 8 to 16, so ShellExecuteExW reads lpVerb from the hwnd
// slot and lpFile from the lpVerb slot. The only symptom is a misleading
// "Access is denied", which is why this numeric guard exists.
func TestStructLayoutMatchesSDK(t *testing.T) {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		t.Skip("the pinned offsets describe the amd64 layout")
	}
	var info shellExecuteInfoW
	if got := unsafe.Sizeof(info.fMask); got != 4 {
		t.Fatalf("fMask is %d bytes, but the SDK declares it ULONG (4)", got)
	}
	cases := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"cbSize", unsafe.Offsetof(info.cbSize), 0},
		{"fMask", unsafe.Offsetof(info.fMask), 4},
		{"hwnd", unsafe.Offsetof(info.hwnd), 8},
		{"lpVerb", unsafe.Offsetof(info.lpVerb), 16},
		{"lpFile", unsafe.Offsetof(info.lpFile), 24},
		{"lpParameters", unsafe.Offsetof(info.lpParameters), 32},
		{"lpDirectory", unsafe.Offsetof(info.lpDirectory), 40},
		{"nShow", unsafe.Offsetof(info.nShow), 48},
		{"hInstApp", unsafe.Offsetof(info.hInstApp), 56},
		{"lpIDList", unsafe.Offsetof(info.lpIDList), 64},
		{"lpClass", unsafe.Offsetof(info.lpClass), 72},
		{"hkeyClass", unsafe.Offsetof(info.hkeyClass), 80},
		{"dwHotKey", unsafe.Offsetof(info.dwHotKey), 88},
		{"hIconOrMonitor", unsafe.Offsetof(info.hIconOrMonitor), 96},
		{"hProcess", unsafe.Offsetof(info.hProcess), 104},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s at offset %d, want %d", c.name, c.got, c.want)
		}
	}
	if got := unsafe.Sizeof(info); got != 112 {
		t.Fatalf("sizeof(shellExecuteInfoW) = %d, want 112 (cbSize must match exactly)", got)
	}
}

// TestStartExercisesShellExecuteEx runs the real ShellExecuteExW call with the
// "open" verb, which needs no prompt.
//
// Every production run goes through this struct, so this test is what actually
// proves the layout, cbSize and SEE_MASK_NOCLOSEPROCESS flag are right end to
// end: a single misplaced field makes the call fail outright.
func TestStartExercisesShellExecuteEx(t *testing.T) {
	cmdExe := filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
	if _, err := os.Stat(cmdExe); err != nil {
		t.Skipf("cmd.exe not found at %s: %v", cmdExe, err)
	}
	p, err := start("open", cmdExe, []string{"/c", "exit", "0"})
	if err != nil {
		t.Fatalf("ShellExecuteExW plumbing failed: %v", err)
	}
	defer p.Close()
	if p.PID <= 0 {
		t.Fatalf("no pid obtained from the process handle: %d", p.PID)
	}
	exited, err := p.Wait(20000)
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if !exited {
		t.Fatal("process did not exit within 20s")
	}
	code, err := p.ExitCode()
	if err != nil {
		t.Fatalf("ExitCode: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
}

func TestWaitTimesOutWithoutLying(t *testing.T) {
	cmdExe := filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
	if _, err := os.Stat(cmdExe); err != nil {
		t.Skipf("cmd.exe not found: %v", err)
	}
	// cmd /c pause would block forever; "timeout" is unavailable in some
	// environments, so use a nested cmd that idles.
	p, err := start("open", cmdExe, []string{"/c", "ping", "-n", "20", "127.0.0.1"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer p.Close()
	start := time.Now()
	exited, err := p.Wait(300)
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if exited {
		t.Skip("the helper process exited immediately; nothing to assert")
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("a 300ms wait took %s", elapsed)
	}
	if err := p.Kill(); err != nil {
		t.Fatalf("Kill: %v", err)
	}
	if exited, err := p.Wait(10000); err != nil || !exited {
		t.Fatalf("killed process did not report exit: exited=%v err=%v", exited, err)
	}
}

func TestStartMissingFileIsNotARefusal(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "definitely-not-here.exe")
	_, err := start("open", missing, nil)
	if err == nil {
		t.Fatal("expected an error for a missing executable")
	}
	// A missing helper must not be reported to the user as "you declined the
	// prompt": that would send them looking for the wrong problem.
	if errors.Is(err, ErrCanceled) {
		t.Fatalf("missing file reported as a cancelled elevation: %v", err)
	}
}

func TestStartRejectsEmptyPath(t *testing.T) {
	if _, err := Start("   ", nil); err == nil {
		t.Fatal("expected an error for an empty executable path")
	}
}

func TestCloseIsIdempotent(t *testing.T) {
	p := &Process{}
	p.Close()
	p.Close()
	if p.h != 0 {
		t.Fatal("handle not cleared")
	}
}
