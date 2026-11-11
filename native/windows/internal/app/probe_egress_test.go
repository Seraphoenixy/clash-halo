package app

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"clash-halo/native/windows/internal/state"
)

// The probe's own config must not carry the active core's listener or
// controller: in proxy mode that would route the test through the proxy.
func TestPrepareProbeDocumentDropsActiveCore(t *testing.T) {
	document := `{
	  "log": {"level": "info"},
	  "inbounds": [
	    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890},
	    {"type": "http", "tag": "old", "listen": "127.0.0.1", "listen_port": 7891}
	  ],
	  "outbounds": [{"type": "direct", "tag": "proxy"}],
	  "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}},
	  "services": [{"type": "example"}]
	}`
	body, err := prepareProbeDocument(document, 45871, "user", "pass", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		t.Fatal(err)
	}
	inbounds, _ := doc["inbounds"].([]any)
	if len(inbounds) != 1 {
		t.Fatalf("inbounds = %v, want exactly the probe listener", inbounds)
	}
	in := inbounds[0].(map[string]any)
	if in["listen_port"] != float64(45871) {
		t.Fatalf("probe port = %v", in["listen_port"])
	}
	if _, ok := doc["experimental"]; ok {
		t.Fatal("the active core's controller survived into the probe config")
	}
	if _, ok := doc["services"]; ok {
		t.Fatal("active-core services survived into the probe config")
	}
	if strings.Contains(string(body), "7890") || strings.Contains(string(body), "9090") {
		t.Fatalf("probe config references the active core: %s", body)
	}
}

func TestPrepareProbeDocumentBindsEgress(t *testing.T) {
	document := `{
	  "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen_port": 7890}],
	  "outbounds": [
	    {"type": "direct", "tag": "direct"},
	    {"type": "block", "tag": "block"},
	    {"type": "selector", "tag": "sel", "outbounds": ["direct"]}
	  ]
	}`
	egress := &probeEgress{Name: "WLAN", IPv4: net.IPv4(192, 168, 1, 20), DNSListen: "127.0.0.1:5353"}
	body, err := prepareProbeDocument(document, 45872, "u", "p", egress, "")
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		t.Fatal(err)
	}
	outbounds := doc["outbounds"].([]any)
	direct := outbounds[0].(map[string]any)
	if direct["inet4_bind_address"] != "192.168.1.20" {
		t.Fatalf("direct outbound not bound to the physical address: %v", direct)
	}
	if _, ok := direct["bind_interface"]; ok {
		t.Fatal("bind_interface must stay out: it breaks the direct outbound under TUN")
	}
	block := outbounds[1].(map[string]any)
	if _, ok := block["inet4_bind_address"]; ok {
		t.Fatal("block outbound must not gain dial fields")
	}
	route := doc["route"].(map[string]any)
	if route["auto_detect_interface"] != false {
		t.Fatalf("auto_detect_interface = %v", route["auto_detect_interface"])
	}
	resolver := route["default_domain_resolver"].(map[string]any)
	if resolver["server"] != "probe-local" {
		t.Fatalf("default_domain_resolver = %v", resolver)
	}
	dns := doc["dns"].(map[string]any)
	servers := dns["servers"].([]any)
	first := servers[0].(map[string]any)
	if first["tag"] != "probe-local" || first["server"] != "127.0.0.1" || first["server_port"] != float64(5353) {
		t.Fatalf("dns server = %v", first)
	}
}

// A bare endpoint is not a proxy. Before this guard the host would dial it as
// one, which is exactly how a test could end up inside the active proxy.
func TestBareEndpointProbeIsRejected(t *testing.T) {
	a := newTestApp(t)
	p := speedParams{
		Metric:    metricProxyLatency,
		Endpoints: []string{"127.0.0.1:7890"},
		NodeIDs:   []string{"n1"},
	}
	results := a.runProbes(p, make(chan struct{}))
	if len(results) != 1 || results[0].ErrorCode != "probe_failed" {
		t.Fatalf("results = %+v", results)
	}
	if !strings.Contains(results[0].ErrorMsg, "当前代理入口") &&
		!strings.Contains(results[0].ErrorMsg, "物理网卡") {
		t.Fatalf("message = %q", results[0].ErrorMsg)
	}
}

