//go:build windows

// Package elevate starts a process with administrator rights through the
// Windows shell, so the user grants it with the ordinary UAC prompt.
//
// The alternative — asking the user to run the whole application as
// administrator — was rejected by the plan: the UI and the tray stay at medium
// integrity and only the TUN service installer is ever elevated. Everything
// here exists to make that one prompt happen on demand, and to report a refusal
// as a normal outcome the user can act on rather than an error they cannot.
package elevate

import (
	"errors"
	"fmt"
	"strings"
	"syscall"
	"unsafe"
)

// ErrCanceled means the user declined the UAC prompt. It is deliberately a
// distinct error: refusing elevation is a legitimate choice, not a failure, and
// the host maps it to `elevation_denied` rather than a scary internal error.
var ErrCanceled = errors.New("elevate: 用户取消了管理员授权")

const (
	// SEE_MASK_NOCLOSEPROCESS is required to receive hProcess.
	seeMaskNoCloseProcess = 0x00000040
	// SEE_MASK_FLAG_NO_UI suppresses the shell's own error dialogs; the UAC
	// prompt itself is not affected.
	seeMaskFlagNoUI = 0x00000400
	// swHide keeps the elevated console from flashing on screen.
	swHide = 0
	// ERROR_CANCELLED is what the shell reports when the user says no.
	errorCancelled = 1223
)

var procShellExecuteExW = syscall.NewLazyDLL("shell32.dll").NewProc("ShellExecuteExW")

// shellExecuteInfoW mirrors SHELLEXECUTEINFOW field for field.
//
// The field types are the SDK's, not convenient Go ones. In particular fMask is
// ULONG — four bytes on every platform — and *not* ULONG_PTR. That mistake
// shifts every later field by four bytes, after which ShellExecuteExW reads a
// verb, a file name and a parameter string out of the wrong slots and the only
// symptom is a misleading "Access is denied". cbSize is computed with
// unsafe.Sizeof (112 on amd64) and TestStructLayoutMatchesSDK pins every offset.
//
// Taken from shellapi.h in the Windows SDK, 10.0.26100.0.
type shellExecuteInfoW struct {
	cbSize         uint32
	fMask          uint32
	hwnd           uintptr
	lpVerb         *uint16
	lpFile         *uint16
	lpParameters   *uint16
	lpDirectory    *uint16
	nShow          int32
	hInstApp       uintptr
	lpIDList       uintptr
	lpClass        *uint16
	hkeyClass      uintptr
	dwHotKey       uint32
	hIconOrMonitor uintptr
	hProcess       syscall.Handle
}

// Process is a launched process the caller can wait for and close.
type Process struct {
	PID  int
	Path string
	h    syscall.Handle
}

// Start runs exePath as administrator with args.
func Start(exePath string, args []string) (*Process, error) {
	return start("runas", exePath, args)
}

// start is separate so tests can exercise the whole ShellExecuteEx path with a
// verb that needs no prompt; production only ever passes "runas".
func start(verb, exePath string, args []string) (*Process, error) {
	if strings.TrimSpace(exePath) == "" {
		return nil, fmt.Errorf("elevate: 可执行路径为空")
	}
	verbPtr, err := syscall.UTF16PtrFromString(verb)
	if err != nil {
		return nil, err
	}
	filePtr, err := syscall.UTF16PtrFromString(exePath)
	if err != nil {
		return nil, err
	}
	var paramsPtr *uint16
	if len(args) > 0 {
		paramsPtr, err = syscall.UTF16PtrFromString(quoteArgs(args))
		if err != nil {
			return nil, err
		}
	}

	info := shellExecuteInfoW{
		fMask:        seeMaskNoCloseProcess | seeMaskFlagNoUI,
		lpVerb:       verbPtr,
		lpFile:       filePtr,
		lpParameters: paramsPtr,
		nShow:        swHide,
	}
	info.cbSize = uint32(unsafe.Sizeof(info))

	ret, _, callErr := procShellExecuteExW.Call(uintptr(unsafe.Pointer(&info)))
	if ret == 0 {
		if isCanceled(callErr) {
			return nil, ErrCanceled
		}
		return nil, fmt.Errorf("elevate: 启动 %s 失败: %w", exePath, callErr)
	}
	if info.hProcess == 0 {
		// Succeeds without a handle only if the mask were wrong, which would
		// silently remove our ability to wait; better to fail loudly.
		return nil, fmt.Errorf("elevate: 未获得进程句柄（SEE_MASK_NOCLOSEPROCESS 失效）")
	}
	pid := processID(info.hProcess)
	return &Process{PID: pid, Path: exePath, h: info.hProcess}, nil
}

// isCanceled reports whether a shell error means the user declined.
func isCanceled(err error) bool {
	return errors.Is(err, syscall.Errno(errorCancelled))
}

var procGetProcessId = syscall.NewLazyDLL("kernel32.dll").NewProc("GetProcessId")

// processID reads the pid behind a process handle.
//
// Resolved dynamically because the syscall package exposes Getpid for the
// current process only, and a shell-returned handle has no os.Process wrapper.
func processID(h syscall.Handle) int {
	pid, _, _ := procGetProcessId.Call(uintptr(h))
	return int(pid)
}

// Wait blocks up to ms milliseconds for exit; ms < 0 waits forever.
func (p *Process) Wait(ms int) (bool, error) {
	timeout := uint32(syscall.INFINITE)
	if ms >= 0 {
		timeout = uint32(ms)
	}
	event, err := syscall.WaitForSingleObject(p.h, timeout)
	if err != nil {
		return false, err
	}
	return event == syscall.WAIT_OBJECT_0, nil
}

// ExitCode reports the process exit code; only meaningful after exit.
func (p *Process) ExitCode() (int, error) {
	var code uint32
	if err := syscall.GetExitCodeProcess(p.h, &code); err != nil {
		return 0, err
	}
	return int(code), nil
}

// Kill terminates the process.
//
// The stop file is the primary way to end an elevated run; this is the backstop
// for a helper that stopped responding. It only works because the handle comes
// from the shell, which opened it with full access on our behalf — a medium
// integrity process cannot obtain such a handle after the fact.
func (p *Process) Kill() error {
	if p.h == 0 {
		return nil
	}
	return syscall.TerminateProcess(p.h, 1)
}

// Close releases the handle. Not closing it leaks a process handle per run.
func (p *Process) Close() {
	if p.h != 0 {
		_ = syscall.CloseHandle(p.h)
		p.h = 0
	}
}
