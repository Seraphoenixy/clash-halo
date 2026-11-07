//go:build windows

package tunsup

// Process and adapter helpers shared by the TUN service runner.
//
// The per-run elevated helper was retired, but these predicates were written
// for it and are still the rules the service depends on: readiness means "the
// adapter exists", stopping means CTRL_BREAK so sing-box removes its routes,
// and liveness must distinguish "gone" from "cannot be inspected" because a
// LocalSystem core denies an unelevated caller.

import (
	"errors"
	"net"
	"os"
	"strings"

	"golang.org/x/sys/windows"
)

// maxCoreLogBytes bounds the log every run appends to.
const maxCoreLogBytes = 8 << 20

var (
	errAdapterConflict = errors.New("TUN adapter registration conflict")
	attachConsole      = windows.NewLazySystemDLL("kernel32.dll").NewProc("AttachConsole")
	freeConsole        = windows.NewLazySystemDLL("kernel32.dll").NewProc("FreeConsole")
)

// IsAdapterConflict recognises the wintun error pair that means an old
// registration still owns the name.
//
// Both halves are required: "create adapter" alone can be a permissions
// problem, and "open existing adapter" alone can be a healthy reuse.
func IsAdapterConflict(output string) bool {
	return strings.Contains(output, "create adapter: Cannot create a file when that file already exists") &&
		strings.Contains(output, "open existing adapter: Element not found")
}

// InterruptCore asks a core process to exit cleanly.
//
// CTRL_BREAK makes sing-box remove the routes and the adapter it created, which
// terminating it outright cannot guarantee.
func InterruptCore(pid uint32) { interruptCore(pid) }

// AdapterExists reports whether the named TUN adapter is visible.
//
// net.Interfaces exposes the adapter's friendly name, which is exactly what
// interface_name sets.
func AdapterExists(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" {
		return false
	}
	list, err := net.Interfaces()
	if err != nil {
		return false
	}
	for _, iface := range list {
		if strings.EqualFold(iface.Name, name) {
			return true
		}
	}
	return false
}

// RotateLog bounds a log file that every run appends to.
//
// The core writes its output straight to this file rather than through the
// rotating host log, so without this an INFO-level core could fill the disk one
// connection at a time.
func RotateLog(path string, max int64) {
	st, err := os.Stat(path)
	if err != nil || st.Size() <= max {
		return
	}
	prev := path + ".1"
	_ = os.Remove(prev)
	_ = os.Rename(path, prev)
}

// ProcessAlive reports whether pid names a running process.
func ProcessAlive(pid int) bool {
	return ProcessState(pid) == ProcessRunning
}

// ProcState is what an unprivileged host can actually learn about a pid.
type ProcState int

const (
	// ProcessRunning: the process exists and has not exited.
	ProcessRunning ProcState = iota
	// ProcessGone: the process does not exist, or has exited.
	ProcessGone
	// ProcessUnknown: the process may well be running, but this caller is not
	// allowed to look. A service-owned core runs as LocalSystem and denies
	// PROCESS_QUERY_LIMITED_INFORMATION to a medium-integrity host, so "access
	// denied" says nothing about whether the tunnel is up.
	ProcessUnknown
)

// ProcessState reports whether pid is running, gone, or unreadable.
//
// The three-way result exists because the two-way one misreported a working
// TUN session: the host asked about a LocalSystem core, got ERROR_ACCESS_DENIED,
// read that as "the core died", tore the tunnel down and restarted the ordinary
// core on top of the port the tunnel still held. Only an explicit "no such
// process" or a real exit code proves the core is gone.
func ProcessState(pid int) ProcState {
	if pid <= 0 {
		return ProcessGone
	}
	const stillActive = 259
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
			return ProcessGone
		}
		return ProcessUnknown
	}
	defer windows.CloseHandle(h)
	var code uint32
	if err := windows.GetExitCodeProcess(h, &code); err != nil {
		return ProcessUnknown
	}
	if code == stillActive {
		return ProcessRunning
	}
	return ProcessGone
}

// interruptCore stops the core and waits for it, escalating if it does not
// leave. The GUI helper may have no console of its own; in that case attach to
// the core's console so CTRL_BREAK can reach its process group.
func interruptCore(pid uint32) {
	if windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, pid) == nil {
		return
	}
	attached, _, _ := attachConsole.Call(uintptr(pid))
	if attached == 0 {
		return
	}
	defer freeConsole.Call()
	_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, pid)
}

// TailText returns the last n bytes of a file, single-lined and trimmed.
//
// The core's fatal line is the only useful diagnostic for a failed adapter, and
// it is at the end of the log.
func TailText(path string, n int, start int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.Size() <= start {
		return ""
	}
	off := st.Size() - int64(n)
	if off < start {
		off = start
	}
	buf := make([]byte, st.Size()-off)
	if _, err := f.ReadAt(buf, off); err != nil {
		return ""
	}
	text := strings.TrimSpace(string(buf))
	// Strip ANSI colour codes: sing-box colours its FATAL lines, and raw escape
	// sequences would show up as garbage in the UI.
	text = StripANSI(text)
	return strings.Join(strings.Fields(text), " ")
}

// StripANSI removes ECMA-48 CSI sequences without pulling in a dependency.
func StripANSI(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != 0x1b {
			b.WriteByte(s[i])
			continue
		}
		// Skip "ESC [ ... final-byte".
		j := i + 1
		if j < len(s) && s[j] == '[' {
			j++
			for j < len(s) && !(s[j] >= 0x40 && s[j] <= 0x7e) {
				j++
			}
			if j < len(s) {
				j++
			}
		}
		i = j - 1
	}
	return b.String()
}
