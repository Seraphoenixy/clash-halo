// Package connapi answers the two connection actions (list/close) by reading
// the Clash API of the core that is actually running.
//
// It was extracted from the app package so the controller cache, the loopback
// rule and the HTTP client have one owner. The app still decides *which* config
// is live (normal supervisor or TUN service); this package only asks that
// source for the path and talks to it.
package connapi

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"clash-halo/native/windows/internal/contract"
)

// Connection is one live connection, flattened from the Clash API's nested
// `metadata` object.
type Connection struct {
	ID            string   `json:"id"`
	Host          string   `json:"host"`
	Network       string   `json:"network"`
	Type          string   `json:"type"`
	Rule          string   `json:"rule"`
	Payload       string   `json:"rulePayload"`
	Chains        []string `json:"chains"`
	Upload        int64    `json:"upload"`
	Download      int64    `json:"download"`
	Start         string   `json:"start"`
	Process       string   `json:"process"`
	ProcessPath   string   `json:"processPath"`
	SourceIP      string   `json:"sourceIp"`
	DestinationIP string   `json:"destinationIp"`
}

// ConnectionsSnapshot is the whole answer of `connections.list`.
type ConnectionsSnapshot struct {
	Connections   []Connection `json:"connections"`
	UploadTotal   int64        `json:"uploadTotal"`
	DownloadTotal int64        `json:"downloadTotal"`
	Memory        int64        `json:"memory"`
	// Controller is included so the page can state where the numbers came from.
	Controller string `json:"controller"`
}

const connectionsTimeout = 4 * time.Second

// Source names the config file of the core serving the Clash API.
//
// The bool is "a core is running". The app satisfies this with its
// supervisor/TUN-aware lookup; tests use a fixed path.
type Source interface {
	ConnectionsConfig() (string, bool)
}

// Service owns the controller cache and the HTTP client. It is safe for
// concurrent use: connections.list polls every 1.5 s while closeConnections
// may run at the same time.
type Service struct {
	source Source
	logf   func(format string, args ...any)

	client *http.Client

	mu    sync.Mutex
	cache struct {
		path   string
		size   int64
		modNs  int64
		addr   string
		secret string
		valid  bool
	}
}

// New builds a service. logf may be nil.
func New(source Source, logf func(format string, args ...any)) *Service {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &Service{
		source: source,
		logf:   logf,
		// The controller is loopback-only, so this client must never go through
		// a proxy: a system-proxy-enabled machine would otherwise route the
		// request back into the core it is querying.
		client: &http.Client{
			Timeout:   connectionsTimeout,
			Transport: &http.Transport{Proxy: nil},
		},
	}
}

// List reads the Clash API's /connections.
func (s *Service) List() (ConnectionsSnapshot, *contract.ErrorObj) {
	var out ConnectionsSnapshot
	configPath, running := s.source.ConnectionsConfig()
	if !running {
		return out, contract.NewError(contract.ErrCoreNotRunning, "代理内核未运行")
	}
	ctrl, err := s.controllerForConfig(configPath)
	if err != nil {
		return out, &contract.ErrorObj{
			Code:    contract.ErrUnsupported,
			Message: "无法查询连接列表",
			Detail:  err.Error(),
		}
	}
	body, err := s.do(http.MethodGet, ctrl.address, ctrl.secret, "/connections")
	if err != nil {
		return out, &contract.ErrorObj{
			Code:    contract.ErrInternal,
			Message: "读取连接列表失败",
			Detail:  err.Error(),
		}
	}
	parsed, err := ParseConnections(body)
	if err != nil {
		return out, &contract.ErrorObj{
			Code:    contract.ErrInternal,
			Message: "连接列表格式无法识别",
			Detail:  err.Error(),
		}
	}
	parsed.Controller = ctrl.address
	return parsed, nil
}

// Close closes one connection, or all of them when id is empty.
func (s *Service) Close(rawID string) (any, *contract.ErrorObj) {
	configPath, running := s.source.ConnectionsConfig()
	if !running {
		return nil, contract.NewError(contract.ErrCoreNotRunning, "代理内核未运行")
	}
	ctrl, err := s.controllerForConfig(configPath)
	if err != nil {
		return nil, &contract.ErrorObj{
			Code:    contract.ErrUnsupported,
			Message: "无法关闭连接",
			Detail:  err.Error(),
		}
	}
	path := "/connections"
	id := strings.TrimSpace(rawID)
	if id != "" {
		// Escaped: the id is opaque and must not be able to change the path.
		path += "/" + url.PathEscape(id)
	}
	if _, err := s.do(http.MethodDelete, ctrl.address, ctrl.secret, path); err != nil {
		return nil, &contract.ErrorObj{
			Code:    contract.ErrInternal,
			Message: "关闭连接失败",
			Detail:  err.Error(),
		}
	}
	s.logf("[host] 已关闭连接 %q", id)
	return map[string]any{"closed": id}, nil
}

type endpoint struct {
	address string
	secret  string
}

