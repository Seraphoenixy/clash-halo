package ipc

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"clash-halo/native/windows/internal/contract"
)

// newTestServer starts a server on a uniquely named pipe so concurrent test
// runs cannot collide.
func newTestServer(t *testing.T, handler Handler) (*Server, string) {
	t.Helper()
	sid, err := CurrentUserSID()
	if err != nil {
		t.Skipf("cannot resolve user SID: %v", err)
	}
	name := `\\.\pipe\clash-halo-test-` + t.Name() + "-" + time.Now().Format("150405.000000")
	srv, err := Listen(Options{
		Name:               name,
		Handler:            handler,
		SecurityDescriptor: currentUserDescriptor(sid),
		StateVersion:       func() int64 { return 5 },
		Seq:                func() int64 { return 1 },
	})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	srv.Serve()
	t.Cleanup(srv.Close)
	return srv, name
}

func dial(t *testing.T, name string) net.Conn {
	t.Helper()
	var lastErr error
	for i := 0; i < 20; i++ {
		c, err := winioDialForTest(name)
		if err == nil {
			return c
		}
		lastErr = err
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("dial: %v", lastErr)
	return nil
}

func TestRequestResponseRoundTrip(t *testing.T) {
	srv, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		if req.Action == "boom" {
			return nil, contract.NewError(contract.ErrInternal, "炸了")
		}
		return map[string]any{"echo": req.ID}, nil
	})
	_ = srv
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()

	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	_, _ = conn.Write([]byte(`{"v":1,"id":"r1","action":"snapshot.get"}` + "\n"))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var resp contract.Response
	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		t.Fatalf("bad response json %q: %v", line, err)
	}
	if !resp.Ok || resp.StateVersion != 5 {
		t.Fatalf("resp = %+v", resp)
	}
	// The action's result must survive the round trip.
	result, _ := resp.Result.(map[string]any)
	if result["echo"] != "r1" {
		t.Fatalf("result = %v", resp.Result)
	}
}

func TestFailedActionCarriesError(t *testing.T) {
	_, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		return nil, &contract.ErrorObj{
			Code: contract.ErrConfigInvalid, Message: "配置无效", Detail: "第 3 行",
		}
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	_, _ = conn.Write([]byte(`{"v":1,"id":"r2","action":"config.apply"}` + "\n"))
	line, _ := bufio.NewReader(conn).ReadString('\n')
	var resp contract.Response
	_ = json.Unmarshal([]byte(line), &resp)
	if resp.Ok || resp.Error == nil {
		t.Fatalf("expected failure: %+v", resp)
	}
	if resp.Error.Code != contract.ErrConfigInvalid {
		t.Fatalf("code = %s", resp.Error.Code)
	}
	if resp.StateVersion != 5 {
		t.Fatalf("failed responses must also carry stateVersion: %+v", resp)
	}
}

func TestMalformedRequestKeepsConnection(t *testing.T) {
	_, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		return map[string]any{"ok": req.Action}, nil
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	reader := bufio.NewReader(conn)

	_, _ = conn.Write([]byte("not json\n"))
	line, _ := reader.ReadString('\n')
	if line == "" {
		t.Fatal("no error response for malformed input")
	}
	// The connection must still work afterwards: a broken UI probe should
	// not force a reconnect that loses the subscription state.
	_, _ = conn.Write([]byte(`{"v":1,"id":"after","action":"snapshot.get"}` + "\n"))
	line, _ = reader.ReadString('\n')
	var resp contract.Response
	_ = json.Unmarshal([]byte(line), &resp)
	if !resp.Ok || resp.ID != "after" {
		t.Fatalf("connection did not survive malformed request: %+v", resp)
	}
}

