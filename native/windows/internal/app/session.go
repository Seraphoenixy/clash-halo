package app

import (
	"sort"
	"strings"
	"sync"
	"time"

	"clash-halo/native/windows/internal/connapi"
	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
)

// The host, not the UI, owns measurements for the lifetime of the process.
//
// Closing the window destroys the Flutter isolate. Anything stored there is
// therefore gone even though the tray, the proxy and the host are still
// running. This session keeps the last speed reading per node and the traffic
// counters in host memory; it is deliberately not written to disk, because
// "the software is running" ends when the host exits, not when the window does.

const (
	trafficHistoryLength  = 40
	trafficSampleInterval = 2 * time.Second
)

type sessionSpeedResult struct {
	Running     bool          `json:"running"`
	TaskID      string        `json:"taskId,omitempty"`
	Metric      string        `json:"metric,omitempty"`
	Total       int           `json:"total"`
	Done        int           `json:"done"`
	Pending     []string      `json:"pending"`
	Results     []ProbeResult `json:"results"`
	UpdatedAtMs int64         `json:"updatedAtMs"`
}

type trafficPoint struct {
	Up   float64 `json:"up"`
	Down float64 `json:"down"`
}

type sessionTraffic struct {
	UpRate            float64        `json:"upRate"`
	DownRate          float64        `json:"downRate"`
	UploadTotal       int64          `json:"uploadTotal"`
	DownloadTotal     int64          `json:"downloadTotal"`
	PeakUp            float64        `json:"peakUp"`
	PeakDown          float64        `json:"peakDown"`
	History           []trafficPoint `json:"history"`
	ActiveConnections int            `json:"activeConnections"`
	UpdatedAtMs       int64          `json:"updatedAtMs"`
	Error             string         `json:"error,omitempty"`
}

type sessionSnapshot struct {
	Speed   sessionSpeedResult `json:"speed"`
	Traffic sessionTraffic     `json:"traffic"`
}

type appSession struct {
	mu      sync.RWMutex
	speed   speedSession
	traffic trafficMonitor
}

type speedSession struct {
	running   bool
	taskID    string
	metric    string
	total     int
	done      int
	pending   map[string]struct{}
	results   map[string]map[string]ProbeResult
	updatedAt time.Time
}

type trafficMonitor struct {
	historyLength int
	at            time.Time
	updatedAt     time.Time
	upload        int64
	download      int64
	upRate        float64
	downRate      float64
	peakUp        float64
	peakDown      float64
	active        int
	error         string
	bytes         map[string][2]int64
	corePID       int
	tunPID        int
	history       []trafficPoint
}

func newAppSession() *appSession {
	return &appSession{
		speed: speedSession{
			pending: make(map[string]struct{}),
			results: make(map[string]map[string]ProbeResult),
		},
		traffic: trafficMonitor{
			historyLength: trafficHistoryLength,
			bytes:         make(map[string][2]int64),
		},
	}
}

func (s *appSession) beginSpeed(taskID, metric string, nodeIDs []string, total int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// A new batch replaces only the readings it is about to measure. Re-running
	// latency must not erase a download figure the user already earned.
	for _, id := range nodeIDs {
		if byMetric, ok := s.speed.results[id]; ok {
			delete(byMetric, metric)
			if len(byMetric) == 0 {
				delete(s.speed.results, id)
			}
		}
	}
	s.speed.pending = make(map[string]struct{}, len(nodeIDs))
	for _, id := range nodeIDs {
		if id != "" {
			s.speed.pending[id] = struct{}{}
		}
	}
	s.speed.running = true
	s.speed.taskID = taskID
	s.speed.metric = metric
	s.speed.total = total
	s.speed.done = 0
	s.speed.updatedAt = time.Now()
}

func (s *appSession) recordSpeed(r ProbeResult) {
	if r.NodeID == "" || r.Metric == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.speed.running {
		return
	}
	if s.speed.results == nil {
		s.speed.results = make(map[string]map[string]ProbeResult)
	}
	byMetric := s.speed.results[r.NodeID]
	if byMetric == nil {
		byMetric = make(map[string]ProbeResult)
		s.speed.results[r.NodeID] = byMetric
	}
	byMetric[r.Metric] = r
	if _, waiting := s.speed.pending[r.NodeID]; waiting {
		delete(s.speed.pending, r.NodeID)
		s.speed.done++
	}
	s.speed.updatedAt = time.Now()
}

