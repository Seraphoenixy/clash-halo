// Package autolaunch registers the tray host to start with Windows.
//
// The registry Run key under HKCU is deliberate rather than a Task Scheduler
// entry or a Start-menu shortcut:
//
//   - HKCU needs no elevation, so the switch works from an unelevated UI and
//     never raises a UAC prompt for a setting the user just clicked;
//   - it is per-user, which matches the rest of this app (its data directory,
//     its single-instance mutex and its tray icon are all per-user);
//   - it is exactly the mechanism the reference client uses, so the entry shows
//     up in the same place in Task Manager's startup tab and can be disabled
//     there without the app fighting it back.
//
// The value stores the quoted absolute path of the host plus its data directory,
// because the host must be able to find the same database whether it was started
// by the user or by Windows. A host started by the shell has a different working
// directory, and without an explicit --dir it would create a second, empty
// profile next to the exe.
package autolaunch

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows/registry"
)

// RunKey is where Windows looks for per-user startup commands.
const runValueName = "ClashHalo"

// Spec describes what to register.
type Spec struct {
	// Executable is the tray host (halo-host.exe), not the UI. Starting the host
	// alone restores the proxy and the tray icon; opening a window is a decision
	// the user makes, and the host already knows how to show one on demand.
	Executable string
	// DataDir is passed as --dir so the host uses the same profile.
	DataDir string
	// ExtraArgs are appended verbatim (for example --silent).
	ExtraArgs []string
}

// command renders the value to store.
func (s Spec) command() string {
	parts := []string{quote(s.Executable), "--dir", quote(s.DataDir)}
	for _, a := range s.ExtraArgs {
		parts = append(parts, quote(a))
	}
	return strings.Join(parts, " ")
}

// quote wraps a path in double quotes when it contains a space.
//
// Windows' startup command line is parsed by the shell, and an unquoted
// `C:\Program Files\...` silently becomes two arguments, which fails only on the
// machines that have a space in the path.
func quote(s string) string {
	if s == "" {
		return `""`
	}
	if strings.ContainsAny(s, " \t") && !strings.HasPrefix(s, `"`) {
		return `"` + s + `"`
	}
	return s
}

// Enable registers the host to start with Windows and returns what was written.
func Enable(spec Spec) (string, error) {
	if spec.Executable == "" {
		return "", fmt.Errorf("自启目标为空")
	}
	if _, err := os.Stat(spec.Executable); err != nil {
		return "", fmt.Errorf("找不到要自启的程序 %s: %w", spec.Executable, err)
	}
	command := spec.command()
	key, _, err := registry.CreateKey(registry.CURRENT_USER, runKeyPath(), registry.SET_VALUE)
	if err != nil {
		return "", fmt.Errorf("打开开机启动项失败: %w", err)
	}
	defer key.Close()
	if err := key.SetStringValue(runValueName, command); err != nil {
		return "", fmt.Errorf("写入开机启动项失败: %w", err)
	}
	return command, nil
}

// Disable removes the startup entry. A missing entry is not an error: the UI
// asks for the state it wants, not for a specific registry transition.
func Disable() error {
	key, err := registry.OpenKey(registry.CURRENT_USER, runKeyPath(), registry.SET_VALUE)
	if err != nil {
		if isNotExist(err) {
			return nil
		}
		return fmt.Errorf("打开开机启动项失败: %w", err)
	}
	defer key.Close()
	if err := key.DeleteValue(runValueName); err != nil && !isNotExist(err) {
		return fmt.Errorf("删除开机启动项失败: %w", err)
	}
	return nil
}

// Status reports whether the entry exists and, if it does, what it runs.
func Status() (enabled bool, command string) {
	key, err := registry.OpenKey(registry.CURRENT_USER, runKeyPath(), registry.QUERY_VALUE)
	if err != nil {
		return false, ""
	}
	defer key.Close()
	value, _, err := key.GetStringValue(runValueName)
	if err != nil {
		return false, ""
	}
	return value != "", value
}

// Matches reports whether the stored command points at [Executable].
//
// Used to distinguish "on" from "on, but pointing at a build that no longer
// exists" — a stale entry from a previous install directory would otherwise show
// as enabled while doing nothing.
func Matches(command, executable string) bool {
	if command == "" || executable == "" {
		return false
	}
	first := strings.Trim(strings.SplitN(command, " ", 2)[0], `"`)
	a, errA := filepath.Abs(first)
	b, errB := filepath.Abs(executable)
	if errA != nil || errB != nil {
		return strings.EqualFold(first, executable)
	}
	return strings.EqualFold(a, b)
}

func runKeyPath() string {
	return `Software\Microsoft\Windows\CurrentVersion\Run`
}

func isNotExist(err error) bool {
	return err == registry.ErrNotExist || os.IsNotExist(err)
}