// controllerForConfig reads the external controller address out of the config
// that is actually running.
//
// Reading the file rather than trusting a snapshot field means the address can
// never disagree with the core. The result is cached against the file's stat
// (size + modification time), so the 1.5 s poll does not re-read and re-parse
// the whole config; a changed file invalidates the cache on the next call.
//
// The secret is part of the result. Reading it and then dropping it left every
// request unauthenticated: with a secret in the config the API answers 401,
// which surfaced as an empty connection page rather than as an auth error.
func (s *Service) controllerForConfig(path string) (endpoint, error) {
	if path == "" {
		return endpoint{}, fmt.Errorf("没有正在使用的配置")
	}
	info, err := os.Stat(path)
	if err != nil {
		return endpoint{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cache.valid &&
		s.cache.path == path &&
		s.cache.size == info.Size() &&
		s.cache.modNs == info.ModTime().UnixNano() {
		if s.cache.addr != "" {
			return endpoint{address: s.cache.addr, secret: s.cache.secret}, nil
		}
		return endpoint{}, fmt.Errorf("配置未启用 Clash API")
	}

	body, err := os.ReadFile(path)
	if err != nil {
		return endpoint{}, err
	}
	var doc struct {
		Experimental struct {
			ClashAPI struct {
				Controller string `json:"external_controller"`
				Secret     string `json:"secret"`
			} `json:"clash_api"`
		} `json:"experimental"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return endpoint{}, err
	}
	addr := strings.TrimSpace(doc.Experimental.ClashAPI.Controller)
	secret := strings.TrimSpace(doc.Experimental.ClashAPI.Secret)
	// The controller must stay on loopback. The host validates this when
	// applying a config too; checking again here means a config that somehow
	// slipped through cannot turn "show my connections" into "call an arbitrary
	// HTTP endpoint on the LAN".
	if addr != "" && !IsLoopbackAddress(addr) {
		return endpoint{}, fmt.Errorf("控制接口不是回环地址：%s", addr)
	}
	s.cache.path = path
	s.cache.size = info.Size()
	s.cache.modNs = info.ModTime().UnixNano()
	s.cache.addr = addr
	s.cache.secret = secret
	s.cache.valid = true
	if addr == "" {
		return endpoint{}, fmt.Errorf("配置未启用 Clash API")
	}
	return endpoint{address: addr, secret: secret}, nil
}

// do performs one request against the local controller. A non-empty secret is
// sent as the bearer token the Clash API expects.
func (s *Service) do(method, controller, secret, path string) ([]byte, error) {
	req, err := http.NewRequest(method, "http://"+controller+path, nil)
	if err != nil {
		return nil, err
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	// Bounded read: the connection list on a busy machine can be large, but an
	// unbounded read on a misbehaving endpoint is a memory hazard.
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("控制接口返回 %d：%s", resp.StatusCode, truncateForError(body))
	}
	return body, nil
}

// ParseConnections turns the Clash API document into our flat model.
//
// Split out from the HTTP call so it can be tested against a captured payload
// without a running core.
func ParseConnections(body []byte) (ConnectionsSnapshot, error) {
	var wire struct {
		Connections []struct {
			ID       string   `json:"id"`
			Upload   int64    `json:"upload"`
			Download int64    `json:"download"`
			Start    string   `json:"start"`
			Chains   []string `json:"chains"`
			Rule     string   `json:"rule"`
			Payload  string   `json:"rulePayload"`
			Metadata struct {
				Network       string `json:"network"`
				Type          string `json:"type"`
				SourceIP      string `json:"sourceIP"`
				DestinationIP string `json:"destinationIP"`
				Host          string `json:"host"`
				Process       string `json:"process"`
				ProcessPath   string `json:"processPath"`
			} `json:"metadata"`
		} `json:"connections"`
		UploadTotal   int64 `json:"uploadTotal"`
		DownloadTotal int64 `json:"downloadTotal"`
		Memory        int64 `json:"memory"`
	}
	if err := json.Unmarshal(body, &wire); err != nil {
		return ConnectionsSnapshot{}, err
	}
	out := ConnectionsSnapshot{
		UploadTotal:   wire.UploadTotal,
		DownloadTotal: wire.DownloadTotal,
		Memory:        wire.Memory,
		Connections:   make([]Connection, 0, len(wire.Connections)),
	}
	for _, c := range wire.Connections {
		host := c.Metadata.Host
		if host == "" {
			// A connection opened by IP has no host; the IP keeps the row
			// readable instead of blank.
			host = c.Metadata.DestinationIP
		}
		out.Connections = append(out.Connections, Connection{
			ID:            c.ID,
			Host:          host,
			Network:       c.Metadata.Network,
			Type:          c.Metadata.Type,
			Rule:          c.Rule,
			Payload:       c.Payload,
			Chains:        append([]string(nil), c.Chains...),
			Upload:        c.Upload,
			Download:      c.Download,
			Start:         c.Start,
			Process:       c.Metadata.Process,
			ProcessPath:   c.Metadata.ProcessPath,
			SourceIP:      c.Metadata.SourceIP,
			DestinationIP: c.Metadata.DestinationIP,
		})
	}
	return out, nil
}

// IsLoopbackAddress reports whether addr is a loopback host:port pair.
func IsLoopbackAddress(addr string) bool {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || port == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// truncateForError keeps an error message readable when the controller answers
// with an HTML error page.
func truncateForError(body []byte) string {
	const limit = 200
	text := strings.TrimSpace(string(body))
	if len(text) > limit {
		return text[:limit] + "…"
	}
	return text
}
