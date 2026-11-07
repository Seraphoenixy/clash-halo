// Package e2e contains the real end-to-end runtime verification for the
// Windows host: it builds the production binary, starts it as a separate
// process, talks to it over the real named pipe, runs traffic through the core
// it launches, and proves shutdown leaves nothing behind.
//
// This is a test rather than a script because it needs to assert on
// process-level facts (core PID gone, pipe gone) that a shell script cannot
// check reliably.
package e2e

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Microsoft/go-winio"

	"clash-halo/native/windows/internal/contract"
)

// singboxPath locates the bundled core.
func singboxPath(t *testing.T) string {
	t.Helper()
	for _, c := range []string{
		os.Getenv("HALO_SINGBOX"),
		filepath.Join("..", "..", "..", "prototype", "bin", "sing-box.exe"),
		filepath.Join("..", "..", "..", ".tmp", "sing-box.exe"),
	} {
		if c == "" {
			continue
		}
		if _, err := os.Stat(c); err == nil {
			abs, _ := filepath.Abs(c)
			return abs
		}
	}
	t.Skip("sing-box binary not found; set HALO_SINGBOX")
	return ""
}

// hostBinary builds halo-host.exe into a temp stage so the test always exercises
// the current sources, not a stale artefact.
func hostBinary(t *testing.T, stage string) string {
	t.Helper()
	out := filepath.Join(stage, "halo-host.exe")
	cmd := exec.Command("go", "build", "-o", out, "./cmd/halo-host")
	cmd.Dir = filepath.Join("..")
	cmd.Env = append(os.Environ(), "GOFLAGS=-mod=mod")
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build host: %v\n%s", err, b)
	}
	return out
}

// freePort asks the OS for an unused port so the test never collides with a
// real proxy the user may already be running.
func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve port: %v", err)
	}
	defer func() { _ = l.Close() }()
	return l.Addr().(*net.TCPAddr).Port
}

type pipeClient struct {
	conn   net.Conn
	reader *bufio.Reader
}

func dialHost(t *testing.T, base string) *pipeClient {
	t.Helper()
	timeout := 5 * time.Second
	name := contract.PipeNameFor(base)
	for i := 0; i < 60; i++ {
		c, err := winio.DialPipe(name, &timeout)
		if err == nil {
			return &pipeClient{conn: c, reader: bufio.NewReader(c)}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("could not connect to the host pipe")
	return nil
}

func (p *pipeClient) call(t *testing.T, action string, params any) contract.Response {
	t.Helper()
	req := map[string]any{"v": contract.ProtocolVersion, "id": "e2e", "action": action}
	if params != nil {
		req["params"] = params
	}
	line, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = p.conn.SetDeadline(time.Now().Add(30 * time.Second))
	if _, err := p.conn.Write(append(line, '\n')); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Events are interleaved with responses on the same stream: the host
	// broadcasts state changes to every connected client. A real client
	// discriminates frames by shape, so the test does the same instead of
	// assuming the next line is its own reply.
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		payload, err := p.reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read response for %s: %v", action, err)
		}
		var probe map[string]json.RawMessage
		if err := json.Unmarshal([]byte(payload), &probe); err != nil {
			t.Fatalf("bad frame %q: %v", payload, err)
		}
		if _, isEvent := probe["event"]; isEvent {
			var ev contract.Event
			_ = json.Unmarshal([]byte(payload), &ev)
			if ev.Event == contract.EventHostExiting {
				t.Fatalf("host announced exit while calling %s", action)
			}
			continue
		}
		var resp contract.Response
		if err := json.Unmarshal([]byte(payload), &resp); err != nil {
			t.Fatalf("bad response %q: %v", payload, err)
		}
		if os.Getenv("HALO_E2E_DEBUG") != "" {
			t.Logf("response for %s: %s", action, strings.TrimSpace(payload))
		}
		return resp
	}
	t.Fatalf("no response to %s within 30s", action)
	return contract.Response{}
}

func (p *pipeClient) snapshot(t *testing.T) map[string]any {
	t.Helper()
	resp := p.call(t, contract.ActionSnapshotGet, nil)
	if !resp.Ok {
		t.Fatalf("snapshot failed: %+v", resp.Error)
	}
	out, _ := resp.Result.(map[string]any)
	return out
}

