// Package tunadmin owns the one-time TUN service installation, its status and
// removal.
//
// It is separate from the TUN enable/disable state machine because installing
// is not a toggle: the service is installed once, stays idle, and every later
// enable only pings it. The package takes the app's seams as callbacks so the
// installation can be tested without SCM or UAC.
package tunadmin

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
	"clash-halo/native/windows/internal/tunservice"
)

// ServiceState is the payload of tun.serviceStatus.
type ServiceState struct {
	Installed    bool   `json:"installed"`
	Reachable    bool   `json:"reachable"`
	Backend      string `json:"backend"`
	Message      string `json:"message,omitempty"`
	ProtectedDir string `json:"protectedDir,omitempty"`
}

// Logger is the host log.
type Logger interface {
	Writef(format string, args ...any)
}

// Deps are the app seams the manager needs.
type Deps struct {
	ServicePath func() string
	CorePath    func() string
	DataDir     func() string
	LogsDir     func() string
	Log         Logger

	// Active reports whether TUN is enabled or pending.
	Active func() bool
	// Ping probes the service control pipe.
	Ping func(timeout time.Duration) (tunservice.PingResult, bool)
	// Installed reads the on-disk install description.
	Installed func() (tunservice.Config, bool)
	// MarkTun publishes a pending/other state into the snapshot.
	MarkTun func(st state.TunState, message string, pid int, adapter string, elevated bool)
	// RefreshSupport recomputes tunSupported after an install/removal.
	RefreshSupport func()
	// DisableTun stops the running TUN session before uninstalling.
	DisableTun func() *contract.ErrorObj
	// RunInstaller elevates the service binary and returns its exit code.
	RunInstaller func(args []string) (int, *contract.ErrorObj)
	// Backend names the current backend ("service"/"none").
	Backend func() string
	// ClearBackend forgets the backend after uninstall.
	ClearBackend func()
}

// Manager performs service admin actions.
type Manager struct {
	deps Deps

	hashOnce sync.Once
	coreHash string
}

// New builds a manager.
func New(deps Deps) *Manager { return &Manager{deps: deps} }

// Status reports what is installed without requiring administrator rights: the
// protected description is readable, the SCM is not.
func (m *Manager) Status() (any, *contract.ErrorObj) {
	d := m.deps
	cfg, installed := d.Installed()
	reachable := false
	message := ""
	if installed {
		if !strings.EqualFold(filepath.Clean(cfg.DataDir), filepath.Clean(d.DataDir())) {
			message = "服务绑定的数据目录与本实例不同，本实例不会使用它"
		} else if _, ok := d.Ping(400 * time.Millisecond); ok {
			reachable = true
		} else {
			message = "服务已安装但当前不可达（可能正在重启或被停止）"
		}
	}
	return ServiceState{
		Installed:    installed,
		Reachable:    reachable,
		Backend:      d.Backend(),
		Message:      message,
		ProtectedDir: cfg.ProtectedDir,
	}, nil
}

// Install stages and registers the service with one elevation.
//
// It refuses while TUN is running: replacing the service binary under a live
// core is the half-state this state machine exists to avoid.
func (m *Manager) Install() (any, *contract.ErrorObj) {
	if m.deps.Active() {
		return nil, contract.NewError(contract.ErrNotReady, "请先关闭 TUN 再安装服务")
	}
	if errObj := m.InstallService(); errObj != nil {
		return nil, errObj
	}
	return m.Status()
}

// InstallService runs the elevated installer without checking TUN state.
//
// The first TUN enable calls it too: the package installer deliberately does
// not register a service, so the one authorization happens when TUN is first
// used, not when the app is installed.
func (m *Manager) InstallService() *contract.ErrorObj {
	d := m.deps
	if _, err := os.Stat(d.ServicePath()); err != nil {
		return &contract.ErrorObj{
			Code:    contract.ErrTunUnavailable,
			Message: "找不到 TUN 服务程序",
			Detail:  filepath.Base(d.ServicePath()) + ": " + err.Error(),
		}
	}
	code, errObj := d.RunInstaller([]string{
		"--install",
		"--app-dir", filepath.Dir(d.CorePath()),
		"--data-dir", d.DataDir(),
	})
	if errObj != nil {
		return errObj
	}
	if code != 0 {
		return &contract.ErrorObj{
			Code:    contract.ErrTunUnavailable,
			Message: "TUN 服务安装失败",
			Detail:  fmt.Sprintf("安装程序退出码 %d；详细日志见 logs/tun-service-install.log", code),
		}
	}
	d.RefreshSupport()
	d.Log.Writef("[host] TUN 服务已安装")
	return nil
}

