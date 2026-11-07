package core

import (
	"os/exec"
	"syscall"
)

func startCheck(corePath, configPath string) *exec.Cmd {
	cmd := exec.Command(corePath, "check", "-c", configPath, "--disable-color")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd
}
