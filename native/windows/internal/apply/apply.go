// Package apply runs the config apply pipeline: validate, stage, promote,
// restart, health-check, roll back, commit.
//
// It is the cross-domain orchestrator. It does not own locking or the TUN
// hand-over gate — app acquires applyMu/tunMu and reconciles TUN before calling
// Apply — but it owns the order and the rollback rules, so "the only place that
// writes a live config" has one implementation and its tests live next to it.
package apply

import (
	"os"
	"strings"

	"clash-halo/native/windows/internal/configstore"
	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/state"
)

// Params is one apply request.
type Params struct {
	Config       string   `json:"config"`
	ConfigHash   string   `json:"configHash"`
	Mode         string   `json:"mode"`
	NodeID       string   `json:"nodeId,omitempty"`
	NodeName     string   `json:"nodeName,omitempty"`
	Controller   string   `json:"controller,omitempty"`
	APISecret    string   `json:"apiSecret,omitempty"`
	RestartOnly  bool     `json:"restartOnly,omitempty"`
	Secrets      []string `json:"secrets,omitempty"`
	StoreHistory bool     `json:"storeHistory,omitempty"`
	StartCore    *bool    `json:"startCore,omitempty"`
}

// Configs is the live config store.
type Configs interface {
	Candidate(config, claimedHash string) (string, string, *contract.ErrorObj)
	Promote(candidate string) error
	// ActivePath resolves the config the host would run now.
	ActivePath() string
	CurrentPath() string
	Hash() string
	Version() int
	SetVersion(hash string, version int)
}

// Store is the runtime snapshot.
type Store interface {
	Snapshot() state.Snapshot
	Update(func(*state.Snapshot)) (state.Snapshot, error)
}

// Supervisor controls the normal core.
type Supervisor interface {
	Start(configPath string) (int, error)
	Stop() error
	Running() bool
	Pid() int
}

// Redactor registers secrets for log redaction.
type Redactor interface {
	Set(secrets ...string)
}

// Logger is the host log.
type Logger interface {
	Writef(format string, args ...any)
}

// Deps are the collaborators the pipeline needs.
type Deps struct {
	Configs    Configs
	Store      Store
	Supervisor Supervisor
	Log        Logger
	Redactor   Redactor
	CorePath   string

	// ReconcileTun folds in a TUN session that already died. Called with tunMu
	// held by the caller.
	ReconcileTun func()
	// ReloadTun restarts the elevated core with the injected runtime config.
	ReloadTun func(config, candidate string, previousPID int) *contract.ErrorObj
	// Validate runs `sing-box check` (or a test double).
	Validate func(corePath, configPath string) error
	// Rollback restores the previous config after a failed start/health check.
	Rollback func(path, hash string, version int) error
	// HealthCheck proves the core serves the controller endpoint.
	HealthCheck func(controller, secret string) error
	// RepointSystemProxy moves the Windows proxy to the applied config's port.
	RepointSystemProxy func(document string)
}

// Applier runs one apply at a time; the caller holds applyMu.
type Applier struct{ deps Deps }

// New builds an applier.
func New(deps Deps) *Applier { return &Applier{deps: deps} }

