package app

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"clash-halo/native/windows/internal/state"
	"clash-halo/native/windows/internal/tunconfig"
)

func marshalJSON(v any) ([]byte, error) { return json.Marshal(v) }

// ProbeResult is one endpoint's measurement. The UI needs the raw numbers and
// the failure reason; it does the ranking so the host stays free of display
// policy.
type ProbeResult struct {
	NodeID   string `json:"nodeId"`
	Endpoint string `json:"endpoint"`
	// Metric says which quantity LatencyMs/DownloadBps describe. Without it the
	// client had to guess, and it guessed "proxy latency" for a download
	// throughput probe as well — the two numbers were then compared and ranked
	// as if they were the same thing.
	Metric      string `json:"metric"`
	Ok          bool   `json:"ok"`
	LatencyMs   int64  `json:"latencyMs"`
	DownloadBps int64  `json:"downloadBps"`
	StatusCode  int    `json:"statusCode"`
	ErrorCode   string `json:"errorCode,omitempty"`
	ErrorMsg    string `json:"errorMsg,omitempty"`
}

const (
	// A 204 endpoint measures the round trip only: no body, nothing to read,
	// so the number is pure latency through the node.
	defaultProbeURL     = "https://www.gstatic.com/generate_204"
	defaultProbeTimeout = 8 * time.Second
	defaultConcurrency  = 8
	// maxConcurrency bounds what the UI may ask for: each worker holds a socket
	// and a TLS handshake, so an unbounded value from a settings file would
	// turn a latency batch into a local port-exhaustion test.
	maxConcurrency     = 32
	probeBodyLimit     = 64 << 10
	probeReadyInterval = 50 * time.Millisecond

	// Throughput needs real bytes. A 204 response has none, so the previous
	// implementation computed DownloadBps from an empty body and reported
	// nonsense (or nothing) while presenting it as a speed measurement.
	//
	// 5 MB rather than 10: measured on this machine's own line (≈0.24 MiB/s),
	// 10 MB needs over 40 s and would always hit the ceiling, turning every slow
	// node into a failure. 5 MB finishes in ~21 s here and still gives a
	// stable rate.
	defaultSpeedURL = "https://speed.cloudflare.com/__down?bytes=5000000"
	// The cap stays as a guard against a metered connection, not as the sample
	// size: whatever arrives within the time budget is what gets measured.
	speedBodyLimit = 10 << 20
	// Download timing gets its own, longer budget than a round trip. It is a
	// *time* budget, not a size budget — see the read loop in probeOne, which
	// keeps partial data instead of failing when the clock runs out.
	speedTimeout = 25 * time.Second
)

// probeTunBypassEnabled gates binding measurement traffic to the physical
// adapter while TUN owns the default route.
//
// The implementation and its tests exist; it stays off until the cost/benefit
// review accepts it and the real-TUN verification is done. See
// docs/tun-measurement-bypass.md.
var probeTunBypassEnabled = false

// SpeedMetric names, mirroring the client's SpeedMetric wire values.
const (
	// metricTCP is reachability of the node's own port: a bare handshake to
	// server:port. It runs before and independently of anything that needs a
	// core, which is what makes it the fast pre-check.
	metricTCP          = "tcp"
	metricProxyLatency = "proxy_latency"
	metricDownload     = "download"
	// metricUDP is end-to-end datagram reachability through the node. It is a
	// different question from metricTCP and a node can pass one and fail the
	// other, so the two are reported separately rather than averaged.
	metricUDP = "udp"
)

// udpProbeTarget is a datagram service that answers a tiny fixed query. Plain
// DNS over UDP: one query, one reply, no TLS, so the round trip measures the
// path and not a handshake.
const (
	udpProbeTarget  = "1.1.1.1:53"
	udpProbeQueryID = 0x4841 // 'HA'
)

// notApplicable is not a failure: a UDP-only node (Hysteria2, TUIC,
// WireGuard) has no TCP listener to connect to, so reporting "unreachable"
// for its TCP probe would slander a node that is working perfectly.
const codeNotApplicable = "not_applicable"

// codeUDPUnconfirmed is UDP's equivalent of "I could not tell".
//
// A datagram port that stays silent is not evidence of a fault: an open port
// running a non-QUIC service, a port behind a firewall that drops rather than
// rejects, and a genuinely closed port all look identical from here. Painting
// that red would put a confident 「不通」 on a node nobody managed to test.
const codeUDPUnconfirmed = "udp_unconfirmed"