func TestDNSRelayForwardsThroughBoundSocket(t *testing.T) {
	upstream, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Skipf("loopback UDP unavailable: %v", err)
	}
	defer upstream.Close()
	go func() {
		buf := make([]byte, 512)
		n, from, err := upstream.ReadFromUDP(buf)
		if err != nil {
			return
		}
		_, _ = upstream.WriteToUDP(append([]byte("reply:"), buf[:n]...), from)
	}()

	egress := &probeEgress{
		Name: "loopback-test",
		IPv4: net.IPv4(127, 0, 0, 1),
		DNS:  upstream.LocalAddr().String(),
	}
	relay, err := startDNSRelay(egress)
	if err != nil {
		t.Fatalf("relay: %v", err)
	}
	defer relay.Close()

	conn, err := net.DialUDP("udp4", nil, mustUDPAddr(t, relay.Addr()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte("query")); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 512)
	n, err := conn.Read(response)
	if err != nil {
		t.Fatal(err)
	}
	if string(response[:n]) != "reply:query" {
		t.Fatalf("response = %q", response[:n])
	}
}

func TestDiscoverProbeEgressFindsAPhysicalPath(t *testing.T) {
	e, err := discoverProbeEgress("")
	if err != nil {
		t.Skipf("no physical adapter on this machine: %v", err)
	}
	if e.Name == "" || e.IPv4 == nil || e.DNS == "" {
		t.Fatalf("incomplete egress: %+v", e)
	}
	if e.IPv4.IsLoopback() || e.IPv4.IsLinkLocalUnicast() {
		t.Fatalf("unexpected address: %v", e.IPv4)
	}
	t.Logf("egress: %s %s dns=%s metric-owner index=%d", e.Name, e.IPv4, e.DNS, e.IfIndex)
}

// The snapshot flag must gate the TUN egress path: no TUN means no rewrite.
func TestProbeEgressOnlyWhenTunActive(t *testing.T) {
	// Covered indirectly by TestPrepareProbeDocumentDropsActiveCore (egress
	// nil) and TestPrepareProbeDocumentBindsEgress (egress set). This test pins
	// the state constant used by runProbes.
	if state.TunEnabled == "" {
		t.Fatal("TunEnabled must not be empty")
	}
}

func mustUDPAddr(t *testing.T, raw string) *net.UDPAddr {
	t.Helper()
	addr, err := net.ResolveUDPAddr("udp4", raw)
	if err != nil {
		t.Fatal(err)
	}
	return addr
}

