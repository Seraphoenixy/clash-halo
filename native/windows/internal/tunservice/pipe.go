package tunservice

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"

	"clash-halo/native/windows/internal/tunsup"
)

// PipeSDDL builds the security descriptor for the control pipe: the installing
// user plus SYSTEM and administrators, nobody else.
//
// The service is a SYSTEM process, so the descriptor is the first boundary; it
// is also the reason the service does not additionally inspect the client SID.
func PipeSDDL(ownerSID string) (string, error) {
	sid := strings.TrimSpace(ownerSID)
	if _, err := windows.StringToSid(sid); err != nil {
		return "", fmt.Errorf("tunservice: 安装者 SID 无效: %w", err)
	}
	return "D:P(A;;GA;;;" + sid + ")(A;;GA;;;SY)(A;;GA;;;BA)", nil
}

// Server serves the control pipe. Requests are handled concurrently: status
// and ping are read-only, and the controller serialises start/stop itself.
type Server struct {
	ctl  *Controller
	log  Logger
	ln   net.Listener
	done chan struct{}
	wg   sync.WaitGroup
	once sync.Once
}

// Listen creates the pipe. ownerSID comes from the install description and is
// what restricts the pipe to the user who installed the service.
func Listen(ctl *Controller, ownerSID string, log Logger) (*Server, error) {
	sddl, err := PipeSDDL(ownerSID)
	if err != nil {
		return nil, err
	}
	if log == nil {
		log = func(string, ...any) {}
	}
	ln, err := winio.ListenPipe(ctl.cfg.PipeName, &winio.PipeConfig{
		SecurityDescriptor: sddl,
		MessageMode:        false,
		InputBufferSize:    16 << 10,
		OutputBufferSize:   16 << 10,
	})
	if err != nil {
		return nil, fmt.Errorf("tunservice: 创建控制管道失败: %w", err)
	}
	return &Server{ctl: ctl, log: log, ln: ln, done: make(chan struct{})}, nil
}

// Serve accepts connections until Close.
func (s *Server) Serve() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			select {
			case <-s.done:
				return
			default:
			}
			s.log("pipe accept failed: %v", err)
			time.Sleep(50 * time.Millisecond)
			continue
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.serveConn(conn)
		}()
	}
}

func (s *Server) serveConn(conn net.Conn) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), MaxFrameBytes)
	writer := bufio.NewWriter(conn)
	for scanner.Scan() {
		req, err := DecodeRequest(scanner.Bytes())
		if err != nil {
			s.reply(writer, &Response{V: ProtocolVersion, OK: false,
				Error: &WireError{Code: CodeBadRequest, Message: err.Error()}})
			continue
		}
		result, wireErr := s.ctl.Handle(req)
		resp := &Response{V: ProtocolVersion, ID: req.ID, OK: wireErr == nil,
			Result: result, Error: wireErr}
		if !s.reply(writer, resp) {
			return
		}
	}
}

func (s *Server) reply(w *bufio.Writer, resp *Response) bool {
	body, err := json.Marshal(resp)
	if err != nil {
		return false
	}
	body = append(body, '\n')
	if _, err := w.Write(body); err != nil {
		return false
	}
	return w.Flush() == nil
}

// Close stops accepting and waits for in-flight requests.
func (s *Server) Close() {
	s.once.Do(func() {
		close(s.done)
		_ = s.ln.Close()
	})
	s.wg.Wait()
}

// Client talks to one installed service.
type Client struct {
	pipeName string
	timeout  time.Duration
	nextID   atomic.Uint64
}

// NewClient builds a client for the pipe of one data directory.
func NewClient(pipeName string, timeout time.Duration) *Client {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &Client{pipeName: pipeName, timeout: timeout}
}

// Ping reports whether a compatible service is present.
func (c *Client) Ping(ctx context.Context) (PingResult, error) {
	var out PingResult
	err := c.call(ctx, ActionPing, nil, &out)
	return out, err
}

// Status reads the service's current state.
func (c *Client) Status(ctx context.Context) (tunsup.Status, error) {
	var out tunsup.Status
	err := c.call(ctx, ActionStatus, nil, &out)
	return out, err
}

// Start asks for one core and returns the settled status.
func (c *Client) Start(ctx context.Context, configPath string, hostPID int) (tunsup.Status, error) {
	params, err := json.Marshal(StartParams{Config: configPath, HostPID: hostPID})
	if err != nil {
		return tunsup.Status{}, err
	}
	var out tunsup.Status
	err = c.call(ctx, ActionStart, params, &out)
	return out, err
}

// Stop ends the core and returns the settled status.
func (c *Client) Stop(ctx context.Context) (tunsup.Status, error) {
	var out tunsup.Status
	err := c.call(ctx, ActionStop, nil, &out)
	return out, err
}

func (c *Client) call(ctx context.Context, action string, params json.RawMessage, out any) error {
	timeout := c.timeout
	if ctx != nil {
		if deadline, ok := ctx.Deadline(); ok {
			timeout = time.Until(deadline)
			if timeout <= 0 {
				return context.DeadlineExceeded
			}
		}
	}
	dialTimeout := timeout
	conn, err := winio.DialPipe(c.pipeName, &dialTimeout)
	if err != nil {
		return fmt.Errorf("tunservice: 连接服务失败: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))

	id := strconv.FormatUint(c.nextID.Add(1), 10)
	req := Request{V: ProtocolVersion, ID: id, Action: action, Params: params}
	body, err := json.Marshal(req)
	if err != nil {
		return err
	}
	if _, err := conn.Write(append(body, '\n')); err != nil {
		return fmt.Errorf("tunservice: 发送请求失败: %w", err)
	}
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), MaxFrameBytes)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return fmt.Errorf("tunservice: 读取响应失败: %w", err)
		}
		return fmt.Errorf("tunservice: 服务关闭了连接")
	}
	var resp Response
	if err := json.Unmarshal(scanner.Bytes(), &resp); err != nil {
		return fmt.Errorf("tunservice: 响应不是 JSON: %w", err)
	}
	if resp.ID != id {
		return fmt.Errorf("tunservice: 响应 id 不匹配（%s != %s）", resp.ID, id)
	}
	if !resp.OK {
		if resp.Error == nil {
			return fmt.Errorf("tunservice: 请求失败")
		}
		return resp.Error
	}
	if out == nil || resp.Result == nil {
		return nil
	}
	raw, err := json.Marshal(resp.Result)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, out)
}
