//go:build windows

package tunsup

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Job is a Windows job object whose members are killed when the last handle to
// it closes.
//
// This is the no-orphan guarantee. If the service is killed, crashes, or is
// terminated by the SCM, the kernel closes the job handle and takes sing-box
// down with it — so a TUN adapter can never be left behind by a service that
// died without running its cleanup path.
type Job struct {
	handle windows.Handle
}

// NewJob creates a kill-on-close job object.
func NewJob() (*Job, error) {
	h, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, fmt.Errorf("tunsup: 创建作业对象失败: %w", err)
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(h,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info))); err != nil {
		_ = windows.CloseHandle(h)
		return nil, fmt.Errorf("tunsup: 配置作业对象失败: %w", err)
	}
	return &Job{handle: h}, nil
}

// Handle exposes the job handle for tests that need to wait on it.
func (j *Job) Handle() windows.Handle { return j.handle }

// AssignByPID adds an already-running process to the job.
//
// A process handle is required rather than a pid; the caller opens one with
// exactly the two rights the job needs and closes it again.
func (j *Job) AssignByPID(pid uint32) error {
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, pid)
	if err != nil {
		return fmt.Errorf("tunsup: 无法打开内核进程 %d: %w", pid, err)
	}
	defer windows.CloseHandle(h)
	if err := windows.AssignProcessToJobObject(j.handle, h); err != nil {
		return fmt.Errorf("tunsup: 将内核加入作业对象失败: %w", err)
	}
	return nil
}

// Terminate kills every process in the job.
func (j *Job) Terminate() error {
	if j.handle == 0 {
		return nil
	}
	return windows.TerminateJobObject(j.handle, 1)
}

// Close releases the handle, which by itself terminates the members.
func (j *Job) Close() error {
	if j.handle == 0 {
		return nil
	}
	err := windows.CloseHandle(j.handle)
	j.handle = 0
	return err
}