// probeWorkers decides how many probes may run at once.
//
// The default and the ceiling live here, not only in the UI: the host also
// accepts a request that omits concurrency, and a hand-edited settings file or
// an older client can ask for a number the pool should not honour.
func probeWorkers(metric string, requested int) int {
	if requested <= 0 {
		if metric == metricDownload {
			return 1
		}
		return defaultConcurrency
	}
	if requested > maxConcurrency {
		return maxConcurrency
	}
	return requested
}

// runProbes measures each endpoint concurrently with a bounded worker pool.
//
// Isolation guarantee: probes use a dedicated http.Client that ignores
// environment proxies and never touches the running core's sockets, so a
// speed test can never disturb (or be disturbed by) real traffic. Each probe
// has its own timeout and its own transport, and is cancelled by the task's
// cancel channel.
func (a *App) runProbes(p speedParams, cancel chan struct{}) []ProbeResult {
	// The metric decides the target, the timeout and which numbers are
	// meaningful. Latency through the node and download throughput are
	// different measurements with different costs; treating them as one probe
	// is what produced a single ambiguous number in the list.
	metric := p.Metric
	if metric == "" {
		if len(p.Configs) > 0 {
			metric = metricProxyLatency
		} else {
			metric = metricTCP
		}
	}
	url_ := p.URL
	if url_ == "" {
		if metric == metricDownload {
			url_ = defaultSpeedURL
		} else {
			url_ = defaultProbeURL
		}
	}
	timeout := defaultProbeTimeout
	if metric == metricDownload {
		timeout = speedTimeout
	}
	if p.TimeoutMs > 0 && p.TimeoutMs < 60000 {
		timeout = time.Duration(p.TimeoutMs) * time.Millisecond
	}
	bodyLimit := int64(probeBodyLimit)
	if metric == metricDownload {
		bodyLimit = speedBodyLimit
	}
	workers := probeWorkers(metric, p.Concurrency)
	// When TUN owns the default route, every unbound socket would be captured
	// by it. Measurements must test the node, not the tunnel: discover the
	// physical adapter and bind the raw probes and every probe-core outbound to
	// it. In system-proxy mode no binding is needed (the system proxy does not
	// intercept sockets), but the probe core still gets its own config.
	var egress *probeEgress
	if a.Store != nil && a.Store.Snapshot().TunState == state.TunEnabled {
		if !probeTunBypassEnabled {
			// Measuring through the tunnel would report the active node as if
			// it were the node under test. Refuse until the bypass is enabled.
			return fillProbeFailure(p, metric, "tun_bypass_disabled",
				"TUN 已开启；测速绕过 TUN 的功能尚未启用，本次未测量")
		}
		exclude := a.Store.Snapshot().TunAdapter
		if exclude == "" {
			// The snapshot can lag the actual adapter name while the tunnel
			// is starting; the runtime config always names it.
			if raw, err := os.ReadFile(a.tunRuntimeConfigPath()); err == nil {
				if name, err := tunconfig.AdapterName(raw); err == nil {
					exclude = name
				}
			}
		}
		e, err := discoverProbeEgress(exclude)
		if err != nil {
			return fillProbeFailure(p, metric, "probe_isolation",
				"TUN 已启用，但无法确定物理网卡，测试未执行："+err.Error())
		}
		relay, err := startDNSRelay(e)
		if err != nil {
			return fillProbeFailure(p, metric, "probe_isolation",
				"TUN 已启用，但无法建立直连 DNS，测试未执行："+err.Error())
		}
		defer relay.Close()
		e.DNSListen = relay.Addr()
		egress = e
	}

	type job struct {
		index    int
		endpoint string
		nodeID   string
	}
	jobs := make(chan job)
	results := make([]ProbeResult, len(p.Endpoints))
	var wg sync.WaitGroup
	var progressMu sync.Mutex
	completed := 0

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				nodeID := ""
				if j.index < len(p.NodeIDs) {
					nodeID = p.NodeIDs[j.index]
				}
				var r ProbeResult
				switch {
				case metric == metricUDP && len(p.Configs) > j.index:
					// The real thing: run the node's own core and fetch a 204
					// through it. For an HTTP/3 Naive or a Hysteria2 node that
					// core speaks QUIC, so this round trip *is* the UDP test,
					// end to end over the transport the node actually uses.
					//
					// A bare datagram probe was tried first and abandoned: on a
					// network that drops UDP/443 it answers only "unconfirmed",
					// because a filtered port and a dead node are
					// indistinguishable from outside. A reply that comes back
					// proves the datagram path works, which is the question
					// worth asking.
					r = a.probeConfig(p.Configs[j.index], url_, timeout, bodyLimit, metricUDP, cancel, egress)
				case metric == metricUDP:
					// No config to run, so only the bare port check is left; on
					// its own it reports that silence proves nothing rather
					// than inventing a verdict.
					r = probeUDP(j.endpoint, timeout, cancel, egress)
				case len(p.Configs) > j.index:
					r = a.probeConfig(p.Configs[j.index], url_, timeout, bodyLimit, metric, cancel, egress)
				case metric == metricTCP:
					// A bare handshake to the node's own port. Everything else
					// here treats the endpoint as an HTTP proxy, which a raw
					// node address is not: the old code sent an HTTP request at
					// server:443 and reported the resulting nonsense as
					// reachability.
					r = probeTCP(j.endpoint, timeout, cancel, egress)
				default:
					// A bare endpoint is treated as an HTTP proxy by this
					// branch. It must never be the app's own entry point: that
					// is how a measurement would silently run through the
					// active proxy (or the TUN) instead of the node.
					if a.isActiveProxyEndpoint(j.endpoint) {
						r = ProbeResult{
							ErrorCode: "probe_failed",
							ErrorMsg:  "该地址是当前代理入口；测速流量不能经过正在使用的代理",
						}
					} else {
						r = probeOne(j.endpoint, url_, timeout, bodyLimit, metric, cancel)
					}
				}
				r.NodeID = nodeID
				r.Endpoint = j.endpoint
				r.Metric = metric
				results[j.index] = r
				progressMu.Lock()
				completed++
				a.emit("task.progress", map[string]any{
					"taskId": p.TaskID,
					"done":   completed,
					"total":  len(p.Endpoints),
					"result": r,
				})
				progressMu.Unlock()
			}
		}()
	}

	for i, ep := range p.Endpoints {
		select {
		case <-cancel:
			close(jobs)
			wg.Wait()
			// Fill the untouched tail with a cancellation marker so the UI
			// never sees a half-populated list presented as complete.
			for k := i; k < len(results); k++ {
				if results[k].Endpoint == "" {
					results[k] = ProbeResult{
						Endpoint:  p.Endpoints[k],
						Metric:    metric,
						ErrorCode: "canceled",
						ErrorMsg:  "任务已取消",
					}
					if k < len(p.NodeIDs) {
						results[k].NodeID = p.NodeIDs[k]
					}
				}
			}
			return results
		case jobs <- job{index: i, endpoint: ep}:
		}
	}
	close(jobs)
	wg.Wait()
	return results
}

