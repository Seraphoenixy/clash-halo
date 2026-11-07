// Package tunconfig rewrites a sing-box configuration so the host can switch
// the running config between "system proxy mode" (no tun inbound, runs
// unelevated) and "TUN mode" (exactly one tun inbound, runs under the
// LocalSystem service).
//
// It is deliberately the only place in the Go code that edits sing-box config
// JSON. The transform is narrow and mechanical, and keeping it isolated is
// what makes it possible to prove that a user's config survives the round trip
// without losing keys this build has never heard of — a config is user data,
// not a template we own.
//
// The field names are pinned to the locked core, sing-box 1.14.4, rather than
// to an older release's documentation: inet4_address/inet6_address were
// deprecated in 1.10.0 and *removed* in 1.12.0, so emitting them makes the
// core refuse to start. The accepted address field is the "address" array of
// CIDR prefixes. A wrong guess here only surfaces at the core process, where
// the message is far less specific than a unit test's.
//
// Errors that describe a value the user chose (adapter name, stack, MTU,
// address) are written in Chinese because they reach the UI through the host's
// error path; errors about the config document itself are internal English
// errors, in the style of the neighbouring packages.
package tunconfig

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"
)

// Stacks accepted by sing-box 1.14.4. Anything else is rejected at option
// validation instead of at core start-up.
const (
	StackSystem = "system"
	StackGvisor = "gvisor"
	StackMixed  = "mixed"
)

// Bounds and fixed values of the injected inbound.
const (
	// TunTag is the tag of the tun inbound this package writes. A fixed tag
	// keeps the injected inbound recognisable and lets route rules refer to it.
	TunTag = "tun-in"

	// MinMTU and MaxMTU bound the MTU when it is written at all. Below 1280 the
	// tunnel cannot carry IPv6, and above 65535 the core rejects the value.
	MinMTU = 1280
	// MaxMTU is the largest MTU sing-box accepts.
	MaxMTU = 65535

	// MaxAdapterNameBytes bounds the adapter name. The name travels through
	// IPC and the UI and is handed to Windows, so a far smaller practical
	// limit than the documented maximum is enforced here.
	MaxAdapterNameBytes = 64
)

// Sentinel errors, so callers can classify a rejection without matching text.
var (
	// ErrInvalidAdapterName rejects a missing or Windows-illegal adapter name.
	ErrInvalidAdapterName = errors.New("TUN 网卡名称无效")
	// ErrInvalidStack rejects a stack sing-box does not implement.
	ErrInvalidStack = errors.New("TUN 协议栈无效")
	// ErrInvalidMTU rejects an MTU outside what sing-box accepts.
	ErrInvalidMTU = errors.New("TUN MTU 无效")
	// ErrInvalidAddress rejects an address that is not a CIDR prefix.
	ErrInvalidAddress = errors.New("TUN 地址无效")
	// ErrInvalidConfig rejects a config document this package cannot rewrite.
	ErrInvalidConfig = errors.New("tunconfig: invalid config")
)

// Options describes the tun inbound to inject.
type Options struct {
	// AdapterName is the Windows adapter name (sing-box interface_name).
	AdapterName string
	// Stack is one of StackSystem, StackGvisor or StackMixed.
	Stack string
	// Address is a single CIDR prefix, e.g. "172.19.0.1/30".
	Address string
	// MTU is written only when non-zero.
	MTU int
	// AutoRoute lets sing-box install the routes for the tunnel.
	AutoRoute bool
	// StrictRoute additionally prevents traffic from bypassing the tunnel.
	StrictRoute bool
}

// DefaultOptions returns the options that reproduce
// tests/fixtures/singbox/tun_inbound.json exactly.
//
// The fixture is the shared, pre-verified description of the inbound this
// project runs. The stack is "mixed" rather than "gvisor": sing-box's mixed
// stack hands TCP to the Windows stack and keeps gvisor only for UDP, which is
// both faster and cheaper per connection than running every TCP stream through
// a userspace stack. The pinned build carries the with_gvisor tag, so mixed is
// available; "sing-box check" accepts it (verified against 1.14.4).
func DefaultOptions() Options {
	return Options{
		AdapterName: "clash-halo",
		Stack:       StackMixed,
		Address:     "172.19.0.1/30",
		MTU:         9000,
		AutoRoute:   true,
		StrictRoute: true,
	}
}

