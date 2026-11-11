// Package tunservice runs the TUN core on behalf of the unprivileged host.
//
// It exists because creating a wintun adapter, installing routes and changing
// firewall rules require administrator rights. Instead of elevating on every
// TUN switch, the app installs this service once; it runs as LocalSystem and
// starts exactly one core when the host asks for one.
//
// Lifecycle rules this package enforces:
//
//   - no core is started at boot or at service start: the service is idle
//     until the host asks for a core;
//   - one core at a time, owned by one host process at a time;
//   - the core dies with the service (job object) and is stopped when the host
//     process that requested it exits;
//   - the config is read, validated and copied into the service's own
//     directory before the core starts, so the file cannot be swapped after
//     validation;
//   - the core binary is verified against the SHA-256 recorded at install.
package tunservice

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	// ProtocolVersion guards the pipe frame format.
	ProtocolVersion = 1

	// ServiceName is the SCM service name. It is deliberately stable across
	// upgrades: the installer updates an existing registration instead of
	// creating a second service.
	ServiceName = "clash-halo-tun"
	// DisplayName and Description are what the Windows service manager shows.
	DisplayName = "Clash Halo TUN Service"
	Description = "按需运行 Clash Halo 的 TUN 内核。空闲时不启动内核；宿主退出后内核随之停止。"

	// PipePrefix is the base name of the control pipe.
	PipePrefix = `\\.\pipe\clash-halo-tun-v1`

	// MaxFrameBytes bounds one NDJSON frame. Requests carry paths and ids,
	// never a full config, so this is generous.
	MaxFrameBytes = 64 << 10
)

// Actions accepted by the service. This is a closed set: the pipe must not
// become a general command channel.
const (
	ActionPing   = "ping"
	ActionStatus = "status"
	ActionStart  = "start"
	ActionStop   = "stop"
)

// PipeNameFor derives the control pipe from the data directory.
//
// The suffix algorithm matches contract.PipeNameFor so two installations with
// different data directories never reach each other's host or service. The
// prefix differs, so a host pipe can never be mistaken for a service pipe.
func PipeNameFor(base string) string {
	if base == "" {
		return PipePrefix
	}
	suffix := strings.ToLower(strings.ReplaceAll(filepath.Clean(base), `\`, "/"))
	return PipePrefix + "-" + strconv.FormatUint(fnv64(suffix), 16)
}

// fnv64 is FNV-1a, copied from the contract package. It is an identifier, not
// a security boundary; a cross-package test pins the two algorithms together.
func fnv64(s string) uint64 {
	var h uint64 = 14695981039346656037
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return h
}

// Request is one control frame.
type Request struct {
	V      int             `json:"v"`
	ID     string          `json:"id"`
	Action string          `json:"action"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Response answers exactly one Request, matched by ID.
type Response struct {
	V      int        `json:"v"`
	ID     string     `json:"id"`
	OK     bool       `json:"ok"`
	Result any        `json:"result,omitempty"`
	Error  *WireError `json:"error,omitempty"`
}

// WireError is the machine-readable half of a failed request.
type WireError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *WireError) Error() string {
	if e == nil {
		return ""
	}
	return e.Code + ": " + e.Message
}

// StartParams asks for one TUN core.
type StartParams struct {
	// Config is the runtime config written by the host. It must live under
	// the installed data directory.
	Config string `json:"config"`
	// HostPID is the process that owns the tunnel. The service watches it and
	// stops the core when it exits, so a crashed host cannot leave an elevated
	// core or a wintun adapter behind.
	HostPID int `json:"hostPid"`
}

// PingResult lets the host recognise a compatible service before using it.
type PingResult struct {
	Protocol     int    `json:"protocol"`
	Version      string `json:"version"`
	OwnerSID     string `json:"ownerSid"`
	CoreSHA256   string `json:"coreSha256"`
	DataDir      string `json:"dataDir"`
	ServiceState string `json:"serviceState"`
	// CoreRuntime is the revision of the installed TUN service and core runtime.
	// The host refreshes older revisions when TUN is enabled.
	CoreRuntime int `json:"coreRuntime"`
}

// DecodeRequest parses one NDJSON line and rejects frames this service does
// not understand. An empty version means the historical frame shape; the only
// supported version is ProtocolVersion.
func DecodeRequest(line []byte) (*Request, error) {
	var req Request
	if err := json.Unmarshal(line, &req); err != nil {
		return nil, fmt.Errorf("tunservice: 请求不是 JSON: %w", err)
	}
	if req.V != 0 && req.V != ProtocolVersion {
		return nil, fmt.Errorf("tunservice: 协议版本不支持 (v=%d)", req.V)
	}
	if strings.TrimSpace(req.Action) == "" {
		return nil, fmt.Errorf("tunservice: 缺少 action")
	}
	if len(req.Params) > MaxFrameBytes {
		return nil, fmt.Errorf("tunservice: 参数过大")
	}
	return &req, nil
}

// Error codes on the wire. The host maps these to its own contract errors; the
// service does not know UI error codes.
const (
	CodeBadRequest      = "bad_request"
	CodeUnknownAction   = "unknown_action"
	CodeRejected        = "rejected"
	CodeStartFailed     = "start_failed"
	CodeServiceStopping = "service_stopping"
)
