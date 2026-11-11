package tunservice

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/windows"

	"clash-halo/native/windows/internal/core"
	"clash-halo/native/windows/internal/tunconfig"
	"clash-halo/native/windows/internal/tunsup"
)

// Logger is the service's diagnostic sink. The service writes to a file in its
// protected directory; tests and --console pass something else.
type Logger func(format string, args ...any)

// Controller owns the one core the service may run.
//
// All start/stop work happens under opMu, so two requests cannot race the same
// adapter. Status reads take only mu and never block on a starting core.
type Controller struct {
	cfg Config
	log Logger

	opMu sync.Mutex
	// core is non-nil only while a core is running. Guarded by opMu.
	core *tunsup.Runner

	mu      sync.Mutex
	status  tunsup.Status
	closing bool
	// ready and grace are seams for tests: production uses the OS adapter
	// list and the production grace period.
	ready    func(string) bool
	grace    time.Duration
	hostPID  int
	host     windows.Handle
	watchEnd chan struct{}
	// configHash identifies the staged document currently running, so a
	// repeated start with the same host and config is a no-op.
	configHash string
}

// NewController builds an idle controller. No process is started here.
func NewController(cfg Config, log Logger) *Controller {
	if log == nil {
		log = func(string, ...any) {}
	}
	// The installer creates these, but a --console run against a prepared
	// directory may have removed them; failing later with "cannot write" would
	// be less clear than creating them now.
	_ = os.MkdirAll(cfg.RunDir, 0o700)
	return &Controller{
		cfg:   cfg,
		log:   log,
		ready: tunsup.AdapterExists,
		grace: coreGracePeriod,
		status: tunsup.Status{
			V:       tunsup.StatusVersion,
			State:   tunsup.StateStopped,
			Message: "",
		},
	}
}

// Config returns the install description the controller was built with.
func (c *Controller) Config() Config { return c.cfg }

// Status returns a copy of the current state.
func (c *Controller) Status() tunsup.Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.status
}

// Handle dispatches one control frame.
func (c *Controller) Handle(req *Request) (any, *WireError) {
	switch req.Action {
	case ActionPing:
		return PingResult{
			Protocol:     ProtocolVersion,
			Version:      "1",
			OwnerSID:     c.cfg.OwnerSID,
			CoreSHA256:   c.cfg.CoreSHA256,
			DataDir:      c.cfg.DataDir,
			ServiceState: string(c.Status().State),
			CoreRuntime:  CoreRuntimeVersion,
		}, nil
	case ActionStatus:
		return c.Status(), nil
	case ActionStart:
		var p StartParams
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return nil, &WireError{Code: CodeBadRequest, Message: "start 参数不是 JSON: " + err.Error()}
		}
		if e := c.Start(p.Config, p.HostPID); e != nil {
			return nil, e
		}
		return c.Status(), nil
	case ActionStop:
		if e := c.Stop(""); e != nil {
			return nil, e
		}
		return c.Status(), nil
	default:
		return nil, &WireError{Code: CodeUnknownAction, Message: "未知操作: " + req.Action}
	}
}

