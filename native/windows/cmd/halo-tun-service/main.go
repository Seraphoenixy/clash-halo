// Command halo-tun-service runs the TUN core for the unprivileged host.
//
// It is installed once by an elevated installer and registered as a Windows
// service running as LocalSystem. The service itself is idle until the host
// asks for a core over the control pipe; it never starts a tunnel at boot, and
// it stops the core when the host process that requested it exits.
//
// Modes:
//
//	--service             run under the service control manager
//	--console             same controller, foreground, for development and tests
//	--install             create or upgrade the service (requires elevation)
//	--uninstall           stop and remove the service (requires elevation)
//	--status              print what is installed and what it is doing
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"golang.org/x/sys/windows/svc"

	"clash-halo/native/windows/internal/logs"
	"clash-halo/native/windows/internal/tunservice"
)

const version = "1"

func main() { os.Exit(run()) }

func run() int {
	serviceMode := flag.Bool("service", false, "以 Windows 服务方式运行")
	consoleMode := flag.Bool("console", false, "前台运行控制器（开发与测试）")
	installMode := flag.Bool("install", false, "安装或升级服务（需要管理员）")
	uninstallMode := flag.Bool("uninstall", false, "停止并删除服务（需要管理员）")
	statusMode := flag.Bool("status", false, "显示安装与运行状态")
	configPath := flag.String("config", "", "受保护目录中的 service.json")
	appDir := flag.String("app-dir", "", "应用目录（内含 sing-box.exe）")
	dataDir := flag.String("data-dir", "", "宿主数据目录")
	// There is deliberately no --protected-dir. The elevated installer must
	// not let its caller choose where a LocalSystem binary is written; that
	// is the same arbitrary-path primitive as the old helper --core flag.
	logPath := flag.String("log", "", "安装/卸载日志文件")
	flag.Parse()

	switch {
	case *installMode:
		if *appDir == "" || *dataDir == "" {
			fmt.Fprintln(os.Stderr, "--install 需要 --app-dir 与 --data-dir")
			return 2
		}
		logf := installerLogger(*logPath)
		res, err := tunservice.Install(tunservice.InstallOptions{
			AppDir:  *appDir,
			DataDir: *dataDir,
		}, logf)
		if err != nil {
			// Also write the reason to the install log. The host starts this
			// program through ShellExecuteEx with SW_HIDE, so stderr goes
			// nowhere: without this line the only evidence of a failed install
			// was "exit code 4" and the last successful step above it.
			logf("install failed: %v", err)
			fmt.Fprintln(os.Stderr, "安装失败:", err)
			return 4
		}
		fmt.Printf("TUN 服务已安装：%s\n", res.Config.ProtectedDir)
		if res.Upgraded {
			fmt.Println("已更新现有服务注册")
		}
		return 0
	case *uninstallMode:
		logf := installerLogger(*logPath)
		if err := tunservice.Uninstall(logf); err != nil {
			logf("uninstall failed: %v", err)
			fmt.Fprintln(os.Stderr, "卸载失败:", err)
			return 4
		}
		fmt.Println("TUN 服务已卸载")
		return 0
	case *statusMode:
		return printStatus()
	case *consoleMode:
		if *configPath == "" {
			fmt.Fprintln(os.Stderr, "--console 需要 --config")
			return 2
		}
		return runConsole(*configPath)
	case *serviceMode:
		if *configPath == "" {
			fmt.Fprintln(os.Stderr, "--service 需要 --config")
			return 2
		}
		return runWindowsService(*configPath)
	default:
		flag.Usage()
		return 2
	}
}