func TestHostEndToEnd(t *testing.T) {
	stage := t.TempDir()
	core := singboxPath(t)
	// Stage the core next to the host exactly as the installer does.
	coreBytes, err := os.ReadFile(core)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, contract.CoreExecutable), coreBytes, 0o700); err != nil {
		t.Fatal(err)
	}
	hostExe := hostBinary(t, stage)
	dataDir := filepath.Join(stage, "data")

	cmd := exec.Command(hostExe, "--no-tray", "--dir", dataDir)
	cmd.Dir = stage
	cmd.Env = os.Environ()
	// Redirect to files rather than using StdoutPipe: Wait() with a pipe can
	// block on I/O that nobody reads, and a hung cleanup would hide the real
	// assertion failure behind a timeout panic.
	outFile, err := os.Create(filepath.Join(stage, "host.stdout.log"))
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stdout = outFile
	cmd.Stderr = outFile
	if err := cmd.Start(); err != nil {
		t.Fatalf("start host: %v", err)
	}
	hostDone := make(chan error, 1)
	go func() { hostDone <- cmd.Wait() }()

	exited := false
	t.Cleanup(func() {
		_ = outFile.Close()
		if exited {
			return
		}
		_ = cmd.Process.Kill()
		select {
		case <-hostDone:
		case <-time.After(10 * time.Second):
			t.Logf("host did not exit after kill; output:\n%s", readFileBestEffort(filepath.Join(stage, "host.stdout.log")))
		}
	})

	client := dialHost(t, dataDir)
	defer func() { _ = client.conn.Close() }()

	// --- 1. host answers status -------------------------------------------
	status := client.call(t, contract.ActionHostStatus, nil)
	if !status.Ok {
		t.Fatalf("host.status failed: %+v", status.Error)
	}
	if status.V != contract.ProtocolVersion {
		t.Fatalf("host returned v=%d", status.V)
	}
	snap := client.snapshot(t)
	if snap["autoLaunch"] != false {
		t.Fatalf("autoLaunch must default false, snapshot=%v", snap["autoLaunch"])
	}

	// --- 2. apply a real config ------------------------------------------
	mixedPort := freePort(t)
	ctlPort := freePort(t)
	// A local server is the traffic target: it proves the proxy path works
	// without depending on internet access or a third-party endpoint.
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "clash-halo-e2e")
	}))
	defer target.Close()

	controller := fmt.Sprintf("127.0.0.1:%d", ctlPort)
	config := fmt.Sprintf(`{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": %d}],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"},
  "experimental": {"clash_api": {"external_controller": %q, "secret": ""}}
}`, mixedPort, controller)
	apply := client.call(t, contract.ActionConfigApply, map[string]any{
		"config": config, "controller": controller,
	})
	if !apply.Ok {
		t.Fatalf("apply failed: %+v (%s)", apply.Error, apply.Error.Detail)
	}
	afterApply := client.snapshot(t)
	if afterApply["coreState"] != "running" {
		t.Fatalf("coreState = %v", afterApply["coreState"])
	}
	corePid := int(afterApply["corePid"].(float64))
	if corePid == 0 {
		t.Fatal("no core pid recorded")
	}

	// --- 3. real traffic through the proxy --------------------------------
	proxyURL := fmt.Sprintf("http://127.0.0.1:%d", mixedPort)
	proxyClient := &http.Client{
		Transport: &http.Transport{
			Proxy: func(*http.Request) (*urlpkgURL, error) { return parseURL(proxyURL) },
		},
		Timeout: 15 * time.Second,
	}
	body, err := getBody(proxyClient, target.URL)
	if err != nil {
		t.Fatalf("traffic through the proxy failed: %v", err)
	}
	if !strings.Contains(body, "clash-halo-e2e") {
		t.Fatalf("unexpected body through proxy: %q", body)
	}

	// --- 4. logs are readable and bounded --------------------------------
	tail := client.call(t, contract.ActionLogTail, map[string]any{"lines": 50})
	if !tail.Ok {
		t.Fatalf("log.tail failed: %+v", tail.Error)
	}
	tailResult, _ := tail.Result.(map[string]any)
	lines, _ := tailResult["lines"].([]any)
	if len(lines) == 0 {
		t.Fatal("host log should not be empty after an apply")
	}
	if !strings.Contains(fmt.Sprint(lines), "action=config.apply") {
		t.Fatalf("log missing expected entry: %v", lines)
	}

	// --- 5. an invalid config must be refused, core keeps running --------
	bad := client.call(t, contract.ActionConfigApply, map[string]any{
		"config": `{"outbounds":[{"type":"definitely-not-a-protocol","tag":"p"}]}`,
	})
	if bad.Ok {
		t.Fatal("invalid config was accepted")
	}
	if bad.Error == nil || bad.Error.Code != contract.ErrConfigInvalid {
		t.Fatalf("expected config_invalid, got %+v", bad.Error)
	}
	afterBad := client.snapshot(t)
	if afterBad["coreState"] != "running" {
		t.Fatalf("core died after a rejected apply: %v", afterBad["coreState"])
	}
	// Traffic must still work through the untouched config.
	if _, err := getBody(proxyClient, target.URL); err != nil {
		t.Fatalf("traffic broke after a rejected apply: %v", err)
	}

	// --- 6. proxy keeps running with no UI connected ---------------------
	// The whole point of a separate host: closing the window must not stop
	// the proxy. There is no UI here at all, and traffic still flowed above.

	// --- 7. shutdown ----------------------------------------------------
	shutdown := client.call(t, contract.ActionHostShutdown, nil)
	if !shutdown.Ok {
		t.Fatalf("shutdown refused: %+v", shutdown.Error)
	}
	_ = client.conn.Close()
	select {
	case err := <-hostDone:
		exited = true
		if err != nil {
			// Include the host's own stdout/stderr and log: a clean exit is part
			// of the contract, so the reason for a non-zero code must be visible.
			t.Fatalf("host exited with error: %v\nhost output:\n%s\nhost log:\n%s",
				err,
				readFileBestEffort(filepath.Join(stage, "host.stdout.log")),
				readFileBestEffort(filepath.Join(stage, "data", "logs", "host.log")))
		}
	case <-time.After(20 * time.Second):
		t.Fatal("host did not exit after shutdown")
	}

	// --- 8. nothing left behind -----------------------------------------
	if processAlive(corePid) {
		t.Fatalf("core process %d survived host shutdown", corePid)
	}
	// The pipe must be gone too, or a later start would attach to a dead host.
	if _, err := winio.DialPipe(contract.PipeNameFor(dataDir), durationPtr(500*time.Millisecond)); err == nil {
		t.Fatal("pipe still accepts connections after shutdown")
	}
}

