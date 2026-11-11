package tunservice

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	// ServiceExeName is the copy the SCM runs. It lives in the protected
	// directory, never beside the user-writable app.
	ServiceExeName = "halo-tun-service.exe"
	// ConfigFileName is the install description in the protected directory.
	ConfigFileName = "service.json"
	coreExeName    = "sing-box.exe"
	// cronetDLLName is the core's optional Naive runtime. It is a companion to
	// sing-box.exe, not a separate program: the loader finds it beside the exe.
	cronetDLLName = "libcronet.dll"
)

// coreRuntimeFiles are the companion files staged next to the approved core.
// A missing source is an error, not a warning: a core that cannot load its
// Naive runtime fails every TUN enable with a message about a library the user
// never installed and cannot install.
var coreRuntimeFiles = []string{cronetDLLName}

// CoreRuntimeVersion identifies the protected TUN runtime: version 1 added
// the companion DLL, and version 2 adds recovery from an invalid Wintun device.
// The host uses it to refresh an older installation even if the core matches.
const CoreRuntimeVersion = 2

// stageCoreRuntime copies the core's companion files into the protected
// directory, replacing older copies so an upgrade cannot pair a new core with a
// stale DLL.
func stageCoreRuntime(appDir, protected string) error {
	for _, name := range coreRuntimeFiles {
		src := filepath.Join(appDir, name)
		info, err := os.Stat(src)
		if err != nil {
			return fmt.Errorf("找不到内核运行时组件 %s：%w", name, err)
		}
		if info.Size() <= 0 {
			return fmt.Errorf("内核运行时组件 %s 为空", name)
		}
		if err := copyFile(src, filepath.Join(protected, name), 0o600); err != nil {
			return fmt.Errorf("无法复制 %s: %w", name, err)
		}
	}
	return nil
}

// InstallOptions describe one installation.
type InstallOptions struct {
	// AppDir holds the app's sing-box.exe; it is the source of the approved
	// copy.
	AppDir string
	// DataDir is the host's data directory, which the service is allowed to
	// read configs from.
	DataDir string
	// ProtectedDir overrides the default under Program Files. Tests use it;
	// production leaves it empty. There is deliberately no command-line flag
	// for it any more: the elevated installer must not let its caller choose
	// where a LocalSystem binary lives.
	ProtectedDir string

	// skipACLCheck is a test-only seam. t.TempDir() is user-writable by
	// construction, so staging tests cannot satisfy the production rule.
	// It is unexported, and no command-line path can set it.
	skipACLCheck bool
}

// InstallResult is what --install reports.
type InstallResult struct {
	Config   Config
	Upgraded bool
}

// Install creates or upgrades the service. It must run elevated: it writes
// under Program Files and registers a LocalSystem service.
func Install(opts InstallOptions, log Logger) (InstallResult, error) {
	if !isElevated() {
		return InstallResult{}, errors.New("安装 TUN 服务需要管理员权限")
	}
	if log == nil {
		log = func(string, ...any) {}
	}
	// An upgrade replaces the service binary and the core; Windows refuses to
	// overwrite an executable that is still running, and a running core would
	// keep the old adapter. Stop the registration first, then stage files.
	if err := stopExistingService(15 * time.Second); err != nil {
		return InstallResult{}, fmt.Errorf("无法停止现有服务: %w", err)
	}
	cfg, err := prepareFiles(opts, log)
	if err != nil {
		return InstallResult{}, err
	}
	upgraded, err := registerService(cfg, log)
	if err != nil {
		return InstallResult{}, err
	}
	log("service installed: protected=%s data=%s pipe=%s", cfg.ProtectedDir, cfg.DataDir, cfg.PipeName)
	return InstallResult{Config: cfg, Upgraded: upgraded}, nil
}

