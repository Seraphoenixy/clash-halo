// Package configstore owns the on-disk config files and the bookkeeping that
// says which one is live.
//
// It was extracted from app so "which config is running" has one owner: the
// candidate write, the promotion, the version/hash counters and the active
// fallback all live here. The apply pipeline still decides *when* to promote.
package configstore

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"clash-halo/native/windows/internal/contract"
)

// Store owns one configs directory and the live-config bookkeeping.
type Store struct {
	dir string

	mu          sync.Mutex
	currentPath string
	hash        string
	version     int
}

// New builds a store for dir.
func New(dir string) *Store { return &Store{dir: dir} }

// CurrentPath is the promoted config the host last applied, if still present.
func (s *Store) CurrentPath() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.currentPath
}

// Hash is the digest of the applied config.
func (s *Store) Hash() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.hash
}

// Version is the monotonic apply counter.
func (s *Store) Version() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.version
}

// SetCurrent records a successful apply.
func (s *Store) SetCurrent(path, hash string, version int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.currentPath = path
	s.hash = hash
	s.version = version
}

// SetVersion records only the hash/version (used by a rollback, where the file
// name does not change).
func (s *Store) SetVersion(hash string, version int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hash = hash
	s.version = version
}

// Clear forgets the applied config.
func (s *Store) Clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.currentPath = ""
	s.hash = ""
	s.version = 0
}

// ActivePath resolves the config the host would run now.
//
// The promoted path wins while it still exists. Otherwise active.json is the
// fallback, and only then the most recently modified remaining .json. The old
// "lexicographically largest path" rule let profile-z.json beat active.json and
// made any hand-copied file live.
func (s *Store) ActivePath() string {
	s.mu.Lock()
	current := s.currentPath
	s.mu.Unlock()
	if current != "" {
		if _, err := os.Stat(current); err == nil {
			return current
		}
	}
	active := filepath.Join(s.dir, "active.json")
	if _, err := os.Stat(active); err == nil {
		return active
	}
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return ""
	}
	var best string
	var bestTime time.Time
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		// candidate.json is unvalidated until promoted, and *.prev is the
		// backup of the previous active config.
		if strings.HasSuffix(e.Name(), ".prev") || e.Name() == "candidate.json" {
			continue
		}
		p := filepath.Join(s.dir, e.Name())
		info, err := e.Info()
		if err != nil {
			continue
		}
		if best == "" || info.ModTime().After(bestTime) {
			best = p
			bestTime = info.ModTime()
		}
	}
	return best
}

// Candidate writes a validated-but-not-yet-promoted config and verifies the
// caller's claimed hash.
func (s *Store) Candidate(config, claimedHash string) (string, string, *contract.ErrorObj) {
	sum := sha256.Sum256([]byte(config))
	hash := hex.EncodeToString(sum[:])
	// A mismatched hash means the UI and host disagree about what is being
	// applied; refusing is safer than applying HTML that happens to be a
	// subscription response body.
	if claimedHash != "" && claimedHash != hash {
		return "", "", &contract.ErrorObj{
			Code:    contract.ErrBadRequest,
			Message: "配置哈希不匹配，已拒绝应用",
			Detail:  fmt.Sprintf("声明 %s，实际 %s", shortHash(claimedHash), shortHash(hash)),
		}
	}
	path := filepath.Join(s.dir, "candidate.json")
	if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
		return "", "", &contract.ErrorObj{
			Code: contract.ErrInternal, Message: "无法写入候选配置", Detail: err.Error(),
		}
	}
	return path, hash, nil
}

// Promote renames a validated candidate into place, keeping the previous
// active file as a recoverable *.prev copy.
func (s *Store) Promote(candidate string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cur := s.currentPath; cur != "" {
		backup := cur + ".prev"
		_ = os.Remove(backup)
		_ = CopyFile(cur, backup)
	}
	active := filepath.Join(s.dir, "active.json")
	if err := os.Rename(candidate, active); err != nil {
		// Rename can fail across volumes or when the file is locked; fall
		// back to a copy so the apply still succeeds.
		if err := CopyFile(candidate, active); err != nil {
			return err
		}
		_ = os.Remove(candidate)
	}
	s.currentPath = active
	return nil
}

// ClearActiveFile removes active.json. Used when a first-ever apply fails and
// there is nothing to roll back to.
func (s *Store) ClearActiveFile() {
	_ = os.Remove(filepath.Join(s.dir, "active.json"))
}

// CopyFile copies src to dst. It is exported because the rollback path in app
// needs the same write.
func CopyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}

func shortHash(hash string) string {
	if len(hash) <= 12 {
		return hash
	}
	return hash[:12]
}
