package tunservice

import (
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// The protected directory must not be derived from %ProgramFiles%: a user-level
// environment override would let the user choose where LocalSystem binaries are
// written. This pins the resolution to the known folder API.
func TestDefaultProtectedDirIgnoresEnvironment(t *testing.T) {
	evil := filepath.Join(t.TempDir(), "evil")
	t.Setenv("ProgramFiles", evil)
	got, err := DefaultProtectedDir()
	if err != nil {
		t.Fatalf("DefaultProtectedDir: %v", err)
	}
	if strings.HasPrefix(strings.ToLower(got), strings.ToLower(evil)) {
		t.Fatalf("protected dir followed the environment: %s", got)
	}
	want, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, windows.KF_FLAG_DEFAULT)
	if err != nil {
		t.Skipf("KnownFolderPath unavailable: %v", err)
	}
	if filepath.Clean(got) != filepath.Join(filepath.Clean(want), "Clash Halo TUN") {
		t.Fatalf("protected dir = %s, want under %s", got, want)
	}
}

// A directory the installing user can write defeats every downstream hash pin.
func TestVerifyProtectedDirRejectsUserWritableDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := VerifyProtectedDir(dir); err == nil {
		t.Fatalf("a user-writable directory must be rejected: %s", dir)
	}
}

// Program Files itself is the baseline the installer relies on.
func TestVerifyProtectedDirAcceptsProgramFiles(t *testing.T) {
	base, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, windows.KF_FLAG_DEFAULT)
	if err != nil {
		t.Skipf("KnownFolderPath unavailable: %v", err)
	}
	if err := VerifyProtectedDir(base); err != nil {
		t.Fatalf("Program Files must pass the ACL check: %v", err)
	}
}
