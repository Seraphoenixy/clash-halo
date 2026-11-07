// TestShutdownFlag covers `halo-host.exe --shutdown`, the entry point the
// installer and the uninstaller use before replacing or deleting files.
//
// The behaviour it must not lose is the reason it exists: the host's own
// shutdown path restores the system proxy and stops the core. Killing the
// process from outside (taskkill, or the installer's own kill) skips that, and
// the machine is left pointing its proxy at a core that is no longer running.
// So the assertion is not "the process died" but "the host exited through its
// own path": the core child is gone and the pipe stopped accepting
// connections.
package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Microsoft/go-winio"

	"clash-halo/native/windows/internal/contract"
)

// stageRunningHost starts a headless host and returns its executable, its data
// directory and the pid of the core it started.
func stageRunningHost(t *testing.T) (hostExe, dataDir string, corePid int) {
	t.Helper()
	stage := t.TempDir()
	core := singboxPath(t)
	coreBytes, err := os.ReadFile(core)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, contract.CoreExecutable), coreBytes, 0o700); err != nil {
		t.Fatal(err)
	}
	hostExe = hostBinary(t, stage)
	dataDir = filepath.Join(stage, "data")

	host := exec.Command(hostExe, "--no-tray", "--dir", dataDir)
	host.Dir = stage
	if err := host.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- host.Wait() }()
	t.Cleanup(func() {
		if host.ProcessState != nil {
			return
		}
		_ = host.Process.Kill()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Log("host did not exit after kill")
		}
	})

	client := dialHost(t, dataDir)
	defer func() { _ = client.conn.Close() }()

	// A core must be running, or "the core is gone afterwards" would pass for
	// the wrong reason. The host only starts one after a config is applied.
	mixedPort := freePort(t)
	config := fmt.Sprintf(`{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": %d}],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}`, mixedPort)
	if resp := client.call(t, contract.ActionConfigApply, map[string]any{"config": config}); !resp.Ok {
		t.Fatalf("apply failed: %+v", resp.Error)
	}
	snap := client.snapshot(t)
	if snap["coreState"] != "running" {
		t.Fatalf("core is not running before shutdown: %v", snap["coreState"])
	}
	corePid = int(snap["corePid"].(float64))
	if corePid == 0 {
		t.Fatal("no core pid recorded")
	}
	return hostExe, dataDir, corePid
}

func runShutdownFlag(t *testing.T, hostExe, dataDir string) (string, error) {
	t.Helper()
	cmd := exec.Command(hostExe, "--shutdown", "--dir", dataDir)
	cmd.Dir = filepath.Dir(hostExe)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func TestShutdownFlagStopsTheHost(t *testing.T) {
	hostExe, dataDir, corePid := stageRunningHost(t)

	out, err := runShutdownFlag(t, hostExe, dataDir)
	if err != nil {
		t.Fatalf("--shutdown failed: %v (%s)", err, out)
	}
	if !strings.Contains(out, `"stopped":true`) {
		t.Fatalf("--shutdown did not report a stopped host: %s", out)
	}
	// --shutdown waits for the pipe to close, so by here the host has finished.
	if _, err := winio.DialPipe(contract.PipeNameFor(dataDir), durationPtr(500*time.Millisecond)); err == nil {
		t.Fatal("pipe still accepts connections after --shutdown")
	}
	if processAlive(corePid) {
		t.Fatalf("core process %d survived --shutdown; the proxy would keep its port", corePid)
	}
}

// A second --shutdown has nothing to stop and must still succeed: installers run
// it unconditionally, including on a machine where the app was never started.
func TestShutdownFlagWithoutHostSucceeds(t *testing.T) {
	stage := t.TempDir()
	core := singboxPath(t)
	coreBytes, _ := os.ReadFile(core)
	_ = os.WriteFile(filepath.Join(stage, contract.CoreExecutable), coreBytes, 0o700)
	hostExe := hostBinary(t, stage)

	out, err := runShutdownFlag(t, hostExe, filepath.Join(stage, "data"))
	if err != nil {
		t.Fatalf("--shutdown without a running host must succeed: %v (%s)", err, out)
	}
	if !strings.Contains(out, `"not-running"`) {
		t.Fatalf("expected a not-running report, got %s", out)
	}
}

// The flag must work even when the files this build ships are already gone.
// An uninstaller deletes the install directory before it removes the running
// host, and an upgrade replaces the core before stopping the old host; a
// --shutdown that resolved the core first would then fail with "找不到内核" and
// the caller would fall back to killing the process.
//
// The running host holds its own handle, so a second copy of the same host
// lies about the file being gone on most toolchains. Renaming it is the honest
// version of the same situation: it is no longer at the path resolveCore
// checks, and the loader is what stops a delete here.
func TestShutdownFlagDoesNotNeedTheCore(t *testing.T) {
	hostExe, dataDir, _ := stageRunningHost(t)

	core := filepath.Join(filepath.Dir(hostExe), contract.CoreExecutable)
	if err := os.Rename(core, core+".removed"); err != nil {
		t.Fatalf("could not move the staged core aside: %v", err)
	}

	out, err := runShutdownFlag(t, hostExe, dataDir)
	if err != nil {
		t.Fatalf("--shutdown must not depend on the core binary: %v (%s)", err, out)
	}
	if !strings.Contains(out, `"stopped":true`) {
		t.Fatalf("--shutdown did not stop the host: %s", out)
	}
}