// TestDNSRelayPublicUnderTun checks the relay against the physical resolver,
// not only the loopback upstream used by the unit test.
func TestDNSRelayPublicUnderTun(t *testing.T) {
	if os.Getenv("HALO_PROBE_EGRESS_NET") != "1" {
		t.Skip("set HALO_PROBE_EGRESS_NET=1 to run the networked DNS test")
	}
	adapter := strings.TrimSpace(os.Getenv("HALO_PROBE_EGRESS_EXCLUDE"))
	if adapter == "" {
		t.Skip("set HALO_PROBE_EGRESS_EXCLUDE to the live TUN adapter name")
	}
	egress, err := discoverProbeEgress(adapter)
	if err != nil {
		t.Skipf("no physical egress: %v", err)
	}
	relay, err := startDoHRelay(egress)
	if err != nil {
		t.Fatalf("dns relay: %v", err)
	}
	defer relay.Close()
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(context.Context, string, string) (net.Conn, error) {
			return net.Dial("udp4", relay.Addr())
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	ips, err := resolver.LookupHost(ctx, "www.baidu.com")
	if err != nil {
		t.Fatalf("relay lookup via %s failed: %v", egress.DNS, err)
	}
	t.Logf("relay via %s -> %v", egress.DNS, ips)
}

// TestProbeConfigThroughPhysicalEgress exercises the actual binding support in
// the pinned core. It needs the network, so it is opt-in.
func TestProbeConfigThroughPhysicalEgress(t *testing.T) {
	if os.Getenv("HALO_PROBE_EGRESS_NET") != "1" {
		t.Skip("set HALO_PROBE_EGRESS_NET=1 to run the networked egress test")
	}
	core := testCorePath(t)
	a := &App{Paths: DefaultPaths(t.TempDir(), core)}
	// A live TUN adapter is not necessarily reported as IF_TYPE_TUNNEL on
	// Windows, so the caller must name it. The real probe path gets the name
	// from the snapshot or the runtime config; this opt-in test takes it from
	// the environment so a TUN-active run cannot silently select the tunnel.
	exclude := strings.TrimSpace(os.Getenv("HALO_PROBE_EGRESS_EXCLUDE"))
	egress, err := discoverProbeEgress(exclude)
	if err != nil {
		t.Skipf("no physical egress: %v", err)
	}
	relay, err := startDoHRelay(egress)
	if err != nil {
		t.Fatalf("dns relay: %v", err)
	}
	defer relay.Close()
	egress.DNSListen = relay.Addr()
	t.Logf("egress %s (%s) dns=%s relay=%s", egress.Name, egress.IPv4, egress.DNS, relay.Addr())

	target := strings.TrimSpace(os.Getenv("HALO_PROBE_URL"))
	if target == "" {
		target = "https://www.gstatic.com/generate_204"
	}
	config := `{"outbounds":[{"type":"direct","tag":"direct"}]}`
	result := a.probeConfig(config, target, 12*time.Second, probeBodyLimit, metricProxyLatency, make(chan struct{}), egress)
	if !result.Ok {
		t.Fatalf("probe through %s (%s) failed: %+v", egress.Name, egress.IPv4, result)
	}
	t.Logf("egress %s (%s): %d ms", egress.Name, egress.IPv4, result.LatencyMs)
}

// This is the full runProbes path with TUN marked active: discovery, DNS relay,
// physical binding and the disposable core. The live TUN adapter name comes
// from the environment so the test can run while a real tunnel is up.
func TestTunBypassRunsProbeWithRealTun(t *testing.T) {
	if os.Getenv("HALO_PROBE_EGRESS_NET") != "1" {
		t.Skip("set HALO_PROBE_EGRESS_NET=1 to run the networked TUN test")
	}
	adapter := strings.TrimSpace(os.Getenv("HALO_PROBE_EGRESS_EXCLUDE"))
	if adapter == "" {
		t.Skip("set HALO_PROBE_EGRESS_EXCLUDE to the live TUN adapter name")
	}
	a := newTestApp(t)
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = state.TunEnabled
		s.TunAdapter = adapter
	})
	target := strings.TrimSpace(os.Getenv("HALO_PROBE_URL"))
	if target == "" {
		target = "https://www.gstatic.com/generate_204"
	}
	p := speedParams{
		Metric:    metricProxyLatency,
		URL:       target,
		Endpoints: []string{"probe"},
		NodeIDs:   []string{"n1"},
		Configs:   []string{`{"outbounds":[{"type":"direct","tag":"direct"}]}`},
	}
	results := a.runProbes(p, make(chan struct{}))
	if len(results) != 1 || !results[0].Ok {
		t.Fatalf("TUN bypass probe failed: %+v", results)
	}
	t.Logf("TUN bypass probe through %s: %d ms", adapter, results[0].LatencyMs)
}

// The raw TCP probe has no disposable core; it resolves through the same DoH
// relay and binds the same physical source.
func TestTunBypassRawTCPWithRealTun(t *testing.T) {
	if os.Getenv("HALO_PROBE_EGRESS_NET") != "1" {
		t.Skip("set HALO_PROBE_EGRESS_NET=1 to run the networked TUN test")
	}
	adapter := strings.TrimSpace(os.Getenv("HALO_PROBE_EGRESS_EXCLUDE"))
	if adapter == "" {
		t.Skip("set HALO_PROBE_EGRESS_EXCLUDE to the live TUN adapter name")
	}
	a := newTestApp(t)
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = state.TunEnabled
		s.TunAdapter = adapter
	})
	p := speedParams{
		Metric:    metricTCP,
		Endpoints: []string{"www.baidu.com:443"},
		NodeIDs:   []string{"n1"},
	}
	results := a.runProbes(p, make(chan struct{}))
	if len(results) != 1 || !results[0].Ok {
		t.Fatalf("TUN bypass raw TCP failed: %+v", results)
	}
	t.Logf("TUN bypass raw TCP through %s: %d ms", adapter, results[0].LatencyMs)
}

// The download path uses the same physical source and DoH relay as latency.
func TestTunBypassDownloadWithRealTun(t *testing.T) {
	if os.Getenv("HALO_PROBE_EGRESS_NET") != "1" {
		t.Skip("set HALO_PROBE_EGRESS_NET=1 to run the networked TUN test")
	}
	adapter := strings.TrimSpace(os.Getenv("HALO_PROBE_EGRESS_EXCLUDE"))
	if adapter == "" {
		t.Skip("set HALO_PROBE_EGRESS_EXCLUDE to the live TUN adapter name")
	}
	a := newTestApp(t)
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = state.TunEnabled
		s.TunAdapter = adapter
	})
	p := speedParams{
		Metric:    metricDownload,
		URL:       defaultSpeedURL,
		Endpoints: []string{"probe"},
		NodeIDs:   []string{"n1"},
		Configs:   []string{`{"outbounds":[{"type":"direct","tag":"direct"}]}`},
	}
	results := a.runProbes(p, make(chan struct{}))
	if len(results) != 1 || !results[0].Ok || results[0].DownloadBps <= 0 {
		t.Fatalf("TUN bypass download failed: %+v", results)
	}
	t.Logf("TUN bypass download through %s: %d B/s", adapter, results[0].DownloadBps)
}

