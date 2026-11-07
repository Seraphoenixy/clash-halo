package tunsup

import (
	"fmt"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// RunnerOptions describe one sing-box child process.
type RunnerOptions struct {
	CorePath   string
	ConfigPath string
	WorkDir    string
	LogPath    string
	// LogLimit bounds the log before this run truncates it; zero uses
	// maxCoreLogBytes.
	LogLimit int64
}

// Runner owns one core process and its job object.
//
// It is the single implementation of "start sing-box, keep it in a job, stop it
// with CTRL_BREAK": the LocalSystem service uses it for every enabled tunnel.
type Runner struct {
	pid      int
	job      *Job
	logFile  *os.File
	logStart int64
	exited   chan struct{}
	exitErr  error
	stopOnce sync.Once
}

// StartRunner launches the core and assigns it to a job object.
func StartRunner(o RunnerOptions) (*Runner, error) {
	limit := o.LogLimit
	if limit <= 0 {
		limit = maxCoreLogBytes
	}
	RotateLog(o.LogPath, limit)
	logFile, err := os.OpenFile(o.LogPath, os.O_CREATE|os.O_RDWR|os.O_APPEND, 0o600)
	if err != nil {
		return nil, fmt.Errorf("无法打开内核日志: %w", err)
	}
	info, err := logFile.Stat()
	if err != nil {
		_ = logFile.Close()
		return nil, fmt.Errorf("无法读取内核日志位置: %w", err)
	}
	job, err := NewJob()
	if err != nil {
		_ = logFile.Close()
		return nil, fmt.Errorf("无法创建作业对象: %w", err)
	}
	cmd := exec.Command(o.CorePath, "run", "-c", o.ConfigPath, "--disable-color")
	cmd.Dir = o.WorkDir
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	// CTRL_BREAK reaches the core's process group, which lets sing-box remove
	// the routes and adapter it created instead of leaving them behind.
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP,
	}
	if err := cmd.Start(); err != nil {
		_ = job.Close()
		_ = logFile.Close()
		return nil, fmt.Errorf("内核启动失败: %w", err)
	}
	r := &Runner{
		pid:      cmd.Process.Pid,
		job:      job,
		logFile:  logFile,
		logStart: info.Size(),
		exited:   make(chan struct{}),
	}
	// Assign after Start: exec.Cmd cannot create a suspended process. The
	// window is benign because sing-box spawns no children and a core that
	// dies this early is reported as failed anyway.
	if err := job.AssignByPID(uint32(r.pid)); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		_ = job.Close()
		_ = logFile.Close()
		return nil, fmt.Errorf("无法把内核放入作业对象: %w", err)
	}
	go func() {
		r.exitErr = cmd.Wait()
		close(r.exited)
	}()
	return r, nil
}

// PID is the core process id.
func (r *Runner) PID() int { return r.pid }

// LogFile is the open core log. Readiness checks read new bytes from it.
func (r *Runner) LogFile() *os.File { return r.logFile }

// LogStart is the log position before this run wrote anything.
func (r *Runner) LogStart() int64 { return r.logStart }

// Exited is closed when the process has exited.
func (r *Runner) Exited() <-chan struct{} { return r.exited }

// ExitErr is the wait error, valid after Exited is closed.
func (r *Runner) ExitErr() error { return r.exitErr }

// Alive reports whether the process has not exited yet.
func (r *Runner) Alive() bool {
	if r == nil {
		return false
	}
	select {
	case <-r.exited:
		return false
	default:
		return true
	}
}

// Stop asks the core to exit cleanly, then terminates it if it does not.
//
// Idempotent: the supervisor may call it from several exit paths and a
// deferred call.
func (r *Runner) Stop(grace time.Duration) {
	if r == nil {
		return
	}
	r.stopOnce.Do(func() {
		InterruptCore(uint32(r.pid))
		select {
		case <-r.exited:
		case <-time.After(grace):
			_ = r.job.Terminate()
			<-r.exited
		}
		_ = r.job.Close()
		_ = r.logFile.Close()
	})
}
