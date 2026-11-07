package app

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
)

func newTestApp(t *testing.T) *App {
	t.Helper()
	base := t.TempDir()
	paths := DefaultPaths(base, testCorePath(t))
	a, err := New(paths, "test")
	if err != nil {
		t.Fatalf("app.New: %v", err)
	}
	t.Cleanup(a.Shutdown)
	return a
}

func request(t *testing.T, a *App, action string, params any) (any, *contract.ErrorObj) {
	t.Helper()
	raw, err := marshalJSON(params)
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	return a.Dispatch(&contract.Request{
		V: contract.ProtocolVersion, ID: "t1", Action: action, Params: raw,
	})
}

func TestSnapshotGet(t *testing.T) {
	a := newTestApp(t)
	result, errObj := request(t, a, contract.ActionSnapshotGet, nil)
	if errObj != nil {
		t.Fatalf("snapshot.get failed: %v", errObj)
	}
	snap, ok := result.(state.Snapshot)
	if !ok {
		t.Fatalf("result type = %T", result)
	}
	if snap.CoreState != state.CoreStopped {
		t.Fatalf("core state = %s", snap.CoreState)
	}
	if snap.AutoLaunch {
		t.Fatal("auto-launch must default off")
	}
}

func TestUnknownActionIsReported(t *testing.T) {
	a := newTestApp(t)
	_, errObj := request(t, a, "nope.notAThing", nil)
	if errObj == nil {
		t.Fatal("unknown action should fail")
	}
	if errObj.Code != contract.ErrUnknownAction {
		t.Fatalf("code = %s", errObj.Code)
	}
	if !strings.Contains(errObj.Detail, "nope.notAThing") {
		t.Fatalf("detail should name the action: %s", errObj.Detail)
	}
}

func TestCoreStartWithoutConfigIsRefused(t *testing.T) {
	a := newTestApp(t)
	_, errObj := request(t, a, contract.ActionCoreStart, nil)
	if errObj == nil {
		t.Fatal("starting with no config must fail")
	}
	// The user must be told what to do, not shown a crash.
	if !strings.Contains(errObj.Message, "配置") {
		t.Fatalf("message = %s", errObj.Message)
	}
}

func TestConfigApplyRejectsStructurallyInvalidConfig(t *testing.T) {
	a := newTestApp(t)
	_, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config": structurallyInvalidConfig,
	})
	if errObj == nil {
		t.Fatal("invalid config must be rejected")
	}
	if errObj.Code != contract.ErrConfigInvalid {
		t.Fatalf("code = %s (%s)", errObj.Code, errObj.Message)
	}
	// The rejection must come from the real core, and must not be persisted:
	// a config the core refused should never become active.json.
	active := filepath.Join(a.Paths.Configs, "active.json")
	if _, err := os.Stat(active); err == nil {
		data, _ := os.ReadFile(active)
		if strings.Contains(string(data), "definitely-not-a-protocol") {
			t.Fatal("invalid config was promoted to active.json")
		}
	}
	if _, err := os.Stat(filepath.Join(a.Paths.Configs, "candidate.json")); err == nil {
		t.Fatal("rejected candidate must be cleaned up")
	}
}

func TestConfigApplyRejectsHashMismatch(t *testing.T) {
	a := newTestApp(t)
	_, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config":     validConfig,
		"configHash": "0000000000000000000000000000000000000000000000000000000000000000",
	})
	if errObj == nil {
		t.Fatal("hash mismatch must be refused")
	}
	if errObj.Code != contract.ErrBadRequest {
		t.Fatalf("code = %s", errObj.Code)
	}
	// Refusing before writing means no config file is created at all. The
	// configs directory now also holds the tun/ subdirectory, which is part of
	// the layout rather than a written config, so only files are counted.
	entries, _ := os.ReadDir(a.Paths.Configs)
	files := 0
	for _, e := range entries {
		if !e.IsDir() {
			files++
		}
	}
	if files != 0 {
		t.Fatalf("no file should exist, found %d", files)
	}
}

func TestConfigApplyWritesActiveWhenCoreStopped(t *testing.T) {
	a := newTestApp(t)
	_, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config": validConfig,
	})
	if errObj != nil {
		t.Fatalf("apply failed: %v (%s)", errObj, errObj.Detail)
	}
	active := filepath.Join(a.Paths.Configs, "active.json")
	data, err := os.ReadFile(active)
	if err != nil {
		t.Fatalf("active.json missing: %v", err)
	}
	if !strings.Contains(string(data), "mixed-in") {
		t.Fatal("active config not written")
	}
	snap := a.Store.Snapshot()
	if snap.ConfigVersion != 1 {
		t.Fatalf("config version = %d", snap.ConfigVersion)
	}
	if len(snap.ConfigHash) != 64 {
		t.Fatalf("hash = %q", snap.ConfigHash)
	}
}

