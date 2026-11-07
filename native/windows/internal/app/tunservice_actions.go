package app

import (
	"errors"
	"path/filepath"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/elevate"
	"clash-halo/native/windows/internal/tunadmin"
	"clash-halo/native/windows/internal/tunservice"
)

// The service installation/status/removal implementation lives in tunadmin.
// These wrappers keep the app's existing action names and let tests observe the
// same seams (tunInstalled, runTunServiceInstallerFn, startElevated).

type tunServiceState = tunadmin.ServiceState

// installedTunService consults the test seam before the real install probe.
func (a *App) installedTunService() (tunservice.Config, bool) {
	if a.tunInstalled != nil {
		return a.tunInstalled()
	}
	return tunservice.Installed()
}

func (a *App) tunServiceStatus() (any, *contract.ErrorObj) {
	return a.tunAdmin.Status()
}

func (a *App) tunServiceInstall() (any, *contract.ErrorObj) {
	return a.tunAdmin.Install()
}

// installTunService runs the elevated installer without checking TUN state.
func (a *App) installTunService() *contract.ErrorObj {
	return a.tunAdmin.InstallService()
}

// ensureTunService makes the service available for this enable.
func (a *App) ensureTunService() (string, string) {
	return a.tunAdmin.Ensure()
}

func (a *App) tunServiceUninstall() (any, *contract.ErrorObj) {
	return a.tunAdmin.Uninstall()
}

// localCoreSHA256 is the digest of the core shipped beside the host, cached for
// the process lifetime. Kept on App because tests and the TUN state machine use
// it; the cache itself lives in tunadmin.
func (a *App) localCoreSHA256() string {
	return a.tunAdmin.LocalCoreHash()
}

// runTunServiceInstaller elevates the service binary and waits for its exit.
//
// The installer inherits no stdout; its diagnostics go to a log file and the
// exit code is the machine-readable result.
func (a *App) runTunServiceInstaller(args []string) (int, *contract.ErrorObj) {
	logPath := filepath.Join(a.Paths.Logs, "tun-service-install.log")
	if a.runTunServiceInstallerFn != nil {
		code, err := a.runTunServiceInstallerFn(args)
		if err != nil {
			return 0, &contract.ErrorObj{Code: contract.ErrInternal, Message: "TUN 服务安装程序失败", Detail: err.Error()}
		}
		return code, nil
	}
	launch := a.startElevated
	if launch == nil {
		launch = elevate.Start
	}
	proc, err := launch(a.Paths.TunService, append(args, "--log", logPath))
	if err != nil {
		if errors.Is(err, elevate.ErrCanceled) {
			return 0, &contract.ErrorObj{
				Code:    contract.ErrElevationDenied,
				Message: "管理员授权被取消",
				Detail:  "TUN 服务未安装；现有 TUN 方式不受影响",
			}
		}
		return 0, &contract.ErrorObj{
			Code:    contract.ErrTunUnavailable,
			Message: "无法启动 TUN 服务安装程序",
			Detail:  err.Error(),
		}
	}
	defer proc.Close()
	exited, err := proc.Wait(120_000)
	if err != nil {
		return 0, &contract.ErrorObj{Code: contract.ErrInternal, Message: "等待安装程序失败", Detail: err.Error()}
	}
	if !exited {
		_ = proc.Kill()
		return 0, &contract.ErrorObj{Code: contract.ErrInternal, Message: "安装程序超时", Detail: "120 秒内未退出"}
	}
	code, err := proc.ExitCode()
	if err != nil {
		return 0, &contract.ErrorObj{Code: contract.ErrInternal, Message: "无法读取安装程序退出码", Detail: err.Error()}
	}
	return code, nil
}
