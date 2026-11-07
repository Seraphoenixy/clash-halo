#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>

// One UI process per data directory.
//
// The background host is already single-instance, but the window was not: any
// second launch (double-clicking the exe, the tray's "open the UI" racing the
// host's own launch) created another full Flutter window. Because each new
// window starts a host and each host opens a window, the two fed each other and
// the desktop accumulated a UI process every couple of seconds. The host side
// is fixed as well; this is the second lock on the same door.
namespace halo {

// Takes the per-data-directory UI lock.
//
// Returns true for the first window, which must call MarkUiWindow once its
// top-level window exists. Returns false when another UI already owns the data
// directory: the caller should call ActivateExistingWindow and exit.
bool AcquireUiSingleInstance();

// Tags |window| so a later launch can find and raise it.
void MarkUiWindow(HWND window);

// Brings the existing window to the foreground, waiting up to |timeout_ms| for
// it to appear (the first instance may still be creating it). Returns false if
// no window showed up, in which case the caller exits quietly rather than
// starting a second Flutter engine.
bool ActivateExistingWindow(int timeout_ms);

}  // namespace halo

#endif  // RUNNER_SINGLE_INSTANCE_H_
