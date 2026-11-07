//go:build windows

package tray

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// ---------------------------------------------------------------------------
// Win32 surface
// ---------------------------------------------------------------------------

var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	shell32  = windows.NewLazySystemDLL("shell32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")

	procRegisterClassExW    = user32.NewProc("RegisterClassExW")
	procCreateWindowExW     = user32.NewProc("CreateWindowExW")
	procDefWindowProcW      = user32.NewProc("DefWindowProcW")
	procDestroyWindow       = user32.NewProc("DestroyWindow")
	procGetMessageW         = user32.NewProc("GetMessageW")
	procTranslateMessage    = user32.NewProc("TranslateMessage")
	procDispatchMessageW    = user32.NewProc("DispatchMessageW")
	procPostMessageW        = user32.NewProc("PostMessageW")
	procPostQuitMessage     = user32.NewProc("PostQuitMessage")
	procCreatePopupMenu     = user32.NewProc("CreatePopupMenu")
	procAppendMenuW         = user32.NewProc("AppendMenuW")
	procDestroyMenu         = user32.NewProc("DestroyMenu")
	procTrackPopupMenuEx    = user32.NewProc("TrackPopupMenuEx")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	procGetCursorPos        = user32.NewProc("GetCursorPos")
	procLoadImageW          = user32.NewProc("LoadImageW")
	procDestroyIcon         = user32.NewProc("DestroyIcon")
	procGetModuleHandleW    = kernel32.NewProc("GetModuleHandleW")

	procShellNotifyIconW = shell32.NewProc("Shell_NotifyIconW")
)

const (
	wmNull      = 0x0000
	wmDestroy   = 0x0002
	wmClose     = 0x0010
	wmCommand   = 0x0111
	wmLButtonUp = 0x0202
	wmRButtonUp = 0x0205
	// wmApp is the first message id an application may claim. Everything the
	// tray posts to itself lives above it so it cannot collide with a
	// WM_* constant.
	wmApp           = 0x8000
	wmTrayCallback  = wmApp + 1
	wmRefreshIcon   = wmApp + 2
	wmTaskbarCreate = 0 // filled in at run time: RegisterWindowMessage("TaskbarCreated")

	nimAdd    = 0
	nimModify = 1
	nimDelete = 2

	nifMessage = 0x00000001
	nifIcon    = 0x00000002
	nifTip     = 0x00000004

	imageIcon      = 1
	lrLoadFromFile = 0x00000010

	mfString    = 0x00000000
	mfPopup     = 0x00000010
	mfSeparator = 0x00000800
	mfChecked   = 0x00000008
	mfDisabled  = 0x00000002
	mfGrayed    = 0x00000001
	mfDefault   = 0x00001000

	tpmLeftAlign    = 0x0000
	tpmTopAlign     = 0x0000
	tpmRightButton  = 0x0002
	tpmReturnCmd    = 0x0100
	tpmNoNotify     = 0x0080
	trayIconID      = 1
	maxTooltipChars = 127
)

// notifyIconData mirrors NOTIFYICONDATAW. Field order and types match the SDK
// declaration exactly; Windows reads it through cbSize, so an accidental
// reordering would silently truncate the tooltip rather than fail loudly.
type notifyIconData struct {
	Size            uint32
	_               uint32
	Wnd             uintptr
	ID              uint32
	Flags           uint32
	CallbackMessage uint32
	_               uint32
	Icon            uintptr
	Tip             [128]uint16
	State           uint32
	StateMask       uint32
	Info            [256]uint16
	Timeout         uint32
	InfoTitle       [64]uint16
	InfoFlags       uint32
	_               uint32
	GuidItem        windows.GUID
	BalloonIcon     uintptr
}

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   uintptr
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSm     uintptr
}

type point struct {
	X int32
	Y int32
}

type msg struct {
	Hwnd    uintptr
	Message uint32
	_       uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	_       uint32
	Pt      point
	_       uint32
}

