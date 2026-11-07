package tunservice

import "golang.org/x/sys/windows"

// isElevated reports whether this process holds an elevated administrator
// token.
//
// Install and Uninstall write under Program Files and touch the SCM, so both
// refuse to run without it. The check is the same one the service controller
// used to import from the retired helper package.
func isElevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}
