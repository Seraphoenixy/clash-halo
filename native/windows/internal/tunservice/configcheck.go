package tunservice

// This file holds the closed-set check applied to a config before the service
// starts an elevated core with it.
//
// The service runs as LocalSystem and is reachable from the unelevated host,
// so it must not become a general "run this config" channel. The checks here
// are what keep that promise: exactly one tun inbound, no non-loopback proxy
// listener, no log file outside the data directory, and a controller that stays
// on this host.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"strings"
)

// maxConfigBytes bounds the document the service is willing to parse, so a
// caller cannot make an elevated process allocate without limit.
const maxConfigBytes = 4 << 20

var (
	errEmptyPath         = errors.New("tunservice: empty path")
	errPathOutsideRoot   = errors.New("tunservice: path outside root")
	errNoTunInbound      = errors.New("tunservice: config declares no tun inbound")
	errUnsafeConfigField = errors.New("tunservice: unsafe config field")
)

// safeJoin resolves candidate under root and refuses anything that escapes it.
//
// filepath.Abs alone is not enough: it happily resolves "..\..\evil". The
// cleaned absolute paths must share root as a prefix *component-wise*, which is
// what filepath.Rel checks: "C:\root-evil" is not inside "C:\root" even though
// it shares a string prefix.
func safeJoin(root, candidate string) (string, error) {
	if strings.TrimSpace(candidate) == "" {
		return "", errEmptyPath
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	absCandidate, err := filepath.Abs(candidate)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(absRoot, absCandidate)
	if err != nil {
		return "", err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("%w: %s", errPathOutsideRoot, candidate)
	}
	return absCandidate, nil
}

// resolveUnderRoot resolves a possibly-relative path against root and refuses
// anything that escapes it.
//
// Relative paths are resolved against root rather than the process working
// directory, because root is where the core actually starts: sing-box
// interprets a relative log.output the same way.
func resolveUnderRoot(root, candidate string) (string, error) {
	if strings.TrimSpace(candidate) == "" {
		return "", errEmptyPath
	}
	p := candidate
	if !filepath.IsAbs(p) {
		p = filepath.Join(root, p)
	}
	return safeJoin(root, p)
}

// isLoopbackEndpoint reports whether a controller endpoint stays on this host.
func isLoopbackEndpoint(endpoint string) bool {
	host, _, err := net.SplitHostPort(endpoint)
	if err != nil {
		host = endpoint
	}
	return isLoopbackHost(host)
}

// isLoopbackHost reports whether a bare listen address stays on this host.
func isLoopbackHost(host string) bool {
	host = strings.Trim(strings.TrimSpace(host), "[]")
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// maxAdapterNameLen bounds the adapter name the service will create.
const maxAdapterNameLen = 64

// validateAdapterName enforces the Windows adapter-name rules.
func validateAdapterName(name string) error {
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("tunservice: adapter name is empty")
	}
	if len(name) > maxAdapterNameLen {
		return fmt.Errorf("tunservice: adapter name too long (%d)", len(name))
	}
	if name == "." || name == ".." {
		return fmt.Errorf("tunservice: adapter name is a relative path")
	}
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			return fmt.Errorf("tunservice: adapter name contains a control character")
		}
		if strings.ContainsRune(`\/:*?"<>|`, r) {
			return fmt.Errorf("tunservice: adapter name contains %q", r)
		}
	}
	return nil
}

// tunProbe extracts only the fields the elevated path cares about.
type tunProbe struct {
	Inbounds []struct {
		Type          string `json:"type"`
		Tag           string `json:"tag"`
		InterfaceName string `json:"interface_name"`
		Listen        string `json:"listen"`
	} `json:"inbounds"`
	Log struct {
		Output string `json:"output"`
	} `json:"log"`
	Experimental struct {
		ClashAPI struct {
			ExternalController string `json:"external_controller"`
		} `json:"clash_api"`
	} `json:"experimental"`
}

// CheckConfigForTun validates a candidate config and returns the adapter name
// it will create.
//
// Three checks matter beyond "is this JSON": exactly one tun inbound (so the
// elevated process does one predictable thing), a log.output that cannot be
// aimed at an arbitrary file, and a controller that stays on loopback. The last
// two are the only primitives in a sing-box config that a caller could
// otherwise abuse once the process runs as LocalSystem.
func CheckConfigForTun(dataDir string, raw []byte) (string, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return "", errEmptyPath
	}
	if len(raw) > maxConfigBytes {
		return "", fmt.Errorf("tunservice: config too large (%d bytes)", len(raw))
	}
	var probe tunProbe
	if err := json.Unmarshal(raw, &probe); err != nil {
		return "", fmt.Errorf("tunservice: config is not a valid JSON object: %w", err)
	}
	adapter, count := "", 0
	for _, in := range probe.Inbounds {
		if in.Type != "tun" {
			continue
		}
		count++
		adapter = in.InterfaceName
	}
	switch {
	case count == 0:
		return "", errNoTunInbound
	case count > 1:
		return "", fmt.Errorf("tunservice: config declares %d tun inbounds", count)
	}
	// A non-tun inbound left on its default listen address binds 0.0.0.0, so
	// an elevated core would expose a proxy to the whole LAN. The generator
	// already writes 127.0.0.1; refusing anything else keeps the closed set
	// actually closed.
	for _, in := range probe.Inbounds {
		if in.Type == "tun" {
			continue
		}
		if strings.TrimSpace(in.Listen) == "" {
			return "", fmt.Errorf("%w: inbound %q 未指定 listen，默认监听所有接口",
				errUnsafeConfigField, in.Tag)
		}
		if !isLoopbackHost(in.Listen) {
			return "", fmt.Errorf("%w: inbound %q 监听在 %s，不是回环地址",
				errUnsafeConfigField, in.Tag, in.Listen)
		}
	}
	if err := validateAdapterName(adapter); err != nil {
		return "", err
	}
	if out := strings.TrimSpace(probe.Log.Output); out != "" {
		if _, err := resolveUnderRoot(dataDir, out); err != nil {
			return "", fmt.Errorf("%w: log.output %q", errUnsafeConfigField, out)
		}
	}
	if ctl := strings.TrimSpace(probe.Experimental.ClashAPI.ExternalController); ctl != "" {
		if !isLoopbackEndpoint(ctl) {
			return "", fmt.Errorf("%w: external_controller %q is not loopback",
				errUnsafeConfigField, ctl)
		}
	}
	return adapter, nil
}