// wireTunInbound is the exact key set sing-box 1.14.4 accepts for a tun
// inbound.
//
// There is deliberately no inet4_address/inet6_address field here: those were
// removed in sing-box 1.12.0 and the core refuses to start with them. A struct
// (rather than a map) keeps the emitted key set reviewable at a glance.
type wireTunInbound struct {
	Type          string   `json:"type"`
	Tag           string   `json:"tag"`
	InterfaceName string   `json:"interface_name"`
	Address       []string `json:"address"`
	MTU           int      `json:"mtu,omitempty"`
	AutoRoute     bool     `json:"auto_route"`
	StrictRoute   bool     `json:"strict_route"`
	Stack         string   `json:"stack"`
}

// inbound renders opts as the inbound object that is written into the config.
// Surrounding whitespace is trimmed so a value pasted into the UI cannot make
// the core fail on a name that merely looks different.
func (opts Options) inbound() wireTunInbound {
	return wireTunInbound{
		Type:          "tun",
		Tag:           TunTag,
		InterfaceName: strings.TrimSpace(opts.AdapterName),
		Address:       []string{strings.TrimSpace(opts.Address)},
		MTU:           opts.MTU,
		AutoRoute:     opts.AutoRoute,
		StrictRoute:   opts.StrictRoute,
		Stack:         opts.Stack,
	}
}

// Validate checks Options against what sing-box 1.14.4 accepts and what
// Windows allows as an adapter name. It never touches the config document.
func Validate(opts Options) error {
	if err := validateAdapterName(opts.AdapterName); err != nil {
		return err
	}
	switch opts.Stack {
	case StackSystem, StackGvisor, StackMixed:
	default:
		return fmt.Errorf("%w: %q（仅支持 %s、%s、%s）",
			ErrInvalidStack, opts.Stack, StackSystem, StackGvisor, StackMixed)
	}
	if opts.MTU != 0 && (opts.MTU < MinMTU || opts.MTU > MaxMTU) {
		return fmt.Errorf("%w: %d（0 表示不写入该字段，否则须为 %d..%d）",
			ErrInvalidMTU, opts.MTU, MinMTU, MaxMTU)
	}
	if _, _, err := net.ParseCIDR(strings.TrimSpace(opts.Address)); err != nil {
		return fmt.Errorf("%w: %q 不是合法的 CIDR 前缀", ErrInvalidAddress, opts.Address)
	}
	return nil
}

// validateAdapterName applies the Windows name rules without requiring the
// rest of Options.
func validateAdapterName(raw string) error {
	name := strings.TrimSpace(raw)
	if name == "" {
		return fmt.Errorf("%w: 不能为空", ErrInvalidAdapterName)
	}
	if len(name) > MaxAdapterNameBytes {
		return fmt.Errorf("%w: %q 为 %d 字节，最多 %d 字节",
			ErrInvalidAdapterName, name, len(name), MaxAdapterNameBytes)
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return fmt.Errorf("%w: %q 含有控制字符 %q", ErrInvalidAdapterName, name, r)
		}
		if strings.ContainsRune(`\/:*?"<>|`, r) {
			return fmt.Errorf("%w: %q 含有非法字符 %q", ErrInvalidAdapterName, name, r)
		}
	}
	return nil
}

// SetAdapterName rewrites the interface_name of the first tun inbound.
//
// The service uses this to retry a TUN start with a fresh adapter name when a
// killed core left a registration that cannot be opened. It edits exactly one
// field and preserves every other key.
func SetAdapterName(raw []byte, name string) ([]byte, error) {
	if err := validateAdapterName(name); err != nil {
		return nil, err
	}
	obj, err := decodeObject(raw)
	if err != nil {
		return nil, err
	}
	list, err := decodeInbounds(obj)
	if err != nil {
		return nil, err
	}
	renamed := false
	for i, in := range list {
		if inboundType(in) != "tun" {
			continue
		}
		var entry map[string]json.RawMessage
		if err := json.Unmarshal(in, &entry); err != nil {
			return nil, fmt.Errorf("%w: tun inbound is not an object", ErrInvalidConfig)
		}
		entry["interface_name"], _ = json.Marshal(strings.TrimSpace(name))
		list[i], err = json.Marshal(entry)
		if err != nil {
			return nil, fmt.Errorf("tunconfig: marshal tun inbound: %w", err)
		}
		renamed = true
		break
	}
	if !renamed {
		return nil, fmt.Errorf("%w: no tun inbound", ErrInvalidConfig)
	}
	obj["inbounds"], err = json.Marshal(list)
	if err != nil {
		return nil, fmt.Errorf("tunconfig: marshal inbounds: %w", err)
	}
	return json.Marshal(obj)
}