func printStatus() int {
	pin := tunservice.ApprovedCoreHash()
	if pin == "" {
		fmt.Println("corePin=(none; development build)")
	} else if len(pin) > 12 {
		fmt.Printf("corePin=%s\n", pin[:12])
	} else {
		fmt.Printf("corePin=%s\n", pin)
	}
	q := tunservice.Query()
	fmt.Printf("installed=%v running=%v state=%v\n", q.Installed, q.Running, q.State)
	if q.Problem != "" {
		fmt.Println("问题:", q.Problem)
	}
	if !q.Installed {
		return 0
	}
	fmt.Printf("protected=%s\ndata=%s\npipe=%s\n", q.Config.ProtectedDir, q.Config.DataDir, q.Config.PipeName)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	ping, err := tunservice.NewClient(q.Config.PipeName, 2*time.Second).Ping(ctx)
	if err != nil {
		fmt.Println("控制管道: 不可达:", err)
	} else {
		fmt.Printf("控制管道: protocol=%d state=%s\n", ping.Protocol, ping.ServiceState)
	}
	return 0
}

func stderrLog(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}

// installerLogger appends to a file when one is requested, because an elevated
// process has no console the host can read. Failures fall back to stderr.
func installerLogger(path string) tunservice.Logger {
	if path == "" {
		return stderrLog
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		fmt.Fprintf(os.Stderr, "无法打开安装日志 %s: %v\n", path, err)
		return stderrLog
	}
	return func(format string, args ...any) {
		fmt.Fprintf(f, format+"\n", args...)
	}
}

// newLogger writes to a rotating file under the protected directory. A service
// has no console, so this is the only diagnostic channel.
func newLogger(protectedDir string) (tunservice.Logger, func()) {
	path := filepath.Join(protectedDir, "service.log")
	rot, err := logs.Open(logs.DefaultOptions(path, logs.NewRedactor()))
	if err != nil {
		fmt.Fprintf(os.Stderr, "无法打开服务日志 %s: %v\n", path, err)
		return stderrLog, func() {}
	}
	return func(format string, args ...any) {
		rot.Writef(format, args...)
	}, func() { _ = rot.Close() }
}

func loadController(configPath string) (*tunservice.Controller, tunservice.Logger, func(), error) {
	cfg, err := tunservice.LoadConfig(configPath)
	if err != nil {
		return nil, nil, func() {}, err
	}
	logf, closeLog := newLogger(cfg.ProtectedDir)
	ctl := tunservice.NewController(cfg, logf)
	return ctl, logf, closeLog, nil
}

type serviceHandler struct {
	ctl *tunservice.Controller
	srv *tunservice.Server
	log tunservice.Logger
}

func (h *serviceHandler) Execute(args []string, r <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	go h.srv.Serve()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for req := range r {
		switch req.Cmd {
		case svc.Interrogate:
			status <- req.CurrentStatus
		case svc.Stop, svc.Shutdown:
			status <- svc.Status{State: svc.StopPending}
			h.log("service stop requested")
			h.ctl.Shutdown()
			h.srv.Close()
			return false, 0
		}
	}
	return false, 0
}

func runWindowsService(configPath string) int {
	ctl, logf, closeLog, err := loadController(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "加载服务配置失败:", err)
		return 4
	}
	defer closeLog()
	srv, err := tunservice.Listen(ctl, ctl.Config().OwnerSID, logf)
	if err != nil {
		logf("listen failed: %v", err)
		return 4
	}
	logf("service starting version=%s", version)
	if err := svc.Run(tunservice.ServiceName, &serviceHandler{ctl: ctl, srv: srv, log: logf}); err != nil {
		logf("svc.Run failed: %v", err)
		return 4
	}
	ctl.Shutdown()
	logf("service stopped")
	return 0
}

func runConsole(configPath string) int {
	ctl, logf, closeLog, err := loadController(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "加载服务配置失败:", err)
		return 4
	}
	defer closeLog()
	srv, err := tunservice.Listen(ctl, ctl.Config().OwnerSID, logf)
	if err != nil {
		fmt.Fprintln(os.Stderr, "监听失败:", err)
		return 4
	}
	go srv.Serve()
	fmt.Printf("TUN 服务控制器已就绪 pipe=%s\n", ctl.Config().PipeName)
	defer srv.Close()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	<-signals
	fmt.Println("正在停止…")
	ctl.Shutdown()
	return 0
}