// prepareFiles stages the two executables and the install description. It is
// separate from the SCM work so it can be tested without administrator rights.
func prepareFiles(opts InstallOptions, log Logger) (Config, error) {
	if strings.TrimSpace(opts.AppDir) == "" {
		return Config{}, errors.New("缺少应用目录")
	}
	if strings.TrimSpace(opts.DataDir) == "" {
		return Config{}, errors.New("缺少数据目录")
	}
	appDir, err := filepath.Abs(opts.AppDir)
	if err != nil {
		return Config{}, err
	}
	dataDir, err := filepath.Abs(opts.DataDir)
	if err != nil {
		return Config{}, err
	}
	protected := opts.ProtectedDir
	if strings.TrimSpace(protected) == "" {
		protected, err = DefaultProtectedDir()
		if err != nil {
			return Config{}, err
		}
	}
	protected, err = filepath.Abs(protected)
	if err != nil {
		return Config{}, err
	}
	if err := os.MkdirAll(protected, 0o755); err != nil {
		return Config{}, fmt.Errorf("无法创建受保护目录: %w", err)
	}
	if !opts.skipACLCheck {
		// The directory name is not the guarantee; the ACL is. Without this
		// check a redirected Program Files would silently turn every later
		// hash pin into a no-op.
		if err := VerifyProtectedDir(protected); err != nil {
			return Config{}, err
		}
	}
	runDir := filepath.Join(protected, "run")
	if err := os.MkdirAll(runDir, 0o700); err != nil {
		return Config{}, fmt.Errorf("无法创建运行目录: %w", err)
	}

	self, err := os.Executable()
	if err != nil {
		return Config{}, err
	}
	serviceDst := filepath.Join(protected, ServiceExeName)
	if !samePath(self, serviceDst) {
		if err := copyFile(self, serviceDst, 0o755); err != nil {
			return Config{}, fmt.Errorf("无法复制服务程序: %w", err)
		}
	}
	coreSrc := filepath.Join(appDir, coreExeName)
	coreDst := filepath.Join(protected, coreExeName)
	coreStat, err := os.Stat(coreSrc)
	if err != nil {
		return Config{}, fmt.Errorf("找不到内核 %s: %w", coreSrc, err)
	}
	if coreStat.Size() <= 0 {
		return Config{}, errors.New("内核文件为空")
	}
	if err := copyFile(coreSrc, coreDst, 0o600); err != nil {
		return Config{}, fmt.Errorf("无法复制内核: %w", err)
	}
	hash, err := ComputeSHA256File(coreDst)
	if err != nil {
		return Config{}, fmt.Errorf("无法计算内核摘要: %w", err)
	}
	// The Naive outbound loads libcronet.dll from the core's own directory, so
	// the approved copy is not self-contained without it. Staging only the exe
	// left every Naive node failing with "cronet: library not found" at the
	// first `sing-box check`, and the user saw that FATAL line as the reason
	// TUN could not start. The DLL is not executed, so it is not hashed: the
	// pin covers the executable, which is what the service runs.
	if err := stageCoreRuntime(appDir, protected); err != nil {
		return Config{}, err
	}
	// When the service binary carries a build-time pin, refuse to approve a
	// different core. This is what stops a replaced file in the user-writable
	// app directory from being promoted to LocalSystem execution.
	if err := checkApprovedCore(coreDst, hash); err != nil {
		return Config{}, err
	}
	sid, err := CurrentUserSID()
	if err != nil {
		return Config{}, fmt.Errorf("无法读取安装者 SID: %w", err)
	}
	cfg, err := NewConfig(protected, dataDir, sid, hash)
	if err != nil {
		return Config{}, err
	}
	if err := cfg.Save(filepath.Join(protected, ConfigFileName)); err != nil {
		return Config{}, fmt.Errorf("无法写入服务配置: %w", err)
	}
	log("copied service=%s core=%s sha256=%s", serviceDst, coreDst, hash[:12])
	return cfg, nil
}

// stopExistingService stops a registration from an earlier install, if any.
func stopExistingService(timeout time.Duration) error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(ServiceName)
	if err != nil {
		if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
			return nil
		}
		return err
	}
	defer s.Close()
	return stopAndWait(s, timeout)
}

// registerService creates or updates the SCM entry, configures recovery, and
// starts it. The returned bool says whether an existing registration was
// updated.
func registerService(cfg Config, log Logger) (bool, error) {
	m, err := mgr.Connect()
	if err != nil {
		return false, fmt.Errorf("无法连接服务控制管理器: %w", err)
	}
	defer m.Disconnect()

	binary := filepath.Join(cfg.ProtectedDir, ServiceExeName)
	configPath := filepath.Join(cfg.ProtectedDir, ConfigFileName)
	serviceConfig := serviceConfig()
	args := []string{"--service", "--config", configPath}

	s, err := m.OpenService(ServiceName)
	upgraded := false
	if err == nil {
		upgraded = true
		if err := stopAndWait(s, 15*time.Second); err != nil {
			s.Close()
			return false, fmt.Errorf("无法停止旧服务: %w", err)
		}
		err = s.UpdateConfig(serviceConfig)
		if err == nil {
			err = s.SetRecoveryActions(recoveryActions(), 86400)
		}
		if err == nil {
			err = s.SetRecoveryActionsOnNonCrashFailures(true)
		}
		if err != nil {
			s.Close()
			return false, fmt.Errorf("无法更新服务配置: %w", err)
		}
	} else {
		if !errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
			return false, fmt.Errorf("无法打开服务: %w", err)
		}
		s, err = m.CreateService(ServiceName, binary, serviceConfig, args...)
		if err != nil {
			return false, fmt.Errorf("无法创建服务: %w", err)
		}
		if err := s.SetRecoveryActions(recoveryActions(), 86400); err != nil {
			s.Close()
			return false, fmt.Errorf("无法设置恢复策略: %w", err)
		}
		if err := s.SetRecoveryActionsOnNonCrashFailures(true); err != nil {
			s.Close()
			return false, fmt.Errorf("无法设置恢复策略: %w", err)
		}
	}
	defer s.Close()
	if err := s.Start(); err != nil {
		return upgraded, fmt.Errorf("服务已注册但启动失败: %w", err)
	}
	log("service %s registered and started (upgraded=%v)", ServiceName, upgraded)
	return upgraded, nil
}