// Options configure the tray icon. Everything except Icon/Tooltip is optional.
type Options struct {
	// Icon is the bytes of a .ico file. It is written to a temporary file
	// because LoadImage(IMAGE_ICON, LR_LOADFROMFILE) is the only loader that
	// reliably handles the multi-size ICO the build bakes in; the file is
	// removed as soon as the handle exists.
	Icon []byte
	Tooltip string
	// Menu is called every time the user right-clicks, so the menu is built
	// from live state and can never show a stale tick mark.
	Menu func() []Item
	// OnCommand receives the Item.ID of the chosen entry.
	OnCommand func(id string)
	// OnLeftClick runs for a left click or double click. It is called on a
	// separate goroutine and must not block the message loop.
	OnLeftClick func()
	// OnReady runs once the icon exists (or once it failed to appear). It is
	// called from the tray goroutine, so it must not call Refresh.
	OnReady func(error)
}

var (
	mu         sync.Mutex
	opts       Options
	hwnd       uintptr
	pending    *pendingUpdate
	applied    []byte
	appliedTip string
	// appliedIcon is the HICON currently installed in the notification area. It
	// is reused for tooltip-only updates so a text change never reloads a bitmap.
	appliedIcon uintptr
	// quitRequested records a Quit that arrived before the window existed.
	quitRequested bool
	running       bool
	lastErr       error
)

type pendingUpdate struct {
	icon      []byte
	tooltip   string
	touchIcon bool
}

// Run creates the icon and pumps messages until Quit is called.
//
// It must be called from the main goroutine: Windows requires the window's
// message loop to run on the thread that created the window, and Go's scheduler
// would otherwise move the goroutine between threads mid-loop.
func Run(options Options) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	mu.Lock()
	opts = options
	applied = options.Icon
	appliedTip = options.Tooltip
	mu.Unlock()

	instance, _, _ := procGetModuleHandleW.Call(0)
	className, err := syscall.UTF16PtrFromString("HaloHostTrayWindow")
	if err != nil {
		return err
	}
	wc := wndClassEx{
		Style:     0,
		WndProc:   syscall.NewCallback(wndProc),
		Instance:  instance,
		ClassName: className,
	}
	wc.Size = uint32(unsafe.Sizeof(wc))
	atom, _, callErr := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	if atom == 0 {
		return fmt.Errorf("RegisterClassExW: %w", callErr)
	}

	title, _ := syscall.UTF16PtrFromString("halo-host tray")
	// WS_POPUP with no visible flag: the window exists only to receive the
	// shell's callback messages. It is deliberately a top-level window rather
	// than message-only, because the "taskbar was recreated" broadcast only
	// reaches top-level windows and losing that message leaves a dead icon
	// after explorer.exe restarts.
	hwnd, _, callErr = procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(title)),
		0x80000000, // WS_POPUP
		0, 0, 0, 0,
		0, 0, instance, 0,
	)
	if hwnd == 0 {
		return fmt.Errorf("CreateWindowExW: %w", callErr)
	}
	taskbarCreatedMsg = registerWindowMessage("TaskbarCreated")

	if err := addIcon(options.Icon, options.Tooltip); err != nil {
		// The icon is the whole point of this mode, but a missing tray must not
		// take down a host that is already serving the proxy: report it and keep
		// pumping so shutdown still works.
		lastErr = err
	}
	mu.Lock()
	running = true
	earlyQuit := quitRequested
	mu.Unlock()
	if options.OnReady != nil {
		options.OnReady(lastErr)
	}
	if earlyQuit {
		// Quit arrived before the window existed; honour it now instead of
		// blocking the message loop until the shutdown watchdog fires.
		procPostMessageW.Call(hwnd, wmClose, 0, 0)
	}

	var m msg
	for {
		ret, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(ret) <= 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	return nil
}

var taskbarCreatedMsg uintptr

// Quit removes the icon and ends the message loop. Safe to call repeatedly and
// from any goroutine; the shutdown path calls it more than once by design.
//
// A Quit that arrives before the window exists is remembered rather than lost:
// the host can be asked to exit during startup (an IPC shutdown, a log-in
// script), and a dropped Quit would leave the process parked in GetMessage with
// the single-instance lock still held.
func Quit() {
	mu.Lock()
	already := quitRequested
	quitRequested = true
	h := hwnd
	mu.Unlock()
	if !already && h != 0 {
		procPostMessageW.Call(h, wmClose, 0, 0)
	}
}

// SetIconAndTooltip swaps both. It never blocks: the values are stored and the
// window thread applies them when it next runs.
func SetIconAndTooltip(icon []byte, tooltip string) {
	mu.Lock()
	pending = &pendingUpdate{icon: icon, tooltip: tooltip, touchIcon: true}
	h := hwnd
	mu.Unlock()
	if h != 0 {
		procPostMessageW.Call(h, wmRefreshIcon, 0, 0)
	}
}

