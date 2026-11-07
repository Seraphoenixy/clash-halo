package core

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// validateTimeout bounds `sing-box check`.
//
// The check runs while applyMu and tunMu are held, and a config that makes the
// core hang (a blocking outbound probe, for example) would otherwise hold the
// whole IPC queue forever: every later request — including core.stop — waits
// behind it.
const validateTimeout = 30 * time.Second

// Validate runs `sing-box check` and folds stderr into the returned error.
//
// Exit code 1 with a structural message is the documented failure mode; a run
// that cannot even start the binary is reported differently so the UI never
// tells the user their node is invalid when the file is merely missing.
func Validate(corePath, configPath string) error {
	if corePath == "" || configPath == "" {
		return errors.New("核心路径或配置路径为空")
	}
	ctx, cancel := context.WithTimeout(context.Background(), validateTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, corePath, "check", "-c", configPath, "--disable-color")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("配置校验超时（%s），已终止校验进程", validateTimeout)
	}
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return fmt.Errorf("无法执行核心校验: %w", err)
	}
	msg := strings.TrimSpace(string(out))
	if msg == "" {
		return fmt.Errorf("配置校验失败 (exit %d)", exitErr.ExitCode())
	}
	return errors.New(firstLines(msg, 4))
}

func firstLines(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "; ")
}
