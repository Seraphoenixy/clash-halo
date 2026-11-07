// Package state holds the runtime snapshot: the single authority for what the
// core is currently doing, independent of any UI being open.
//
// The snapshot is persisted with an atomic replace so a crash mid-write can
// never leave a half-written file that would make the next start misread the
// system-proxy restore state (the most dangerous field here).
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// CoreState is the lifecycle state of the sing-box process.
type CoreState string

// Lifecycle states.
const (
	CoreStopped  CoreState = "stopped"
	CoreStarting CoreState = "starting"
	CoreRunning  CoreState = "running"
	CoreFailed   CoreState = "failed"
)

// ProxyMode is the routing intent.
type ProxyMode string

// Routing modes.
const (
	ModeRule   ProxyMode = "rule"
	ModeGlobal ProxyMode = "global"
	ModeDirect ProxyMode = "direct"
)

// TunState is the elevation-bound TUN state.
type TunState string

// TUN states.
//
// `unverified` is a legacy wire value: an earlier build refused activation and
// reported it. It is kept so an old snapshot or UI still parses, but nothing
// writes it any more.
const (
	TunDisabled    TunState = "disabled"
	TunPending     TunState = "pending"
	TunEnabled     TunState = "enabled"
	TunFailed      TunState = "failed"
	TunUnsupported TunState = "unsupported"
	TunUnverified  TunState = "unverified"
)

// SystemProxy records exactly what we wrote so restoration only ever happens
// when the current value still equals our own last write.
type SystemProxy struct {
	Supported  bool   `json:"supported"`
	Enabled    bool   `json:"enabled"`
	Restorable bool   `json:"restorable"`
	Endpoint   string `json:"endpoint"`
	// AppliedValue is the registry value data we wrote, verbatim.
	AppliedValue string `json:"appliedValue"`
	// AppliedProxyEnable is the ProxyEnable DWORD we wrote (1 or 0).
	AppliedProxyEnable int `json:"appliedProxyEnable"`
	// PreviousValue/PreviousEnable let us restore the user's prior setting.
	PreviousValue  string `json:"previousValue"`
	PreviousEnable int    `json:"previousEnable"`
}

// Snapshot mirrors RuntimeSnapshot in Dart. Field names must match exactly.
type Snapshot struct {
	StateVersion       int64       `json:"stateVersion"`
	CoreState          CoreState   `json:"coreState"`
	CorePID            int         `json:"corePid"`
	CoreRestarts       int         `json:"coreRestarts"`
	ActiveNodeID       string      `json:"activeNodeId"`
	ActiveNodeName     string      `json:"activeNodeName"`
	Mode               ProxyMode   `json:"mode"`
	ConfigVersion      int         `json:"configVersion"`
	ConfigHash         string      `json:"configHash"`
	SystemProxy        SystemProxy `json:"systemProxy"`
	TunState           TunState    `json:"tunState"`
	TunSupported       bool        `json:"tunSupported"`
	TunMessage         string      `json:"tunMessage"`
	// TunPID is the elevated sing-box process, which is *not* CorePID: the two
	// cores are mutually exclusive and owned by different supervisors.
	TunPID int `json:"tunPid"`
	// TunAdapter is the adapter name the service actually created, reported
	// back so the UI shows reality rather than the request.
	TunAdapter string `json:"tunAdapter"`
	// TunElevated records whether the running TUN core is really elevated.
	// Reporting true without a real token check would be the exact false
	// claim the plan forbids, so only the elevated service may set it.
	TunElevated bool `json:"tunElevated"`
	AutoLaunch         bool        `json:"autoLaunch"`
	// CoreWanted records the user's *intent* about the core, which is a
	// different fact from whether a core process happens to be alive.
	//
	// CoreState cannot serve this purpose: load() rewrites a stale "running"
	// to "stopped" on every host restart, because a dead process should not be
	// reported as live. That reset is correct, but it left nothing behind to
	// answer "should we start it again?", so every launch began with the core
	// off and the user had to press start — again — for a node they had already
	// applied. This field survives the restart and carries that intent.
	CoreWanted bool `json:"coreWanted"`
	HostVersion        string      `json:"hostVersion"`
	CoreVersion        string      `json:"coreVersion"`
	SingboxPath        string      `json:"singboxPath"`
	LastErrorCode      string      `json:"lastErrorCode"`
	LastErrorMsg       string      `json:"lastErrorMsg"`
	LogBytes           int64       `json:"logBytes"`
	UpdatedAtMs        int64       `json:"updatedAtMs"`
	SubscriptionRun    bool        `json:"subscriptionRunnerActive"`
	SpeedTestRunning   bool        `json:"speedTestRunning"`
}

// Store owns the snapshot and its persistence.
type Store struct {
	mu       sync.RWMutex
	snap     Snapshot
	path     string
	version  int64
	listeners []func(Snapshot)
}