// HasTunInbound reports whether the config already declares a tun inbound.
func HasTunInbound(raw []byte) (bool, error) {
	obj, err := decodeObject(raw)
	if err != nil {
		return false, err
	}
	list, err := decodeInbounds(obj)
	if err != nil {
		return false, err
	}
	for _, in := range list {
		if inboundType(in) == "tun" {
			return true, nil
		}
	}
	return false, nil
}

// AdapterName returns the interface_name of the tun inbound, or "" if none.
//
// The first tun inbound wins, which matches Inject's "replace in place"
// behaviour: whatever that returns is what the service will report back.
func AdapterName(raw []byte) (string, error) {
	obj, err := decodeObject(raw)
	if err != nil {
		return "", err
	}
	list, err := decodeInbounds(obj)
	if err != nil {
		return "", err
	}
	for _, in := range list {
		var view struct {
			Type          string `json:"type"`
			InterfaceName string `json:"interface_name"`
		}
		if err := json.Unmarshal(in, &view); err != nil {
			continue
		}
		if view.Type == "tun" {
			return view.InterfaceName, nil
		}
	}
	return "", nil
}

// Inject returns raw with exactly one tun inbound built from opts and
// route.auto_detect_interface set to true.
//
// An existing tun inbound is replaced where it stands so the surrounding
// inbounds keep their order and any duplicate hand-edited tun inbounds are
// collapsed; otherwise the new inbound is appended. route.auto_detect_interface
// is forced to true because otherwise Windows routes the proxy's own outbound
// traffic back into the tunnel, which is a silent, total loss of connectivity.
//
// DoH URLs emitted by older Halo versions are converted to structured
// endpoints. All unrelated keys are preserved. raw itself is never modified.
func Inject(raw []byte, opts Options) ([]byte, error) {
	if err := Validate(opts); err != nil {
		return nil, err
	}
	obj, err := decodeObject(raw)
	if err != nil {
		return nil, err
	}
	list, err := decodeInbounds(obj)
	if err != nil {
		return nil, err
	}
	encodedInbound, err := json.Marshal(opts.inbound())
	if err != nil {
		return nil, fmt.Errorf("tunconfig: marshal tun inbound: %w", err)
	}

	// A fresh slice every time: appending to or overwriting the slice decoded
	// from raw would write into the caller's backing array.
	next := make([]json.RawMessage, 0, len(list)+1)
	replaced := false
	for _, in := range list {
		if inboundType(in) == "tun" {
			if !replaced {
				next = append(next, json.RawMessage(encodedInbound))
				replaced = true
			}
			// Any further tun inbound is dropped: two of them is a config the
			// core cannot use, and the caller's contract is "exactly one".
			continue
		}
		next = append(next, in)
	}
	if !replaced {
		next = append(next, json.RawMessage(encodedInbound))
	}
	encodedInbounds, err := json.Marshal(next)
	if err != nil {
		return nil, fmt.Errorf("tunconfig: marshal inbounds: %w", err)
	}
	obj["inbounds"] = encodedInbounds

	route, err := decodeRoute(obj)
	if err != nil {
		return nil, err
	}
	route["auto_detect_interface"] = json.RawMessage("true")
	encodedRoute, err := json.Marshal(route)
	if err != nil {
		return nil, fmt.Errorf("tunconfig: marshal route: %w", err)
	}
	obj["route"] = encodedRoute
	repairDoHEndpoints(obj)

	return json.Marshal(obj)
}

