package app

import (
	"testing"
	"time"

	"clash-halo/native/windows/internal/connapi"
	"clash-halo/native/windows/internal/contract"
)

func TestSpeedSessionKeepsResultsAfterBatchFinishes(t *testing.T) {
	s := newAppSession()
	s.beginSpeed("t1", metricProxyLatency, []string{"n1", "n2"}, 2)
	s.recordSpeed(ProbeResult{
		NodeID: "n1", Metric: metricProxyLatency, Ok: true, LatencyMs: 12,
	})

	live := s.speedSnapshot()
	if !live.Running || live.TaskID != "t1" || live.Done != 1 {
		t.Fatalf("live batch = %+v", live)
	}
	if len(live.Pending) != 1 || live.Pending[0] != "n2" {
		t.Fatalf("pending = %v", live.Pending)
	}

	s.finishSpeed("t1")
	done := s.speedSnapshot()
	if done.Running {
		t.Fatal("finished session still reports running")
	}
	if len(done.Results) != 1 || done.Results[0].NodeID != "n1" {
		t.Fatalf("results after finish = %+v", done.Results)
	}
	if done.Results[0].LatencyMs != 12 {
		t.Fatalf("latency = %d", done.Results[0].LatencyMs)
	}
}

func TestSpeedSessionStartsOnlyTheMetricItRemeasures(t *testing.T) {
	s := newAppSession()
	s.beginSpeed("t1", metricProxyLatency, []string{"n1"}, 1)
	s.recordSpeed(ProbeResult{NodeID: "n1", Metric: metricProxyLatency, Ok: true, LatencyMs: 12})
	s.finishSpeed("t1")

	s.beginSpeed("t2", metricDownload, []string{"n1"}, 1)
	s.recordSpeed(ProbeResult{NodeID: "n1", Metric: metricDownload, Ok: true, DownloadBps: 1000})
	s.finishSpeed("t2")

	got := s.speedSnapshot()
	if len(got.Results) != 2 {
		t.Fatalf("results = %+v, want latency and download", got.Results)
	}
}

func TestSpeedForgetDropsEveryMetricForOneNode(t *testing.T) {
	s := newAppSession()
	s.beginSpeed("t1", "tcp", []string{"n1", "n2"}, 2)
	s.recordSpeed(ProbeResult{NodeID: "n1", Metric: "tcp", Ok: true, LatencyMs: 3})
	s.recordSpeed(ProbeResult{NodeID: "n2", Metric: "tcp", Ok: true, LatencyMs: 4})
	s.finishSpeed("t1")

	s.forgetSpeed("n1")
	got := s.speedSnapshot()
	if len(got.Results) != 1 || got.Results[0].NodeID != "n2" {
		t.Fatalf("results after forget = %+v", got.Results)
	}
}

func TestClientCountZeroKeepsSpeedTaskRunning(t *testing.T) {
	a := newTestApp(t)
	cancel := make(chan struct{})
	a.speedRunning = true
	a.speedCancel = cancel
	a.speedDone = make(chan struct{})
	a.OnClientCount(0)
	select {
	case <-cancel:
		t.Fatal("closing the last window cancelled the speed task")
	default:
	}
	if !a.speedRunning {
		t.Fatal("speed task was marked stopped after the last window closed")
	}
}

func TestSessionGetKeepsResultsAfterClientDisconnect(t *testing.T) {
	a := newTestApp(t)
	a.sess.beginSpeed("t1", metricProxyLatency, []string{"n1"}, 1)
	a.sess.recordSpeed(ProbeResult{
		NodeID: "n1", Metric: metricProxyLatency, Ok: true, LatencyMs: 12,
	})
	a.sess.finishSpeed("t1")
	a.OnClientCount(0)

	raw, errObj := request(t, a, contract.ActionSessionGet, map[string]any{})
	if errObj != nil {
		t.Fatalf("session.get: %+v", errObj)
	}
	snap, ok := raw.(sessionSnapshot)
	if !ok {
		t.Fatalf("session.get returned %T", raw)
	}
	if len(snap.Speed.Results) != 1 || snap.Speed.Results[0].LatencyMs != 12 {
		t.Fatalf("speed results after disconnect = %+v", snap.Speed.Results)
	}
}

func TestTrafficMonitorCountsProxyDeltaOnly(t *testing.T) {
	m := trafficMonitor{historyLength: 40, bytes: make(map[string][2]int64)}
	start := time.Unix(1000, 0)
	m.sample(connapi.ConnectionsSnapshot{
		Connections: []connapi.Connection{
			{ID: "proxy", Chains: []string{"proxy"}, Upload: 100, Download: 200},
			{ID: "direct", Chains: []string{"direct"}, Upload: 9000, Download: 9000},
		},
	}, start)
	if m.upload != 0 || m.download != 0 || m.active != 1 {
		t.Fatalf("baseline = upload %d download %d active %d", m.upload, m.download, m.active)
	}

	m.sample(connapi.ConnectionsSnapshot{
		Connections: []connapi.Connection{
			{ID: "proxy", Chains: []string{"proxy"}, Upload: 300, Download: 500},
			{ID: "direct", Chains: []string{"direct"}, Upload: 9900, Download: 9900},
		},
	}, start.Add(2*time.Second))

	if m.upload != 200 || m.download != 300 {
		t.Fatalf("totals = %d/%d, want 200/300", m.upload, m.download)
	}
	if m.upRate != 100 || m.downRate != 150 {
		t.Fatalf("rates = %.1f/%.1f, want 100/150", m.upRate, m.downRate)
	}
	if len(m.history) != 1 {
		t.Fatalf("history = %d samples, want 1", len(m.history))
	}
	if m.active != 1 {
		t.Fatalf("active = %d, want the proxy connection only", m.active)
	}
}

func TestTrafficMonitorResetsWhenCoreChanges(t *testing.T) {
	s := newAppSession()
	s.observeCore(true, 11, 0)
	s.sampleTraffic(connapi.ConnectionsSnapshot{
		Connections: []connapi.Connection{
			{ID: "a", Chains: []string{"proxy"}, Upload: 10, Download: 10},
		},
	}, time.Unix(1000, 0))
	s.sampleTraffic(connapi.ConnectionsSnapshot{
		Connections: []connapi.Connection{
			{ID: "a", Chains: []string{"proxy"}, Upload: 30, Download: 30},
		},
	}, time.Unix(1002, 0))
	if got := s.trafficSnapshot(); got.UploadTotal != 20 {
		t.Fatalf("upload before reset = %d, want 20", got.UploadTotal)
	}

	s.observeCore(true, 12, 0)
	got := s.trafficSnapshot()
	if got.UploadTotal != 0 || len(got.History) != 0 || got.ActiveConnections != 0 {
		t.Fatalf("traffic survived copy change: %+v", got)
	}
}
