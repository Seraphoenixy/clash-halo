package app

import (
	"os"
	"path/filepath"
	"testing"
)

// testCorePath returns the real sing-box binary used by integration tests.
//
// These tests deliberately exercise the real core instead of a fake: the
// config-apply pipeline's whole purpose is to reject what the real binary
// rejects, and a stub would pass configs the product must refuse.
func testCorePath(t testing.TB) string {
	t.Helper()
	for _, candidate := range []string{
		os.Getenv("HALO_SINGBOX"),
		"../../../.tmp/singbox/sing-box.exe",
		"../../../.tmp/sing-box.exe",
		"../../../../prototype/bin/sing-box.exe",
		"../../../prototype/bin/sing-box.exe",
	} {
		if candidate == "" {
			continue
		}
		if _, err := os.Stat(candidate); err == nil {
			abs, err := filepath.Abs(candidate)
			if err != nil {
				t.Fatalf("abs: %v", err)
			}
			return abs
		}
	}
	t.Skip("sing-box binary not found; set HALO_SINGBOX to run integration tests")
	return ""
}

const validConfig = `{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 17890}],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}`

const structurallyInvalidConfig = `{
  "outbounds": [{"type": "definitely-not-a-protocol", "tag": "proxy"}]
}`
