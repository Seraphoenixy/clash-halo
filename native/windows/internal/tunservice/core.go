package tunservice

import "time"

const (
	// coreStartupTimeout bounds one core start attempt, including the wintun
	// adapter creation that can legitimately take ten seconds on a dirty
	// machine.
	coreStartupTimeout = 25 * time.Second
	// coreGracePeriod is how long a stopping core may take to remove its
	// routes and adapter before the job object terminates it.
	coreGracePeriod = 6 * time.Second
	// coreLogLimit bounds the service-side core log. It is rotated, not
	// truncated, so the previous crash stays readable.
	coreLogLimit = 8 << 20
	// readinessPoll is the adapter probe interval while starting.
	readinessPoll = 100 * time.Millisecond
	// maxStartBudget bounds all attempts together. The host abandons an apply
	// after ~60 s, so retrying past this only turns a failure into a client
	// timeout.
	maxStartBudget = 50 * time.Second
)