// Apply runs the pipeline.
func (a *Applier) Apply(p Params) (any, *contract.ErrorObj) {
	d := a.deps
	if strings.TrimSpace(p.Config) == "" {
		return nil, contract.NewError(contract.ErrBadRequest, "config 不能为空")
	}
	if d.ReconcileTun != nil {
		d.ReconcileTun()
	}

	// Register the secrets before anything is written to disk so the first log
	// line already redacts them.
	if len(p.Secrets) > 0 {
		d.Redactor.Set(p.Secrets...)
	}

	candidate, hash, errObj := d.Configs.Candidate(p.Config, p.ConfigHash)
	if errObj != nil {
		return nil, errObj
	}

	// Default true: applying a config means "make this the live proxy".
	wantRunning := true
	if p.StartCore != nil {
		wantRunning = *p.StartCore
	}
	snap := d.Store.Snapshot()
	inTun := snap.TunState == state.TunEnabled

	// 1. Structural validation by the real core binary.
	//
	// In TUN mode the injected runtime config is validated by
	// reloadTunConfig instead. Validating the base document first and the
	// injected one second runs the core's check over the ~1 MB document twice,
	// which cost about a second on every node switch.
	if !(inTun && wantRunning) {
		if err := d.Validate(d.CorePath, candidate); err != nil {
			_ = os.Remove(candidate)
			return nil, &contract.ErrorObj{
				Code:    contract.ErrConfigInvalid,
				Message: "配置未通过核心校验，已保留原配置",
				Detail:  err.Error(),
			}
		}
	}

	previousPath, previousHash := d.Configs.ActivePath(), d.Configs.Hash()
	previousVersion := d.Configs.Version()

	if inTun && wantRunning {
		if errObj := d.ReloadTun(p.Config, candidate, snap.TunPID); errObj != nil {
			_ = os.Remove(candidate)
			return nil, errObj
		}
	} else {
		// 2. Swap in the candidate.
		d.Log.Writef("[host] applying config %s (%d bytes)", hash[:12], len(p.Config))
		if err := d.Configs.Promote(candidate); err != nil {
			return nil, &contract.ErrorObj{
				Code: contract.ErrConfigApply, Message: "写入配置失败", Detail: err.Error(),
			}
		}
	}
	// 3. Restart the core onto the new config, when it is expected to run.
	wasRunning := d.Supervisor.Running()
	if wantRunning && !inTun {
		if wasRunning {
			_ = d.Supervisor.Stop()
		}
		if _, err := d.Supervisor.Start(d.Configs.CurrentPath()); err != nil {
			// 5. Roll back to the previous config, which is still on disk.
			rollbackErr := d.Rollback(previousPath, previousHash, previousVersion)
			return nil, &contract.ErrorObj{
				Code:    contract.ErrConfigApply,
				Message: "应用新配置失败，已回退到上一个配置",
				Detail:  joinErrors(err, rollbackErr),
			}
		}
		// 4. Prove the core actually serves traffic before declaring success.
		if err := d.HealthCheck(p.Controller, p.APISecret); err != nil {
			_ = d.Supervisor.Stop()
			rollbackErr := d.Rollback(previousPath, previousHash, previousVersion)
			return nil, &contract.ErrorObj{
				Code:    contract.ErrHealthCheck,
				Message: "新配置健康检查未通过，已回退到上一个配置",
				Detail:  joinErrors(err, rollbackErr),
			}
		}
	}

	// Commit the bookkeeping only after success.
	d.Configs.SetVersion(hash, previousVersion+1)
	_, _ = d.Store.Update(func(s *state.Snapshot) {
		s.ConfigHash = hash
		s.ConfigVersion = previousVersion + 1
		s.ActiveNodeID = p.NodeID
		s.ActiveNodeName = p.NodeName
		if p.Mode != "" {
			s.Mode = state.ProxyMode(p.Mode)
		}
		if d.Supervisor.Running() {
			s.CoreState = state.CoreRunning
			s.CorePID = d.Supervisor.Pid()
		}
		// Applying a config with startCore=true is a request for a live proxy,
		// so the intent to run is recorded here and survives the next restart.
		s.CoreWanted = wantRunning
		s.LastErrorCode = ""
		s.LastErrorMsg = ""
	})
	// The Windows proxy must point at the port this config actually listens on,
	// before the snapshot broadcast and the UI's follow-up read.
	d.RepointSystemProxy(p.Config)
	return map[string]any{
		"configHash":    hash,
		"configVersion": previousVersion + 1,
		"corePid":       d.Supervisor.Pid(),
		"applied":       true,
	}, nil
}

func joinErrors(primary error, rollback error) string {
	if primary == nil {
		if rollback == nil {
			return ""
		}
		return rollback.Error()
	}
	if rollback == nil {
		return primary.Error()
	}
	return primary.Error() + "；回退失败: " + rollback.Error()
}

var _ Configs = (*configstore.Store)(nil)