// Start launches one core from configPath on behalf of hostPID.
//
// The returned status is the settled state: running with the adapter that was
// actually created, or failed with the core's own explanation. A failed start
// never leaves a process behind.
func (c *Controller) Start(configPath string, hostPID int) *WireError {
	c.opMu.Lock()
	defer c.opMu.Unlock()

	if c.isClosing() {
		return &WireError{Code: CodeServiceStopping, Message: "服务正在停止"}
	}
	if hostPID <= 0 {
		return &WireError{Code: CodeBadRequest, Message: "缺少宿主进程号"}
	}
	if !within(c.cfg.DataDir, configPath) {
		return &WireError{Code: CodeRejected, Message: "配置路径不在数据目录内"}
	}
	if err := c.verifyCore(); err != nil {
		c.setStatus(tunsup.StateFailed, 0, "", err.Error(), hostPID)
		return &WireError{Code: CodeRejected, Message: err.Error()}
	}
	raw, err := readConfig(configPath)
	if err != nil {
		c.setStatus(tunsup.StateFailed, 0, "", err.Error(), hostPID)
		return &WireError{Code: CodeRejected, Message: err.Error()}
	}
	adapter, err := CheckConfigForTun(c.cfg.DataDir, raw)
	if err != nil {
		msg := "配置未通过提权前检查: " + err.Error()
		c.setStatus(tunsup.StateFailed, 0, "", msg, hostPID)
		return &WireError{Code: CodeRejected, Message: msg}
	}
	hash := digest(raw)

	if c.alreadyRunning(hash, hostPID) {
		return nil
	}

	// Watch the host before starting anything: a host that is already gone
	// must not cost a core start, and a host that dies during startup is
	// caught by the same handle.
	hostHandle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(hostPID))
	if err != nil {
		msg := fmt.Sprintf("无法监视宿主进程 %d: %v", hostPID, err)
		c.setStatus(tunsup.StateFailed, 0, "", msg, hostPID)
		return &WireError{Code: CodeRejected, Message: msg}
	}

	c.setStatus(tunsup.StateStarting, 0, adapter, "正在启动内核", hostPID)
	c.stopCoreLocked()
	c.clearHostLocked()
	c.host = hostHandle
	c.hostPID = hostPID
	c.watchEnd = make(chan struct{})
	go c.watchHost(hostHandle, hostPID, c.watchEnd)

	firstError := ""
	startedAt := time.Now()
	for attempt := 1; attempt <= 3; attempt++ {
		remaining := maxStartBudget - time.Since(startedAt)
		if remaining < 5*time.Second {
			if firstError == "" {
				firstError = "TUN 启动超过时间预算"
			}
			break
		}
		budget := coreStartupTimeout
		if budget > remaining {
			budget = remaining
		}
		name := adapterVariant(adapter, attempt-1)
		staged, err := tunconfig.SetAdapterName(raw, name)
		if err != nil {
			firstError = err.Error()
			break
		}
		stagedPath := filepath.Join(c.cfg.RunDir, "runtime.json")
		if err := writeFileAtomic(stagedPath, staged, 0o600); err != nil {
			firstError = "无法写入运行配置: " + err.Error()
			break
		}
		// The host's own check is skipped in service mode; validate the exact
		// bytes the core will read once, not once per retry.
		if attempt == 1 {
			if err := core.Validate(c.cfg.CorePath, stagedPath); err != nil {
				firstError = coreFailureMessage(err.Error())
				break
			}
		}
		proc, err := c.launch(stagedPath, name, budget)
		if err == nil {
			c.core = proc
			c.configHash = hash
			c.setStatus(tunsup.StateRunning, proc.PID(), name, "TUN 已启用", hostPID)
			c.log("tun started pid=%d adapter=%s host=%d", proc.PID(), name, hostPID)
			return nil
		}
		var conflict *adapterConflictError
		if !errors.As(err, &conflict) {
			firstError = err.Error()
			break
		}
		c.log("adapter %q conflicted, retrying with a fresh name: %s", name, conflict.Error())
		firstError = err.Error()
	}
	c.clearHostLocked()
	c.setStatus(tunsup.StateFailed, 0, "", firstError, hostPID)
	c.log("tun start failed: %s", firstError)
	return &WireError{Code: CodeStartFailed, Message: firstError}
}

// Stop ends the running core. message, when set, is what the snapshot shows
// after a requested stop; an empty message means "stopped, no error".
func (c *Controller) Stop(message string) *WireError {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	c.stopCoreLocked()
	c.clearHostLocked()
	next := tunsup.StateStopped
	if message != "" {
		next = tunsup.StateFailed
	}
	c.setStatus(next, 0, "", message, 0)
	if message != "" {
		c.log("tun stopped: %s", message)
	}
	return nil
}

// Shutdown stops the core and refuses further starts. Safe to call twice.
func (c *Controller) Shutdown() {
	c.mu.Lock()
	if c.closing {
		c.mu.Unlock()
		return
	}
	c.closing = true
	c.mu.Unlock()
	c.opMu.Lock()
	c.stopCoreLocked()
	c.clearHostLocked()
	c.setStatus(tunsup.StateStopped, 0, "", "", 0)
	c.opMu.Unlock()
}

func (c *Controller) isClosing() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closing
}

// alreadyRunning is true when the same host asks again for the same document
// and the core is still healthy. It keeps a double click from restarting the
// tunnel and re-creating the adapter.
func (c *Controller) alreadyRunning(hash string, hostPID int) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.status.State != tunsup.StateRunning || c.hostPID != hostPID {
		return false
	}
	if c.configHash != hash {
		return false
	}
	// Do not compare the adapter to the configured name: a conflict retry may
	// have chosen "clash-halo-1". The document hash is the identity.
	return c.core != nil && c.core.Alive() && c.ready(c.status.Adapter)
}