func TestRequestsAreSerialised(t *testing.T) {
	var active int32
	var maxActive int32
	var mu sync.Mutex
	var order []string
	_, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		cur := atomic.AddInt32(&active, 1)
		mu.Lock()
		if cur > maxActive {
			maxActive = cur
		}
		order = append(order, req.ID)
		mu.Unlock()
		// Simulate real work; without serialisation the counter would spike.
		time.Sleep(20 * time.Millisecond)
		atomic.AddInt32(&active, -1)
		return map[string]any{"id": req.ID}, nil
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(conn)
	// Mutating actions only: read actions run on the fast path by design, so
	// using snapshot.get here would assert the wrong thing.
	for i := 0; i < 5; i++ {
		_, _ = conn.Write([]byte(`{"v":1,"id":"q` + itoaTest(i) + `","action":"config.apply"}` + "\n"))
	}
	for i := 0; i < 5; i++ {
		if _, err := reader.ReadString('\n'); err != nil {
			t.Fatalf("read %d: %v", i, err)
		}
	}
	if maxActive != 1 {
		t.Fatalf("max concurrent handlers = %d, requests must be serialised", maxActive)
	}
	if len(order) != 5 {
		t.Fatalf("order length = %d", len(order))
	}
	// FIFO: a config apply arriving first must not be overtaken by a later
	// snapshot request.
	for i, id := range order {
		if id != "q"+itoaTest(i) {
			t.Fatalf("order = %v, expected q0..q4", order)
		}
	}
}

func TestReadActionRunsWhileCommandIsInFlight(t *testing.T) {
	// A TUN enable parks the worker for up to 90 seconds. The pages keep
	// polling snapshot.get / connections.list / log.tail during that window,
	// and those reads must not queue behind the command — otherwise every page
	// freezes on its last frame while the UAC prompt sits on screen.
	entered := make(chan struct{})
	release := make(chan struct{})
	_, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		if req.Action == "config.apply" {
			close(entered)
			<-release
			return map[string]any{}, nil
		}
		return map[string]any{"fast": true}, nil
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(conn)

	_, _ = conn.Write([]byte(`{"v":1,"id":"slow","action":"config.apply"}` + "\n"))
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("worker never picked up the command")
	}
	_, _ = conn.Write([]byte(`{"v":1,"id":"fast","action":"snapshot.get"}` + "\n"))

	// The read's reply must arrive while the command is still parked; a
	// serialised host answers nothing until release. The wait is judged from
	// the test side rather than a pipe read deadline, so the assertion holds
	// regardless of deadline behaviour on a connection the server has not yet
	// written to.
	reply := make(chan string, 1)
	go func() {
		line, err := reader.ReadString('\n')
		if err == nil {
			reply <- line
		}
	}()
	select {
	case line := <-reply:
		var resp contract.Response
		if err := json.Unmarshal([]byte(line), &resp); err != nil {
			t.Fatalf("bad response json %q: %v", line, err)
		}
		if resp.ID != "fast" || !resp.Ok {
			t.Fatalf("expected the read's reply first, got %s", line)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("read action was blocked by an in-flight command")
	}

	// The command still completes afterwards, with its own reply.
	close(release)
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("no reply for the parked command: %v", err)
	}
	var resp2 contract.Response
	_ = json.Unmarshal([]byte(line), &resp2)
	if resp2.ID != "slow" {
		t.Fatalf("expected the command's reply second, got %s", line)
	}
}

func TestOversizedRequestIsRejectedNotSilentlyClosed(t *testing.T) {
	// A batch speed test once crossed the 1 MiB frame ceiling and the scanner
	// dropped the connection mid-request, which the UI saw as a reconnect. The
	// ceiling is now 8 MiB; this pins that a legitimate batch-sized frame
	// (well past the old limit) makes the round trip intact.
	_, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		return map[string]any{"bytes": len(req.Params)}, nil
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(conn)

	padding := make([]byte, 2<<20)
	for i := range padding {
		padding[i] = 'a'
	}
	req := `{"v":1,"id":"big","action":"tray.publish","params":{"pad":"` + string(padding) + `"}}`
	_, err := conn.Write(append([]byte(req), '\n'))
	if err != nil {
		t.Fatalf("write: %v", err)
	}
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("no reply for a 2 MiB request: %v", err)
	}
	var resp contract.Response
	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		t.Fatalf("bad response json: %v", err)
	}
	if !resp.Ok || resp.ID != "big" {
		t.Fatalf("resp = %s", line)
	}
}

func TestBroadcastReachesSubscribedClients(t *testing.T) {
	srv, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		return map[string]any{}, nil
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	reader := bufio.NewReader(conn)
	// Wait until the client is registered before broadcasting.
	for i := 0; i < 40 && srv.ClientCount() == 0; i++ {
		time.Sleep(25 * time.Millisecond)
	}
	srv.Broadcast(contract.EventStateChanged, map[string]any{"coreState": "running"})
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("no event received: %v", err)
	}
	var ev contract.Event
	if err := json.Unmarshal([]byte(line), &ev); err != nil {
		t.Fatalf("bad event: %v", err)
	}
	if ev.Event != contract.EventStateChanged || ev.V != contract.ProtocolVersion {
		t.Fatalf("event = %+v", ev)
	}
	data, _ := ev.Data.(map[string]any)
	if data["coreState"] != "running" {
		t.Fatalf("event data = %v", ev.Data)
	}
}

