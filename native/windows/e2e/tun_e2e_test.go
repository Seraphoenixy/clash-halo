package e2e

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"clash-halo/native/windows/internal/contract"

	"golang.org/x/sys/windows"
)

// processExited reports whether a pid names a process that has terminated.
//
// OpenProcess succeeding is not enough: a terminated process whose object is
// still referenced can still be opened, so the exit code is the real answer.
func processExited(pid int) (bool, error) {
	const stillActive = 259
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return true, nil
	}
	defer windows.CloseHandle(h)
	var code uint32
	if err := windows.GetExitCodeProcess(h, &code); err != nil {
		return true, err
	}
	return code != stillActive, nil
}

// This file holds the one verification that cannot run unattended.
//
// Proving that TUN really captures traffic needs an administrator token, which
// means a real UAC prompt that a human has to see and accept. It is gated behind
// HALO_TUN_E2E=1 and skipped by default rather than being weakened into a test
// that passes without proving anything. The reasoning is the same one the plan
// applies to every platform claim: an unverified capability stays labelled
// unverified instead of being inferred from the code.
//
// Run it deliberately:
//
//	HALO_TUN_E2E=1 HALO_SINGBOX=<path> go test ./e2e/ -run TunEndToEnd -v -timeout 10m
//
// and click "Yes" on the UAC prompt when it appears.

// tunServiceBinary builds halo-tun-service.exe into the stage.
func tunServiceBinary(t *testing.T, stage string) string {
	t.Helper()
	out := filepath.Join(stage, "halo-tun-service.exe")
	cmd := exec.Command("go", "build", "-o", out, "./cmd/halo-tun-service")
	cmd.Dir = filepath.Join("..")
	cmd.Env = append(os.Environ(), "GOFLAGS=-mod=mod")
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build tun service: %v\n%s", err, b)
	}
	return out
}

// stageCore copies the core into the stage.
//
// The service installer copies the core from the app directory into its
// protected directory, exactly as an installed layout would. A hard link keeps
// the 82 MB binary from being duplicated when the volume allows it.
func stageCore(t *testing.T, core, stage string) string {
	t.Helper()
	dst := filepath.Join(stage, "sing-box.exe")
	if err := os.Link(core, dst); err == nil {
		return dst
	}
	src, err := os.Open(core)
	if err != nil {
		t.Fatalf("open core: %v", err)
	}
	defer src.Close()
	out, err := os.Create(dst)
	if err != nil {
		t.Fatalf("create staged core: %v", err)
	}
	defer out.Close()
	if _, err := io.Copy(out, src); err != nil {
		t.Fatalf("copy core: %v", err)
	}
	return dst
}

// callSlow is call() with an explicit deadline.
//
// Enabling TUN blocks until the user answers the UAC prompt, so the 30 second
// default would fail a perfectly healthy run.
func (p *pipeClient) callSlow(t *testing.T, action string, params any, timeout time.Duration) contract.Response {
	t.Helper()
	req := map[string]any{"v": contract.ProtocolVersion, "id": "tun-e2e", "action": action}
	if params != nil {
		req["params"] = params
	}
	line, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = p.conn.SetDeadline(time.Now().Add(timeout))
	if _, err := p.conn.Write(append(line, '\n')); err != nil {
		t.Fatalf("write: %v", err)
	}
	deadline := time.Now().Add(timeout)
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
			continue
		}
		var resp contract.Response
		if err := json.Unmarshal([]byte(payload), &resp); err != nil {
			t.Fatalf("bad response %q: %v", payload, err)
		}
		if resp.ID != "tun-e2e" {
			continue
		}
		return resp
	}
	t.Fatalf("no response for %s within %s", action, timeout)
	return contract.Response{}
}

func psOutput(t *testing.T, script string) string {
	t.Helper()
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("powershell: %v\n%s", err, out)
	}
	return strings.TrimSpace(string(out))
}

// adapterUp reports the adapter's status line, or "" when it does not exist.
func adapterUp(t *testing.T, name string) string {
	return psOutput(t, fmt.Sprintf(
		"$a = Get-NetAdapter -Name '%s' -ErrorAction SilentlyContinue | Select-Object -First 1; "+
			"if ($a) { \"$($a.Status)|$($a.InterfaceDescription)\" } else { '' }", name))
}

func adapterAddresses(t *testing.T, name string) string {
	return psOutput(t, fmt.Sprintf(
		"(Get-NetIPAddress -InterfaceAlias '%s' -AddressFamily IPv4 -ErrorAction SilentlyContinue | "+
			"Select-Object -ExpandProperty IPAddress) -join ','", name))
}

// adapterBytes returns received and sent byte counters for the adapter.
func adapterBytes(t *testing.T, name string) (int64, int64, bool) {
	out := psOutput(t, fmt.Sprintf(
		"$s = Get-NetAdapterStatistics -Name '%s' -ErrorAction SilentlyContinue; "+
			"if ($s) { \"$($s.ReceivedBytes),$($s.SentBytes)\" } else { '' }", name))
	if out == "" {
		return 0, 0, false
	}
	parts := strings.Split(out, ",")
	if len(parts) != 2 {
		return 0, 0, false
	}
	rx, err1 := strconv.ParseInt(strings.TrimSpace(parts[0]), 10, 64)
	tx, err2 := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
	if err1 != nil || err2 != nil {
		return 0, 0, false
	}
	return rx, tx, true
}