func (s *appSession) finishSpeed(taskID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.speed.taskID != taskID {
		return
	}
	s.speed.running = false
	s.speed.taskID = ""
	s.speed.metric = ""
	s.speed.total = 0
	s.speed.done = 0
	s.speed.pending = make(map[string]struct{})
	s.speed.updatedAt = time.Now()
}

func (s *appSession) forgetSpeed(nodeID string) {
	if nodeID == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.speed.results, nodeID)
	delete(s.speed.pending, nodeID)
	s.speed.updatedAt = time.Now()
}

func (s *appSession) speedSnapshot() sessionSpeedResult {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.speedSnapshotLocked()
}

func (s *appSession) speedSnapshotLocked() sessionSpeedResult {
	out := sessionSpeedResult{
		Running:     s.speed.running,
		TaskID:      s.speed.taskID,
		Metric:      s.speed.metric,
		Total:       s.speed.total,
		Done:        s.speed.done,
		Pending:     make([]string, 0, len(s.speed.pending)),
		Results:     make([]ProbeResult, 0),
		UpdatedAtMs: s.speed.updatedAt.UnixMilli(),
	}
	for id := range s.speed.pending {
		out.Pending = append(out.Pending, id)
	}
	sort.Strings(out.Pending)
	ids := make([]string, 0, len(s.speed.results))
	for id := range s.speed.results {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		metrics := make([]string, 0, len(s.speed.results[id]))
		for metric := range s.speed.results[id] {
			metrics = append(metrics, metric)
		}
		sort.Strings(metrics)
		for _, metric := range metrics {
			out.Results = append(out.Results, s.speed.results[id][metric])
		}
	}
	return out
}

func (s *appSession) observeCore(running bool, corePID, tunPID int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !running {
		if s.traffic.corePID != 0 || s.traffic.tunPID != 0 || !s.traffic.at.IsZero() {
			s.traffic.reset()
		}
		return
	}
	if s.traffic.corePID != corePID || s.traffic.tunPID != tunPID {
		// A new core means its cumulative counters started at zero. Keeping the
		// old peak and history would describe processes that no longer exist.
		s.traffic.reset()
		s.traffic.corePID = corePID
		s.traffic.tunPID = tunPID
	}
}

func (s *appSession) sampleTraffic(snapshot connapi.ConnectionsSnapshot, at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.traffic.sample(snapshot, at)
}

func (s *appSession) setTrafficError(message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.traffic.error = message
	s.traffic.updatedAt = time.Now()
}

func (s *appSession) trafficSnapshot() sessionTraffic {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.traffic.snapshotLocked()
}

func (s *appSession) snapshot() sessionSnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return sessionSnapshot{
		Speed:   s.speedSnapshotLocked(),
		Traffic: s.traffic.snapshotLocked(),
	}
}

func (m *trafficMonitor) sample(snapshot connapi.ConnectionsSnapshot, at time.Time) {
	previous := m.at
	dt := at.Sub(previous)
	if !previous.IsZero() && dt < 50*time.Millisecond {
		return
	}
	connections := make([]connapi.Connection, 0, len(snapshot.Connections))
	for _, c := range snapshot.Connections {
		if hasProxyChain(c.Chains) {
			connections = append(connections, c)
		}
	}
	if !previous.IsZero() && dt >= 50*time.Millisecond {
		seconds := dt.Seconds()
		var upDelta, downDelta int64
		regressed := false
		for _, c := range connections {
			before := m.bytes[c.ID]
			if c.Upload < before[0] || c.Download < before[1] {
				// A counter that moved backwards means the core restarted
				// between samples. Treat the sample as a fresh baseline instead
				// of drawing a negative rate; the PID check normally catches
				// this first.
				regressed = true
				break
			}
			upDelta += c.Upload - before[0]
			downDelta += c.Download - before[1]
		}
		if !regressed {
			m.upload += upDelta
			m.download += downDelta
			m.upRate = float64(upDelta) / seconds
			m.downRate = float64(downDelta) / seconds
			m.peakUp = max(m.peakUp, m.upRate)
			m.peakDown = max(m.peakDown, m.downRate)
			m.history = append(m.history, trafficPoint{Up: m.upRate, Down: m.downRate})
			if len(m.history) > m.historyLength {
				m.history = m.history[len(m.history)-m.historyLength:]
			}
		}
	}
	m.at = at
	m.updatedAt = at
	m.active = len(connections)
	m.error = ""
	m.bytes = make(map[string][2]int64, len(connections))
	for _, c := range connections {
		m.bytes[c.ID] = [2]int64{c.Upload, c.Download}
	}
}