func TestConfigApplyStartsCoreAndHealthChecks(t *testing.T) {
	a := newTestApp(t)
	// This config listens on a real port and exposes the controller, so a
	// successful apply proves start + health check, not merely file writing.
	config := `{
	  "log": {"level": "warn", "timestamp": true},
	  "inbounds": [
	    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 17892}
	  ],
	  "outbounds": [{"type": "direct", "tag": "direct"}],
	  "route": {"final": "direct"},
	  "experimental": {
	    "clash_api": {"external_controller": "127.0.0.1:17893", "secret": ""}
	  }
	}`
	_, errObj := request(t, a, contract.ActionConfigApply, map[string]any{
		"config":     config,
		"controller": "127.0.0.1:17893",
	})
	if errObj != nil {
		t.Fatalf("apply failed: %v (%s)", errObj.Message, errObj.Detail)
	}
	if !a.Supervisor.Running() {
		t.Fatal("core should be running after a successful apply")
	}
	if pid := a.Supervisor.Pid(); pid == 0 {
		t.Fatal("core pid not recorded")
	}
	snap := a.Store.Snapshot()
	if snap.CoreState != state.CoreRunning || snap.CorePID == 0 {
		t.Fatalf("snapshot = %+v", snap)
	}
	// Stop deterministically so the test does not leak a process.
	if _, e := request(t, a, contract.ActionCoreStop, nil); e != nil {
		t.Fatalf("stop failed: %v", e)
	}
	after := a.Store.Snapshot()
	if after.CoreState != state.CoreStopped || after.CorePID != 0 {
		t.Fatalf("after stop: %+v", after)
	}
}

func TestModeChangesAreValidatedAndPersisted(t *testing.T) {
	a := newTestApp(t)
	if _, errObj := request(t, a, contract.ActionProxySetMode, map[string]any{"mode": "global"}); errObj != nil {
		t.Fatalf("global rejected: %v", errObj)
	}
	if got := a.Store.Snapshot().Mode; got != state.ModeGlobal {
		t.Fatalf("mode = %s", got)
	}
	_, errObj := request(t, a, contract.ActionProxySetMode, map[string]any{"mode": "turbo"})
	if errObj == nil {
		t.Fatal("unknown mode must be rejected")
	}
	if errObj.Code != contract.ErrBadRequest {
		t.Fatalf("code = %s", errObj.Code)
	}
	// A rejected mode must not change the stored value.
	if got := a.Store.Snapshot().Mode; got != state.ModeGlobal {
		t.Fatalf("mode changed to %s after rejection", got)
	}
}

// TUN is offered only when the binaries it needs are on disk. The default test
// layout points the service at the core's directory, where no service is built,
// so this is the "not installed" case.
func TestTunUnavailableWithoutService(t *testing.T) {
	a := newTestApp(t)
	if a.Store.Snapshot().TunSupported {
		t.Fatal("TUN must not be advertised without a service binary")
	}
	if got := a.Store.Snapshot().TunState; got != state.TunUnsupported {
		t.Fatalf("tun state = %s, want unsupported", got)
	}
	_, errObj := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": true})
	if errObj == nil {
		t.Fatal("enabling TUN without a service must fail")
	}
	if errObj.Code != contract.ErrTunUnavailable {
		t.Fatalf("code = %s, want %s", errObj.Code, contract.ErrTunUnavailable)
	}
	// The message has to name what is missing, otherwise the user cannot fix it.
	if !strings.Contains(a.Store.Snapshot().TunMessage, "halo-tun-service.exe") {
		t.Fatalf("tun message does not name the missing service: %q",
			a.Store.Snapshot().TunMessage)
	}
	// Disabling is always allowed and clears the state.
	if _, e := request(t, a, contract.ActionTunSetEnabled, map[string]any{"enabled": false}); e != nil {
		t.Fatalf("disable failed: %v", e)
	}
	if got := a.Store.Snapshot().TunState; got != state.TunDisabled {
		t.Fatalf("tun state after disable = %s", got)
	}
}