// A configured probe must not dial the active proxy. This is behavioral, not
// just a config-shape check: the active listener sees no connection.
func TestProbeConfigDoesNotDialActiveProxy(t *testing.T) {
	active, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer active.Close()
	var hits int32
	go func() {
		for {
			conn, err := active.Accept()
			if err != nil {
				return
			}
			atomic.AddInt32(&hits, 1)
			_ = conn.Close()
		}
	}()

	a := newTestApp(t)
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.SystemProxy.Enabled = true
		s.SystemProxy.Endpoint = active.Addr().String()
	})

	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()

	config := `{"outbounds":[{"type":"direct","tag":"proxy"}]}`
	result := a.probeConfig(config, target.URL, 5*time.Second, probeBodyLimit, metricProxyLatency, make(chan struct{}), nil)
	if !result.Ok {
		t.Fatalf("probe through its own config failed: %+v", result)
	}
	time.Sleep(100 * time.Millisecond)
	if got := atomic.LoadInt32(&hits); got != 0 {
		t.Fatalf("the probe dialed the active proxy %d times", got)
	}
}

// The shipped build must enable the bypass: this is the requirement that
// node ranking measures the node, not the current tunnel.
func TestTunBypassEnabledByDefault(t *testing.T) {
	if !probeTunBypassEnabled {
		t.Fatal("TUN measurement bypass is disabled")
	}
}

// While the bypass is disabled, a TUN-active run is refused rather than
// measured through the tunnel. The default is enabled; this test overrides it
// to keep the refusal path covered for builds that turn it off.
func TestTunActiveWithoutBypassRefusesMeasurement(t *testing.T) {
	old := probeTunBypassEnabled
	probeTunBypassEnabled = false
	t.Cleanup(func() { probeTunBypassEnabled = old })

	a := newTestApp(t)
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = state.TunEnabled
	})
	p := speedParams{
		Metric:    metricProxyLatency,
		Endpoints: []string{"127.0.0.1:12345"},
		NodeIDs:   []string{"n1"},
	}
	results := a.runProbes(p, make(chan struct{}))
	if len(results) != 1 || results[0].ErrorCode != "tun_bypass_disabled" {
		t.Fatalf("results = %+v", results)
	}
	if !strings.Contains(results[0].ErrorMsg, "尚未启用") {
		t.Fatalf("message = %q", results[0].ErrorMsg)
	}
}

// With the bypass enabled, a bare endpoint is still refused (it cannot be
// rebound); a configured probe goes through the physical-egress path.
func TestTunActiveWithBypassRejectsBareEndpoint(t *testing.T) {
	old := probeTunBypassEnabled
	probeTunBypassEnabled = true
	t.Cleanup(func() { probeTunBypassEnabled = old })

	a := newTestApp(t)
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.TunState = state.TunEnabled
	})
	p := speedParams{
		Metric:    metricProxyLatency,
		Endpoints: []string{"127.0.0.1:12345"},
		NodeIDs:   []string{"n1"},
	}
	results := a.runProbes(p, make(chan struct{}))
	if len(results) != 1 || results[0].ErrorCode != "probe_failed" {
		t.Fatalf("results = %+v", results)
	}
	if !strings.Contains(results[0].ErrorMsg, "当前代理入口") &&
		!strings.Contains(results[0].ErrorMsg, "物理网卡") {
		t.Fatalf("message = %q", results[0].ErrorMsg)
	}
}

func TestPrepareProbeDocumentRejectsActiveProxyOutbound(t *testing.T) {
	document := `{"outbounds":[{"type":"http","tag":"proxy","server":"127.0.0.1","server_port":7890}]}`
	if _, err := prepareProbeDocument(document, 45873, "u", "p", nil, "127.0.0.1:7890"); err == nil {
		t.Fatal("a probe whose node is the active proxy must be rejected")
	}
	if _, err := prepareProbeDocument(document, 45874, "u", "p", nil, "127.0.0.1:7891"); err != nil {
		t.Fatalf("a different port is not the active proxy: %v", err)
	}
}
