//go:build windows

package tunsup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsAdapterConflictRequiresBothHalves(t *testing.T) {
	both := "create adapter: Cannot create a file when that file already exists. | " +
		"open existing adapter: Element not found."
	if !IsAdapterConflict(both) {
		t.Fatal("the paired wintun failure must be recognised as a conflict")
	}
	for _, partial := range []string{
		"create adapter: Cannot create a file when that file already exists.",
		"open existing adapter: Element not found",
		"Access is denied.",
		"",
	} {
		if IsAdapterConflict(partial) {
			t.Fatalf("partial output %q must not be classified as a conflict", partial)
		}
	}
}

func TestAdapterExistsRejectsEmptyName(t *testing.T) {
	if AdapterExists("") || AdapterExists("   ") {
		t.Fatal("an empty adapter name cannot exist")
	}
}

func TestRotateLogKeepsOnePreviousFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "core.log")
	if err := os.WriteFile(path, []byte(strings.Repeat("x", 64)), 0o600); err != nil {
		t.Fatal(err)
	}
	RotateLog(path, 32)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("the live log should have moved, stat err = %v", err)
	}
	prev, err := os.ReadFile(path + ".1")
	if err != nil || len(prev) != 64 {
		t.Fatalf("rotated log = %d bytes, err %v", len(prev), err)
	}
	// A log below the limit is left alone.
	if err := os.WriteFile(path, []byte("small"), 0o600); err != nil {
		t.Fatal(err)
	}
	RotateLog(path, 32)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("a small log must stay in place: %v", err)
	}
}

func TestTailTextStartsAtOffsetAndStripsANSI(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "core.log")
	body := "old line\n" + "\x1b[31mFATAL\x1b[0m configure tun interface:\n" +
		"  create adapter failed\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	start := int64(len("old line\n"))
	got := TailText(path, 8<<10, start)
	if strings.Contains(got, "old line") {
		t.Fatalf("text before the start offset leaked: %q", got)
	}
	if strings.Contains(got, "\x1b[") {
		t.Fatalf("ANSI escapes survived: %q", got)
	}
	if !strings.Contains(got, "FATAL configure tun interface") {
		t.Fatalf("tail = %q", got)
	}
	if strings.Contains(got, "\n") {
		t.Fatalf("tail must be single-lined: %q", got)
	}
}

func TestTailTextWithoutNewBytesIsEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "core.log")
	if err := os.WriteFile(path, []byte("abc"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := TailText(path, 1024, 3); got != "" {
		t.Fatalf("no new bytes should yield nothing, got %q", got)
	}
}

func TestProcessStateDistinguishesAliveAndGone(t *testing.T) {
	if got := ProcessState(os.Getpid()); got != ProcessRunning {
		t.Fatalf("own process = %v, want running", got)
	}
	if got := ProcessState(0); got != ProcessGone {
		t.Fatalf("pid 0 = %v, want gone", got)
	}
	if !ProcessAlive(os.Getpid()) {
		t.Fatal("the test process is alive")
	}
	if ProcessAlive(0) {
		t.Fatal("pid 0 is not alive")
	}
}