func TestHostExitingSurvivesTheImmediateClose(t *testing.T) {
	// The shutdown path broadcasts host.exiting and closes the pipe on the very
	// next line (main.go's shutdown(), server.Broadcast then server.Close).
	//
	// That ordering is what lets the window exit with the tray: if the UI missed
	// the event it would sit there reconnecting to a pipe that no longer exists
	// — the "tray quit but the window stayed" report. This pins that the frame
	// reaches the client even though Close follows immediately, so the fix does
	// not silently depend on the reader winning a race.
	srv, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		return map[string]any{}, nil
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	_, _ = conn.Write([]byte(`{"v":1,"id":"sub","action":"event.subscribe","params":{"enabled":true}}` + "\n"))
	reader := bufio.NewReader(conn)
	if _, err := reader.ReadString('\n'); err != nil {
		t.Fatalf("no subscribe reply: %v", err)
	}

	srv.Broadcast(contract.EventHostExiting, map[string]any{"reason": "shutdown"})
	srv.Close()

	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("host.exiting was lost to the close: %v", err)
	}
	var ev contract.Event
	if err := json.Unmarshal([]byte(line), &ev); err != nil {
		t.Fatalf("bad event: %v", err)
	}
	if ev.Event != contract.EventHostExiting {
		t.Fatalf("event = %+v", ev)
	}
}

func TestSubscribeWithoutEnabledFieldIsRejected(t *testing.T) {
	// Regression: the UI sent {"events":true}. `enabled` stayed at its zero
	// value, the client was quietly subscribed=false, and every later event was
	// dropped — which surfaced as a latency batch stuck on "测试中" forever.
	// A wrong field name must fail loudly instead of muting the client.
	srv, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		return map[string]any{}, nil
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	reader := bufio.NewReader(conn)
	for i := 0; i < 40 && srv.ClientCount() == 0; i++ {
		time.Sleep(25 * time.Millisecond)
	}

	_, _ = conn.Write([]byte(`{"v":1,"id":"sub","action":"event.subscribe","params":{"events":true}}` + "\n"))
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("no reply to subscribe: %v", err)
	}
	var resp contract.Response
	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		t.Fatalf("bad reply: %v", err)
	}
	if resp.Ok {
		t.Fatalf("a subscribe without enabled must fail, got %s", line)
	}
	if resp.Error == nil || resp.Error.Code != contract.ErrBadRequest {
		t.Fatalf("error = %+v", resp.Error)
	}

	// And the client must still be subscribed: rejecting the malformed request
	// must not change the state it failed to spell out.
	srv.Broadcast(contract.EventStateChanged, map[string]any{"coreState": "running"})
	evLine, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("rejected subscribe silenced the client: %v", err)
	}
	if !strings.Contains(evLine, contract.EventStateChanged) {
		t.Fatalf("event = %s", evLine)
	}
}

func TestUnsubscribedClientGetsNoEvents(t *testing.T) {
	srv, name := newTestServer(t, func(req *contract.Request) (any, *contract.ErrorObj) {
		return map[string]any{}, nil
	})
	conn := dial(t, name)
	defer func() { _ = conn.Close() }()
	reader := bufio.NewReader(conn)
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	_, _ = conn.Write([]byte(`{"v":1,"id":"s","action":"event.subscribe","params":{"enabled":false}}` + "\n"))
	if _, err := reader.ReadString('\n'); err != nil {
		t.Fatalf("no subscribe ack: %v", err)
	}
	for i := 0; i < 40 && srv.ClientCount() == 0; i++ {
		time.Sleep(25 * time.Millisecond)
	}
	srv.Broadcast(contract.EventLogAppended, map[string]any{"line": "x"})
	_ = conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if _, err := reader.ReadString('\n'); err == nil {
		t.Fatal("unsubscribed client should not receive events")
	}
}

