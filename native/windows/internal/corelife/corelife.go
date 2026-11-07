// Package corelife owns the normal (non-TUN) core lifecycle decisions.
//
// It does not own the locks: app still holds tunMu around Start and applyMu
// around Restart, because those guard cross-domain state (TUN hand-over and the
// config apply pipeline). What moves here is the state machine and the snapshot
// bookkeeping, so the rules live next to their tests instead of inside a
// 1500-line App.
package corelife

import (
	"errors"
	"path/filepath"

	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/core"
	"clash-halo/native/windows/internal/state"
)

// Supervisor is the core process controller.
type Supervisor interface {
	Start(configPath string) (int, error)
	Stop() error
	LastExit() string
	ResetBackoff()
}

// Store is the runtime snapshot.
type Store interface {
	Snapshot() state.Snapshot
	Update(func(*state.Snapshot)) (state.Snapshot, error)
}

// Configs resolves the live config path.
type Configs interface {
	ActivePath() string
}

// Logger is the host log.
type Logger interface {
	Writef(format string, args ...any)
}

// Lifecycle runs the start/stop/resume decisions.
type Lifecycle struct {
	supervisor Supervisor
	store      Store
	configs    Configs
	log        Logger
	tunEnabled func() bool
}

// New builds a lifecycle.
func New(supervisor Supervisor, store Store, configs Configs, log Logger, tunEnabled func() bool) *Lifecycle {
	return &Lifecycle{
		supervisor: supervisor,
		store:      store,
		configs:    configs,
		log:        log,
		tunEnabled: tunEnabled,
	}
}

// Start launches the core onto the active config.
func (l *Lifecycle) Start() (any, *contract.ErrorObj) {
	if l.tunEnabled != nil && l.tunEnabled() {
		return nil, contract.NewError(contract.ErrCoreAlreadyRunning, "TUN 内核已在运行")
	}
	configPath := l.configs.ActivePath()
	if configPath == "" {
		return nil, contract.NewError(contract.ErrConfigInvalid,
			"没有可用的配置，请先应用节点或订阅")
	}
	pid, err := l.supervisor.Start(configPath)
	if err != nil {
		if errors.Is(err, core.ErrAlreadyRunning) {
			return nil, contract.NewError(contract.ErrCoreAlreadyRunning, "核心已在运行")
		}
		_, _ = l.store.Update(func(s *state.Snapshot) {
			s.CoreState = state.CoreFailed
			s.LastErrorCode = contract.ErrConfigApply
			s.LastErrorMsg = err.Error()
		})
		return nil, &contract.ErrorObj{
			Code: contract.ErrConfigApply, Message: "核心启动失败", Detail: err.Error(),
		}
	}
	_, _ = l.store.Update(func(s *state.Snapshot) {
		s.CoreState = state.CoreRunning
		s.CorePID = pid
		s.CoreWanted = true
		s.LastErrorCode = ""
		s.LastErrorMsg = ""
	})
	return map[string]any{"corePid": pid}, nil
}

// Stop stops the core.
func (l *Lifecycle) Stop() (any, *contract.ErrorObj) {
	err := l.supervisor.Stop()
	if errors.Is(err, core.ErrNotRunning) {
		return nil, contract.NewError(contract.ErrCoreNotRunning, "核心未在运行")
	}
	_, _ = l.store.Update(func(s *state.Snapshot) {
		s.CoreState = state.CoreStopped
		s.CorePID = 0
		// Explicitly stopping is an instruction, not an accident. Without this
		// the restore step would bring the core straight back on next launch
		// and the stop button would look broken.
		s.CoreWanted = false
	})
	return map[string]any{"corePid": 0}, nil
}

// Resume starts the core when the last session left it running.
//
// Every host launch used to begin with the core off even when a node had been
// applied and the user had never asked to stop it: coreState is deliberately
// reset to "stopped" on load (a dead process must not be reported as live), and
// nothing recorded the *intent* that survived the reset.
//
// It deliberately does not touch the system proxy (a machine-wide side effect
// after a possible half-written registry is not a decision to make on the
// user's behalf), does not start TUN (the boot-time elevation prompt cannot be
// answered), and does not fight an explicit stop (coreWanted is cleared by
// Stop).
//
// A failure is reported through the snapshot and the log rather than returned,
// because the host must still come up so the UI can show the error.
func (l *Lifecycle) Resume() {
	s := l.store.Snapshot()
	if !s.CoreWanted {
		return
	}
	configPath := l.configs.ActivePath()
	if configPath == "" {
		// A fresh install has never applied anything: surfacing "配置已不存在"
		// on every first launch would be a lie the user cannot act on. An
		// install that did apply a config and no longer has one had it deleted
		// underneath us, which the user should hear about.
		if s.ConfigVersion > 0 || s.ConfigHash != "" {
			_, _ = l.store.Update(func(sn *state.Snapshot) {
				sn.LastErrorCode = contract.ErrConfigInvalid
				sn.LastErrorMsg = "上次运行的内核配置已不存在，未能自动恢复"
			})
			l.log.Writef("[host] 内核恢复跳过：上次的配置已不存在")
			return
		}
		l.log.Writef("[host] 内核恢复跳过：还没有应用过配置")
		return
	}
	pid, err := l.supervisor.Start(configPath)
	if err != nil {
		if errors.Is(err, core.ErrAlreadyRunning) {
			// Another supervisor already owns it; nothing to do and nothing
			// broken, so do not manufacture an error state.
			return
		}
		_, _ = l.store.Update(func(sn *state.Snapshot) {
			sn.CoreState = state.CoreFailed
			sn.CorePID = 0
			sn.LastErrorCode = contract.ErrConfigApply
			sn.LastErrorMsg = err.Error()
		})
		l.log.Writef("[host] 内核恢复失败：%v", err)
		return
	}
	_, _ = l.store.Update(func(sn *state.Snapshot) {
		sn.CoreState = state.CoreRunning
		sn.CorePID = pid
		sn.LastErrorCode = ""
		sn.LastErrorMsg = ""
	})
	l.log.Writef("[host] 已恢复上次的内核 pid=%d config=%s（系统代理保持原样）",
		pid, filepath.Base(configPath))
}

// LastExit is exposed for callers that need the supervisor's explanation.
func (l *Lifecycle) LastExit() string { return l.supervisor.LastExit() }

// ResetBackoff clears the supervisor's failure budget.
func (l *Lifecycle) ResetBackoff() { l.supervisor.ResetBackoff() }
