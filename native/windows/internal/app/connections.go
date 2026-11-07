package app

import (
	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
)

// connectionsConfigPath selects the config of the core serving the Clash API.
// The elevated TUN core runs under the LocalSystem service, outside the normal
// supervisor, so the two paths answer from different files.
func (a *App) connectionsConfigPath() (string, bool) {
	a.reconcileTun()
	if a.Store.Snapshot().TunState == state.TunEnabled {
		return a.tunRuntimeConfigPath(), true
	}
	if a.Supervisor.Running() {
		return a.activeConfigPath(), true
	}
	return "", false
}

// ConnectionsConfig implements connapi.Source. The connection package owns the
// HTTP client and its cache; this method is the only thing it needs from app.
func (a *App) ConnectionsConfig() (string, bool) { return a.connectionsConfigPath() }

func (a *App) connectionsList(_ *contract.Request) (any, *contract.ErrorObj) {
	return a.conn.List()
}

func (a *App) connectionsClose(req *contract.Request) (any, *contract.ErrorObj) {
	var p struct {
		ID string `json:"id"`
	}
	if e := contract.DecodeParams(req, &p); e != nil {
		return nil, e
	}
	return a.closeConnections(p.ID)
}

// closeConnections is the shared implementation; the tray's 关闭所有连接 reaches
// it through CloseAllConnections so there is one request builder, not two.
func (a *App) closeConnections(rawID string) (any, *contract.ErrorObj) {
	return a.conn.Close(rawID)
}