// SetTooltip changes only the text, leaving the current bitmap in place. The
// snapshot stream fires far more often than the icon variant changes, and
// reloading an .ico for a text update would be pure waste.
func SetTooltip(tooltip string) {
	mu.Lock()
	pending = &pendingUpdate{tooltip: tooltip}
	h := hwnd
	mu.Unlock()
	if h != 0 {
		procPostMessageW.Call(h, wmRefreshIcon, 0, 0)
	}
}

// LastError returns the error that prevented the icon from appearing, if any.
func LastError() error {
	mu.Lock()
	defer mu.Unlock()
	return lastErr
}

// Running reports whether the message loop is active.
func Running() bool {
	mu.Lock()
	defer mu.Unlock()
	return running
}

func registerWindowMessage(name string) uintptr {
	p, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return 0
	}
	r, _, _ := user32.NewProc("RegisterWindowMessageW").Call(uintptr(unsafe.Pointer(p)))
	return r
}

func wndProc(h, message, wParam, lParam uintptr) uintptr {
	switch message {
	case wmTrayCallback:
		// wParam is the icon id, lParam the mouse message.
		switch uint32(lParam) & 0xffff {
		case wmLButtonUp:
			mu.Lock()
			cb := opts.OnLeftClick
			mu.Unlock()
			if cb != nil {
				go cb()
			}
			return 0
		case wmRButtonUp:
			showMenu(h)
			return 0
		}
	case wmRefreshIcon:
		applyPending()
		return 0
	case wmCommand:
		// Fallback for a menu shown without TPM_RETURNCMD. Kept so a future
		// change to the flags cannot silently swallow every command.
		return 0
	case wmClose:
		removeIcon()
		procDestroyWindow.Call(h)
		return 0
	case wmDestroy:
		procPostQuitMessage.Call(0)
		mu.Lock()
		running = false
		mu.Unlock()
		return 0
	default:
		if taskbarCreatedMsg != 0 && message == taskbarCreatedMsg {
			// explorer.exe restarted and dropped every icon in the notification
			// area. Re-add instead of leaving the user with nothing.
			mu.Lock()
			icon, tip := applied, appliedTip
			mu.Unlock()
			_ = addIcon(icon, tip)
			return 0
		}
	}
	r, _, _ := procDefWindowProcW.Call(h, message, wParam, lParam)
	return r
}

func showMenu(h uintptr) {
	mu.Lock()
	build := opts.Menu
	mu.Unlock()
	if build == nil {
		return
	}
	items := build()
	if len(items) == 0 {
		return
	}

	ids, commands := compile(items)
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)
	appendItems(menu, items, ids)

	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	// The owner window must be foreground before the menu is shown, otherwise
	// the menu stays on screen after the user clicks elsewhere.
	procSetForegroundWindow.Call(h)
	cmd, _, _ := procTrackPopupMenuEx.Call(
		menu,
		tpmReturnCmd|tpmRightButton|tpmLeftAlign|tpmTopAlign,
		uintptr(pt.X), uintptr(pt.Y), h, 0,
	)
	// Documented workaround for the "menu does not dismiss" bug when the owner
	// is not a normal foreground window.
	procPostMessageW.Call(h, wmNull, 0, 0)

	if id := commands[uint32(cmd)]; id != "" {
		mu.Lock()
		cb := opts.OnCommand
		mu.Unlock()
		if cb != nil {
			go cb(id)
		}
	}
}