// launch starts one core and waits until its adapter exists or it fails.
func (c *Controller) launch(stagedPath, adapter string, budget time.Duration) (*tunsup.Runner, error) {
	logPath := filepath.Join(c.cfg.RunDir, "core.log")
	p, err := tunsup.StartRunner(tunsup.RunnerOptions{
		CorePath:   c.cfg.CorePath,
		ConfigPath: stagedPath,
		WorkDir:    c.cfg.RunDir,
		LogPath:    logPath,
		LogLimit:   coreLogLimit,
	})
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(budget)
	for time.Now().Before(deadline) {
		if !p.Alive() {
			output := tunsup.TailText(logPath, 8<<10, p.LogStart())
			err := fmt.Errorf("TUN 适配器未能建立：%s", output)
			if tunsup.IsAdapterConflict(output) {
				p.Stop(c.grace)
				return nil, &adapterConflictError{detail: err.Error()}
			}
			p.Stop(c.grace)
			return nil, err
		}
		if c.isClosing() {
			p.Stop(c.grace)
			return nil, errors.New("服务正在停止")
		}
		if c.ready(adapter) {
			return p, nil
		}
		time.Sleep(readinessPoll)
	}
	output := tunsup.TailText(logPath, 8<<10, p.LogStart())
	p.Stop(c.grace)
	return nil, fmt.Errorf("等待 TUN 适配器超时（%s）：%s", budget, output)
}

// stopCoreLocked kills the current core if any. Caller holds opMu.
func (c *Controller) stopCoreLocked() {
	if c.core != nil {
		c.core.Stop(c.grace)
		c.core = nil
	}
	c.configHash = ""
}

// watchHost stops the core when the owning host exits.
func (c *Controller) watchHost(handle windows.Handle, hostPID int, end chan struct{}) {
	for {
		event, err := windows.WaitForSingleObject(handle, 1000)
		if err != nil || event != uint32(windows.WAIT_TIMEOUT) {
			select {
			case <-end:
				return
			default:
			}
			c.hostGone(hostPID)
			return
		}
		select {
		case <-end:
			return
		default:
		}
	}
}

func (c *Controller) hostGone(hostPID int) {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	if c.isClosing() {
		return
	}
	c.mu.Lock()
	current := c.hostPID
	c.mu.Unlock()
	if current != hostPID {
		return
	}
	c.log("host %d exited; stopping the tunnel", hostPID)
	c.stopCoreLocked()
	c.clearHostLocked()
	c.setStatus(tunsup.StateFailed, 0, "", "宿主已退出，TUN 已停止", 0)
}

// clearHostLocked releases the watcher. Caller holds opMu.
func (c *Controller) clearHostLocked() {
	c.mu.Lock()
	end := c.watchEnd
	handle := c.host
	c.watchEnd = nil
	c.host = 0
	c.hostPID = 0
	c.mu.Unlock()
	if end != nil {
		close(end)
	}
	if handle != 0 {
		_ = windows.CloseHandle(handle)
	}
}

// setStatus publishes one transition.
func (c *Controller) setStatus(st tunsup.State, pid int, adapter, message string, hostPID int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.status = tunsup.Status{
		V:         tunsup.StatusVersion,
		State:     st,
		PID:       pid,
		Adapter:   adapter,
		Elevated:  true,
		Message:   message,
		HostPID:   hostPID,
		UpdatedMs: time.Now().UnixMilli(),
	}
}

// verifyCore refuses to run anything but the bytes approved for this build.
func (c *Controller) verifyCore() error {
	if err := statCore(c.cfg.CorePath); err != nil {
		return err
	}
	return checkApprovedCore(c.cfg.CorePath, c.cfg.CoreSHA256)
}

// adapterVariant returns the Nth candidate name. Variant 0 is the requested
// name; later variants get a numeric suffix so a dead registration cannot make
// every attempt fail.
func adapterVariant(base string, n int) string {
	base = strings.TrimSpace(base)
	if n <= 0 {
		return base
	}
	suffix := fmt.Sprintf("-%d", n)
	max := tunconfig.MaxAdapterNameBytes - len(suffix)
	if len(base) > max {
		base = base[:max]
	}
	return base + suffix
}

// adapterConflictError marks a failure that a new adapter name can fix.
type adapterConflictError struct{ detail string }

func (e *adapterConflictError) Error() string { return e.detail }

func readConfig(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("无法读取配置: %w", err)
	}
	if info.Size() <= 0 || info.Size() > maxConfigBytes {
		return nil, fmt.Errorf("配置大小 %d 不在允许范围内", info.Size())
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("无法读取配置: %w", err)
	}
	return body, nil
}

func writeFileAtomic(path string, body []byte, perm os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, perm); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func digest(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}