func TestLogTailIsBoundedAndRedacted(t *testing.T) {
	a := newTestApp(t)
	a.Redactor.Set("sup3r-s3cret-token")
	a.Log.Writef("[test] connecting with sup3r-s3cret-token")
	result, errObj := request(t, a, contract.ActionLogTail, map[string]any{"lines": 50})
	if errObj != nil {
		t.Fatalf("log.tail failed: %v", errObj)
	}
	payload, ok := result.(map[string]any)
	if !ok {
		t.Fatalf("result type = %T", result)
	}
	raw := payload["lines"]
	lines, ok := raw.([]map[string]any)
	if !ok {
		// The dispatcher may return []map[string]any typed as any.
		if s, isSlice := raw.([]any); isSlice {
			for _, item := range s {
				m, _ := item.(map[string]any)
				lines = append(lines, m)
			}
		} else {
			t.Fatalf("lines type = %T", raw)
		}
	}
	joined := ""
	for _, l := range lines {
		joined += strings.TrimSpace(toString(l["text"])) + "\n"
	}
	if strings.Contains(joined, "sup3r-s3cret-token") {
		t.Fatalf("secret leaked into log.tail: %s", joined)
	}
	if !strings.Contains(joined, "***") {
		t.Fatalf("expected redaction marker: %s", joined)
	}
}

func toString(v any) string {
	s, _ := v.(string)
	return s
}

func TestSpeedTestRejectsEmptyEndpoints(t *testing.T) {
	a := newTestApp(t)
	_, errObj := request(t, a, contract.ActionSpeedtest, map[string]any{
		"taskId": "sp1", "endpoints": []string{},
	})
	if errObj == nil {
		t.Fatal("empty endpoint list must be rejected")
	}
	if errObj.Code != contract.ErrBadRequest {
		t.Fatalf("code = %s", errObj.Code)
	}
	if a.Store.Snapshot().SpeedTestRunning {
		t.Fatal("a rejected task must not leave the running flag set")
	}
}

func TestSpeedTestCancel(t *testing.T) {
	a := newTestApp(t)
	_, errObj := request(t, a, contract.ActionTaskCancel, map[string]any{"taskId": "x"})
	if errObj == nil {
		t.Fatal("cancelling a non-running task must fail")
	}
	if errObj.Code != contract.ErrNotFound {
		t.Fatalf("code = %s", errObj.Code)
	}
}

func TestSpeedTestCancelOwnsTaskAndWaitsForRelease(t *testing.T) {
	a := newTestApp(t)
	entered := make(chan struct{})
	proxy := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
	}))
	defer proxy.Close()
	params := map[string]any{
		"taskId": "current", "metric": metricProxyLatency,
		"endpoints": []string{strings.TrimPrefix(proxy.URL, "http://")},
		"url":       "http://probe.invalid", "timeoutMs": 2000,
	}
	if _, e := request(t, a, contract.ActionSpeedtest, params); e != nil {
		t.Fatal(e)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("probe did not reach the proxy")
	}
	if _, e := request(t, a, contract.ActionTaskCancel, map[string]any{"taskId": "old"}); e == nil || e.Code != contract.ErrNotFound {
		t.Fatalf("stale cancellation = %v, want not_found", e)
	}
	finishing := make(chan struct{})
	release := make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	a.Store.Subscribe(func(s state.Snapshot) {
		if !s.SpeedTestRunning {
			select {
			case <-finishing:
			default:
				close(finishing)
				<-release
			}
		}
	})
	cancelled := make(chan *contract.ErrorObj, 1)
	go func() {
		_, e := request(t, a, contract.ActionTaskCancel, map[string]any{"taskId": "current"})
		cancelled <- e
	}()
	select {
	case <-finishing:
	case <-time.After(time.Second):
		t.Fatal("cancel did not reach the stopped-state update")
	}
	next := make(chan *contract.ErrorObj, 1)
	go func() {
		_, e := request(t, a, contract.ActionSpeedtest, map[string]any{
			"taskId": "next", "metric": metricTCP, "endpoints": []string{"127.0.0.1:1"},
		})
		next <- e
	}()
	select {
	case <-cancelled:
		t.Fatal("cancel acknowledged before publishing stopped state")
	case <-next:
		t.Fatal("next task overtook the stopped-state update")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	if e := <-cancelled; e != nil {
		t.Fatal(e)
	}
	if e := <-next; e != nil {
		t.Fatal(e)
	}
}

func TestProbeClassifiesFailures(t *testing.T) {
	// A closed port must be reported as connection_refused, not a generic
	// network error, so the UI can say what actually happened.
	res := probeOne("127.0.0.1:1", "http://127.0.0.1:1/", 700*time.Millisecond, probeBodyLimit, metricProxyLatency, make(chan struct{}))
	if res.Ok {
		t.Fatal("probe to a closed port cannot succeed")
	}
	if res.ErrorCode == "" {
		t.Fatal("failure must carry a code")
	}
}

