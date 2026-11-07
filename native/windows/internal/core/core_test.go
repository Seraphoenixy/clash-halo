package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/windows"

	"clash-halo/native/windows/internal/logs"
)

// The child process these tests supervise: this same test binary, started with
// the arguments Start uses, so it stays alive until the supervisor kills it.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "run" {
		time.Sleep(60 * time.Second)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func newSupervisor(t *testing.T) *Supervisor {
	t.Helper()
	dir := t.TempDir()
	log, err := logs.Open(logs.DefaultOptions(filepath.Join(dir, "host.log"), logs.NewRedactor()))
	if err != nil {
		t.Fatalf("open host log: %v", err)
	}
	t.Cleanup(func() { _ = log.Close() })
	cfg := filepath.Join(dir, "active.json")
	if err := os.WriteFile(cfg, []byte(`{}`), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	s := New(Options{CorePath: os.Args[0], ConfigDir: dir, Log: log})
	// A failed assertion must not leave the 60-second child behind.
	t.Cleanup(func() { _ = s.Stop() })
	return s
}

func processAlive(pid int) bool {
	const stillActive = 259
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	var code uint32
	if err := windows.GetExitCodeProcess(h, &code); err != nil {
		return false
	}
	return code == stillActive
}

// Stop must not report success before the child is gone: every caller that
// starts the next process immediately depends on it.
func TestStopWaitsForChildExit(t *testing.T) {
	s := newSupervisor(t)
	pid, err := s.Start(filepath.Join(s.configDir, "active.json"))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if !processAlive(pid) {
		t.Fatalf("child %d is not alive right after Start", pid)
	}
	if err := s.Stop(); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if processAlive(pid) {
		t.Fatalf("Stop returned while child %d was still running", pid)
	}
	if s.Running() {
		t.Fatal("Running still reports the stopped child")
	}
}

// The regression: after a stop the old process could still be unwinding, and
// Start returned ErrAlreadyRunning for a legitimate restart.
func TestStartImmediatelyAfterStop(t *testing.T) {
	s := newSupervisor(t)
	cfg := filepath.Join(s.configDir, "active.json")
	if _, err := s.Start(cfg); err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := s.Stop(); err != nil {
		t.Fatalf("stop: %v", err)
	}
	pid, err := s.Start(cfg)
	if err != nil {
		t.Fatalf("start right after stop: %v", err)
	}
	if pid <= 0 {
		t.Fatalf("pid = %d", pid)
	}
	_ = s.Stop()
}

// A requested stop must never be reported as an unexpected exit: the shared
// `stopping` flag this replaced could be reset by the next Start before the old
// Wait goroutine observed it, which made an ordinary switch look like a crash.
func TestStopDoesNotReportUnexpectedExit(t *testing.T) {
	dir := t.TempDir()
	log, err := logs.Open(logs.DefaultOptions(filepath.Join(dir, "host.log"), logs.NewRedactor()))
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	called := make(chan string, 1)
	s := New(Options{CorePath: os.Args[0], ConfigDir: dir, Log: log,
		OnExit: func(_ int, reason string) { called <- reason }})
	cfg := filepath.Join(dir, "active.json")
	if err := os.WriteFile(cfg, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(cfg); err != nil {
		t.Fatal(err)
	}
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	select {
	case reason := <-called:
		t.Fatalf("a requested stop was reported as a crash: %s", reason)
	case <-time.After(500 * time.Millisecond):
	}
}

// The counterpart: a real crash still has to reach onExit, otherwise the
// no-spurious-exit test above could pass by simply never reporting anything.
func TestCrashStillReportsUnexpectedExit(t *testing.T) {
	dir := t.TempDir()
	log, err := logs.Open(logs.DefaultOptions(filepath.Join(dir, "host.log"), logs.NewRedactor()))
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	called := make(chan string, 1)
	s := New(Options{CorePath: os.Args[0], ConfigDir: dir, Log: log,
		OnExit: func(_ int, reason string) { called <- reason }})
	cfg := filepath.Join(dir, "active.json")
	if err := os.WriteFile(cfg, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	pid, err := s.Start(cfg)
	if err != nil {
		t.Fatal(err)
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Kill(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-called:
	case <-time.After(5 * time.Second):
		t.Fatal("a crashed core did not reach onExit")
	}
}

// Two live cores would fight over the controller port, so this must still be
// rejected rather than turned into a silent second start.
func TestStartWhileRunningStillRejected(t *testing.T) {
	s := newSupervisor(t)
	cfg := filepath.Join(s.configDir, "active.json")
	if _, err := s.Start(cfg); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer s.Stop()
	if _, err := s.Start(cfg); err == nil {
		t.Fatal("starting a second core while one is live must fail")
	} else if err != ErrAlreadyRunning {
		t.Fatalf("error = %v, want ErrAlreadyRunning", err)
	}
}
