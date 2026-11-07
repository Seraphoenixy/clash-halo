// Package ipc serves the named pipe.
//
// Design constraints taken from the plan:
//   - the pipe is restricted to the current user (plus admins/system) so
//     another user on the machine cannot control the proxy;
//   - requests are serialised: one request at a time, in arrival order, because
//     two concurrent `config.apply` calls would race the core;
//   - a request that arrives while another is in flight is queued, not
//     rejected, so the UI never sees a spurious `busy`;
//   - events are broadcast to every connected client, each with its own
//     buffered writer, and a slow client is disconnected instead of stalling
//     the host.
package ipc

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"runtime/debug"
	"sync"
	"time"

	"github.com/Microsoft/go-winio"

	"clash-halo/native/windows/internal/contract"
)

const (
	// maxRequestBytes bounds one request line. It used to be 1 MiB on the
	// assumption that config.apply is the largest legitimate request, but a
	// batch speed test sends every node's generated config in one
	// speedtest.start frame — roughly 0.7–1.2 KB per node, so a 1000-node
	// subscription crossed the old ceiling and the scanner simply closed the
	// connection mid-request. 8 MiB keeps a 5000-node batch comfortably inside
	// the frame while still bounding memory per connection.
	maxRequestBytes = 8 << 20
	// writeTimeout keeps a wedged client from blocking a broadcast.
	writeTimeout = 5 * time.Second
	// idleTimeout closes a connection that has sent nothing for this long.
	// The UI keeps its connection open and idle when minimized, so this is
	// generous; a real reconnect is cheap and yields a fresh snapshot.
	idleTimeout = 30 * time.Minute
)

// Client is one connected UI process.
type Client struct {
	conn net.Conn
	mu   sync.Mutex
	// subscribed gates event delivery: a client that only wants to send
	// commands can opt out of event spam.
	subscribed bool
	closed     bool
}

// Send writes one encoded frame.
func (c *Client) Send(payload []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return net.ErrClosed
	}
	_ = c.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
	_, err := c.conn.Write(payload)
	if err != nil {
		c.closed = true
		return err
	}
	return nil
}

func (c *Client) close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	c.closed = true
	_ = c.conn.Close()
}

// Handler executes one request. Returning an ErrorObj produces a failed
// response; returning a nil error with a result produces a success.
type Handler func(req *contract.Request) (any, *contract.ErrorObj)

// Server owns the listener, the client set and the serialised request queue.
type Server struct {
	name     string
	listener net.Listener
	handler  Handler

	clientsMu sync.RWMutex
	clients   map[*Client]struct{}

	// requestCh is the serialisation point: capacity 1 keeps ordering
	// strict while still letting the accept loop enqueue.
	requestCh chan queueItem
	done      chan struct{}
	closeOnce sync.Once
	wg        sync.WaitGroup

	// stateVersion supplies the version stamped on every response.
	stateVersion func() int64
	seq          func() int64

	// onClientChange lets the app drop per-client UI state when the last
	// window closes, so subscription timers can pause.
	onClientChange func(count int)

	// afterReply runs after a response has been written, so a handler that asks
	// the host to exit can act only once its acknowledgement is delivered.
	afterReply func(action string)

	// onPanic observes a handler panic after the server has already converted
	// it into an error response. It exists for logging only; it must not
	// re-panic, because that would take the host down again.
	onPanic func(req *contract.Request, recovered any, stack []byte)
}

type queueItem struct {
	client  *Client
	request *contract.Request
}

// Options configure a Server.
type Options struct {
	Name           string
	Handler        Handler
	StateVersion   func() int64
	Seq            func() int64
	OnClientChange func(count int)
	// AfterReply runs once a response has been written, so a handler that asks
	// the host to exit can wait for its acknowledgement to be delivered.
	AfterReply func(action string)
	// OnPanic is called after a handler panic has been recovered. It is a
	// logging hook; the client always receives an internal error response.
	OnPanic func(req *contract.Request, recovered any, stack []byte)
	// SecurityDescriptor defaults to current-user-only plus admins/system.
	SecurityDescriptor string
}

// CurrentUserDescriptor builds the SDDL that grants the host owner full access
// and everyone else nothing. Adding SYSTEM keeps the LocalSystem TUN service
// able to reach the host's pipe if that is ever needed.
func currentUserDescriptor(sid string) string {
	return "D:P(A;;GA;;;" + sid + ")(A;;GA;;;SY)(A;;GA;;;BA)"
}