// TestSecondInstanceHandsOff proves a second host does not fight the first for
// the core and the pipe.
func TestSecondInstanceHandsOff(t *testing.T) {
	stage := t.TempDir()
	core := singboxPath(t)
	coreBytes, _ := os.ReadFile(core)
	_ = os.WriteFile(filepath.Join(stage, contract.CoreExecutable), coreBytes, 0o700)
	hostExe := hostBinary(t, stage)
	dataDir := filepath.Join(stage, "data")

	first := exec.Command(hostExe, "--no-tray", "--dir", dataDir)
	first.Dir = stage
	if err := first.Start(); err != nil {
		t.Fatal(err)
	}
	firstDone := make(chan error, 1)
	go func() { firstDone <- first.Wait() }()
	t.Cleanup(func() {
		// Wait may already have completed and drained firstDone; killing and
		// waiting again would then block the full timeout and print a
		// misleading "did not exit after kill" during a passing run.
		if first.ProcessState != nil {
			return
		}
		_ = first.Process.Kill()
		select {
		case <-firstDone:
		case <-time.After(10 * time.Second):
			t.Log("first host did not exit after kill")
		}
	})
	client := dialHost(t, dataDir)
	defer func() { _ = client.conn.Close() }()

	// A second instance must exit promptly without stealing the pipe.
	second := exec.Command(hostExe, "--no-tray", "--dir", dataDir)
	second.Dir = stage
	out, err := second.CombinedOutput()
	if err != nil {
		t.Fatalf("second instance failed: %v (%s)", err, out)
	}
	if !strings.Contains(string(out), "alreadyRunning") {
		t.Fatalf("second instance should report alreadyRunning, got %q", out)
	}
	// The first host is still serving.
	if !client.call(t, contract.ActionHostStatus, nil).Ok {
		t.Fatal("first host stopped serving after a second instance started")
	}
	_ = client.call(t, contract.ActionHostShutdown, nil)
	select {
	case <-firstDone:
	case <-time.After(15 * time.Second):
		t.Fatal("first host did not exit")
	}
}

// TestHostRefusesWithoutCore proves the host does not start a proxy it cannot
// actually run.
func TestHostRefusesWithoutCore(t *testing.T) {
	stage := t.TempDir()
	hostExe := hostBinary(t, stage)
	cmd := exec.Command(hostExe, "--no-tray", "--dir", filepath.Join(stage, "data"))
	cmd.Dir = stage
	// Scrub HALO_SINGBOX: the harness sets it for the tests that *do* need a
	// core, and inheriting it here would defeat the scenario under test and
	// leave CombinedOutput blocked on a host that is legitimately running.
	cmd.Env = envWithout("HALO_SINGBOX")
	out, err := cmd.CombinedOutput()
	if err == nil {
		_ = cmd.Process.Kill()
		t.Fatal("host started without a core binary")
	}
	if !strings.Contains(string(out), "sing-box") {
		t.Fatalf("error should name the missing core: %s", out)
	}
}