func (m *trafficMonitor) reset() {
	m.at = time.Time{}
	m.updatedAt = time.Time{}
	m.upload = 0
	m.download = 0
	m.upRate = 0
	m.downRate = 0
	m.peakUp = 0
	m.peakDown = 0
	m.active = 0
	m.error = ""
	m.bytes = make(map[string][2]int64)
	m.corePID = 0
	m.tunPID = 0
	m.history = nil
}

func (m *trafficMonitor) snapshotLocked() sessionTraffic {
	history := make([]trafficPoint, len(m.history))
	copy(history, m.history)
	return sessionTraffic{
		UpRate:            m.upRate,
		DownRate:          m.downRate,
		UploadTotal:       m.upload,
		DownloadTotal:     m.download,
		PeakUp:            m.peakUp,
		PeakDown:          m.peakDown,
		History:           history,
		ActiveConnections: m.active,
		UpdatedAtMs:       m.updatedAt.UnixMilli(),
		Error:             m.error,
	}
}

func hasProxyChain(chains []string) bool {
	for _, chain := range chains {
		if strings.EqualFold(chain, "proxy") {
			return true
		}
	}
	return false
}

// StartSessionSampler starts the host-owned traffic clock. It is called by the
// production entry point, not by app.New: unit tests build App values with no
// core and must not inherit a two-second timer.
func (a *App) StartSessionSampler() {
	if a == nil || a.sess == nil {
		return
	}
	a.sessionOnce.Do(func() {
		go a.runSessionSampler()
	})
}

func (a *App) runSessionSampler() {
	a.sampleSessionTraffic()
	ticker := time.NewTicker(trafficSampleInterval)
	defer ticker.Stop()
	for {
		select {
		case <-a.sessionStop:
			return
		case <-ticker.C:
			a.sampleSessionTraffic()
		}
	}
}

func (a *App) sampleSessionTraffic() {
	if a.sess == nil || a.Store == nil || a.conn == nil {
		return
	}
	snapshot := a.Store.Snapshot()
	running := snapshot.CoreState == state.CoreRunning
	a.sess.observeCore(running, snapshot.CorePID, snapshot.TunPID)
	if !running {
		return
	}
	connections, errObj := a.conn.List()
	if errObj != nil {
		a.sess.setTrafficError(errObj.Message)
		return
	}
	a.sess.sampleTraffic(connections, time.Now())
}

func (a *App) stopSessionSampler() {
	if a == nil || a.sessionStop == nil {
		return
	}
	a.sessionStopOnce.Do(func() { close(a.sessionStop) })
}

func (a *App) sessionGet(_ *contract.Request) (any, *contract.ErrorObj) {
	if a.sess == nil {
		return sessionSnapshot{}, nil
	}
	return a.sess.snapshot(), nil
}

func (a *App) trafficGet(_ *contract.Request) (any, *contract.ErrorObj) {
	if a.sess == nil {
		return sessionTraffic{History: []trafficPoint{}}, nil
	}
	return a.sess.trafficSnapshot(), nil
}

func (a *App) speedForget(req *contract.Request) (any, *contract.ErrorObj) {
	var p struct {
		NodeID string `json:"nodeId"`
	}
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	if a.sess != nil {
		a.sess.forgetSpeed(p.NodeID)
	}
	return map[string]any{"forgotten": p.NodeID}, nil
}