// Listen creates the pipe server.
func Listen(opts Options) (*Server, error) {
	if opts.Name == "" {
		opts.Name = contract.PipeName
	}
	sd := opts.SecurityDescriptor
	if sd == "" {
		// Never fall back to a permissive descriptor: refuse instead.
		return nil, errNoDescriptor
	}
	l, err := winio.ListenPipe(opts.Name, &winio.PipeConfig{
		SecurityDescriptor: sd,
		MessageMode:        false,
		InputBufferSize:    64 << 10,
		OutputBufferSize:   64 << 10,
	})
	if err != nil {
		return nil, err
	}
	return &Server{
		name:           opts.Name,
		listener:       l,
		handler:        opts.Handler,
		clients:        make(map[*Client]struct{}),
		requestCh:      make(chan queueItem, 1),
		done:           make(chan struct{}),
		stateVersion:   opts.StateVersion,
		seq:            opts.Seq,
		onClientChange: opts.OnClientChange,
		afterReply:     opts.AfterReply,
		onPanic:        opts.OnPanic,
	}, nil
}

// Serve runs the accept loop and the request worker until Close.
func (s *Server) Serve() {
	s.wg.Add(2)
	go s.acceptLoop()
	go s.workLoop()
}

func (s *Server) acceptLoop() {
	defer s.wg.Done()
	backoff := 50 * time.Millisecond
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.done:
				return
			default:
			}
			// A transient accept failure must not kill the host: retry with
			// a bounded backoff, then give up only if the server is closing.
			time.Sleep(backoff)
			if backoff < time.Second {
				backoff *= 2
			}
			continue
		}
		backoff = 50 * time.Millisecond
		go s.handleConn(conn)
	}
}

// readActions are pure queries: they touch only mutex-guarded state and never
// mutate the core, so they are safe to run outside the serialised queue.
//
// Keeping them off the worker is what keeps the UI alive during long commands:
// a TUN enable waits up to 90 seconds inside the worker for a UAC answer, and
// with everything serialised the pages' polling (snapshot.get every couple of
// seconds, connections.list every 1.5 s, log.tail every 1.5 s) queued behind
// it and every page froze on its last frame.
var readActions = map[string]struct{}{
	contract.ActionSnapshotGet:     {},
	contract.ActionHostStatus:      {},
	contract.ActionLogTail:         {},
	contract.ActionConnectionsList: {},
}

func (s *Server) handleConn(conn net.Conn) {
	client := &Client{conn: conn, subscribed: true}
	s.clientsMu.Lock()
	s.clients[client] = struct{}{}
	count := len(s.clients)
	s.clientsMu.Unlock()
	if s.onClientChange != nil {
		s.onClientChange(count)
	}
	defer func() {
		s.clientsMu.Lock()
		delete(s.clients, client)
		remaining := len(s.clients)
		s.clientsMu.Unlock()
		client.close()
		if s.onClientChange != nil {
			s.onClientChange(remaining)
		}
	}()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), maxRequestBytes)
	for {
		_ = conn.SetReadDeadline(time.Now().Add(idleTimeout))
		if !scanner.Scan() {
			// A line over maxRequestBytes used to close the connection with no
			// frame at all, so the UI saw "disconnected" and retried the same
			// oversized request forever. Report the reason first.
			if errors.Is(scanner.Err(), bufio.ErrTooLong) {
				payload, encErr := contract.Encode(contract.Fail("",
					contract.NewError(contract.ErrBadRequest, "请求行超出长度上限"),
					s.stateVersionValue()))
				if encErr == nil {
					_ = client.Send(payload)
				}
			}
			return
		}
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		req, errObj := contract.DecodeRequest(line)
		if errObj != nil {
			// A malformed request gets an error but keeps the connection:
			// the UI can retry and a version mismatch is worth reporting
			// without tearing down the session.
			payload, encErr := contract.Encode(
				contract.Fail("", errObj, s.stateVersionValue()))
			if encErr == nil {
				_ = client.Send(payload)
			}
			continue
		}
		if req.Action == contract.ActionEventSubscribe {
			var params struct {
				Enabled *bool `json:"enabled"`
			}
			if e := contract.DecodeParams(req, &params); e != nil {
				payload, _ := contract.Encode(contract.Fail(req.ID, e, s.stateVersionValue()))
				_ = client.Send(payload)
				continue
			}
			// `enabled` is required rather than defaulted to false. A client that
			// spelled the field differently (`{"events":true}` was one) used to
			// be silently unsubscribed, so it received no events at all and the
			// damage showed up far away as a latency test that never finished.
			// An explicit error is loud, immediate, and fixable.
			if params.Enabled == nil {
				e := contract.NewError(contract.ErrBadRequest,
					"event.subscribe 需要 enabled 字段")
				payload, _ := contract.Encode(contract.Fail(req.ID, e, s.stateVersionValue()))
				_ = client.Send(payload)
				continue
			}
			enabled := *params.Enabled
			client.mu.Lock()
			client.subscribed = enabled
			client.mu.Unlock()
			payload, _ := contract.Encode(
				contract.OK(req.ID, map[string]any{"subscribed": enabled},
					s.stateVersionValue()))
			_ = client.Send(payload)
			continue
		}
		if _, ok := readActions[req.Action]; ok {
			// Dispatch on its own goroutine instead of the queue. The handler
			// set is audited for read-only access (see readActions); responses
			// are paired by id, so a read that overtakes a queued command is
			// indistinguishable from one that arrived later.
			go func() {
				select {
				case <-s.done:
					return
				default:
				}
				s.reply(client, req)
			}()
			continue
		}
		select {
		case s.requestCh <- queueItem{client: client, request: req}:
		case <-s.done:
			return
		}
	}
}

