// Package sysproxy manages the per-user WinINet proxy setting.
//
// Safety invariant, and the reason this package exists separately: the host
// only ever restores the proxy if the registry still holds **exactly** the
// value it wrote. If the user (or another app) changed it afterwards, the host
// leaves it alone and reports `restorable=false`. Silently overwriting a user
// setting is the failure mode this design forbids.
package sysproxy

import (
	"errors"
	"fmt"
	"strings"
	"sync"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	keyPath   = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`
	valEnable = "ProxyEnable"
	valServer = "ProxyServer"
	valBypass = "ProxyOverride"

	// DefaultBypass keeps loopback traffic off the proxy: without this the
	// client's own control requests would be routed through the tunnel.
	DefaultBypass = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;" +
		"172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;" +
		"172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>"
)

// State is the current registry proxy configuration.
type State struct {
	Enable bool
	Server string
	Bypass string
}

// Manager serialises proxy writes for one process.
type Manager struct {
	mu sync.Mutex
}

// New creates a manager.
func New() *Manager { return &Manager{} }

// Read returns the current per-user proxy state. A missing value is treated as
// "not enabled / empty", which is the documented Windows default.
func (m *Manager) Read() (State, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, keyPath, registry.QUERY_VALUE)
	if err != nil {
		return State{}, fmt.Errorf("无法读取代理注册表项: %w", err)
	}
	defer func() { _ = k.Close() }()
	st := State{}
	if v, _, err := k.GetIntegerValue(valEnable); err == nil {
		st.Enable = v != 0
	}
	if s, _, err := k.GetStringValue(valServer); err == nil {
		st.Server = s
	}
	if s, _, err := k.GetStringValue(valBypass); err == nil {
		st.Bypass = s
	}
	return st, nil
}

// Apply writes the proxy endpoint and enables it, returning the previous state
// so the caller can persist an accurate "what we replaced" record.
func (m *Manager) Apply(endpoint string) (previous State, applied State, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	prev, err := m.Read()
	if err != nil {
		// Not fatal for Apply: we can still write if the key exists.
		prev = State{}
	}
	k, err := registry.OpenKey(registry.CURRENT_USER, keyPath, registry.SET_VALUE)
	if err != nil {
		return prev, State{}, fmt.Errorf("无法写入代理注册表项: %w", err)
	}
	defer func() { _ = k.Close() }()
	if err := k.SetDWordValue(valEnable, 1); err != nil {
		return prev, State{}, err
	}
	if err := k.SetStringValue(valServer, endpoint); err != nil {
		// Roll the enable bit back rather than leaving a half-applied state.
		_ = k.SetDWordValue(valEnable, uint32(boolToInt(prev.Enable)))
		return prev, State{}, err
	}
	bypass := prev.Bypass
	if bypass == "" {
		bypass = DefaultBypass
		_ = k.SetStringValue(valBypass, bypass)
	}
	notifyChange()
	applied = State{Enable: true, Server: endpoint, Bypass: bypass}
	return prev, applied, nil
}

// DisableIfServer turns off an enabled proxy only when it still points at
// server. It is used when a previous run left ProxyEnable=1 after the host
// snapshot already said "system proxy off"; RestoreIfUnchanged refuses to touch
// that state because it does not match the recorded applied value.
func (m *Manager) DisableIfServer(server string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, err := m.Read()
	if err != nil {
		return false, err
	}
	if !cur.Enable || normalizeServer(cur.Server) != normalizeServer(server) {
		return false, nil
	}
	k, err := registry.OpenKey(registry.CURRENT_USER, keyPath, registry.SET_VALUE)
	if err != nil {
		return false, err
	}
	defer func() { _ = k.Close() }()
	if err := k.SetDWordValue(valEnable, 0); err != nil {
		return false, err
	}
	notifyChange()
	return true, nil
}

// RestoreIfUnchanged rewrites [previous] only when the registry still contains
// exactly [applied]. It returns false (and no error) when someone else changed
// the setting, which is a normal, non-error outcome.
func (m *Manager) RestoreIfUnchanged(applied, previous State) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, err := m.Read()
	if err != nil {
		return false, err
	}
	if !sameState(cur, applied) {
		return false, nil
	}
	k, err := registry.OpenKey(registry.CURRENT_USER, keyPath, registry.SET_VALUE)
	if err != nil {
		return false, err
	}
	defer func() { _ = k.Close() }()
	if previous.Server == "" {
		if err := k.DeleteValue(valServer); err != nil && !errors.Is(err, registry.ErrNotExist) {
			return false, err
		}
	} else if err := k.SetStringValue(valServer, previous.Server); err != nil {
		return false, err
	}
	enable := uint32(0)
	if previous.Enable {
		enable = 1
	}
	if err := k.SetDWordValue(valEnable, enable); err != nil {
		return false, err
	}
	notifyChange()
	return true, nil
}

// sameState compares the fields that decide routing. The bypass list is
// excluded: another app expanding the bypass list does not change who receives
// traffic, and treating it as a conflict would block a legitimate restore.
func sameState(a, b State) bool {
	return a.Enable == b.Enable && normalizeServer(a.Server) == normalizeServer(b.Server)
}

func normalizeServer(s string) string {
	s = strings.TrimSpace(s)
	// WinINet value is "<scheme>=<host>" for a typed-only proxy. Compare the
	// host portion so a scheme-only spelling difference is not a conflict.
	if idx := strings.LastIndex(s, "="); idx >= 0 {
		return strings.ToLower(strings.TrimSpace(s[idx+1:]))
	}
	return strings.ToLower(s)
}

func notifyChange() {
	// Without this, running browsers keep the old configuration until restart;
	// the user would think the switch did nothing. Failures are non-fatal: the
	// registry (and thus every newly started app) is already correct.
	wininet := windows.NewLazySystemDLL("wininet.dll")
	proc := wininet.NewProc("InternetSetOptionW")
	if err := proc.Find(); err != nil {
		return
	}
	// INTERNET_OPTION_SETTINGS_CHANGED = 39, INTERNET_OPTION_REFRESH = 37
	_, _, _ = proc.Call(0, 39, 0, 0)
	_, _, _ = proc.Call(0, 37, 0, 0)
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// Endpoint formats a loopback proxy endpoint for the registry.
func Endpoint(host string, port int) string {
	if host == "" {
		host = "127.0.0.1"
	}
	return fmt.Sprintf("%s:%d", host, port)
}

// Supported reports whether this platform's proxy integration is available.
func Supported() bool { return true }