// isActiveProxyEndpoint reports whether a bare endpoint is the app's own
// proxy entry (the TUN or the mixed inbound the system proxy points at).
//
// A node's own address never matches this: it is the server:port of the node,
// not the local listener this app exposes.
func (a *App) isActiveProxyEndpoint(endpoint string) bool {
	if a.Store == nil {
		return false
	}
	snap := a.Store.Snapshot()
	if snap.TunState == state.TunEnabled {
		// With TUN active even a raw directed probe would be captured; a bare
		// endpoint has no node config to rebind, so it cannot be isolated.
		return true
	}
	active := strings.TrimSpace(snap.SystemProxy.Endpoint)
	return active != "" && strings.EqualFold(strings.TrimSpace(endpoint), active)
}

// fillProbeFailure marks every endpoint with one setup failure, so the UI shows
// "not run" and its reason instead of a half-populated result list.
func fillProbeFailure(p speedParams, metric, code, message string) []ProbeResult {
	results := make([]ProbeResult, len(p.Endpoints))
	for i := range results {
		results[i] = ProbeResult{
			Endpoint:  p.Endpoints[i],
			Metric:    metric,
			ErrorCode: code,
			ErrorMsg:  message,
		}
		if i < len(p.NodeIDs) {
			results[i].NodeID = p.NodeIDs[i]
		}
	}
	return results
}

