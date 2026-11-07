// Package core supervises the bundled sing-box process.
//
// The host, not the UI, owns the core: closing the Flutter window must not
// interrupt the proxy. Restarts are bounded with exponential backoff so a
// broken config cannot spin the CPU forever.
package core

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"clash-halo/native/windows/internal/logs"
)

// Supervisor state for the running core process.
type Supervisor struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	restarts   int
	lastExit   string
	path       string
	configDir  string
	log        *logs.Rotating
	coreLog    io.Closer
	startedAt  time.Time
	onExit     func(restarts int, lastExit string)
	backoff    time.Duration
	maxBackoff time.Duration
	// Bounded restart budget within a rolling window; exceeding it leaves the
	// core stopped and an error surfaced to the UI rather than trying forever.
	windowStart  time.Time
	windowCount  int
	maxPerWindow int
	window       time.Duration
	// done is closed when the current child has exited. Stop waits on it, so
	// a caller that stops and immediately starts again cannot race the old
	// process for the listen ports and the TUN adapter.
	done chan struct{}
	// stopCh belongs to the current child and is closed by Stop. The Wait
	// goroutine reads it to tell a requested stop from a crash; a shared bool
	// could be reset by the next Start before the old child finished exiting.
	stopCh chan struct{}
	// stopTimeout bounds that wait; a core that ignores its kill is still
	// reported as stopped once the handle is closed.
	stopTimeout time.Duration
}

// Options configure a Supervisor.
type Options struct {
	CorePath  string
	ConfigDir string
	Log       *logs.Rotating
	OnExit    func(restarts int, lastExit string)
}

// New creates a supervisor. It does not start anything.
func New(opts Options) *Supervisor {
	return &Supervisor{
		path:         opts.CorePath,
		configDir:    opts.ConfigDir,
		log:          opts.Log,
		onExit:       opts.OnExit,
		backoff:      500 * time.Millisecond,
		maxBackoff:   15 * time.Second,
		maxPerWindow: 6,
		window:       10 * time.Minute,
		stopTimeout:  5 * time.Second,
	}
}

// Pid reports the running process id, or 0.
func (s *Supervisor) Pid() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd == nil || s.cmd.Process == nil {
		return 0
	}
	return s.cmd.Process.Pid
}

// Running reports whether a live process is tracked.
func (s *Supervisor) Running() bool { return s.Pid() != 0 }

// RestartCount reports how many times the core has been restarted.
func (s *Supervisor) RestartCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.restarts
}

// LastExit reports the most recent exit reason.
func (s *Supervisor) LastExit() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastExit
}

// ErrAlreadyRunning is returned when Start is called twice.
var ErrAlreadyRunning = errors.New("core already running")

// ErrNotRunning is returned when Stop has nothing to stop.
var ErrNotRunning = errors.New("core not running")

// Start launches `sing-box run -c <config>`. It returns once the process is
// spawned; readiness is proven separately by the caller's health check.
func (s *Supervisor) Start(configPath string) (int, error) {
	// A previous child that is already exiting must not turn this start into
	// ErrAlreadyRunning. That window was reachable after every stop, and it
	// surfaced as "核心已在运行" on a node switch the user had just requested.
	if err := s.awaitPrevious(2 * time.Second); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd != nil && s.cmd.Process != nil {
		return 0, ErrAlreadyRunning
	}
	if _, err := os.Stat(s.path); err != nil {
		return 0, fmt.Errorf("找不到核心程序 %s: %w", filepath.Base(s.path), err)
	}
	if _, err := os.Stat(configPath); err != nil {
		return 0, fmt.Errorf("找不到配置文件: %w", err)
	}
	cmd := exec.Command(s.path, "run", "-c", configPath, "--disable-color")
	cmd.Dir = s.configDir
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true,
		// A new process group keeps core shutdown independent of the host's
		// console, so stopping the host cannot orphan the core child tree.
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
	coreLog := s.openCoreLog()
	if coreLog != nil {
		cmd.Stdout = coreLog
		cmd.Stderr = coreLog
	}
	if err := cmd.Start(); err != nil {
		if coreLog != nil {
			_ = coreLog.Close()
		}
		s.lastExit = err.Error()
		return 0, err
	}
	s.cmd = cmd
	s.startedAt = time.Now()
	done := make(chan struct{})
	stopCh := make(chan struct{})
	s.done = done
	s.stopCh = stopCh
	pid := cmd.Process.Pid
	s.log.Writef("[host] core started pid=%d config=%s", pid, filepath.Base(configPath))
	go s.wait(cmd, coreLog, done, stopCh)
	return pid, nil
}

// awaitPrevious waits for a child that is already exiting to finish.
//
// Stop waits for that itself, so this only matters for two concurrent
// callers, or for the short window in which the Wait goroutine has not cleared
// s.cmd yet. Returning ErrAlreadyRunning in that window made a legitimate
// restart look like a duplicate start.
func (s *Supervisor) awaitPrevious(timeout time.Duration) error {
	s.mu.Lock()
	if s.cmd == nil || s.cmd.Process == nil {
		s.mu.Unlock()
		return nil
	}
	done := s.done
	s.mu.Unlock()
	if done == nil {
		return ErrAlreadyRunning
	}
	select {
	case <-done:
		return nil
	case <-time.After(timeout):
		return ErrAlreadyRunning
	}
}