// appendItems fills hMenu from the model, consuming one id per clickable entry.
func appendItems(hMenu uintptr, items []Item, ids []uint32) int {
	used := 0
	take := func() uint32 {
		if used >= len(ids) {
			return 0
		}
		id := ids[used]
		used++
		return id
	}
	for _, item := range items {
		switch item.Kind {
		case Separator:
			take()
			procAppendMenuW.Call(hMenu, mfSeparator, 0, 0)
		case Submenu:
			take()
			sub, _, _ := procCreatePopupMenu.Call()
			if sub == 0 {
				continue
			}
			consumed := appendItems(sub, item.Children, ids[used:])
			used += consumed
			label, _ := syscall.UTF16PtrFromString(item.Label)
			flags := uintptr(mfPopup | mfString)
			if item.Disabled {
				flags |= mfGrayed
			}
			procAppendMenuW.Call(hMenu, flags, sub, uintptr(unsafe.Pointer(label)))
		default:
			id := take()
			label, _ := syscall.UTF16PtrFromString(item.Label)
			flags := uintptr(mfString)
			if item.Kind == Check || item.Kind == Radio {
				if item.Checked {
					flags |= mfChecked
				}
			}
			if item.Disabled {
				flags |= mfGrayed
			}
			if item.Default {
				flags |= mfDefault
			}
			procAppendMenuW.Call(hMenu, flags, uintptr(id), uintptr(unsafe.Pointer(label)))
		}
	}
	return used
}

func applyPending() {
	mu.Lock()
	p := pending
	pending = nil
	mu.Unlock()
	if p == nil {
		return
	}
	mu.Lock()
	if p.touchIcon {
		applied = p.icon
		appliedIcon = 0
	}
	icon := applied
	reuse := !p.touchIcon && appliedIcon != 0
	tipSame := p.tooltip == appliedTip
	appliedTip = p.tooltip
	mu.Unlock()
	if reuse && tipSame {
		return
	}
	_ = modifyIcon(icon, p.tooltip, reuse)
}

func newNotifyIconData() notifyIconData {
	var d notifyIconData
	d.Size = uint32(unsafe.Sizeof(d))
	d.Wnd = hwnd
	d.ID = trayIconID
	d.Flags = nifMessage | nifIcon | nifTip
	d.CallbackMessage = wmTrayCallback
	return d
}

func addIcon(icon []byte, tooltip string) error {
	d := newNotifyIconData()
	h, err := loadIcon(icon)
	if err != nil {
		return err
	}
	mu.Lock()
	appliedIcon = h
	mu.Unlock()
	d.Icon = h
	copyTip(&d, tooltip)
	ok, _, callErr := procShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&d)))
	if ok == 0 {
		return fmt.Errorf("Shell_NotifyIcon(NIM_ADD): %w", callErr)
	}
	return nil
}

func modifyIcon(icon []byte, tooltip string, reuse bool) error {
	d := newNotifyIconData()
	if reuse {
		mu.Lock()
		d.Icon = appliedIcon
		mu.Unlock()
	} else {
		h, err := loadIcon(icon)
		if err != nil {
			return err
		}
		mu.Lock()
		appliedIcon = h
		mu.Unlock()
		d.Icon = h
	}
	copyTip(&d, tooltip)
	ok, _, callErr := procShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(&d)))
	if ok == 0 {
		return fmt.Errorf("Shell_NotifyIcon(NIM_MODIFY): %w", callErr)
	}
	return nil
}

func removeIcon() {
	d := newNotifyIconData()
	procShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&d)))
}

func copyTip(d *notifyIconData, tip string) {
	runes := []rune(tip)
	if len(runes) > maxTooltipChars {
		runes = runes[:maxTooltipChars]
	}
	u, err := syscall.UTF16FromString(string(runes))
	if err != nil {
		return
	}
	copy(d.Tip[:len(d.Tip)-1], u)
}

// loadIcon turns .ico bytes into a HICON.
//
// The bytes go through a temporary file on purpose: LoadImage with
// LR_LOADFROMFILE is the loader the multi-size ICO produced by
// tools/build-icons.py was verified against, and it lets Windows pick the
// bitmap whose size matches the notification area instead of rescaling the
// first frame. The file is deleted as soon as the handle exists; the bitmap is
// already in memory by then.
func loadIcon(icon []byte) (uintptr, error) {
	if len(icon) == 0 {
		return 0, errors.New("托盘图标为空")
	}
	f, err := os.CreateTemp("", "halo-tray-*.ico")
	if err != nil {
		return 0, err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err := f.Write(icon); err != nil {
		f.Close()
		return 0, err
	}
	if err := f.Close(); err != nil {
		return 0, err
	}
	path, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return 0, err
	}
	h, _, callErr := procLoadImageW.Call(
		0,
		uintptr(unsafe.Pointer(path)),
		imageIcon,
		0, 0,
		lrLoadFromFile,
	)
	if h == 0 {
		return 0, fmt.Errorf("LoadImageW(%s): %w", name, callErr)
	}
	return h, nil
}