func waitForAdapterGone(t *testing.T, name string, timeout time.Duration) bool {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if adapterUp(t, name) == "" {
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

func TestTunEndToEnd(t *testing.T) {
	if os.Getenv("HALO_TUN_E2E") != "1" {
		t.Skip("set HALO_TUN_E2E=1 to run the elevated TUN verification; " +
			"it raises a real UAC prompt that a human must accept")
	}
	core := singboxPath(t)
	stage := t.TempDir()
	corePath := stageCore(t, core, stage)
	tunServiceBinary(t, stage)
	hostExe := hostBinary(t, stage)
	base := filepath.Join(stage, "data")
	if err := os.MkdirAll(base, 0o700); err != nil {
		t.Fatal(err)
	}

	const adapter = "clash-halo-e2e"

	port := freePort(t)
	cfg := fmt.Sprintf(`{
  "log": { "level": "warn" },
  "inbounds": [ { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": %d } ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}`, port)

	hostCmd := exec.Command(hostExe, "-no-tray", "-dir", base)
	hostCmd.Env = append(envWithout("HALO_SINGBOX"), "HALO_SINGBOX="+corePath)
	stdout, err := hostCmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	hostCmd.Stderr = hostCmd.Stdout
	if err := hostCmd.Start(); err != nil {
		t.Fatalf("start host: %v", err)
	}
	hostLog := &strings.Builder{}
	go func() { _, _ = io.Copy(hostLog, stdout) }()
	t.Cleanup(func() {
		_ = hostCmd.Process.Kill()
		_, _ = hostCmd.Process.Wait()
	})

	client := dialHost(t, base)

	// TUN must be advertised now that the service binary sits beside the core.
	status := client.callSlow(t, contract.ActionHostStatus, nil, 20*time.Second)
	statusPayload, _ := status.Result.(map[string]any)
	if statusPayload["tunSupported"] != true {
		t.Fatalf("host does not offer TUN: %v (host log: %s)", statusPayload, hostLog.String())
	}

	if resp := client.callSlow(t, contract.ActionConfigApply,
		map[string]any{"config": cfg, "startCore": true}, 60*time.Second); !resp.Ok {
		t.Fatalf("config.apply failed: %+v", resp.Error)
	}

	// Once TUN is on, every later exit path must turn it off again, including a
	// failed assertion and a panic. Leaving an elevated core behind would leave
	// the user's routing changed.
	tunOn := false
	defer func() {
		if !tunOn {
			return
		}
		t.Log("teardown: disabling TUN")
		resp := client.callSlow(t, contract.ActionTunSetEnabled,
			map[string]any{"enabled": false}, 60*time.Second)
		t.Logf("teardown tun.setEnabled(false): ok=%v err=%+v", resp.Ok, resp.Error)
		waitForAdapterGone(t, adapter, 20*time.Second)
	}()

	t.Log("enabling TUN — accept the UAC prompt for the one-time service install now")
	// strictRoute is left off for the first run: it installs firewall rules, and
	// a verification run should not change more of the machine than it must.
	resp := client.callSlow(t, contract.ActionTunSetEnabled, map[string]any{
		"enabled":     true,
		"adapterName": adapter,
		"strictRoute": false,
	}, 180*time.Second)
	if !resp.Ok {
		t.Fatalf("tun.setEnabled(true) failed: %+v\nhost log:\n%s", resp.Error, hostLog.String())
	}
	tunOn = true

	payload, _ := resp.Result.(map[string]any)
	t.Logf("tun.setEnabled result: %v", payload)
	if payload["tunState"] != "enabled" {
		t.Fatalf("tunState = %v, want enabled", payload["tunState"])
	}
	if payload["tunElevated"] != true {
		t.Fatalf("host did not confirm a real elevated token: %v", payload)
	}
	pid, _ := payload["tunPid"].(float64)
	if pid <= 0 {
		t.Fatalf("no elevated core pid reported: %v", payload)
	}
	if got, _ := payload["tunAdapter"].(string); got != adapter {
		t.Fatalf("adapter = %q, want %q", got, adapter)
	}

	// The kernel's own view, not the host's claim.
	up := adapterUp(t, adapter)
	t.Logf("adapter status: %q", up)
	if up == "" {
		t.Fatalf("host reported TUN enabled but no adapter named %q exists", adapter)
	}
	if !strings.HasPrefix(up, "Up") {
		t.Fatalf("adapter %q is not Up: %q", adapter, up)
	}
	addresses := adapterAddresses(t, adapter)
	t.Logf("adapter IPv4 addresses: %q", addresses)
	if !strings.Contains(addresses, "172.19.0.1") {
		t.Fatalf("adapter does not carry the configured address: %q", addresses)
	}
	t.Logf("default route: %s", psOutput(t, "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | "+
		"Sort-Object RouteMetric | Select-Object -First 3 | "+
		"ForEach-Object { \"$($_.InterfaceAlias) metric=$($_.RouteMetric)\" }) -join '; '"))

	// Proof that traffic really traverses the tunnel: pin the request's source
	// address to the tunnel's own IP and require the adapter's counters to move.
	//
	// Pinning matters on this machine. Another TUN adapter (singbox_tun) already
	// installs a competing default route at the same metric, so letting Windows
	// choose would make a rising counter ambiguous. The address 172.19.0.1
	// belongs only to our adapter, so a packet sourced from it must enter the
	// TUN.
	beforeRx, beforeTx, ok := adapterBytes(t, adapter)
	if !ok {
		t.Fatalf("cannot read adapter statistics, so traffic through the tunnel is unproven")
	}
	t.Logf("adapter bytes before: rx=%d tx=%d", beforeRx, beforeTx)

	code, size := httpGetThroughTunnel(t, tunSourceIP, []string{
		"https://example.com/",
		"https://www.wintun.net/",
		"https://cp.cloudflare.com/generate_204",
	})
	t.Logf("request sourced from %s: status=%d bodyBytes=%d", tunSourceIP, code, size)

	afterRx, afterTx, _ := adapterBytes(t, adapter)
	deltaRx, deltaTx := afterRx-beforeRx, afterTx-beforeTx
	t.Logf("adapter bytes after: rx=%d tx=%d (delta rx=%d tx=%d)",
		afterRx, afterTx, deltaRx, deltaTx)
	// A TLS handshake plus a response is kilobytes even when the body is empty,
	// so anything below a couple of kilobytes means the bytes never entered the
	// tunnel. Either direction is accepted because TUN statistics count reads
	// and writes from the driver's point of view.
	if deltaRx < 2048 && deltaTx < 2048 {
		t.Fatalf("adapter counters barely moved (rx +%d, tx +%d): traffic did not go through the tunnel",
			deltaRx, deltaTx)
	}

	// Disabling must restore the machine: adapter gone, and the host back to a
	// runnable state rather than reporting a stale tunnel.
	resp = client.callSlow(t, contract.ActionTunSetEnabled,
		map[string]any{"enabled": false}, 60*time.Second)
	if !resp.Ok {
		t.Fatalf("tun.setEnabled(false) failed: %+v", resp.Error)
	}
	tunOn = false
	offPayload, _ := resp.Result.(map[string]any)
	t.Logf("tun.setEnabled(false) result: %v", offPayload)
	if offPayload["tunState"] != "disabled" {
		t.Fatalf("tunState = %v after disable", offPayload["tunState"])
	}
	if !waitForAdapterGone(t, adapter, 30*time.Second) {
		t.Fatalf("adapter %q still exists after TUN was disabled", adapter)
	}
	t.Log("adapter removed after disable")

	// The elevated core must be gone too, not merely detached.
	if exited, err := processExited(int(pid)); err != nil || !exited {
		t.Fatalf("elevated core pid %d survived disable (exited=%v err=%v)", int(pid), exited, err)
	}

	// Leave the machine as it was found: the service is a persistent
	// registration, unlike the retired per-run helper. This costs one more UAC
	// prompt; a failed run before this point must be cleaned up by running
	// `halo-tun-service.exe --uninstall` as administrator.
	t.Log("uninstalling the TUN service — accept the UAC prompt to leave no registration behind")
	resp = client.callSlow(t, contract.ActionTunServiceUninstall, nil, 120*time.Second)
	if !resp.Ok {
		t.Fatalf("tun.serviceUninstall failed: %+v", resp.Error)
	}
	t.Log("TUN service uninstalled")
}

// tunSourceIP is the address the stub config assigns to the tunnel.
const tunSourceIP = "172.19.0.1"

// httpGetThroughTunnel fetches the first URL that answers, with the source
// address pinned to the tunnel.
//
// Binding an address that only our adapter owns forces the packet into the TUN
// regardless of how Windows breaks the tie between several default routes.
func httpGetThroughTunnel(t *testing.T, sourceIP string, urls []string) (int, int) {
	t.Helper()
	dialer := &net.Dialer{
		Timeout:   20 * time.Second,
		LocalAddr: &net.TCPAddr{IP: net.ParseIP(sourceIP)},
	}
	client := &http.Client{
		Timeout:   25 * time.Second,
		Transport: &http.Transport{DialContext: dialer.DialContext},
	}
	var lastErr error
	for _, u := range urls {
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			lastErr = err
			continue
		}
		req.Header.Set("User-Agent", "clash-halo-e2e")
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			t.Logf("GET %s with source %s failed: %v", u, sourceIP, err)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		_ = resp.Body.Close()
		if resp.StatusCode >= 400 {
			lastErr = fmt.Errorf("%s: status %d", u, resp.StatusCode)
			continue
		}
		return resp.StatusCode, len(body)
	}
	t.Fatalf("no request succeeded with source %s: %v", sourceIP, lastErr)
	return 0, 0
}
