package app

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestProbeListenerRejectsDifferentProxy(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(time.Second))
		if _, err := io.ReadFull(conn, make([]byte, 3)); err == nil {
			_, _ = conn.Write([]byte{5, 0})
		}
	}()
	if probeListenerReady(context.Background(), listener.Addr().String(), "halo-probe", "different") {
		t.Fatal("a listening proxy without the probe credentials passed readiness")
	}
}

func TestProbeWorkers(t *testing.T) {
	cases := []struct {
		name      string
		metric    string
		requested int
		want      int
	}{
		{"unset latency uses the default", metricProxyLatency, 0, 8},
		{"unset download stays serial", metricDownload, 0, 1},
		{"an explicit value passes through", metricProxyLatency, 16, 16},
		{"above the ceiling is clamped", metricProxyLatency, 33, 32},
		{"negative is treated as unset", metricProxyLatency, -1, 8},
		{"download is clamped too", metricDownload, 64, 32},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := probeWorkers(c.metric, c.requested); got != c.want {
				t.Fatalf("probeWorkers(%q, %d) = %d, want %d",
					c.metric, c.requested, got, c.want)
			}
		})
	}
}

func BenchmarkProbeBatch(b *testing.B) {
	core := testCorePath(b)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	const count = 12
	configs := make([]string, count)
	for i := range configs {
		configs[i] = validConfig + strings.Repeat(" ", i)
	}
	for _, workers := range []int{1, 4, 8} {
		b.Run(fmt.Sprintf("workers=%d", workers), func(b *testing.B) {
			a := &App{Paths: DefaultPaths(b.TempDir(), core)}
			params := speedParams{
				Metric: metricProxyLatency, URL: server.URL, Concurrency: workers,
				Configs: configs, Endpoints: make([]string, count),
			}
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				for _, result := range a.runProbes(params, make(chan struct{})) {
					if !result.Ok {
						b.Fatalf("probe failed: %+v", result)
					}
				}
			}
		})
	}
}

func BenchmarkDownloadSharedLink(b *testing.B) {
	const nodes = 4
	chunk := make([]byte, 16<<10)
	for _, workers := range []int{1, 2, 4} {
		b.Run(fmt.Sprintf("workers=%d", workers), func(b *testing.B) {
			ticks := time.NewTicker(10 * time.Millisecond)
			defer ticks.Stop()
			proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
				flusher := w.(http.Flusher)
				flusher.Flush()
				for i := 0; i < 16; i++ {
					select {
					case <-r.Context().Done():
						return
					case <-ticks.C:
					}
					if _, err := w.Write(chunk); err != nil {
						return
					}
					flusher.Flush()
				}
			}))
			defer proxy.Close()
			endpoints := make([]string, nodes)
			for i := range endpoints {
				endpoints[i] = strings.TrimPrefix(proxy.URL, "http://")
			}
			params := speedParams{
				Metric: metricDownload, Concurrency: workers, Endpoints: endpoints,
				URL: "http://probe.invalid/sample",
			}
			a := &App{}
			var totalRate int64
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				for _, result := range a.runProbes(params, make(chan struct{})) {
					if !result.Ok {
						b.Fatalf("probe failed: %+v", result)
					}
					totalRate += result.DownloadBps
				}
			}
			b.ReportMetric(float64(totalRate)/float64(b.N*nodes), "B/s/node")
		})
	}
}

func TestDownloadProbeDefaultsToSerial(t *testing.T) {
	var active atomic.Int32
	var overlapped atomic.Bool
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if active.Add(1) > 1 {
			overlapped.Store(true)
		}
		defer active.Add(-1)
		time.Sleep(75 * time.Millisecond)
		_, _ = w.Write([]byte("sample"))
	}))
	defer proxy.Close()
	endpoint := strings.TrimPrefix(proxy.URL, "http://")
	a := &App{}
	results := a.runProbes(speedParams{
		Metric: metricDownload, Endpoints: []string{endpoint, endpoint},
		URL: "http://probe.invalid/sample",
	}, make(chan struct{}))
	if overlapped.Load() || !results[0].Ok || !results[1].Ok {
		t.Fatalf("expected two successful serial downloads, got %+v", results)
	}
}

func TestProbeConfigReportsCoreExitBeforeReadinessTimeout(t *testing.T) {
	a := newTestApp(t)
	// The core accepts this document in check mode, then rejects the empty
	// direct detour while starting its DNS transport.
	const config = `{
		"outbounds":[{"type":"direct","tag":"direct"}],
		"dns":{"servers":[{"type":"udp","tag":"local","server":"127.0.0.1","detour":"direct"}]}
	}`
	start := time.Now()
	result := a.probeConfig(config, defaultProbeURL, 8*time.Second, probeBodyLimit, metricProxyLatency, make(chan struct{}), nil)
	if !strings.Contains(result.ErrorMsg, "测试内核在端口就绪前退出") {
		t.Fatalf("got %+v, want startup exit", result)
	}
	if elapsed := time.Since(start); elapsed >= 5*time.Second {
		t.Fatalf("reporting startup exit took %v", elapsed)
	}
}

func TestProbeConfigRejectsInvalidDocuments(t *testing.T) {
	a := newTestApp(t)
	for _, document := range []string{"null", structurallyInvalidConfig} {
		got := a.probeConfig(document, defaultProbeURL, 8*time.Second, probeBodyLimit, metricProxyLatency, make(chan struct{}), nil)
		if got.Ok || got.ErrorCode != "probe_failed" {
			t.Fatalf("invalid document %q returned %+v", document, got)
		}
	}
}

func TestProbeUDPCancelReleasesWaitingSocket(t *testing.T) {
	listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := listener.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	cancel := make(chan struct{})
	done := make(chan ProbeResult, 1)
	go func() {
		done <- probeUDP(listener.LocalAddr().String(), 8*time.Second, cancel, nil)
	}()
	_, _, err = listener.ReadFrom(make([]byte, 128))
	close(cancel)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-done:
		if result.ErrorCode != "canceled" {
			t.Fatalf("got %+v, want cancellation", result)
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation left the UDP probe waiting for its network timeout")
	}
}

func TestProbeProgressCountsCompletionsInOrder(t *testing.T) {
	silent, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer silent.Close()
	responder, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer responder.Close()
	go func() {
		buf := make([]byte, 128)
		if n, addr, err := responder.ReadFrom(buf); err == nil {
			_, _ = responder.WriteTo(buf[:n], addr)
		}
	}()
	cancel := make(chan struct{})
	a := &App{}
	var counts []int
	a.SetEventSink(func(_ string, data any) {
		progress := data.(map[string]any)
		counts = append(counts, progress["done"].(int))
		if progress["result"].(ProbeResult).Ok {
			close(cancel)
		}
	})
	results := a.runProbes(speedParams{
		Metric: metricUDP, Concurrency: 2,
		Endpoints: []string{silent.LocalAddr().String(), responder.LocalAddr().String()},
	}, cancel)
	if !results[1].Ok || results[0].ErrorCode != "canceled" {
		t.Fatalf("expected second probe to finish first: %+v", results)
	}
	if len(counts) != 2 || counts[0] != 1 || counts[1] != 2 {
		t.Fatalf("completion counts = %v, want [1 2]", counts)
	}
}
