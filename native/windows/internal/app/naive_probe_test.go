package app

import (
	"os"
	"testing"
)

func TestNaiveH3UDPProbeDoesNotCrash(t *testing.T) {
	configPath := os.Getenv("HALO_NAIVE_H3_CONFIG")
	if configPath == "" {
		configPath = "../../../../build/windows-x64/user-data/probe-3676886078/config.json"
	}
	document, err := os.ReadFile(configPath)
	if err != nil {
		t.Skipf("需要一份 Naive H3 配置样本: %v", err)
	}

	a := newTestApp(t)
	// 与 UI 的 metric=udp 调用保持一致：带 configs，因此逐个节点跑真实内核。
	results := a.runProbes(speedParams{
		TaskID:    "e2e-udp-h3",
		Metric:    metricUDP,
		Configs:   []string{string(document)},
		Endpoints: []string{""},
		NodeIDs:   []string{"naive-h3"},
	}, make(chan struct{}))

	if len(results) != 1 {
		t.Fatalf("结果数 = %d, 期望 1", len(results))
	}
	got := results[0]
	t.Logf("结果: ok=%v metric=%s code=%q msg=%q latency=%dms",
		got.Ok, got.Metric, got.ErrorCode, got.ErrorMsg, got.LatencyMs)

	if got.NodeID != "naive-h3" || got.Metric != metricUDP {
		t.Fatalf("unexpected probe result: %+v", got)
	}
}