func TestClientCountTracksConnections(t *testing.T) {
	var counts []int
	var mu sync.Mutex
	sid, err := CurrentUserSID()
	if err != nil {
		t.Skip(err)
	}
	name := `\\.\pipe\clash-halo-test-count-` + time.Now().Format("150405.000000")
	srv, err := Listen(Options{
		Name:               name,
		Handler:            func(req *contract.Request) (any, *contract.ErrorObj) { return nil, nil },
		SecurityDescriptor: currentUserDescriptor(sid),
		OnClientChange: func(n int) {
			mu.Lock()
			counts = append(counts, n)
			mu.Unlock()
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	srv.Serve()
	defer srv.Close()

	c1 := dial(t, name)
	// 3 seconds, not 1: `go test ./...` runs packages in parallel, and under that
	// load the accept loop can be starved past a one-second budget. The counter
	// still has to reach the right value — only the deadline moved — so a real
	// counting bug still fails, just later.
	for i := 0; i < 120 && srv.ClientCount() == 0; i++ {
		time.Sleep(25 * time.Millisecond)
	}
	if srv.ClientCount() != 1 {
		t.Fatalf("count = %d", srv.ClientCount())
	}
	c2 := dial(t, name)
	for i := 0; i < 120 && srv.ClientCount() < 2; i++ {
		time.Sleep(25 * time.Millisecond)
	}
	if srv.ClientCount() != 2 {
		t.Fatalf("count = %d, expected 2", srv.ClientCount())
	}
	_ = c1.Close()
	_ = c2.Close()
	for i := 0; i < 120 && srv.ClientCount() > 0; i++ {
		time.Sleep(25 * time.Millisecond)
	}
	if srv.ClientCount() != 0 {
		t.Fatalf("clients not cleaned up: %d", srv.ClientCount())
	}
	mu.Lock()
	defer mu.Unlock()
	if len(counts) == 0 || counts[len(counts)-1] != 0 {
		t.Fatalf("client change callback = %v", counts)
	}
}

func TestSecurityDescriptorRestrictsToCurrentUser(t *testing.T) {
	sid, err := CurrentUserSID()
	if err != nil {
		t.Skip(err)
	}
	sd := currentUserDescriptor(sid)
	// The descriptor must start with a protected DACL (D:P) so inherited ACEs
	// from the parent object cannot widen access.
	if sd[:3] != "D:P" {
		t.Fatalf("descriptor not protected: %s", sd)
	}
	// Only the user SID, SYSTEM and Administrators may appear.
	for _, acl := range []string{";;;" + sid + ")", "(A;;GA;;;SY)", "(A;;GA;;;BA)"} {
		if !containsSub(sd, acl) {
			t.Fatalf("descriptor missing %q: %s", acl, sd)
		}
	}
	// "WD" (Everyone) or "AN" (Anonymous) must never be granted.
	for _, bad := range []string{"WD", "AN", "AU"} {
		if containsSub(sd, ";;;"+bad+")") {
			t.Fatalf("descriptor grants %q: %s", bad, sd)
		}
	}
}

func TestEmptyDescriptorIsRefused(t *testing.T) {
	if _, err := Listen(Options{Name: `\\.\pipe\x`, Handler: nil}); err == nil {
		t.Fatal("a server without a descriptor must refuse to start")
	}
}

func containsSub(s, sub string) bool {
	return len(sub) > 0 && len(s) >= len(sub) && indexOfSub(s, sub) >= 0
}

func indexOfSub(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

// A handler panic must become an error response, not a dead host. The host is
// the process that keeps the core alive, so an out-of-range index on one
// request used to take the proxy down with it.
func TestHandlerPanicBecomesErrorResponse(t *testing.T) {
	var recovered any
	var stackLen int
	srv := &Server{
		handler: func(*contract.Request) (any, *contract.ErrorObj) {
			panic("boom")
		},
		onPanic: func(_ *contract.Request, r any, stack []byte) {
			recovered = r
			stackLen = len(stack)
		},
	}
	_, errObj := srv.invoke(&contract.Request{Action: contract.ActionConfigApply})
	if errObj == nil {
		t.Fatal("a panicking handler must produce an error response")
	}
	if errObj.Code != contract.ErrInternal {
		t.Fatalf("code = %q, want %q", errObj.Code, contract.ErrInternal)
	}
	if recovered != "boom" {
		t.Fatalf("OnPanic got %v", recovered)
	}
	if stackLen == 0 {
		t.Fatal("OnPanic must receive the stack for the log")
	}
	if strings.Contains(errObj.Detail, "boom") {
		t.Fatalf("panic text leaked to the client: %q", errObj.Detail)
	}
}

func itoaTest(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