// TestTrayHostExitsOnShutdown is the regression test for a zombie host.
//
// The tray mode host used to run every shutdown step — stop the core, restore
// the system proxy, close the log and the pipe — and then stay inside the
// systray message loop forever. Nothing looked wrong from the outside except
// that `--status` reported "not running" (the pipe was gone) while host.lock
// stayed locked. The next UI therefore started a "new" host, that host lost the
// single-instance race and opened another UI, and the machine accumulated a UI
// process about every two seconds.
//
// The assertion is deliberately about the *process*, not the pipe: a host that
// answers "quitting" and closes its pipe has not necessarily exited, and the
// lock it still holds is what caused the storm.
func TestTrayHostExitsOnShutdown(t *testing.T) {
	stage := t.TempDir()
	core := singboxPath(t)
	coreBytes, _ := os.ReadFile(core)
	_ = os.WriteFile(filepath.Join(stage, contract.CoreExecutable), coreBytes, 0o700)
	hostExe := hostBinary(t, stage)
	dataDir := filepath.Join(stage, "data")

	// Tray mode, not --no-tray: the headless path never had this bug because it
	// blocks on `done` instead of the systray event loop.
	host := exec.Command(hostExe, "--dir", dataDir)
	host.Dir = stage
	stdout, err := host.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	host.Stderr = host.Stdout
	if err := host.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- host.Wait() }()
	t.Cleanup(func() {
		// The shutdown path normally already reaped the process; waiting again
		// on a drained channel would stall for the full timeout on a pass.
		if host.ProcessState != nil {
			return
		}
		_ = host.Process.Kill()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Log("tray host did not exit after kill")
		}
	})
	go func() {
		// Drain so a chatty host can never block on a full pipe.
		buf := make([]byte, 4096)
		for {
			if _, err := stdout.Read(buf); err != nil {
				return
			}
		}
	}()

	client := dialHost(t, dataDir)
	defer func() { _ = client.conn.Close() }()
	if !client.call(t, contract.ActionHostShutdown, nil).Ok {
		t.Fatal("shutdown refused")
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("tray host exited with error: %v", err)
		}
	case <-time.After(25 * time.Second):
		// Report the useful half of the diagnosis: the pipe may already be gone.
		_, dialErr := winio.DialPipe(contract.PipeNameFor(dataDir),
			durationPtr(300*time.Millisecond))
		t.Fatalf("tray host process survived shutdown (pipe dial: %v); "+
			"a surviving host keeps host.lock and makes every later launch "+
			"start another host and another window", dialErr)
	}

	// The lock must be free again, which is what actually prevents the loop:
	// the OS releases host.lock when the process dies. A second host started on
	// the same data directory must therefore win the lock rather than report
	// "alreadyRunning" — that word is exactly what a still-locked directory
	// would print, so the check is cheap and directly on the causal path.
	second := exec.Command(hostExe, "--status", "--dir", dataDir)
	second.Dir = stage
	out, err := second.Output()
	if err != nil {
		t.Fatalf("--status after shutdown failed: %v", err)
	}
	if !strings.Contains(string(out), `"running":false`) {
		t.Fatalf("status after shutdown should report not-running, got %s", out)
	}
}

// TestStatusCLIReportsNotRunning covers the diagnostics path used by release
// validation.
func TestStatusCLIReportsNotRunning(t *testing.T) {
	stage := t.TempDir()
	core := singboxPath(t)
	coreBytes, _ := os.ReadFile(core)
	_ = os.WriteFile(filepath.Join(stage, contract.CoreExecutable), coreBytes, 0o700)
	hostExe := hostBinary(t, stage)
	out, err := exec.Command(hostExe, "--status", "--dir", filepath.Join(stage, "data")).Output()
	if err != nil {
		t.Fatalf("--status failed: %v", err)
	}
	if !strings.Contains(string(out), `"running":false`) {
		t.Fatalf("expected not-running report, got %s", out)
	}
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	// On Windows FindProcess always succeeds; a zero-length signal check is
	// not available, so consult the process list instead.
	out, err := exec.Command("powershell", "-NoProfile", "-Command",
		fmt.Sprintf("Get-Process -Id %d -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id", pid)).Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == fmt.Sprint(pid)
}

func durationPtr(d time.Duration) *time.Duration { return &d }

// envWithout returns the current environment with the named variables removed.
func envWithout(names ...string) []string {
	drop := make(map[string]struct{}, len(names))
	for _, n := range names {
		drop[n] = struct{}{}
	}
	out := os.Environ()[:0:0]
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		if _, skipped := drop[strings.ToUpper(key)]; skipped {
			continue
		}
		if _, skipped := drop[key]; skipped {
			continue
		}
		out = append(out, kv)
	}
	return out
}

func readFileBestEffort(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) > 40 {
		lines = lines[len(lines)-40:]
	}
	return strings.Join(lines, "\n")
}

// The two helpers below keep the import list small in the assertions above.
func getBody(c *http.Client, target string) (string, error) {
	resp, err := c.Get(target)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return string(b), err
}