func TestProbeDoesNotHangOnUnreachableProxy(t *testing.T) {
	cancel := make(chan struct{})
	start := time.Now()
	res := probeOne("10.255.255.1:9", "http://example.com/", 500*time.Millisecond, probeBodyLimit, metricProxyLatency, cancel)
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("probe took %s, must respect its timeout", elapsed)
	}
	if res.Ok {
		t.Fatal("unreachable proxy cannot succeed")
	}
}

func TestProbeOneReadsRealBytesForDownload(t *testing.T) {
	// A latency probe and a throughput probe are different measurements. The
	// download probe must read the body and report bytes per second; the
	// latency probe must not report a throughput at all, because its 204 target
	// has no body to measure.
	body := make([]byte, 8<<20)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	// The probe talks to the target through a proxy, and here the target is
	// served directly, so use the server itself as the "proxy": it accepts the
	// absolute-form request a proxy receives.
	addr := strings.TrimPrefix(srv.URL, "http://")
	dl := probeOne(addr, srv.URL, 3*time.Second, speedBodyLimit, metricDownload, make(chan struct{}))
	if !dl.Ok {
		t.Fatalf("download probe failed: %s %s", dl.ErrorCode, dl.ErrorMsg)
	}
	if dl.Metric != metricDownload {
		t.Fatalf("metric = %q, want %q", dl.Metric, metricDownload)
	}
	if dl.DownloadBps <= 0 {
		t.Fatalf("download probe must report throughput, got %d", dl.DownloadBps)
	}

	lat := probeOne(addr, srv.URL, 3*time.Second, probeBodyLimit, metricProxyLatency, make(chan struct{}))
	if !lat.Ok {
		t.Fatalf("latency probe failed: %s %s", lat.ErrorCode, lat.ErrorMsg)
	}
	if lat.Metric != metricProxyLatency {
		t.Fatalf("metric = %q, want %q", lat.Metric, metricProxyLatency)
	}
	// Latency is deliberately not asserted numerically: a loopback round trip
	// is under a millisecond and rounds to 0, which says nothing about the
	// code path. What matters here is that each probe reports the metric it was
	// asked for, so the two numbers can never be compared as one.
}

func TestSlowDownloadStillReportsARate(t *testing.T) {
	// A working-but-slow node is the one a speed test exists to find. If the
	// clock runs out mid-transfer, the bytes that did arrive are still a valid
	// measurement; failing there reports "unusable" for a node that merely
	// needed longer than the budget.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "1000000")
		chunk := make([]byte, 8192)
		for i := 0; i < 122; i++ {
			if _, err := w.Write(chunk); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			time.Sleep(20 * time.Millisecond)
		}
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")
	// A budget far shorter than the transfer: the response cannot finish.
	res := probeOne(addr, srv.URL, 300*time.Millisecond, speedBodyLimit,
		metricDownload, make(chan struct{}))
	if !res.Ok {
		t.Fatalf("partial data is still a measurement: %s %s",
			res.ErrorCode, res.ErrorMsg)
	}
	if res.DownloadBps <= 0 {
		t.Fatalf("a partial read must still yield a rate, got %d", res.DownloadBps)
	}
}

func TestDownloadProbeRejectsEmptyBody(t *testing.T) {
	// Asking for throughput and getting zero bytes is a failure, not a 0 B/s
	// result: a user would read 0 B/s as "this node is unusably slow" rather
	// than "the speed endpoint answered with nothing".
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")
	res := probeOne(addr, srv.URL, 3*time.Second, speedBodyLimit, metricDownload, make(chan struct{}))
	if res.Ok {
		t.Fatal("an empty body cannot be reported as a successful speed test")
	}
	if res.ErrorCode != "empty_body" {
		t.Fatalf("code = %q, want empty_body", res.ErrorCode)
	}
}

func TestProbeTCPConnectsToTheNodesOwnPort(t *testing.T) {
	// The TCP check must be a plain handshake, not an HTTP request: it is given
	// server:port of the node itself, which is not an HTTP proxy and would
	// answer an HTTP request with anything or nothing.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	res := probeTCP(ln.Addr().String(), 2*time.Second, make(chan struct{}), nil)
	if !res.Ok {
		t.Fatalf("open port must be reachable: %s %s", res.ErrorCode, res.ErrorMsg)
	}
	if res.Metric != metricTCP {
		t.Fatalf("metric = %q, want %q", res.Metric, metricTCP)
	}
	// A closed port must fail, and with a code the UI can explain.
	closed, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := closed.Addr().String()
	closed.Close()
	bad := probeTCP(addr, 2*time.Second, make(chan struct{}), nil)
	if bad.Ok {
		t.Fatal("a closed port cannot be reported as reachable")
	}
	if bad.ErrorCode == "" {
		t.Fatal("a failed TCP probe must carry an error code")
	}
}

