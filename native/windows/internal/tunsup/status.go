// Package tunsup runs the elevated sing-box process that owns a TUN adapter.
//
// The TUN core is deliberately dumb: the LocalSystem service starts one fixed
// core with one validated config, and the runner keeps it in a job object so
// the core cannot outlive the service. The host owns every decision; the
// service owns only privilege.
//
// A Windows job object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is the heart of
// the no-orphan guarantee. If the service dies for any reason — including being
// killed, which is the one case a cleanup handler cannot cover — the kernel
// closes the job handle and terminates sing-box with it, so an elevated process
// can never outlive the request that created it.
package tunsup

// StatusVersion guards the status wire format shared with the host.
const StatusVersion = 1

// State is the lifecycle of the elevated core.
type State string

// States reported to the host.
const (
	StateStarting State = "starting"
	StateRunning  State = "running"
	StateStopped  State = "stopped"
	StateFailed   State = "failed"
)

// Status is the service's report of the core it owns.
type Status struct {
	V       int    `json:"v"`
	State   State  `json:"state"`
	PID     int    `json:"pid"`
	Adapter string `json:"adapter,omitempty"`
	// Elevated is the service's own token check, never the host's assumption.
	Elevated bool `json:"elevated"`
	// Message is user-facing, in Chinese, and never contains credentials.
	Message string `json:"message,omitempty"`
	// HostPID lets the host recognise a status left over from a previous run.
	HostPID   int   `json:"hostPid"`
	UpdatedMs int64 `json:"updatedAtMs"`
}