// Each node receives its own disposable core; active runtime configuration is untouched.
// Keep a logical reservation after closing the listener for the child to bind.
var probePorts sync.Map

func reserveProbePort() (*net.TCPAddr, error) {
	for {
		listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			return nil, err
		}
		addr := listener.Addr().(*net.TCPAddr)
		_, used := probePorts.LoadOrStore(addr.Port, struct{}{})
		_ = listener.Close()
		if !used {
			return addr, nil
		}
	}
}

// A TCP handshake alone cannot identify the child. Authenticate against the
// mixed listener before sending the real request through the port.
func probeListenerReady(ctx context.Context, endpoint, user, password string) bool {
	conn, err := (&net.Dialer{Timeout: 100 * time.Millisecond}).DialContext(ctx, "tcp", endpoint)
	if err != nil {
		return false
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	_ = conn.SetDeadline(time.Now().Add(100 * time.Millisecond))
	var reply [2]byte
	if _, err := conn.Write([]byte{5, 1, 2}); err != nil {
		return false
	}
	if _, err := io.ReadFull(conn, reply[:]); err != nil || reply != [2]byte{5, 2} {
		return false
	}
	auth := append([]byte{1, byte(len(user))}, user...)
	auth = append(append(auth, byte(len(password))), password...)
	if _, err := conn.Write(auth); err != nil {
		return false
	}
	_, err = io.ReadFull(conn, reply[:])
	return err == nil && reply == [2]byte{1, 0}
}

func (a *App) probeConfig(document, target string, timeout time.Duration, bodyLimit int64, metric string, cancel chan struct{}, egress *probeEgress) ProbeResult {
	fail := func(err error) ProbeResult { return ProbeResult{ErrorCode: "probe_failed", ErrorMsg: err.Error()} }
	addr, err := reserveProbePort()
	if err != nil {
		return fail(err)
	}
	defer probePorts.Delete(addr.Port)
	endpoint := addr.String()
	const user = "halo-probe"
	password := rand.Text()
	prepared, err := prepareProbeDocument(document, addr.Port, user, password, egress, a.activeProxyEndpoint())
	if err != nil {
		return fail(err)
	}
	dir, err := os.MkdirTemp(a.Paths.Root, "probe-")
	if err != nil {
		return fail(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "config.json")
	if err = os.WriteFile(path, prepared, 0600); err != nil {
		return fail(err)
	}
	ctx, stop := probeContext(timeout+5*time.Second, cancel)
	defer stop()
	// The disposable core validates its config when it starts.
	cmd := exec.CommandContext(ctx, a.Paths.Core, "run", "-c", path)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err = cmd.Start(); err != nil {
		return fail(err)
	}
	exited := make(chan struct{})
	var exitErr error
	go func() {
		exitErr = cmd.Wait()
		close(exited)
	}()
	defer func() {
		_ = cmd.Process.Kill()
		<-exited
	}()
	readiness := time.NewTicker(probeReadyInterval)
	defer readiness.Stop()
	for {
		if probeListenerReady(ctx, endpoint, user, password) {
			break
		}
		select {
		case <-exited:
			if ctx.Err() == context.Canceled {
				return ProbeResult{ErrorCode: "canceled", ErrorMsg: "任务已取消"}
			}
			if exitErr == nil {
				return fail(errors.New("测试内核在端口就绪前退出"))
			}
			return fail(fmt.Errorf("测试内核在端口就绪前退出: %w", exitErr))
		case <-ctx.Done():
			if ctx.Err() == context.Canceled {
				return ProbeResult{ErrorCode: "canceled", ErrorMsg: "任务已取消"}
			}
			return fail(ctx.Err())
		case <-readiness.C:
		}
	}
	return probeOne(url.UserPassword(user, password).String()+"@"+endpoint, target, timeout, bodyLimit, metric, cancel)
}

// prepareProbeDocument builds the disposable core's config.
//
// The running app's inbounds, controller and any other extension are removed
// before the probe's own inbound is installed. A measurement must never borrow
// the active core: in system-proxy mode that would route the test through the
// proxy, and in TUN mode the physical-egress rewrite below is what keeps the
// probe out of the tunnel.
func prepareProbeDocument(document string, port int, user, password string, egress *probeEgress, activeProxy string) ([]byte, error) {
	var config map[string]any
	if err := json.Unmarshal([]byte(document), &config); err != nil {
		return nil, err
	}
	if config == nil {
		return nil, errors.New("测试配置必须是 JSON 对象")
	}
	config["inbounds"] = []any{map[string]any{
		"type": "mixed", "listen": "127.0.0.1", "listen_port": port,
		"users": []map[string]string{{"username": user, "password": password}},
	}}
	// experimental carries the active core's Clash API and cache paths;
	// services are active-core state. Neither belongs to a measurement.
	delete(config, "experimental")
	delete(config, "services")
	if err := rejectActiveProxyOutbound(config, activeProxy); err != nil {
		return nil, err
	}
	if egress != nil {
		if err := applyProbeEgress(config, egress, egress.DNSListen); err != nil {
			return nil, err
		}
	}
	return json.Marshal(config)
}

// activeProxyEndpoint is the mixed inbound the system proxy points at. It is
// compared against bare endpoints and probe outbounds so a measurement can
// never be routed back into the app's own proxy.
func (a *App) activeProxyEndpoint() string {
	if a.Store == nil {
		return ""
	}
	return strings.TrimSpace(a.Store.Snapshot().SystemProxy.Endpoint)
}

// rejectActiveProxyOutbound refuses a probe config whose node is the app's own
// listener. A real node never lives at the local proxy endpoint.
func rejectActiveProxyOutbound(config map[string]any, active string) error {
	if active == "" {
		return nil
	}
	host, portText, err := net.SplitHostPort(active)
	if err != nil {
		return nil
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return nil
	}
	outbounds, _ := config["outbounds"].([]any)
	for _, raw := range outbounds {
		outbound, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		server, _ := outbound["server"].(string)
		if server == "" || !strings.EqualFold(strings.TrimSpace(server), host) {
			continue
		}
		serverPort, _ := outbound["server_port"].(float64)
		if int(serverPort) == port {
			return fmt.Errorf("测试配置的出站指向当前代理入口 %s，测速流量不能经过正在使用的代理", active)
		}
	}
	return nil
}

// probeOne measures latency and a small download through a specific proxy
// endpoint.
func probeOne(endpoint, target string, timeout time.Duration, bodyLimit int64, metric string, cancel chan struct{}) ProbeResult {
	res := ProbeResult{Endpoint: endpoint, Metric: metric}
	u, err := url.Parse("http://" + endpoint)
	if err != nil || u.Host == "" {
		res.ErrorCode = "bad_endpoint"
		res.ErrorMsg = "代理地址格式不正确"
		return res
	}
	res.Endpoint = u.Host
	select {
	case <-cancel:
		res.ErrorCode = "canceled"
		res.ErrorMsg = "任务已取消"
		return res
	default:
	}

	ctx, cancelFn := probeContext(timeout, cancel)
	defer cancelFn()

	transport := &http.Transport{
		Proxy:               http.ProxyURL(u),
		DisableKeepAlives:   false,
		MaxIdleConns:        1,
		IdleConnTimeout:     timeout,
		TLSHandshakeTimeout: timeout,
		DialContext: (&net.Dialer{
			Timeout:   timeout,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		// No environment proxy: the measurement must go through the node
		// under test or not go at all.
		ProxyConnectHeader: http.Header{},
		ForceAttemptHTTP2:  true,
	}
	client := &http.Client{Transport: transport, Timeout: timeout}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		res.ErrorCode = "bad_request"
		res.ErrorMsg = err.Error()
		return res
	}
	req.Header.Set("User-Agent", "clash-halo-speedtest/1")

	started := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		res.ErrorCode = classifyProbeError(err)
		res.ErrorMsg = err.Error()
		res.LatencyMs = time.Since(started).Milliseconds()
		return res
	}
	defer func() { _ = resp.Body.Close() }()
	res.StatusCode = resp.StatusCode
	res.LatencyMs = time.Since(started).Milliseconds()
	if resp.StatusCode >= 400 {
		res.ErrorCode = "http_status"
		res.ErrorMsg = fmt.Sprintf("HTTP %d", resp.StatusCode)
		return res
	}
	// Read for as long as the budget allows, then compute the rate from what
	// actually arrived.
	//
	// Sizing this by bytes alone is wrong on a slow line: a 10 MB sample needs
	// ~40 s at 0.25 MiB/s, so a fixed 20 s timeout turned a working node into a
	// failure. Measuring over a fixed *time* window instead gives every node
	// the same fair chance and still yields a rate, because a rate is bytes
	// over time and does not care whether the body finished.
	readStart := time.Now()
	n, err := io.Copy(io.Discard, io.LimitReader(resp.Body, bodyLimit))
	elapsed := time.Since(readStart)
	if err != nil && !errors.Is(err, io.EOF) {
		// A timeout during the read is not a failure when bytes did arrive: the
		// sample is simply the part we managed to fetch, which is still a valid
		// measurement and is exactly what a slow node should report.
		var netErr net.Error
		timedOut := errors.As(err, &netErr) && netErr.Timeout()
		if !timedOut || n == 0 {
			res.ErrorCode = classifyProbeError(err)
			res.ErrorMsg = err.Error()
			return res
		}
	}
	if elapsed > 0 {
		res.DownloadBps = int64(float64(n) / elapsed.Seconds())
	}
	// A latency probe reports the round trip and no throughput (the 204 body is
	// empty, so a rate would divide by nothing useful). A download probe reports
	// throughput and keeps the connect time it also measured, because a node
	// that is fast to connect but slow to transfer is a different problem from
	// one that is slow to answer at all.
	if metric == metricDownload && n == 0 {
		res.ErrorCode = "empty_body"
		res.ErrorMsg = "测速地址没有返回数据"
		return res
	}
	res.Ok = true
	return res
}

// probeTCP measures whether the node's own port accepts a TCP connection.
//
// This is deliberately the cheapest probe in the app: no core is started, no
// configuration is parsed and no traffic crosses the proxy. It answers "is
// anything listening at server:port", which is the question worth asking
// before spending seconds on a login attempt.
func probeTCP(endpoint string, timeout time.Duration, cancel chan struct{}, egress *probeEgress) ProbeResult {
	res := ProbeResult{Endpoint: endpoint, Metric: metricTCP}
	select {
	case <-cancel:
		res.ErrorCode = "canceled"
		res.ErrorMsg = "任务已取消"
		return res
	default:
	}
	if timeout > defaultProbeTimeout {
		timeout = defaultProbeTimeout
	}
	ctx, stop := probeContext(timeout, cancel)
	defer stop()
	dialEndpoint := endpoint
	if egress != nil {
		host, port, err := net.SplitHostPort(endpoint)
		if err != nil {
			res.ErrorCode = "bad_endpoint"
			res.ErrorMsg = err.Error()
			return res
		}
		ip, err := egress.resolve(ctx, host)
		if err != nil {
			res.ErrorCode = "dns"
			res.ErrorMsg = "解析节点地址失败：" + err.Error()
			return res
		}
		dialEndpoint = net.JoinHostPort(ip.String(), port)
	}
	started := time.Now()
	dialer := &net.Dialer{}
	if egress != nil {
		dialer = egress.tcpDialer(timeout)
	}
	conn, err := dialer.DialContext(ctx, "tcp", dialEndpoint)
	res.LatencyMs = time.Since(started).Milliseconds()
	if err != nil {
		res.ErrorCode = classifyProbeError(err)
		res.ErrorMsg = err.Error()
		return res
	}
	_ = conn.Close()
	res.Ok = true
	return res
}

// probeUDP asks whether the node's own UDP port answers.
//
// This is a port check, not a tunnel test. The distinction matters: an earlier
// version ran the node's core, opened a SOCKS5 UDP association and sent a DNS
// query through it, which conflated two unrelated questions and answered
// neither. Naive, for one, only forwards TCP CONNECT, so that test failed
// against nodes that work perfectly — and it cost a core launch per node,
// which is the opposite of a quick reachability pre-check.
//
// What is measured here is the same thing the TCP probe measures, on the other
// transport: is the address:port this node listens on answering datagrams?
// That is what decides whether an HTTP/3 or Hysteria2 node is reachable at
// all, and it needs no configuration and no core.
func probeUDP(endpoint string, timeout time.Duration, cancel chan struct{}, egress *probeEgress) ProbeResult {
	res := ProbeResult{Endpoint: endpoint, Metric: metricUDP}
	select {
	case <-cancel:
		res.ErrorCode = "canceled"
		res.ErrorMsg = "任务已取消"
		return res
	default:
	}
	if timeout > defaultProbeTimeout {
		timeout = defaultProbeTimeout
	}
	ctx, stop := probeContext(timeout, cancel)
	defer stop()

	var addr *net.UDPAddr
	if egress != nil {
		host, portText, err := net.SplitHostPort(endpoint)
		if err != nil {
			res.ErrorCode = "bad_endpoint"
			res.ErrorMsg = err.Error()
			return res
		}
		ip, err := egress.resolve(ctx, host)
		if err != nil {
			res.ErrorCode = "dns"
			res.ErrorMsg = "解析节点地址失败：" + err.Error()
			return res
		}
		port, err := strconv.Atoi(portText)
		if err != nil {
			res.ErrorCode = "bad_endpoint"
			res.ErrorMsg = err.Error()
			return res
		}
		addr = &net.UDPAddr{IP: ip, Port: port}
	} else {
		var err error
		addr, err = net.ResolveUDPAddr("udp", endpoint)
		if err != nil {
			res.ErrorCode = "bad_endpoint"
			res.ErrorMsg = err.Error()
			return res
		}
	}

	var conn *net.UDPConn
	var err error
	if egress != nil {
		conn, err = egress.udpListen()
	} else {
		conn, err = net.ListenUDP("udp", nil)
	}
	if err != nil {
		res.ErrorCode = classifyProbeError(err)
		res.ErrorMsg = err.Error()
		return res
	}
	defer conn.Close()
	stopClosing := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stopClosing()

	// A QUIC version-negotiation probe: a long-header packet carrying an
	// unsupported version number. RFC 9000 says a QUIC server answers such a
	// packet with a Version Negotiation, so a reply proves both that the port
	// is open and that something speaking QUIC is behind it.
	probe := []byte{
		0xc0,                   // long header, fixed bit
		0x00, 0x00, 0x00, 0x01, // version 1
		0x08, 1, 2, 3, 4, 5, 6, 7, 8, // destination connection id
		0x08, 9, 10, 11, 12, 13, 14, 15, 16, // source connection id
		0x00, 0x3f, 0xa5, // a version we know it does not support
	}
	deadline := time.Now().Add(timeout)
	_ = conn.SetDeadline(deadline)
	started := time.Now()
	if _, err = conn.WriteToUDP(probe, addr); err != nil {
		res.ErrorCode = classifyProbeError(err)
		res.ErrorMsg = err.Error()
		return res
	}
	buf := make([]byte, 1500)
	for {
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() == context.Canceled {
				res.ErrorCode = "canceled"
				res.ErrorMsg = "任务已取消"
				return res
			}
			var netErr net.Error
			if ctx.Err() == context.DeadlineExceeded || (errors.As(err, &netErr) && netErr.Timeout()) {
				res.ErrorCode = codeUDPUnconfirmed
				res.ErrorMsg = "端口没有回应（UDP 无法区分开放与静默）"
				return res
			}
			res.ErrorCode = classifyProbeError(err)
			res.ErrorMsg = err.Error()
			return res
		}
		if n > 0 {
			res.LatencyMs = time.Since(started).Milliseconds()
			res.Ok = true
			return res
		}
	}
}

func probeContext(timeout time.Duration, cancel <-chan struct{}) (context.Context, context.CancelFunc) {
	ctx, stop := context.WithTimeout(context.Background(), timeout)
	go func() {
		select {
		case <-cancel:
			stop()
		case <-ctx.Done():
		}
	}()
	return ctx, stop
}

// classifyProbeError maps transport failures to stable codes for the UI.
func classifyProbeError(err error) string {
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		if netErr.Timeout() {
			return "timeout"
		}
	}
	msg := err.Error()
	switch {
	case containsAny(msg, "connection refused", "actively refused"):
		return "connection_refused"
	case containsAny(msg, "no such host", "name resolution"):
		return "dns"
	case containsAny(msg, "certificate", "x509"):
		return "tls"
	case containsAny(msg, "EOF", "reset"):
		return "reset"
	default:
		return "network"
	}
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if sub != "" && strings.Contains(s, sub) {
			return true
		}
	}
	return false
}
