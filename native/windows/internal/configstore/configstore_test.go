package configstore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func write(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestActivePathPrefersThePromotedConfig(t *testing.T) {
	dir := t.TempDir()
	store := New(dir)
	active := write(t, dir, "active.json", "active")
	old := write(t, dir, "profile-z.json", "z")
	// Make profile-z older so the mtime fallback would not pick it either.
	oldTime := time.Now().Add(-time.Hour)
	if err := os.Chtimes(old, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}

	if got := store.ActivePath(); got != active {
		t.Fatalf("ActivePath = %q, want active.json", got)
	}
	if err := os.Remove(active); err != nil {
		t.Fatal(err)
	}
	// Without active.json the newest remaining config wins; a lexicographic
	// rule used to let profile-z beat a freshly applied profile-a.
	fresh := write(t, dir, "profile-a.json", "a")
	if got := store.ActivePath(); got != fresh {
		t.Fatalf("ActivePath = %q, want the newest config", got)
	}
}

func TestCandidateVerifiesClaimedHash(t *testing.T) {
	dir := t.TempDir()
	store := New(dir)

	path, hash, errObj := store.Candidate(`{"x":1}`, "")
	if errObj != nil {
		t.Fatalf("Candidate: %v", errObj)
	}
	if path == "" || len(hash) != 64 {
		t.Fatalf("path=%q hash=%q", path, hash)
	}
	if _, _, errObj := store.Candidate(`{"x":1}`, "abc"); errObj == nil {
		t.Fatal("a short mismatched hash must be rejected, not panic")
	} else if !strings.Contains(errObj.Detail, "abc") {
		t.Fatalf("detail lost the claimed hash: %q", errObj.Detail)
	}
	if _, _, errObj := store.Candidate(`{"x":1}`, hash); errObj != nil {
		t.Fatalf("matching hash rejected: %v", errObj)
	}
}

func TestPromoteKeepsThePreviousConfig(t *testing.T) {
	dir := t.TempDir()
	store := New(dir)

	first, _, errObj := store.Candidate(`{"v":1}`, "")
	if errObj != nil {
		t.Fatal(errObj)
	}
	if err := store.Promote(first); err != nil {
		t.Fatal(err)
	}
	if store.CurrentPath() == "" {
		t.Fatal("promote did not record the current path")
	}

	second, hash, errObj := store.Candidate(`{"v":2}`, "")
	if errObj != nil {
		t.Fatal(errObj)
	}
	if err := store.Promote(second); err != nil {
		t.Fatal(err)
	}
	if got := store.CurrentPath(); got != filepath.Join(dir, "active.json") {
		t.Fatalf("current = %q", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "active.json.prev")); err != nil {
		t.Fatalf("previous config was not kept: %v", err)
	}
	store.SetVersion(hash, 2)
	if store.Version() != 2 || store.Hash() != hash {
		t.Fatalf("version/hash = %d/%q", store.Version(), store.Hash())
	}
}

func TestFirstApplyFailureClearsTheRecord(t *testing.T) {
	dir := t.TempDir()
	store := New(dir)
	store.ClearActiveFile()
	store.Clear()
	if store.CurrentPath() != "" || store.Hash() != "" || store.Version() != 0 {
		t.Fatal("Clear must forget the applied config")
	}
}