// Ensure makes the service available for this enable.
//
// The first enable installs it with one authorization; later enables ping a
// resident service. An app update changes the local core, so the approved copy
// is refreshed with one authorization at the next enable.
//
// It returns ("ready"|"absent"|"denied"|"failed", detail).
func (m *Manager) Ensure() (string, string) {
	d := m.deps
	ping, reachable := d.Ping(400 * time.Millisecond)
	if reachable {
		coreMatches := localMatches(m.LocalCoreHash(), ping.CoreSHA256)
		// Service fixes and companion files can change without changing the core.
		runtimeComplete := ping.CoreRuntime >= tunservice.CoreRuntimeVersion
		if coreMatches && runtimeComplete {
			return "ready", ""
		}
		message := "应用内核已更新，正在更新 TUN 服务（需要一次管理员授权）"
		if coreMatches {
			message = "正在更新 TUN 服务（需要一次管理员授权）"
		}
		d.MarkTun(state.TunPending, message, 0, "", false)
		d.Log.Writef("[host] TUN 服务需要更新（core=%v runtime=%d/%d）",
			coreMatches, ping.CoreRuntime, tunservice.CoreRuntimeVersion)
		if errObj := m.InstallService(); errObj != nil {
			if errObj.Code == contract.ErrElevationDenied {
				return "denied", errObj.Detail
			}
			return "failed", errObj.Message + "：" + errObj.Detail
		}
		if _, ok := m.waitForService(20 * time.Second); ok {
			return "ready", ""
		}
		return "failed", "服务更新后控制管道不可达"
	}

	if _, err := os.Stat(d.ServicePath()); err != nil {
		if _, installed := d.Installed(); installed {
			return "failed", "TUN 服务已安装，但当前目录缺少 halo-tun-service.exe，请重新安装应用"
		}
		return "absent", ""
	}
	_, installed := d.Installed()
	message := "首次启用：正在安装 TUN 服务（需要一次管理员授权）"
	if installed {
		message = "TUN 服务不可达，正在修复（需要一次管理员授权）"
	}
	d.MarkTun(state.TunPending, message, 0, "", false)
	d.Log.Writef("[host] %s", message)
	if errObj := m.InstallService(); errObj != nil {
		if errObj.Code == contract.ErrElevationDenied {
			return "denied", errObj.Detail
		}
		return "failed", errObj.Message + "：" + errObj.Detail
	}
	if _, ok := m.waitForService(20 * time.Second); ok {
		return "ready", ""
	}
	return "failed", "服务安装成功但控制管道不可达"
}

// Uninstall stops TUN, then removes the service registration.
func (m *Manager) Uninstall() (any, *contract.ErrorObj) {
	d := m.deps
	if d.Active() {
		if errObj := d.DisableTun(); errObj != nil {
			return nil, errObj
		}
	}
	if _, err := os.Stat(d.ServicePath()); err != nil {
		return nil, &contract.ErrorObj{
			Code:    contract.ErrTunUnavailable,
			Message: "找不到 TUN 服务程序",
			Detail:  filepath.Base(d.ServicePath()) + ": " + err.Error(),
		}
	}
	code, errObj := d.RunInstaller([]string{"--uninstall"})
	if errObj != nil {
		return nil, errObj
	}
	if code != 0 {
		return nil, &contract.ErrorObj{
			Code:    contract.ErrTunUnavailable,
			Message: "TUN 服务卸载失败",
			Detail:  fmt.Sprintf("卸载程序退出码 %d", code),
		}
	}
	d.ClearBackend()
	d.RefreshSupport()
	d.Log.Writef("[host] TUN 服务已卸载")
	return m.Status()
}

// LocalCoreHash is the digest of the core shipped beside the host, cached for
// the process lifetime.
func (m *Manager) LocalCoreHash() string {
	m.hashOnce.Do(func() {
		m.coreHash, _ = tunservice.ComputeSHA256File(m.deps.CorePath())
	})
	return m.coreHash
}

func (m *Manager) waitForService(timeout time.Duration) (tunservice.PingResult, bool) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ping, ok := m.deps.Ping(500 * time.Millisecond); ok {
			return ping, true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return tunservice.PingResult{}, false
}

func localMatches(local, remote string) bool {
	return local == "" || remote == "" || strings.EqualFold(local, remote)
}
