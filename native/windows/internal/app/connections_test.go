package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"clash-halo/native/windows/internal/connapi"
	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
)

func TestConnectionsUseTunController(t *testing.T) {
	a := newTestApp(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/connections":
			_, _ = w.Write([]byte(sampleConnections))
		case r.Method == http.MethodDelete && r.URL.Path == "/connections/c1a2b3":
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	controller := strings.TrimPrefix(server.URL, "http://")
	config, err := json.Marshal(map[string]any{
		"experimental": map[string]any{
			"clash_api": map[string]string{"external_controller": controller},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(a.Paths.TunConfigs, "runtime.json"), config, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, errObj := request(t, a, contract.ActionConnectionsList, nil); errObj == nil || errObj.Code != contract.ErrCoreNotRunning {
		t.Fatalf("stopped core: got %v, want core_not_running", errObj)
	}

	a.markTun(state.TunEnabled, "", 1234, "test-tun", true)
	t.Cleanup(func() { a.markTun(state.TunDisabled, "", 0, "", false) })
	got, errObj := request(t, a, contract.ActionConnectionsList, nil)
	if errObj != nil {
		t.Fatalf("list with TUN enabled: %v", errObj)
	}
	snapshot := got.(connapi.ConnectionsSnapshot)
	if snapshot.Controller != controller || snapshot.DownloadTotal != 913422 {
		t.Fatalf("unexpected TUN connection snapshot: %+v", snapshot)
	}
	if _, errObj := request(t, a, contract.ActionConnectionsClose, map[string]any{"id": "c1a2b3"}); errObj != nil {
		t.Fatalf("close with TUN enabled: %v", errObj)
	}
}

// A captured payload, shaped exactly like the Clash API's /connections answer:
// the destination lives inside `metadata` while the rule and chains sit at the
// top level. Flattening is the host's job so the UI never has to know that.
const sampleConnections = `{
  "downloadTotal": 913422,
  "uploadTotal": 120455,
  "memory": 0,
  "connections": [
    {
      "id": "c1a2b3",
      "metadata": {
        "network": "tcp",
        "type": "HTTPS",
        "sourceIP": "127.0.0.1",
        "destinationIP": "93.184.216.34",
        "sourcePort": "51234",
        "destinationPort": "443",
        "host": "example.com",
        "process": "chrome.exe",
        "processPath": "C:\\Program Files\\Google\\Chrome\\chrome.exe"
      },
      "upload": 1000,
      "download": 2000,
      "start": "2026-11-04T08:00:00.000000000+08:00",
      "chains": ["节点 A", "DIRECT"],
      "rule": "DomainSuffix",
      "rulePayload": "example.com"
    },
    {
      "id": "d4e5f6",
      "metadata": {
        "network": "udp",
        "type": "QUIC",
        "destinationIP": "1.1.1.1"
      },
      "upload": 10,
      "download": 20,
      "start": "2026-11-04T08:00:01+08:00",
      "chains": ["节点 A"],
      "rule": "Match",
      "rulePayload": ""
    }
  ]
}`

func TestParseClashConnections(t *testing.T) {
	snapshot, err := connapi.ParseConnections([]byte(sampleConnections))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if snapshot.DownloadTotal != 913422 || snapshot.UploadTotal != 120455 {
		t.Fatalf("totals = %d/%d", snapshot.UploadTotal, snapshot.DownloadTotal)
	}
	if len(snapshot.Connections) != 2 {
		t.Fatalf("got %d connections", len(snapshot.Connections))
	}

	first := snapshot.Connections[0]
	if first.Host != "example.com" {
		t.Fatalf("host = %q", first.Host)
	}
	if first.Rule != "DomainSuffix" || first.Payload != "example.com" {
		t.Fatalf("rule = %q/%q", first.Rule, first.Payload)
	}
	if len(first.Chains) != 2 || first.Chains[0] != "节点 A" {
		t.Fatalf("chains = %v", first.Chains)
	}
	if first.Process != "chrome.exe" || first.Type != "HTTPS" {
		t.Fatalf("process/type = %q/%q", first.Process, first.Type)
	}
	if first.Upload != 1000 || first.Download != 2000 {
		t.Fatalf("bytes = %d/%d", first.Upload, first.Download)
	}

	// A connection addressed by IP has no host; falling back to the destination
	// IP is what keeps the row readable instead of blank.
	second := snapshot.Connections[1]
	if second.Host != "1.1.1.1" {
		t.Fatalf("ip connection host = %q", second.Host)
	}
	if second.Network != "udp" {
		t.Fatalf("network = %q", second.Network)
	}
}

func TestParseClashConnectionsEmpty(t *testing.T) {
	snapshot, err := connapi.ParseConnections([]byte(`{"connections":[],"uploadTotal":0}`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(snapshot.Connections) != 0 {
		t.Fatalf("got %d connections", len(snapshot.Connections))
	}
	// Non-nil slice: the JSON encoder would otherwise emit null and the UI's
	// parser would have to special-case it.
	if snapshot.Connections == nil {
		t.Fatal("connections must be an empty slice, not nil")
	}

	if _, err := connapi.ParseConnections([]byte("not json")); err == nil {
		t.Fatal("garbage must not parse")
	}
}

// The controller must never leave the loopback interface: the host reads the
// address from a config file that a user can edit by hand, so the check is the
// only thing standing between "show connections" and "call an arbitrary host".
func TestIsLoopbackAddress(t *testing.T) {
	loopback := []string{
		"127.0.0.1:9090",
		"127.0.0.5:1",
		"[::1]:9090",
		"localhost:9090",
	}
	for _, addr := range loopback {
		if !connapi.IsLoopbackAddress(addr) {
			t.Fatalf("%q should be allowed", addr)
		}
	}
	rejected := []string{
		"",
		"9090",
		"0.0.0.0:9090",
		"192.168.1.10:9090",
		"example.com:9090",
		"127.0.0.1",
	}
	for _, addr := range rejected {
		if connapi.IsLoopbackAddress(addr) {
			t.Fatalf("%q should be rejected", addr)
		}
	}
}
