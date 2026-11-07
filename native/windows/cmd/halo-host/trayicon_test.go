package main

import (
	"strings"
	"testing"

	"clash-halo/native/windows/internal/state"
)

// The tray icon used to turn green the moment the core started, which is the
// normal state right after the UI launches — system proxy off, nothing routed
// through the app, and a green icon claiming otherwise. "A running core is not
// proof of proxying" is the entire point of the three icon variants, so it is
// pinned here rather than left to the comment.
func TestTrayIconStaysIdleWhileOnlyTheCoreRuns(t *testing.T) {
	cases := []struct {
		name string
		snap state.Snapshot
		want string
	}{
		{
			name: "everything off",
			snap: state.Snapshot{},
			want: "idle",
		},
		{
			name: "core started by the UI, nothing proxied",
			snap: state.Snapshot{CoreState: state.CoreRunning},
			want: "idle",
		},
		{
			name: "core running with a node selected but proxy still off",
			snap: state.Snapshot{
				CoreState:      state.CoreRunning,
				ActiveNodeName: "香港 01",
			},
			want: "idle",
		},
		{
			name: "system proxy on",
			snap: state.Snapshot{
				CoreState:   state.CoreRunning,
				SystemProxy: state.SystemProxy{Enabled: true},
			},
			want: "active",
		},
		{
			name: "TUN on",
			snap: state.Snapshot{
				CoreState: state.CoreRunning,
				TunState:  state.TunEnabled,
			},
			want: "tun",
		},
		{
			name: "TUN on and system proxy on: TUN wins",
			snap: state.Snapshot{
				CoreState:   state.CoreRunning,
				TunState:    state.TunEnabled,
				SystemProxy: state.SystemProxy{Enabled: true},
			},
			want: "tun",
		},
		{
			name: "core stopped but the proxy switch is somehow still on",
			snap: state.Snapshot{SystemProxy: state.SystemProxy{Enabled: true}},
			want: "active",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := trayIconKey(tc.snap); got != tc.want {
				t.Fatalf("trayIconKey = %q, want %q", got, tc.want)
			}
		})
	}
}

// The colour and the tooltip answer the same question, so they must not
// contradict each other. A violet (idle) icon must never read "代理运行中", and a
// green one must never read "已停止".
func TestTrayTooltipAgreesWithTheIcon(t *testing.T) {
	cases := []struct {
		name     string
		snap     state.Snapshot
		wantKey  string
		contains string
		excludes []string
	}{
		{
			name:     "core only",
			snap:     state.Snapshot{CoreState: state.CoreRunning, ActiveNodeName: "香港 01"},
			wantKey:  "idle",
			contains: "系统代理未开启",
			excludes: []string{"代理运行中", "TUN"},
		},
		{
			name: "proxying",
			snap: state.Snapshot{
				CoreState:      state.CoreRunning,
				ActiveNodeName: "香港 01",
				SystemProxy:    state.SystemProxy{Enabled: true},
			},
			wantKey:  "active",
			contains: "香港 01",
			excludes: []string{"已停止"},
		},
		{
			name: "tun",
			snap: state.Snapshot{
				CoreState: state.CoreRunning,
				TunState:  state.TunEnabled,
			},
			wantKey:  "tun",
			contains: "TUN",
			excludes: []string{"已停止"},
		},
		{
			// The worst combination: the switch says traffic is proxied and the
			// core that should do it is dead. The green icon is honest about the
			// switch, so the tooltip has to be honest about the core.
			name: "proxying but the core died",
			snap: state.Snapshot{
				CoreState:    state.CoreFailed,
				LastErrorMsg: "exit status 1",
				SystemProxy:  state.SystemProxy{Enabled: true},
			},
			wantKey:  "active",
			contains: "exit status 1",
		},
		{
			name:     "stopped",
			snap:     state.Snapshot{},
			wantKey:  "idle",
			contains: "已停止",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := trayIconKey(tc.snap); got != tc.wantKey {
				t.Fatalf("trayIconKey = %q, want %q", got, tc.wantKey)
			}
			tip := trayTooltip(tc.snap)
			if !strings.Contains(tip, tc.contains) {
				t.Fatalf("tooltip %q does not mention %q", tip, tc.contains)
			}
			for _, bad := range tc.excludes {
				if strings.Contains(tip, bad) {
					t.Fatalf("tooltip %q must not claim %q", tip, bad)
				}
			}
		})
	}
}