// reply runs one handler and writes its response, shared by the serialised
// worker and the read fast path.
func (s *Server) reply(client *Client, req *contract.Request) {
	result, errObj := s.invoke(req)
	var resp contract.Response
	if errObj != nil {
		resp = contract.Fail(req.ID, errObj, s.stateVersionValue())
	} else {
		resp = contract.OK(req.ID, result, s.stateVersionValue())
	}
	payload, err := contract.Encode(resp)
	if err != nil {
		payload, _ = contract.Encode(contract.Fail(req.ID,
			&contract.ErrorObj{Code: contract.ErrInternal, Message: "响应序列化失败"},
			s.stateVersionValue()))
	}
	_ = client.Send(payload)
	// The reply is on the wire before anything else happens. A handler
	// that asks the host to quit (host.shutdown) used to close the pipe
	// from another goroutine while this response was still pending, so
	// the caller saw only host.exiting and could not tell "shutting
	// down" from "the host died mid-request". Deferring the teardown to
	// AfterReply makes the order deterministic instead of timing-based.
	if s.afterReply != nil {
		s.afterReply(req.Action)
	}
}

// invoke isolates the handler behind a panic boundary.
//
// A handler is ordinary Go code touching shared state; a single out-of-range
// slice index used to unwind the worker goroutine, and with it the whole host
// process. The host is the only thing keeping the core alive, so a malformed
// frame must produce an error response rather than a dead proxy. The recovered
// value is reported through OnPanic (log only) and never echoed to the client:
// panic text can carry heap contents and file paths.
func (s *Server) invoke(req *contract.Request) (result any, errObj *contract.ErrorObj) {
	defer func() {
		if r := recover(); r != nil {
			result = nil
			errObj = &contract.ErrorObj{
				Code:    contract.ErrInternal,
				Message: "处理请求时发生内部错误",
				Detail:  fmt.Sprintf("action=%s", req.Action),
			}
			if s.onPanic != nil {
				s.onPanic(req, r, debug.Stack())
			}
		}
	}()
	return s.handler(req)
}

func (s *Server) workLoop() {
	defer s.wg.Done()
	for {
		select {
		case <-s.done:
			return
		case item := <-s.requestCh:
			s.reply(item.client, item.request)
		}
	}
}

func (s *Server) stateVersionValue() int64 {
	if s.stateVersion == nil {
		return 0
	}
	return s.stateVersion()
}

// Broadcast sends an event to every subscribed client. Clients that fail to
// take the write are dropped: a stalled UI must not slow the host down.
func (s *Server) Broadcast(event string, data any) {
	seq := int64(0)
	if s.seq != nil {
		seq = s.seq()
	}
	// Collect the targets before encoding: a frame for a connection list can be
	// megabytes, and a state change with no window open must not pay that
	// serialisation. seq still advances on every call so sequence numbers keep
	// their meaning for callers that count broadcasts rather than deliveries.
	s.clientsMu.RLock()
	targets := make([]*Client, 0, len(s.clients))
	for c := range s.clients {
		c.mu.Lock()
		subscribed := c.subscribed
		c.mu.Unlock()
		if subscribed {
			targets = append(targets, c)
		}
	}
	s.clientsMu.RUnlock()
	if len(targets) == 0 {
		return
	}
	payload, err := contract.Encode(contract.Event{
		V:            contract.ProtocolVersion,
		Event:        event,
		Seq:          seq,
		StateVersion: s.stateVersionValue(),
		Data:         data,
	})
	if err != nil {
		return
	}
	var stale []*Client
	for _, c := range targets {
		if err := c.Send(payload); err != nil {
			stale = append(stale, c)
		}
	}
	for _, c := range stale {
		c.close()
	}
}

// errNoDescriptor explains a refused start.
var errNoDescriptor = errors.New("拒绝启动：未提供管道安全描述符")

// ClientCount reports connected UI processes.
func (s *Server) ClientCount() int {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()
	return len(s.clients)
}

// Close stops accepting and closes every client.
func (s *Server) Close() {
	s.closeOnce.Do(func() {
		close(s.done)
		_ = s.listener.Close()
		s.clientsMu.Lock()
		for c := range s.clients {
			c.close()
		}
		s.clients = make(map[*Client]struct{})
		s.clientsMu.Unlock()
		s.wg.Wait()
	})
}

// CurrentUserSID returns the SID string of the running user.
func CurrentUserSID() (string, error) {
	token, err := openCurrentProcessToken()
	if err != nil {
		return "", err
	}
	defer closeToken(token)
	return tokenUserSID(token)
}