// Older active configs put the full DoH URL in server. sing-box check accepts
// it, but the first DNS exchange fails when sing-box builds its request URL.
func repairDoHEndpoints(obj map[string]json.RawMessage) {
	var dns map[string]json.RawMessage
	if json.Unmarshal(obj["dns"], &dns) != nil {
		return
	}
	var servers []json.RawMessage
	if json.Unmarshal(dns["servers"], &servers) != nil {
		return
	}
	changed := false
	for i, raw := range servers {
		var entry map[string]json.RawMessage
		if json.Unmarshal(raw, &entry) != nil {
			continue
		}
		var kind, address string
		if json.Unmarshal(entry["type"], &kind) != nil || kind != "https" ||
			json.Unmarshal(entry["server"], &address) != nil {
			continue
		}
		endpoint, err := url.Parse(address)
		if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" {
			continue
		}
		if port := endpoint.Port(); port != "" && entry["server_port"] == nil {
			value, err := strconv.ParseUint(port, 10, 16)
			if err != nil || value == 0 {
				continue
			}
			entry["server_port"], _ = json.Marshal(value)
		}
		if endpoint.Path != "" && entry["path"] == nil {
			entry["path"], _ = json.Marshal(endpoint.Path)
		}
		entry["server"], _ = json.Marshal(endpoint.Hostname())
		servers[i], _ = json.Marshal(entry)
		changed = true
	}
	if changed {
		dns["servers"], _ = json.Marshal(servers)
		obj["dns"], _ = json.Marshal(dns)
	}
}

// Strip removes every tun inbound, leaving all other keys untouched.
//
// A config with several tun inbounds (a hand-edited file, or two runs of a
// broken build) loses all of them; route and every other key are returned
// exactly as they were. When there is nothing to remove the input is returned
// unchanged rather than re-encoded, so a no-op really is a no-op.
func Strip(raw []byte) ([]byte, error) {
	obj, err := decodeObject(raw)
	if err != nil {
		return nil, err
	}
	if _, ok := obj["inbounds"]; !ok {
		return append([]byte(nil), raw...), nil
	}
	list, err := decodeInbounds(obj)
	if err != nil {
		return nil, err
	}
	next := make([]json.RawMessage, 0, len(list))
	removed := false
	for _, in := range list {
		if inboundType(in) == "tun" {
			removed = true
			continue
		}
		next = append(next, in)
	}
	if !removed {
		return append([]byte(nil), raw...), nil
	}
	encoded, err := json.Marshal(next)
	if err != nil {
		return nil, fmt.Errorf("tunconfig: marshal inbounds: %w", err)
	}
	obj["inbounds"] = encoded
	return json.Marshal(obj)
}

// decodeObject parses raw as a JSON object.
//
// RawMessage values keep every untouched key byte-for-byte, which is what lets
// Strip and Inject round-trip a config without understanding most of it.
func decodeObject(raw []byte) (map[string]json.RawMessage, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, fmt.Errorf("%w: document is empty", ErrInvalidConfig)
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidConfig, err)
	}
	// JSON "null" unmarshals into a nil map without error.
	if obj == nil {
		return nil, fmt.Errorf("%w: root must be a JSON object", ErrInvalidConfig)
	}
	return obj, nil
}

// decodeInbounds returns the raw inbounds array, or nil when the config has
// none. A null inbounds value is treated as "none" rather than as an error: it
// is what a hand-edited or generated config can contain.
func decodeInbounds(obj map[string]json.RawMessage) ([]json.RawMessage, error) {
	raw, ok := obj["inbounds"]
	if !ok || isNull(raw) {
		return nil, nil
	}
	var list []json.RawMessage
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, fmt.Errorf("%w: inbounds must be an array: %v", ErrInvalidConfig, err)
	}
	return list, nil
}

// decodeRoute returns the route object, creating an empty one when route is
// missing or null.
func decodeRoute(obj map[string]json.RawMessage) (map[string]json.RawMessage, error) {
	raw, ok := obj["route"]
	if !ok || isNull(raw) {
		return map[string]json.RawMessage{}, nil
	}
	var route map[string]json.RawMessage
	if err := json.Unmarshal(raw, &route); err != nil {
		return nil, fmt.Errorf("%w: route must be an object: %v", ErrInvalidConfig, err)
	}
	if route == nil {
		route = map[string]json.RawMessage{}
	}
	return route, nil
}

// inboundType returns the "type" of one inbound element, or "" if the element
// is not a JSON object. A junk element is skipped rather than rejected so a
// hand-edited config can still be stripped without losing data.
func inboundType(raw json.RawMessage) string {
	var view struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(raw, &view); err != nil {
		return ""
	}
	return view.Type
}

// isNull reports whether a raw JSON value is the literal null.
func isNull(raw json.RawMessage) bool {
	return string(bytes.TrimSpace(raw)) == "null"
}