func (s *Supervisor) openCoreLog() io.WriteCloser {
	if s.log == nil {
		return nil
	}
	// Core stdout is a separate bounded file so its chatty output cannot
	// evict host log lines; both are redacted by their own writers.
	path := filepath.Join(s.configDir, "core-output.log")
	rotator, err := logs.Open(logs.DefaultOptions(path, logs.NewRedactor()))
	if err != nil {
		return nil
	}
	return &closerAdapter{r: rotator}
}

type closerAdapter struct{ r *logs.Rotating }

func (c *closerAdapter) Write(p []byte) (int, error) {
	// Split on newlines: the rotating log writes line-oriented entries.
	scanner := bufio.NewScanner(bytesReader(p))
	scanner.Buffer(make([]byte, 256), 4096)
	n := 0
	for scanner.Scan() {
		line := scanner.Text()
		_ = c.r.Write(line)
		n += len(line)
	}
	return len(p), nil
}

func (c *closerAdapter) Close() error { return c.r.Close() }

func (s *Supervisor) wait(cmd *exec.Cmd, coreLog io.Closer, done chan struct{}, stopCh chan struct{}) {
	err := cmd.Wait()
	if coreLog != nil {
		_ = coreLog.Close()
	}
	// Read this child's own stop signal, not a supervisor-wide flag: the next
	// Start resets a shared flag before this goroutine may get to observe it.
	unexpected := true
	select {
	case <-stopCh:
		unexpected = false
	default:
	}
	s.mu.Lock()
	if s.cmd == cmd {
		s.cmd = nil
		s.done = nil
		s.stopCh = nil
	}
	if err != nil {
		s.lastExit = err.Error()
	} else {
		s.lastExit = "exit 0"
	}
	restarts := s.restarts
	onExit := s.onExit
	uptime := time.Since(s.startedAt)
	s.mu.Unlock()
	// Clear s.cmd before closing: a Start that observes the close must find
	// no live child, or it would wait on the same channel forever.
	close(done)

	s.log.Writef("[host] core exited after %s: %s", uptime.Round(time.Second), s.lastExit)
	if unexpected && onExit != nil {
		onExit(restarts, s.lastExit)
	}
}

// Stop terminates the core and suppresses the exit callback.
//
// It returns only after the child has exited (or the bounded wait elapsed), so
// a caller can start the next core or the elevated TUN core immediately. The
// previous version signalled the kill and returned at once; every caller then
// guessed with a 300 ms sleep, which was both slow on the happy path and too
// short when Windows took longer to release the listen ports.
func (s *Supervisor) Stop() error {
	s.mu.Lock()
	cmd := s.cmd
	if cmd == nil || cmd.Process == nil {
		s.mu.Unlock()
		return ErrNotRunning
	}
	done := s.done
	stopCh := s.stopCh
	pid := cmd.Process.Pid
	timeout := s.stopTimeout
	// Closing before the kill guarantees the Wait goroutine sees this as a
	// requested stop even if the process dies instantly.
	if stopCh != nil {
		select {
		case <-stopCh:
		default:
			close(stopCh)
		}
	}
	s.mu.Unlock()

	s.log.Writef("[host] stopping core pid=%d", pid)
	if err := cmd.Process.Kill(); err != nil {
		// Already gone is not a failure worth surfacing.
		if !errors.Is(err, os.ErrProcessDone) {
			s.log.Writef("[host] stop core failed: %v", err)
		}
	}
	if done != nil {
		select {
		case <-done:
		case <-time.After(timeout):
			s.log.Writef("[host] core pid=%d did not exit within %s", pid, timeout)
		}
	}
	return nil
}

// NextBackoff records an unexpected exit and reports how long to wait before
// a restart, or ok=false when the rolling budget is exhausted.
func (s *Supervisor) NextBackoff(now time.Time) (time.Duration, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.windowStart.IsZero() || now.Sub(s.windowStart) > s.window {
		s.windowStart = now
		s.windowCount = 0
	}
	s.windowCount++
	if s.windowCount > s.maxPerWindow {
		s.lastExit = fmt.Sprintf("核心在 %s 内失败 %d 次，已停止自动重启",
			s.window.Round(time.Minute), s.windowCount)
		return 0, false
	}
	d := s.backoff
	// Double until the cap.
	s.backoff *= 2
	if s.backoff > s.maxBackoff {
		s.backoff = s.maxBackoff
	}
	s.restarts++
	return d, true
}

// ResetBackoff is called after a core has run healthily long enough to prove
// the previous failure was transient.
func (s *Supervisor) ResetBackoff() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.backoff = 500 * time.Millisecond
	s.windowStart = time.Time{}
	s.windowCount = 0
}

// HealthCheck queries the Clash API over the loopback address the generated
// config enables. It proves the core is not merely alive but serving.
func HealthCheck(controllerAddr, secret string, timeout time.Duration) error {
	if controllerAddr == "" {
		return errors.New("未配置控制接口")
	}
	return probeHTTP("http://"+controllerAddr+"/version", secret, timeout)
}

func bytesReader(p []byte) io.Reader { return &sliceReader{buf: p} }

type sliceReader struct {
	buf []byte
	off int
}

func (r *sliceReader) Read(p []byte) (int, error) {
	if r.off >= len(r.buf) {
		return 0, io.EOF
	}
	n := copy(p, r.buf[r.off:])
	r.off += n
	return n, nil
}
