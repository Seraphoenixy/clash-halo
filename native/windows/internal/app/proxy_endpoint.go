package app

import (
	"encoding/json"
	"fmt"

	"clash-halo/native/windows/internal/state"
)

// mixedInboundPort returns the port a generated config listens on for mixed
// traffic, or 0 when the document has no such inbound.
//
// Preference order matches what the generator emits: a `mixed` inbound carries
// both HTTP and SOCKS, so it is what Windows' proxy setting should point at. The
// socks/http fallbacks exist because a hand-edited or imported config may only
// have one of them, and pointing the system proxy at a closed port is worse than
// pointing it at a working but narrower one.
func mixedInboundPort(document string) int {
	var doc struct {
		Inbounds []struct {
			Type       string `json:"type"`
			ListenPort int    `json:"listen_port"`
		} `json:"inbounds"`
	}
	if err := json.Unmarshal([]byte(document), &doc); err != nil {
		return 0
	}
	best := 0
	for _, inbound := range doc.Inbounds {
		if inbound.ListenPort <= 0 {
			continue
		}
		switch inbound.Type {
		case "mixed":
			return inbound.ListenPort
		case "socks", "http":
			if best == 0 {
				best = inbound.ListenPort
			}
		}
	}
	return best
}

// repointSystemProxy keeps the Windows proxy aimed at the port the config that
// was just applied actually listens on.
//
// Before this, changing the mixed port in the UI left the registry pointing at
// the previous port: the dashboard said "系统代理 已开启", Windows said the same,
// and every application got connection refused because nothing listened there.
//
// Only the applied value is rewritten here. `SetSystemProxy` must not be reused:
// it records the *current* registry value as the user's original, so calling it
// while the proxy is already on would overwrite the restore bookkeeping and
// leave the user's own proxy setting unrecoverable.
func (a *App) repointSystemProxy(document string) {
	snapshot := a.Store.Snapshot()
	if !snapshot.SystemProxy.Enabled {
		return
	}
	port := mixedInboundPort(document)
	if port <= 0 {
		return
	}
	endpoint := fmt.Sprintf("127.0.0.1:%d", port)
	if endpoint == snapshot.SystemProxy.Endpoint {
		return
	}
	_, applied, err := a.Proxy.Apply(endpoint)
	if err != nil {
		a.Log.Writef("[host] 更新系统代理端点失败: %v", err)
		return
	}
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.SystemProxy.Endpoint = endpoint
		s.SystemProxy.AppliedValue = applied.Server
		s.SystemProxy.AppliedProxyEnable = 1
	})
	a.Log.Writef("[host] 系统代理端点已跟随配置更新为 %s", endpoint)
}