// Open loads (or initialises) the snapshot at path.
//
// A corrupt file is not fatal: the host starts from a safe default snapshot
// with no claimed system-proxy write, because a false "we changed the proxy"
// claim would cause us to clobber a user setting we never touched.
func Open(path string, hostVersion string, singboxPath string) (*Store, error) {
	s := &Store{
		path: path,
		snap: Snapshot{
			StateVersion:    1,
			CoreState:       CoreStopped,
			Mode:            ModeRule,
			TunState:        TunDisabled,
			TunSupported:    false,
			TunMessage:      "",
			HostVersion:     hostVersion,
			SingboxPath:     singboxPath,
			AutoLaunch:      false,
			UpdatedAtMs:     time.Now().UnixMilli(),
		},
		version: 1,
	}
	if err := s.load(); err != nil {
		// Keep the corrupt file for diagnosis rather than deleting it.
		if _, statErr := os.Stat(path); statErr == nil {
			_ = os.Rename(path, fmt.Sprintf("%s.corrupt-%d", path, time.Now().UnixMilli()))
		}
	}
	s.snap.StateVersion = s.version
	return s, nil
}

// hasKey reports whether a JSON object carries the given top-level key, which
// tells "absent, migrate it" apart from "explicitly false, respect it".
func hasKey(b []byte, key string) bool {
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(b, &probe); err != nil {
		return false
	}
	_, ok := probe[key]
	return ok
}

func (s *Store) load() error {
	b, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if len(b) == 0 {
		return nil
	}
	var loaded Snapshot
	if err := json.Unmarshal(b, &loaded); err != nil {
		return err
	}
	if loaded.StateVersion <= 0 {
		return fmt.Errorf("snapshot version invalid: %d", loaded.StateVersion)
	}
	// A previously running core is not trusted after a restart: report it as
	// stopped until supervision actually proves a live process.
	wasRunning := loaded.CoreState == CoreRunning || loaded.CoreState == CoreStarting
	if wasRunning {
		loaded.CoreState = CoreStopped
		loaded.CorePID = 0
	}
	// Snapshots written before CoreWanted existed have no intent recorded, so
	// it has to be inferred, and the honest evidence is "there was an applied
	// config and the user never stopped the core".
	//
	// coreState alone is not enough evidence: a *clean* shutdown stops the core
	// and persists coreState=stopped, so an install that was proxying happily
	// right up to the upgrade would look identical to one where the user had
	// pressed stop. Requiring an applied config (configHash) is what tells them
	// apart, and it keeps a never-configured install from wanting a core it has
	// nothing to run. A file that *does* carry the key is believed as-is,
	// including an explicit false from a user who stopped the core.
	if !loaded.CoreWanted && (wasRunning || loaded.ConfigHash != "") &&
		!hasKey(b, "coreWanted") {
		loaded.CoreWanted = true
	}
	// Same for TUN: a service-owned core does not survive a host restart.
	if loaded.TunState == TunEnabled || loaded.TunState == TunPending {
		loaded.TunState = TunDisabled
	}
	s.snap = loaded
	s.version = loaded.StateVersion
	return nil
}

// Snapshot returns a copy of the current snapshot.
func (s *Store) Snapshot() Snapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.snap
}

// StateVersion returns the current version, used in every response.
func (s *Store) StateVersion() int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.version
}

// Update mutates the snapshot under lock, bumps the version, persists it and
// notifies listeners.
//
// Persistence errors are returned but the in-memory state still changes, so a
// disk problem never makes the host lie about what it is doing right now.
func (s *Store) Update(mutate func(*Snapshot)) (Snapshot, error) {
	s.mu.Lock()
	mutate(&s.snap)
	s.version++
	s.snap.StateVersion = s.version
	s.snap.UpdatedAtMs = time.Now().UnixMilli()
	next := s.snap
	path := s.path
	listeners := append([]func(Snapshot){}, s.listeners...)
	s.mu.Unlock()

	persistErr := writeAtomic(path, next)
	for _, fn := range listeners {
		fn(next)
	}
	return next, persistErr
}

// Subscribe registers a callback invoked after every successful update.
func (s *Store) Subscribe(fn func(Snapshot)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.listeners = append(s.listeners, fn)
}

// writeAtomic writes via a temp file and rename so readers never observe a
// partial snapshot.
func writeAtomic(path string, snap Snapshot) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	// os.Rename on Windows is MoveFileEx(MOVEFILE_REPLACE_EXISTING), so it
	// replaces an existing runtime.json atomically. Removing the target first
	// opened a window in which a crash left no snapshot at all — losing the
	// system-proxy bookkeeping that makes recovery possible.
	return os.Rename(tmp, path)
}

// SortedKeys is a test helper used by snapshot comparisons.
func SortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