// serviceConfig is the SCM registration used by both paths.
//
// ServiceType must be set explicitly. mgr.CreateService fills a zero
// ServiceType with SERVICE_WIN32_OWN_PROCESS, but mgr.UpdateConfig does not:
// it passes the zero straight to ChangeServiceConfig, which rejects it with
// "The parameter is incorrect." Fresh installs therefore succeeded while every
// upgrade failed — and an upgrade is exactly what an app update triggers.
func serviceConfig() mgr.Config {
	return mgr.Config{
		ServiceType:      windows.SERVICE_WIN32_OWN_PROCESS,
		DisplayName:      DisplayName,
		Description:      Description,
		StartType:        mgr.StartAutomatic,
		ServiceStartName: "LocalSystem",
		ErrorControl:     mgr.ErrorNormal,
	}
}

// recoveryActions give the SCM a bounded restart policy. The service itself is
// stateless: a restart never brings a core or an adapter back.
func recoveryActions() []mgr.RecoveryAction {
	return []mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 15 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}
}

// Uninstall stops and removes the service, then deletes the protected copy.
// The data directory is left alone: it belongs to the user.
func Uninstall(log Logger) error {
	if !isElevated() {
		return errors.New("卸载 TUN 服务需要管理员权限")
	}
	if log == nil {
		log = func(string, ...any) {}
	}
	protected, err := DefaultProtectedDir()
	if err != nil {
		return err
	}
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("无法连接服务控制管理器: %w", err)
	}
	defer m.Disconnect()
	s, err := m.OpenService(ServiceName)
	if err == nil {
		_ = stopAndWait(s, 15*time.Second)
		if err := s.Delete(); err != nil {
			s.Close()
			return fmt.Errorf("无法删除服务: %w", err)
		}
		s.Close()
		log("service %s deleted", ServiceName)
	} else if !errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
		return fmt.Errorf("无法打开服务: %w", err)
	}
	if err := os.RemoveAll(protected); err != nil {
		return fmt.Errorf("无法删除受保护目录: %w", err)
	}
	log("removed %s", protected)
	return nil
}

// Installed reports the install description without touching the SCM. The
// host runs unprivileged and may not be allowed to open the service, but it can
// read the protected directory; that is enough to say "installed or not".
func Installed() (Config, bool) {
	protected, err := DefaultProtectedDir()
	if err != nil {
		return Config{}, false
	}
	cfg, err := LoadConfig(filepath.Join(protected, ConfigFileName))
	if err != nil {
		return Config{}, false
	}
	return cfg, true
}

// InstallQuery is the state --status and the app report.
type InstallQuery struct {
	Installed bool
	Running   bool
	State     svc.State
	Config    Config
	Problem   string
}

// Query installs nothing; it reports what is on this machine.
func Query() InstallQuery {
	var out InstallQuery
	protected, err := DefaultProtectedDir()
	if err != nil {
		out.Problem = err.Error()
		return out
	}
	cfgPath := filepath.Join(protected, ConfigFileName)
	cfg, err := LoadConfig(cfgPath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			out.Problem = err.Error()
		}
		return out
	}
	out.Installed = true
	out.Config = cfg

	m, err := mgr.Connect()
	if err != nil {
		out.Problem = err.Error()
		return out
	}
	defer m.Disconnect()
	s, err := m.OpenService(ServiceName)
	if err != nil {
		out.Problem = "服务未注册: " + err.Error()
		return out
	}
	defer s.Close()
	st, err := s.Query()
	if err != nil {
		out.Problem = err.Error()
		return out
	}
	out.State = st.State
	out.Running = st.State == svc.Running
	return out
}

// stopAndWait asks the service to stop and waits for the SCM to say it did.
func stopAndWait(s *mgr.Service, timeout time.Duration) error {
	st, err := s.Control(svc.Stop)
	if err != nil && !errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE) {
		return err
	}
	deadline := time.Now().Add(timeout)
	for {
		if st.State == svc.Stopped {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("服务未在 %s 内停止", timeout)
		}
		time.Sleep(200 * time.Millisecond)
		st, err = s.Query()
		if err != nil {
			return err
		}
	}
}

// CurrentUserSID returns the SID of the process token. In the elevated
// installer this is the user who approved the prompt, which is the account the
// control pipe is restricted to.
func CurrentUserSID() (string, error) {
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &token); err != nil {
		return "", err
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return "", err
	}
	return user.User.Sid.String(), nil
}

func samePath(a, b string) bool {
	aa, err := filepath.Abs(a)
	if err != nil {
		return false
	}
	bb, err := filepath.Abs(b)
	if err != nil {
		return false
	}
	return strings.EqualFold(aa, bb)
}