func TestProbeUDPSilenceIsNotAVerdict(t *testing.T) {
	// Without a config there is no core to run, so the bare port check is all
	// that is left. A silence there must not become "unreachable": a port that
	// is open behind something that drops datagrams looks exactly like a closed
	// one. Reporting a fault would condemn a node nobody managed to test.
	silent, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer silent.Close()
	a := &App{}
	got := a.runProbes(speedParams{
		TaskID:    "udp-noconfig",
		Metric:    metricUDP,
		Endpoints: []string{silent.LocalAddr().String()},
		NodeIDs:   []string{"n1"},
		TimeoutMs: 100,
	}, make(chan struct{}))
	if len(got) != 1 {
		t.Fatalf("results = %d, want 1", len(got))
	}
	if got[0].ErrorCode != codeUDPUnconfirmed {
		t.Fatalf("code = %q, want %q", got[0].ErrorCode, codeUDPUnconfirmed)
	}
	if got[0].Ok {
		t.Fatal("a probe that got no answer must not report success")
	}
}

func TestSpeedTestEmitsProgressAndFinish(t *testing.T) {
	a := newTestApp(t)
	events := make(chan string, 16)
	a.SetEventSink(func(event string, data any) {
		select {
		case events <- event:
		default:
		}
	})
	_, errObj := request(t, a, contract.ActionSpeedtest, map[string]any{
		"taskId":    "sp2",
		"endpoints": []string{"127.0.0.1:1"},
		"nodeIds":   []string{"n_1"},
		"timeoutMs": 500,
	})
	if errObj != nil {
		t.Fatalf("speedtest start failed: %v", errObj)
	}
	deadline := time.After(10 * time.Second)
	finished := false
	for !finished {
		select {
		case ev := <-events:
			if ev == contract.EventTaskFinished {
				finished = true
			}
		case <-deadline:
			t.Fatal("task.finished never arrived")
		}
	}
	if a.Store.Snapshot().SpeedTestRunning {
		t.Fatal("running flag not cleared after finish")
	}
	// A second task may start now that the first completed.
	if _, e := request(t, a, contract.ActionSpeedtest, map[string]any{
		"taskId": "sp3", "endpoints": []string{"127.0.0.1:1"},
	}); e != nil {
		t.Fatalf("second task refused: %v", e)
	}
}

// The tray menu mirrors Verge's 订阅 submenu, which cannot work unless the
// subscription list survives the publish/read round trip. It did not at first:
// TrayCatalog() copied only the node slice, so the menu silently lost its
// 订阅 submenu even though the UI had published one.
func TestTrayCatalogKeepsProfiles(t *testing.T) {
	a := newTestApp(t)
	if _, errObj := request(t, a, contract.ActionTrayPublish, map[string]any{
		"nodes": []map[string]any{
			{"id": "n1", "name": "香港 01", "group": "机场 A"},
		},
		"activeNodeId":    "n1",
		"profiles":        []map[string]any{{"id": "p1", "name": "机场 A"}},
		"activeProfileId": "p1",
	}); errObj != nil {
		t.Fatalf("tray.publish failed: %v", errObj)
	}

	got := a.TrayCatalog()
	if len(got.Profiles) != 1 || got.Profiles[0].Name != "机场 A" {
		t.Fatalf("profiles were dropped: %+v", got.Profiles)
	}
	if got.ActiveProfile != "p1" {
		t.Fatalf("active profile lost: %q", got.ActiveProfile)
	}
	if len(got.Nodes) != 1 || got.ActiveNodeID != "n1" {
		t.Fatalf("nodes were dropped: %+v", got)
	}
}

// The returned catalogue must be a copy: the tray builds a menu from it on the
// tray goroutine while a UI may publish a replacement.
func TestTrayCatalogIsACopy(t *testing.T) {
	a := newTestApp(t)
	a.SetTrayCatalog(TrayCatalog{
		Nodes:    []TrayNode{{ID: "n1", Name: "香港 01"}},
		Profiles: []TrayProfile{{ID: "p1", Name: "机场 A"}},
	})
	got := a.TrayCatalog()
	got.Nodes[0].Name = "mutated"
	got.Profiles[0].Name = "mutated"
	if a.TrayCatalog().Nodes[0].Name != "香港 01" {
		t.Fatal("the caller can mutate the live node list")
	}
	if a.TrayCatalog().Profiles[0].Name != "机场 A" {
		t.Fatal("the caller can mutate the live profile list")
	}
}
