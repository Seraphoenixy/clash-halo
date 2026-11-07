// Package contract mirrors packages/contracts: one JSON object per line,
// discriminated by presence of `action`, `event` or `ok`.
//
// The Go side must never invent fields the Dart side does not know about, so
// structs here are the single source of truth for wire names.
package contract

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
)

// ProtocolVersion must stay in sync with kProtocolVersion in Dart.
const ProtocolVersion = 1

// PipeName is the production pipe. The version suffix allows a second
// installation of a different major version to coexist without confusion.
const PipeName = `\\.\pipe\clash-halo-host-v1`

// PipeNameFor derives the pipe name for a data directory.
//
// A single global name would make two hosts with different data directories
// fight for one pipe, and `--status` would then report the state of whichever
// instance happened to win. Deriving the name from the directory keeps each
// installation isolated and lets diagnostics address the right host.
// The empty base keeps the historical name for the default install layout.
func PipeNameFor(base string) string {
	if base == "" {
		return PipeName
	}
	suffix := strings.ToLower(strings.ReplaceAll(filepath.Clean(base), `\`, "/"))
	return PipeName + "-" + strconv.FormatUint(fnv64(suffix), 16)
}

// fnv64 is FNV-1a, chosen because it is short, stable across processes and
// needs no extra dependency; it is an identifier, not a security boundary.
func fnv64(s string) uint64 {
	var h uint64 = 14695981039346656037
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return h
}

// CoreExecutable is the bundled sing-box binary name.
const CoreExecutable = "sing-box.exe"

// Actions accepted by the host.
const (
	ActionSnapshotGet   = "snapshot.get"
	ActionHostStatus    = "host.status"
	ActionHostShutdown  = "host.shutdown"
	ActionCoreStart     = "core.start"
	ActionCoreStop      = "core.stop"
	ActionCoreRestart   = "core.restart"
	ActionConfigApply   = "config.apply"
	ActionNodeSelect    = "node.select"
	ActionProxySetMode  = "proxy.setMode"
	ActionSystemProxy   = "systemProxy.set"
	ActionAutoLaunchSet = "autoLaunch.set"
	// ActionCoreResumeSet toggles whether a core that was running last session
	// is started again on the next host launch.
	ActionCoreResumeSet  = "coreResume.set"
	ActionTunSetEnabled  = "tun.setEnabled"
	// The service is installed once and then used without UAC. These actions
	// exist so the settings page can report and change that state.
	ActionTunServiceStatus    = "tun.serviceStatus"
	ActionTunServiceInstall   = "tun.serviceInstall"
	ActionTunServiceUninstall = "tun.serviceUninstall"
	ActionSpeedtest      = "speedtest.start"
	ActionTaskCancel     = "task.cancel"
	ActionLogTail        = "log.tail"
	ActionEventSubscribe = "event.subscribe"
	// ActionTrayPublish lets the UI hand the tray a compact node catalogue.
	// The host never owns the node database, so the tray menu's node list is a
	// projection the UI keeps fresh rather than something the host reads.
	ActionTrayPublish = "tray.publish"
	// Connections are read from the sing-box Clash API by the host, because the
	// controller is loopback-only and the UI has no HTTP stack pointed at it.
	ActionConnectionsList  = "connections.list"
	ActionConnectionsClose = "connections.close"
)

// Events pushed to subscribers.
const (
	EventStateChanged = "state.changed"
	EventLogAppended  = "log.appended"
	EventTaskStarted  = "task.started"
	EventTaskProgress = "task.progress"
	EventTaskFinished = "task.finished"
	EventHostExiting  = "host.exiting"
	// EventTrayCommand tells a running UI what the tray just asked for. The
	// same request is also written to tray-request.json, because the UI may not
	// be open at all — the tray has to work with the window closed.
	EventTrayCommand = "tray.command"
)

// Error codes. Chinese descriptions live on the Dart side; the host only
// reports codes plus a short message.
const (
	ErrBadRequest    = "bad_request"
	ErrUnknownAction = "unknown_action"
	// Wire codes must match HaloErrorCode in packages/contracts: the UI switches
	// on these strings, so a mismatch silently degrades every error path.
	ErrProtocolVersion    = "version_mismatch"
	ErrNotReady           = "conflict"
	ErrCoreNotRunning     = "core_not_running"
	ErrCoreAlreadyRunning = "already_running"
	ErrConfigInvalid      = "config_invalid"
	ErrConfigApply        = "config_apply_failed"
	ErrHealthCheck        = "core_failed"
	ErrElevationRequired  = "elevation_required"
	ErrElevationDenied    = "elevation_denied"
	ErrUnsupported        = "unsupported_capability"
	ErrTunUnavailable     = "tun_unavailable"
	ErrBusy               = "busy"
	ErrCanceled           = "task_canceled"
	ErrTaskNotFound       = "task_not_found"
	ErrUnauthorized       = "unauthorized"
	ErrSystemProxyFailed  = "system_proxy_failed"
	ErrInternal           = "internal"
	ErrNotFound           = "not_found"
	// Kept as an alias so existing call sites keep compiling.
	ErrSystemProxy = ErrSystemProxyFailed
)

// Request is an inbound command.
type Request struct {
	V      int             `json:"v"`
	ID     string          `json:"id"`
	Action string          `json:"action"`
	Params json.RawMessage `json:"params,omitempty"`
}

// ErrorObj is the structured error payload.
type ErrorObj struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Detail  string `json:"detail,omitempty"`
}

func (e *ErrorObj) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("%s: %s (%s)", e.Code, e.Message, e.Detail)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

// NewError builds an ErrorObj.
func NewError(code, message string) *ErrorObj {
	return &ErrorObj{Code: code, Message: message}
}

// Response is a command result.
type Response struct {
	V            int       `json:"v"`
	ID           string    `json:"id"`
	Ok           bool      `json:"ok"`
	Result       any       `json:"result,omitempty"`
	Error        *ErrorObj `json:"error,omitempty"`
	StateVersion int64     `json:"stateVersion"`
}

// Event is a pushed state/log/task notification.
type Event struct {
	V     int    `json:"v"`
	Event string `json:"event"`
	Seq   int64  `json:"seq"`
	// StateVersion lets a client order events against snapshots. The Dart
	// envelope has always parsed this field; leaving it out made every event
	// claim version 0.
	StateVersion int64 `json:"stateVersion"`
	Data         any   `json:"data,omitempty"`
}

// OK builds a successful response.
func OK(id string, result any, stateVersion int64) Response {
	return Response{V: ProtocolVersion, ID: id, Ok: true, Result: result, StateVersion: stateVersion}
}

// Fail builds a failed response.
func Fail(id string, err *ErrorObj, stateVersion int64) Response {
	return Response{V: ProtocolVersion, ID: id, Ok: false, Error: err, StateVersion: stateVersion}
}

// Encode writes one newline-terminated JSON object, never embedding a raw
// newline in the payload.
func Encode(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	// ReplaceAll copies the whole buffer even when nothing matches, and every
	// response pays that copy. JSON string values already escape their own
	// newlines, so a raw \n can only appear via a RawMessage field; scan first
	// and rewrite only when there is actually something to rewrite.
	if bytes.IndexByte(b, '\n') >= 0 {
		b = bytes.ReplaceAll(b, []byte("\n"), []byte(`\n`))
	}
	return append(b, '\n'), nil
}

// DecodeRequest parses one line into a Request, rejecting a body whose
// version is newer than this host supports.
//
// One parse, not two: the old implementation unmarshalled the whole line into
// a probe map just to learn whether `action` was present, then unmarshalled it
// again into the Request. A config.apply payload — the largest legitimate
// request — was therefore walked twice per command. A pointer field tells
// "absent" from "empty" in the same single pass.
func DecodeRequest(line []byte) (*Request, *ErrorObj) {
	var raw struct {
		V      int             `json:"v"`
		ID     string          `json:"id"`
		Action *string         `json:"action"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(line, &raw); err != nil {
		return nil, NewError(ErrBadRequest, "请求不是有效的 JSON 对象")
	}
	if raw.Action == nil {
		return nil, NewError(ErrBadRequest, "请求缺少 action 字段")
	}
	if raw.V != ProtocolVersion {
		return nil, &ErrorObj{
			Code:    ErrProtocolVersion,
			Message: "协议版本不匹配",
			Detail:  fmt.Sprintf("收到 v=%d，宿主支持 v=%d", raw.V, ProtocolVersion),
		}
	}
	if *raw.Action == "" {
		return nil, NewError(ErrBadRequest, "action 不能为空")
	}
	return &Request{
		V:      raw.V,
		ID:     raw.ID,
		Action: *raw.Action,
		Params: raw.Params,
	}, nil
}

// DecodeParams unmarshals request params into dst; an absent params object is
// treated as an empty object rather than an error.
func DecodeParams(req *Request, dst any) *ErrorObj {
	if len(req.Params) == 0 || string(req.Params) == "null" {
		return nil
	}
	if err := json.Unmarshal(req.Params, dst); err != nil {
		return &ErrorObj{
			Code:    ErrBadRequest,
			Message: "参数格式不正确",
			Detail:  err.Error(),
		}
	}
	return nil
}

// ParseLines splits a buffered stream into complete lines, returning the
// remainder that is not yet terminated. Bounded so a hostile client cannot
// exhaust memory.
func ParseLines(buf []byte, maxLine int) ([][]byte, []byte, *ErrorObj) {
	var lines [][]byte
	for {
		idx := bytes.IndexByte(buf, '\n')
		if idx < 0 {
			if len(buf) > maxLine {
				return nil, nil, NewError(ErrBadRequest, "请求行超长")
			}
			return lines, buf, nil
		}
		line := bytes.TrimRight(buf[:idx], "\r")
		if len(line) > maxLine {
			return nil, nil, NewError(ErrBadRequest, "请求行超长")
		}
		if len(bytes.TrimSpace(line)) > 0 {
			lines = append(lines, line)
		}
		buf = buf[idx+1:]
	}
}

// ErrUnknown is returned by dispatch when no handler matches.
var ErrUnknown = errors.New("unknown action")
