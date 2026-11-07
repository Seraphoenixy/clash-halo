// Command halo-host is the Windows background host for clash-halo.
//
// It owns the sing-box core, the tray icon, the system proxy and the named
// pipe. The Flutter UI is a client that may start and exit freely; the proxy
// keeps running because the host is independent of it.
//
// Subcommands:
//
//	halo-host.exe                 run the host (starts the tray)
//	halo-host.exe --no-tray       run headless (used by tests)
//	halo-host.exe --status        print host status as JSON (diagnostics)
//	halo-host.exe --shutdown      stop the host that owns a data directory
//	halo-host.exe --dir <path>    override the data directory (tests)
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"clash-halo/native/windows/internal/app"
	"clash-halo/native/windows/internal/contract"
	"clash-halo/native/windows/internal/ipc"
	"clash-halo/native/windows/internal/state"
	"clash-halo/native/windows/internal/tray"
)

// hostVersion is stamped at build time via -ldflags; the literal is the
// fallback used by `go run`.
var hostVersion = "0.1.0"

// buildFlavor distinguishes a debug build from a release build in diagnostics.
var buildFlavor = "dev"

func main() {
	noTray := flag.Bool("no-tray", false, "run without the tray icon")
	statusOnly := flag.Bool("status", false, "print host status and exit")
	dir := flag.String("dir", "", "override the data directory")
	exitOnStdinClose := flag.Bool("exit-on-stdin-close", false,
		"exit when stdin closes (used by scripts that pipe a signal)")
	fromUI := flag.Bool("from-ui", false,
		"started by the UI: never open a window when a host already runs")
	silentStart := flag.Bool("silent-start", false,
		"started by Windows at login: restore the proxy and stay in the tray, "+
			"do not open a window")
	shutdownOnly := flag.Bool("shutdown", false,
		"stop the host that owns the data directory and exit")
	flag.Parse()

	base, err := resolveDir(*dir)
	if err != nil {
		fail("无法确定数据目录", err)
	}
	// Handled before the core is located: stopping a running host must not
	// depend on the files this build ships. An installer stops the previous
	// version by running its own --shutdown, and an upgrade that has already
	// deleted or replaced the core would otherwise be unable to shut it down.
	if *shutdownOnly {
		os.Exit(shutdownRunning(base))
	}
	corePath, coreVersion, err := resolveCore()
	if err != nil {
		fail("找不到 sing-box 核心", err)
	}
	paths := app.DefaultPaths(base, corePath)

	if *statusOnly {
		printStatus(base, corePath)
		return
	}

	// One host per user session. A second instance must hand off to the
	// existing one rather than fight over the core and the pipe.
	if acquired, err := acquireSingleInstance(base); err != nil {
		fail("无法创建单实例锁", err)
	} else if !acquired {
		// Another host owns this data directory. Opening the UI is the helpful
		// thing to do only when the *user* started this host; see
		// shouldOpenUIOnHandOff for why the other case is a process storm.
		if shouldOpenUIOnHandOff(*fromUI, *silentStart) {
			launchUI(base)
		}
		fmt.Fprintln(os.Stdout, `{"alreadyRunning":true}`)
		return
	}

	a, err := app.New(paths, hostVersion)
	if err != nil {
		fail("宿主初始化失败", err)
	}
	// Record the version the core binary actually reported. This is the single
	// source the overview and the about panel both read; leaving it unset is
	// what made the overview show a dash while the about panel showed a
	// constant that had nothing to do with the file on disk.
	a.SetCoreVersion(coreVersion)

	descriptor, err := ipc.DescriptorForCurrentUser()
	if err != nil {
		fail("无法生成管道安全描述符", err)
	}
	pipeName := contract.PipeNameFor(base)
	// The quit signal is sent only after host.shutdown's response was written.
	// Closing the pipe from inside the handler raced the reply, so a client that
	// asked the host to stop could receive host.exiting and never the "quitting"
	// acknowledgement it waits for.
	var quitAfterReply func()
	server, err := ipc.Listen(ipc.Options{
		Name:               pipeName,
		Handler:            a.Dispatch,
		StateVersion:       a.Store.StateVersion,
		Seq:                nextSeq(),
		SecurityDescriptor: descriptor,
		OnClientChange:     a.OnClientCount,
		AfterReply: func(action string) {
			if action == contract.ActionHostShutdown && quitAfterReply != nil {
				quitAfterReply()
			}
		},
		OnPanic: func(req *contract.Request, recovered any, stack []byte) {
			// The response is already an internal error; this line is the only
			// durable evidence of what actually went wrong. Never re-panic:
			// the whole point of the boundary is that the host survives.
			a.Log.Writef("[host] panic while handling %s: %v\n%s",
				req.Action, recovered, stack)
		},
	})
	if err != nil {
		fail("管道监听失败", err)
	}
	a.SetEventSink(server.Broadcast)
	server.Serve()
	a.Log.Writef("[host] listening on %s", pipeName)
	a.Log.Writef("[host] version=%s (%s) dir=%s", hostVersion, buildFlavor, base)

	// Any core exit pushes a state change; the snapshot listener forwards it
	// to connected clients so the UI never shows a stale "running".
	a.Store.Subscribe(func(s state.Snapshot) {
		server.Broadcast(contract.EventStateChanged, s)
	})

	// Bring back the core the last session was using, before any client can ask.
	//
	// Deliberately after Serve() so the resume cannot delay the pipe: a UI that
	// connects while the core is still starting sees coreState=starting and the
	// normal "内核启动中" state instead of a connection timeout. Doing it here
	// rather than inside app.New keeps construction free of process side
	// effects, which is what lets the tests build an App without spawning
	// sing-box.
	go func() {
		// One short beat so the tray icon and the pipe exist first: a failing
		// core must be able to report itself to a UI that can actually connect.
		time.Sleep(300 * time.Millisecond)
		a.ResumeCore()
	}()

	done := make(chan struct{})
	var once sync.Once
	shutdown := func() {
		once.Do(func() {
			a.Log.Writef("[host] 收到退出请求")
			server.Broadcast(contract.EventHostExiting, map[string]any{"reason": "shutdown"})
			server.Close()
			a.Shutdown()
			// Leave the tray message loop. Without this the tray mode host
			// finished every shutdown step, closed its log and pipe, and then
			// kept sitting in GetMessage forever: a process that had answered
			// "quitting" but still held the single-instance lock on host.lock.
			// The next UI then failed its --status probe, started a "new" host,
			// and that host opened another UI. Quit is idempotent and harmless
			// in headless mode, where no tray window exists.
			tray.Quit()
			close(done)
		})
	}

	go func() {
		<-a.QuitCh()
		shutdown()
	}()
	// Installed after the goroutine above, so a quit requested before the pipe
	// was ready still terminates the host.
	quitAfterReply = a.RequestQuit

	if *noTray {
		// Headless mode runs until an IPC shutdown request arrives. It must
		// not tie its lifetime to stdin: launched from a service manager or a
		// detached console, stdin is already closed and the host would exit
		// before serving a single request.
		if *exitOnStdinClose {
			go func() {
				_, _ = os.Stdin.Read(make([]byte, 1))
				shutdown()
			}()
		}
		<-done
		return
	}

	// Tray mode from here on. A GUI-subsystem host launched detached has nowhere
	// to write stderr, so a failure inside the tray library is invisible: the
	// process keeps serving the pipe and the user only notices that no icon ever
	// appeared. Point the standard error handle at the host log first — that is
	// where those messages belong anyway.
	captureStderr(paths.HostLog)
	// The tray package reports its own failures through the logger callback
	// passed to tray.Run, so there is no library-owned stderr to redirect any more.

	runTray(a, shutdown, done, base, paths)
}

// runTray owns the notification-area icon and the menu behind it.
//
// This replaces the third-party systray library, which on Windows cannot
// distinguish a left click from a right click: it pops the menu for both. The
// interaction model copied from Clash Verge Rev is explicit about the
// difference — left click opens the window, right click opens the menu — so the
// window procedure has to be ours.
//
// Everything the menu shows is read from the live snapshot at the moment the
// menu is built, never cached: a tick mark that says the system proxy is off
// while traffic is being proxied is worse than no tick mark at all.
func runTray(a *app.App, shutdown func(), done chan struct{}, base string, paths app.Paths) {
	// Track the icon from the first snapshot, and keep tracking it while the
	// window is open. Subscribing before Run means no state transition can slip
	// between the initial paint and the first change.
	//
	// The pre-Run call cannot paint yet (there is no icon), so it only records
	// the variant; OnReady reports what actually went into the notification area.
	applyTrayIcon(a.Store.Snapshot())
	a.Store.Subscribe(func(s state.Snapshot) {
		if applyTrayIcon(s) {
			a.Log.Writef("[host] 托盘图标切换为 %s（%s）", trayIconKey(s), trayTooltip(s))
		}
	})

	err := tray.Run(tray.Options{
		Icon:    trayIcon(a.Store.Snapshot()),
		Tooltip: trayTooltip(a.Store.Snapshot()),
		Menu:    func() []tray.Item { return buildTrayMenu(a) },
		OnLeftClick: func() {
			// Left click toggles: bring the window up, or put it away when it is
			// already the foreground window.
			//
			// Clash Verge Rev does the "show" half only, and its own maintainers
			// flag that as a defect: clicking the icon of a window you are
			// already looking at appears to do nothing. Hiding is safe here
			// because it is ShowWindow(SW_HIDE), not a close — the UI process
			// keeps running and the tray can bring it straight back, whereas the
			// window's X button really does exit the UI.
			toggleMainWindow(base)
		},
		OnCommand: func(id string) { handleTrayCommand(a, base, shutdown, id) },
		OnReady: func(err error) {
			if err != nil {
				// The icon is the only surface the host owns, so a failure here
				// must be readable afterwards: the process may have no console.
				a.Log.Writef("[host] 托盘图标未创建（%s）：%v；后台与界面仍正常工作，只是没有通知区域图标",
					trayEnvironment(), err)
				return
			}
			a.Log.Writef("[host] 托盘图标已应用（%s）", trayIconKey(a.Store.Snapshot()))
		},
	})
	if err != nil {
		// No icon, no quit entry point: fall back to a headless host that the UI
		// can still drive, instead of exiting and taking the proxy with it.
		a.Log.Writef("[host] 托盘不可用（%s）：%v；转为无托盘后台运行", trayEnvironment(), err)
		<-done
		return
	}
	// The message loop ends only when Quit posted WM_CLOSE, which the shutdown
	// path does. Make sure that path has run before the process leaves.
	shutdown()
	exitAfterShutdown(done)
}

// buildTrayMenu renders the menu model from the current state.
//
// The layout is a field-for-field copy of Clash Verge Rev's tray menu
// (src-tauri/src/core/tray/mod.rs, create_tray_menu). Copying the *order* matters
// more than it looks: this menu is used from muscle memory, and Verge's users
// reach for 出站模式 third from the top and 退出 at the very bottom without
// reading. Entries we have no equivalent for are dropped rather than invented;
// entries that map onto a real capability keep Verge's label verbatim so the two
// menus can be compared line by line.
//
//	仪表板
//	─────────
//	出站模式（规则） ▸ 规则模式 / 全局模式 / 直连模式
//	─────────
//	订阅 ▸ {每个订阅}                        当前订阅打勾
//	代理 ▸ {分组} ▸ {节点}                   当前节点打勾
//	─────────
//	☑ 系统代理
//	☑ TUN 模式
//	─────────
//	轻量模式
//	打开目录 ▸ 配置目录 / 内核目录 / 日志目录 / 应用日志 / 内核日志
//	更多 ▸ 复制环境变量 / 关闭所有连接 / 重启 Clash 内核 / 重启应用 / 版本
//	─────────
//	退出
//
// Every entry that carries state shows it as a tick, never as a label that has
// to be read ("停止代理" / "启动代理"): a menu that renames itself is harder to
// scan than one where the ticks move.
func buildTrayMenu(a *app.App) []tray.Item {
	s := a.Store.Snapshot()
	cat := a.TrayCatalog()
	tunOn := s.TunState == state.TunEnabled

	items := []tray.Item{
		tray.NormalItem("open", "仪表板"),
		tray.Sep(),
		tray.SubmenuItem("出站模式（"+modeText(s.Mode)+"）",
			tray.RadioItem("mode:"+string(state.ModeRule), "规则模式", s.Mode == state.ModeRule),
			tray.RadioItem("mode:"+string(state.ModeGlobal), "全局模式", s.Mode == state.ModeGlobal),
			tray.RadioItem("mode:"+string(state.ModeDirect), "直连模式", s.Mode == state.ModeDirect),
		),
		tray.Sep(),
	}

	// 订阅: Verge's 订阅 submenu lists profiles and ticks the current one.
	if len(cat.Profiles) > 0 {
		profileItems := make([]tray.Item, 0, len(cat.Profiles))
		for _, p := range cat.Profiles {
			profileItems = append(profileItems,
				tray.RadioItem("profile:"+p.ID, p.Name, p.ID == cat.ActiveProfile))
		}
		items = append(items, tray.SubmenuItem("订阅", profileItems...))
	}

	// 代理: Verge nests one submenu per proxy group, each holding its nodes.
	// Our groups are subscription names plus a synthetic local group, which is
	// the same shape one level up.
	if len(cat.Nodes) > 0 {
		groups := make([]string, 0, 4)
		byGroup := map[string][]tray.Item{}
		for _, n := range cat.Nodes {
			if _, seen := byGroup[n.Group]; !seen {
				groups = append(groups, n.Group)
			}
			byGroup[n.Group] = append(byGroup[n.Group],
				tray.RadioItem("node:"+n.ID, n.Name, n.ID == cat.ActiveNodeID))
		}
		// A node with no subscription belongs to the local group, which Verge
		// would call the direct/global bucket. Labelling it keeps those nodes
		// reachable instead of dropping them out of the submenu entirely.
		groupMenus := make([]tray.Item, 0, len(groups))
		for _, g := range groups {
			label := g
			if label == "" {
				label = "本地"
			}
			groupMenus = append(groupMenus, tray.SubmenuItem(label, byGroup[g]...))
		}
		items = append(items, tray.SubmenuItem("代理", groupMenus...))
	} else {
		items = append(items, tray.Item{Label: "代理（打开界面后可切换）", Disabled: true})
	}

	items = append(items,
		tray.Sep(),
		// The two switches are one choice: only one core runs, and whichever is
		// ticked owns the mixed inbound. Ticking either turns the other off, so
		// the inactive one is greyed with the reason in its label rather than
		// left clickable and silently cancelling the other.
		systemProxyMenuItem(s, tunOn),
		tray.CheckItem("tun", "TUN 模式", tunOn,
			!s.TunSupported && s.TunState != state.TunEnabled),
		tray.Sep(),
		// 轻量模式 is Verge's "close the window, keep the core". This app's UI
		// process is already independent of the host, so the 检查项 exists to
		// mirror the menu; it is ticked when no UI window is attached.
		tray.CheckItem("lightweight", "轻量模式", a.UIClients() == 0, false),
		tray.SubmenuItem("打开目录",
			tray.NormalItem("open:configs", "配置目录"),
			tray.NormalItem("open:core", "内核目录"),
			tray.NormalItem("open:logs", "日志目录"),
			tray.NormalItem("open:applog", "应用日志"),
			tray.NormalItem("open:corelog", "内核日志"),
		),
		tray.SubmenuItem("更多",
			tray.NormalItem("copy:env", "复制环境变量"),
			tray.NormalItem("conn:closeall", "关闭所有连接"),
			tray.NormalItem("core:restart", "重启 Clash 内核"),
			tray.NormalItem("app:restart", "重启应用"),
			tray.Item{Label: "版本 " + a.HostVersion, Disabled: true},
		),
		tray.Sep(),
		tray.NormalItem("quit", "退出"),
	)
	return items
}

// systemProxyMenuItem renders the Windows-proxy entry.
//
// It stays clickable while TUN is up: ticking it is how the user switches back
// to ordinary proxy mode, and the host stops the tunnel first. Greying it made
// TUN the only reachable mode from this menu.
//
// The label names the consequence, because an entry that quietly stops TUN is a
// large change to trigger from a menu item whose label says "系统代理".
//
// The enabled case keeps the bare label: state is shown by the tick, and the
// menu's own rule is that an entry never renames itself to report it.
func systemProxyMenuItem(s state.Snapshot, tunOn bool) tray.Item {
	if tunOn {
		return tray.CheckItem("sysproxy", "系统代理（点击关闭 TUN）", false,
			!s.SystemProxy.Supported)
	}
	return tray.CheckItem("sysproxy", "系统代理", s.SystemProxy.Enabled, !s.SystemProxy.Supported)
}

// handleTrayCommand runs one menu selection.
//
// It runs on its own goroutine (the tray library spawns it), so anything slow —
// a TUN enable can wait 90 seconds for a UAC answer — does not freeze the icon
// or the message loop.
func handleTrayCommand(a *app.App, base string, shutdown func(), id string) {
	switch {
	case id == "open":
		showMainWindow(base)

	case strings.HasPrefix(id, "mode:"):
		mode := strings.TrimPrefix(id, "mode:")
		// Record the intent immediately so the menu's tick mark follows the
		// click, then let the UI rewrite the config's route rules. The host
		// cannot do that part: the generator lives in Dart.
		if e := a.SwitchMode(mode); e != nil {
			a.Log.Writef("[host] 托盘切换模式失败: %s", e.Message)
			showMainWindow(base)
			return
		}
		if err := a.RequestModeSwitch(mode); err != nil {
			a.Log.Writef("[host] 托盘切换模式失败: %v", err)
		}
		// A running UI applies it in place. With no window open the mode can
		// only take effect once one exists, so open it rather than leaving the
		// menu claiming a mode that traffic does not follow.
		if a.UIClients() == 0 {
			showMainWindow(base)
		}

	case id == "sysproxy":
		enabled := a.Store.Snapshot().SystemProxy.Enabled
		if _, e := a.SetSystemProxy(!enabled); e != nil {
			a.Log.Writef("[host] 托盘切换系统代理失败: %v", e.Message)
			showMainWindow(base)
		}

	case id == "tun":
		enabled := a.Store.Snapshot().TunState == state.TunEnabled
		if _, e := a.SetTun(!enabled); e != nil {
			a.Log.Writef("[host] 托盘切换 TUN 失败: %s", e.Message)
			showMainWindow(base)
		}

	case strings.HasPrefix(id, "node:"):
		// The host cannot build a config from a node; it asks the UI to. When a
		// window is already open the switch happens there quietly — popping the
		// window on every tray node change would make the menu unusable as a
		// remote control. With no window, one has to open for the request to be
		// carried out at all.
		if err := a.RequestNodeSwitch(strings.TrimPrefix(id, "node:")); err != nil {
			a.Log.Writef("[host] 托盘切换节点失败: %v", err)
		}
		if a.UIClients() == 0 {
			showMainWindow(base)
		}

	case strings.HasPrefix(id, "open:"):
		// Verge names these 配置目录 / 内核目录 / 日志目录 / 应用日志 / 内核日志.
		// The last two open the file rather than the folder: "看日志" is what the
		// entry is for, and making the user pick the file out of a directory
		// listing is a step that exists only in this app.
		switch strings.TrimPrefix(id, "open:") {
		case "configs":
			openFolder(a.Paths.Configs)
		case "logs":
			openFolder(a.Paths.Logs)
		case "core":
			openFolder(filepath.Dir(a.Paths.Core))
		case "applog":
			openFile(a.Paths.HostLog)
		case "corelog":
			openFile(a.CoreLogPath())
		}

	case strings.HasPrefix(id, "profile:"):
		// Switching a subscription is a config change like switching a node, so
		// it travels the same route: the generator lives in Dart.
		if err := a.RequestProfileSwitch(strings.TrimPrefix(id, "profile:")); err != nil {
			a.Log.Writef("[host] 托盘切换订阅失败: %v", err)
		}
		if a.UIClients() == 0 {
			showMainWindow(base)
		}

	case id == "conn:closeall":
		if _, e := a.CloseAllConnections(); e != nil {
			a.Log.Writef("[host] 托盘关闭所有连接失败: %s", e.Message)
			showMainWindow(base)
		}

	case id == "copy:env":
		if err := copyProxyEnv(a); err != nil {
			a.Log.Writef("[host] 复制环境变量失败: %v", err)
		}

	case id == "app:restart":
		// Verge's 重启应用 restarts both the window and the core. Here the host
		// is the parent of everything, so the honest equivalent is: start a
		// fresh UI, then shut this host down; the new UI starts a new host.
		launchUI(base)
		shutdown()

	case id == "lightweight":
		// Toggling mirrors Verge: entering lightweight mode closes the window and
		// leaves the core running. Leaving it opens the window again. The tick is
		// derived from whether a UI is attached, so this is a pure UI action.
		if a.UIClients() == 0 {
			showMainWindow(base)
		} else {
			hideMainWindow()
		}

	case id == "core:restart":
		// No Supervisor.Restart exists; stop-then-start is the same sequence the
		// IPC restart handler performs, and it keeps one implementation of the
		// backoff bookkeeping. Going through RestartCore (not the supervisor
		// directly) is what keeps applyMu held for the tray path too.
		if errObj := a.RestartCore(); errObj != nil {
			a.Log.Writef("[host] 托盘重启内核失败: %s", errObj.Message)
		}

	case id == "quit":
		shutdown()
	}
}

// modeText is the short Chinese name used in the mode submenu title, so the
// current mode is readable without opening the submenu.
func modeText(m state.ProxyMode) string {
	switch m {
	case state.ModeGlobal:
		return "全局"
	case state.ModeDirect:
		return "直连"
	default:
		return "规则"
	}
}

// showMainWindow brings the Flutter window forward, starting it if it is not
// running.
//
// The UI is a separate process that the user may have closed while the proxy
// kept running, so "open" has two cases. When the window exists, Windows will
// not always hand it the foreground just because another process asked: the
// topmost-then-normal dance is the standard workaround and the same one Clash
// Verge Rev uses.
func showMainWindow(base string) {
	if hwnd := findMainWindow(); hwnd != 0 {
		const (
			swRestore  = 9
			swShow     = 5
			hwndTop    = uintptr(0xFFFFFFFFFFFFFFFE) // HWND_TOPMOST (-1)
			hwndNoTop  = uintptr(0xFFFFFFFFFFFFFFFD) // HWND_NOTOPMOST (-2)
			swpNoMove  = 0x0002
			swpNoSize  = 0x0001
			swpShowWin = 0x0040
		)
		user32 := syscall.NewLazyDLL("user32.dll")
		_, _, _ = user32.NewProc("ShowWindow").Call(hwnd, swRestore)
		_, _, _ = user32.NewProc("ShowWindow").Call(hwnd, swShow)
		setPos := user32.NewProc("SetWindowPos")
		_, _, _ = setPos.Call(hwnd, hwndTop, 0, 0, 0, 0, swpNoMove|swpNoSize|swpShowWin)
		_, _, _ = setPos.Call(hwnd, hwndNoTop, 0, 0, 0, 0, swpNoMove|swpNoSize|swpShowWin)
		_, _, _ = user32.NewProc("SetForegroundWindow").Call(hwnd)
		return
	}
	// No window yet. It may still be starting (the user's click and the process's
	// first frame are only milliseconds apart), and launching a second copy would
	// leave two windows connected to the same host. Give a starting instance a
	// moment to create its window before deciding it is not there.
	for i := 0; i < 6; i++ {
		time.Sleep(250 * time.Millisecond)
		if hwnd := findMainWindow(); hwnd != 0 {
			_, _, _ = syscall.NewLazyDLL("user32.dll").NewProc("SetForegroundWindow").Call(hwnd)
			return
		}
	}
	launchUI(base)
}

// toggleMainWindow is the left-click action: show the window, or hide it when it
// is already the one the user is looking at.
//
// "Already looking at" is decided by the foreground window rather than by
// IsWindowVisible: a window that is visible but buried under another app should
// be raised, not hidden. Hiding uses SW_HIDE, which leaves the UI process — and
// its unsaved work — alive; the window's close button is a different path that
// exits the process.
func toggleMainWindow(base string) {
	hwnd := findMainWindow()
	if hwnd == 0 {
		showMainWindow(base)
		return
	}
	const swHide = 0
	user32 := syscall.NewLazyDLL("user32.dll")
	foreground, _, _ := user32.NewProc("GetForegroundWindow").Call()
	isVisible, _, _ := user32.NewProc("IsWindowVisible").Call(hwnd)
	if foreground == hwnd && isVisible != 0 {
		_, _, _ = user32.NewProc("ShowWindow").Call(hwnd, swHide)
		return
	}
	showMainWindow(base)
}

// hideMainWindow puts the window away without closing the UI process.
//
// This is what 轻量模式 means in Clash Verge Rev: the window goes away, the core
// and the tray stay. Here the UI process already outlives the window, so hiding
// is enough — and it is deliberately SW_HIDE rather than a close, because the
// window's × button is the path that really exits the UI.
func hideMainWindow() {
	if hwnd := findMainWindow(); hwnd != 0 {
		const swHide = 0
		_, _, _ = syscall.NewLazyDLL("user32.dll").NewProc("ShowWindow").Call(hwnd, swHide)
	}
}

// openFolder reveals a directory in Explorer.
func openFolder(dir string) {
	if dir == "" {
		return
	}
	_ = exec.Command("explorer.exe", dir).Start()
}

// openFile opens a file with its default handler, falling back to revealing it
// in Explorer when there is nothing registered for the extension.
func openFile(path string) {
	if path == "" {
		return
	}
	if _, err := os.Stat(path); err != nil {
		return
	}
	// cmd /c start is what shell-executes the association; rundll32 and
	// ShellExecute both need more plumbing for the same result.
	_ = exec.Command("cmd", "/c", "start", "", path).Start()
}

// copyProxyEnv puts the proxy environment variables on the clipboard, the same
// convenience Clash Verge Rev offers as 复制环境变量.
//
// The endpoint comes from the live snapshot, not a hard-coded 7890: the mixed
// inbound port is user-configurable and a copied variable pointing at a port
// nothing listens on is worse than no entry at all. The clipboard write is
// best-effort because a headless host can legitimately have no clipboard.
func copyProxyEnv(a *app.App) error {
	endpoint := a.Store.Snapshot().SystemProxy.Endpoint
	if endpoint == "" {
		endpoint = "127.0.0.1:7890"
	}
	// Both spellings: Unix tools read lower case, Windows-native ones upper.
	text := strings.Join([]string{
		"export http_proxy=http://" + endpoint,
		"export https_proxy=http://" + endpoint,
		"set HTTP_PROXY=http://" + endpoint,
		"set HTTPS_PROXY=http://" + endpoint,
	}, "\r\n")
	if err := clipboardWrite(text); err != nil {
		return err
	}
	a.Log.Writef("[host] 已复制代理环境变量 (%s)", endpoint)
	return nil
}

// clipboardWrite puts s on the Windows clipboard.
//
// CF_UNICODETEXT wants CRLF line endings; a bare newline copy pastes as one
// long line in every Windows editor.
func clipboardWrite(text string) error {
	const (
		cfUnicodeText = 13
		gmemMoveable  = 0x0002
	)
	user32 := syscall.NewLazyDLL("user32.dll")
	kernel32dll := syscall.NewLazyDLL("kernel32.dll")
	openClipboard := user32.NewProc("OpenClipboard")
	emptyClipboard := user32.NewProc("EmptyClipboard")
	setClipboardData := user32.NewProc("SetClipboardData")
	closeClipboard := user32.NewProc("CloseClipboard")
	globalAlloc := kernel32dll.NewProc("GlobalAlloc")
	globalLock := kernel32dll.NewProc("GlobalLock")
	globalUnlock := kernel32dll.NewProc("GlobalUnlock")
	globalFree := kernel32dll.NewProc("GlobalFree")
	rtlMoveMemory := kernel32dll.NewProc("RtlMoveMemory")

	utf16, err := syscall.UTF16FromString(text)
	if err != nil {
		return err
	}
	size := uintptr(len(utf16) * 2)

	if ok, _, callErr := openClipboard.Call(0); ok == 0 {
		return fmt.Errorf("OpenClipboard: %w", callErr)
	}
	defer closeClipboard.Call()
	emptyClipboard.Call()

	h, _, callErr := globalAlloc.Call(gmemMoveable, size)
	if h == 0 {
		return fmt.Errorf("GlobalAlloc: %w", callErr)
	}
	ptr, _, callErr := globalLock.Call(h)
	if ptr == 0 {
		globalFree.Call(h)
		return fmt.Errorf("GlobalLock: %w", callErr)
	}
	// Copy the UTF-16 code units, terminator included, while the block is
	// still locked. The previous order unlocked first and then wrote through
	// the returned pointer, which is undefined behaviour: GlobalUnlock may
	// move the block, so the copy could land in freed memory.
	//
	// RtlMoveMemory rather than a Go copy: the destination is an HGlobal, i.e.
	// Windows memory, and turning that uintptr back into a Go pointer is exactly
	// the conversion vet (correctly) refuses to accept. Handing both addresses
	// to the API keeps the operation on the Windows side, and the Go source
	// pointer only has to stay alive for the duration of this call, which the
	// runtime guarantees.
	_, _, _ = rtlMoveMemory.Call(
		ptr,
		uintptr(unsafe.Pointer(&utf16[0])),
		size,
	)
	globalUnlock.Call(h)
	if ok, _, callErr := setClipboardData.Call(cfUnicodeText, h); ok == 0 {
		// Ownership never transferred, so the block is still ours to free.
		globalFree.Call(h)
		return fmt.Errorf("SetClipboardData: %w", callErr)
	}
	return nil
}

// mainWindowTitle must match the title the Flutter runner creates.
//
// The two live in different toolchains (apps/flutter/windows/runner/main.cpp
// passes L"Clash Halo" to Create) and nothing else connects them; the tray
// finding no window would silently start a second instance instead of focusing
// the running one.
const mainWindowTitle = "Clash Halo"

func findMainWindow() uintptr {
	name, err := syscall.UTF16PtrFromString(mainWindowTitle)
	if err != nil {
		return 0
	}
	h, _, _ := syscall.NewLazyDLL("user32.dll").NewProc("FindWindowW").Call(
		0, uintptr(unsafe.Pointer(name)))
	return h
}

// exitTimeout bounds how long the process keeps running after a shutdown was
// requested. The system-proxy restore and the TUN teardown are the slow parts
// and both already have their own timeouts; this is the last line of defence
// against a wedged tray loop leaving a zombie host behind.
const exitTimeout = 20 * time.Second

// shutdownReplyTimeout is how long --shutdown waits for the host to acknowledge
// the request, and shutdownExitTimeout how long it then waits for the process
// to finish tearing down. exitAfterShutdown above gives the host 20s after the
// request; the exit wait stays above that so a host that is within its own
// budget is never declared stuck.
const (
	shutdownReplyTimeout = 30 * time.Second
	shutdownExitTimeout  = 30 * time.Second
)

// exitAfterShutdown terminates the process once the shutdown path finished and
// never returns. It exists because "stop the host" must mean "no process left",
// not "no pipe left": a zombie host still owns host.lock, so the next launch
// sees no running host and starts a second one on top of it.
func exitAfterShutdown(done <-chan struct{}) {
	select {
	case <-done:
	case <-time.After(exitTimeout):
	}
	// os.Exit skips deferred calls, so the log and the state were already
	// flushed inside shutdown. Waiting a beat lets systray's WM_CLOSE teardown
	// delete the tray icon first; a hard exit before that leaves a dead icon in
	// the notification area until the user hovers over it.
	time.Sleep(250 * time.Millisecond)
	os.Exit(0)
}

// trayTooltip is the icon's one-line answer, and it has to agree with the icon
// colour above it: a green icon next to "代理已停止", or a violet icon next to
// "代理运行中", is the kind of inconsistency that makes a user distrust every
// other status in the app.
//
// The icon colour tracks the switches the user threw (system proxy / TUN), so
// the tooltip does too and reports core health *inside* that answer. A core that
// failed while the system proxy points at it is the worst state to be in, and
// "代理异常" has to say so instead of hiding behind the green icon.
func trayTooltip(s state.Snapshot) string {
	node := s.ActiveNodeName
	named := func(prefix string) string {
		if node == "" {
			return prefix
		}
		return prefix + "：" + node
	}

	switch {
	case s.TunState == state.TunEnabled && s.CoreState == state.CoreFailed:
		return "TUN 已开但内核异常：" + s.LastErrorMsg
	case s.TunState == state.TunEnabled:
		return named("TUN 已接管全部流量")
	case s.SystemProxy.Enabled && s.CoreState == state.CoreFailed:
		return "系统代理已开但内核异常：" + s.LastErrorMsg
	case s.SystemProxy.Enabled:
		return named("代理运行中")
	case s.CoreState == state.CoreFailed:
		return "内核异常：" + s.LastErrorMsg
	case s.CoreState == state.CoreRunning:
		// The common case: the UI started the core, the user has not turned on
		// the system proxy or TUN. Traffic is not being proxied, and the violet
		// icon above says exactly that.
		return "内核运行中，系统代理未开启"
	default:
		return "代理已停止"
	}
}

func nextSeq() func() int64 {
	var mu sync.Mutex
	var n int64
	return func() int64 {
		mu.Lock()
		defer mu.Unlock()
		n++
		return n
	}
}

func resolveDir(override string) (string, error) {
	if override != "" {
		return override, nil
	}
	if v := os.Getenv("HALO_DATA_DIR"); v != "" {
		return v, nil
	}
	if exe, err := os.Executable(); err == nil {
		if _, err := os.Stat(filepath.Join(filepath.Dir(exe), "portable.flag")); err == nil {
			return filepath.Join(filepath.Dir(exe), "user-data"), nil
		}
	}
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, "AppData", "Local", "clash-halo"), nil
	}
	return filepath.Join(base, "clash-halo"), nil
}

// resolveCore locates sing-box.exe next to the host, falling back to a bundled
// subdirectory. A missing core is fatal: starting without it would let the
// host claim a proxy is running when nothing is.
// resolveCore locates the sing-box binary.
//
// The candidate list deliberately never includes the UI executable. An earlier
// version listed the UI binary first, so in a packaged layout — where the UI,
// halo-host.exe and sing-box.exe share one directory — the host adopted its own
// user interface as the proxy core. Every core operation then failed with an
// error that pointed at the config rather than at the real mistake, and TUN was
// doubly broken because the elevated TUN service refuses a core not named
// sing-box.exe.
//
// The candidate is also probed, so a path that merely exists can no longer
// masquerade as the core.
// resolveCore finds a real sing-box and reports both its path and version.
// A version of "" means the binary answered but its output was not parsable;
// callers must render that as unknown rather than substituting a constant.
func resolveCore() (string, string, error) {
	if v := os.Getenv("HALO_SINGBOX"); v != "" {
		if _, err := os.Stat(v); err != nil {
			return "", "", fmt.Errorf("HALO_SINGBOX 指向的文件不存在: %s", v)
		}
		return assertCore(v)
	}
	exe, err := os.Executable()
	if err != nil {
		return "", "", err
	}
	dir := filepath.Dir(exe)
	var tried []string
	for _, candidate := range []string{
		filepath.Join(dir, contract.CoreExecutable),
		filepath.Join(dir, "core", contract.CoreExecutable),
		filepath.Join(dir, "..", "core", contract.CoreExecutable),
	} {
		tried = append(tried, candidate)
		if _, err := os.Stat(candidate); err == nil {
			return assertCore(filepath.Clean(candidate))
		}
	}
	return "", "", fmt.Errorf("未找到 %s（已检查：%s）",
		contract.CoreExecutable, strings.Join(tried, "、"))
}

// assertCore proves that a candidate really is sing-box, and reports the
// version string it printed.
//
// The version is returned rather than discarded because it is the only honest
// source for what the UI calls 「内核版本」. The about panel used to show a
// hard-coded `sing-box 1.14.4`, which was a claim about the build that produced
// the app rather than about the binary actually on disk — and the overview card
// showed a dash for the same field, so the two disagreed.
func assertCore(path string) (string, string, error) {
	if !strings.EqualFold(filepath.Base(path), contract.CoreExecutable) {
		return "", "", fmt.Errorf("%s 不是 %s：内核文件名必须完全一致",
			path, contract.CoreExecutable)
	}
	// A timeout is defence in depth: even a correctly named binary must not be
	// able to hang the host at startup.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "version")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", "", fmt.Errorf("%s 不是可用的 sing-box 内核: %w", path, err)
	}
	text := string(out)
	if !strings.Contains(text, "sing-box version") {
		return "", "", fmt.Errorf("%s 不是 sing-box 内核（其版本输出无法识别）", path)
	}
	return path, parseCoreVersion(text), nil
}

// parseCoreVersion extracts the version token from `sing-box version` output.
//
// The first line is `sing-box version 1.14.4`, optionally followed by build
// tags in parentheses. Returning just the number keeps the UI free to decide
// how to label it; an unparsable output yields "" so the caller can say
// 「版本未知」 instead of inventing one.
func parseCoreVersion(out string) string {
	for _, line := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(line)
		rest, ok := strings.CutPrefix(trimmed, "sing-box version ")
		if !ok {
			continue
		}
		// Stop at whitespace: build metadata after the number is not part of
		// the version the user asked about.
		if fields := strings.Fields(rest); len(fields) > 0 {
			return fields[0]
		}
	}
	return ""
}

// shouldOpenUIOnHandOff decides what a losing second instance does.
//
// Opening the UI is right when the user started the host and asked to see the
// app. It is catastrophic when the *UI* started the host: the UI is already
// running, so the new window is pure duplication, and because a duplicated
// window in turn tries to start a host, the two sides launch each other forever.
// That is not hypothetical — it produced a new UI process roughly every two
// seconds until the desktop had dozens of them.
//
// A login start is in the same category as a UI start for the opposite reason:
// Windows launched this at sign-in, the user did not ask to see anything, and a
// window popping up at every boot is the classic complaint about proxy clients
// that auto-start.
func shouldOpenUIOnHandOff(fromUI, silentStart bool) bool {
	if silentStart {
		return false
	}
	return !fromUI
}

// acquireSingleInstance takes an exclusive lock file for the data directory.
// The handle is intentionally never released: closing the process releases it
// and the OS reclaims the lock even after a crash.
var lockHandle syscall.Handle

func acquireSingleInstance(base string) (bool, error) {
	path := filepath.Join(base, "host.lock")
	_ = os.MkdirAll(base, 0o700)
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return false, err
	}
	h, err := syscall.CreateFile(p, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0,
		nil, syscall.OPEN_ALWAYS, syscall.FILE_ATTRIBUTE_HIDDEN, 0)
	if err != nil {
		// ERROR_SHARING_VIOLATION (32) means another host holds the lock.
		if errno, ok := err.(syscall.Errno); ok && errno == 32 {
			return false, nil
		}
		return false, err
	}
	lockHandle = h
	return true, nil
}

// launchUI starts the Flutter UI next to the host, ignoring failure because the
// user may prefer launching it themselves.
// uiExecutable is the file name of the Flutter UI, which the tray launches.
//
// The two names live in different toolchains — this Go constant and the
// BINARY_NAME variable in apps/flutter/windows/CMakeLists.txt — and nothing else
// connects them. They had already drifted once: the tray looked for
// clash-halo.exe while Flutter built halo.exe, so "open the UI" from the tray
// menu did nothing at all, silently. TestUIBinaryNameMatchesBuild now pins them
// together.
const uiExecutable = "clash-halo.exe"

// uiCandidates lists where the UI may sit relative to the host.
func uiCandidates(dir string) []string {
	return []string{
		filepath.Join(dir, uiExecutable),
		filepath.Join(dir, "ui", uiExecutable),
		filepath.Join(dir, "..", uiExecutable),
	}
}

func launchUI(base string) {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	dir := filepath.Dir(exe)
	for _, candidate := range uiCandidates(dir) {
		if _, err := os.Stat(candidate); err == nil {
			cmd := exec.Command(candidate)
			// The UI must open on the *same* data directory as the host that is
			// already running, otherwise it would start a second host with its
			// own pipe and show an empty state.
			cmd.Env = append(os.Environ(), "HALO_DATA_DIR="+base)
			cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: false}
			if err := cmd.Start(); err == nil {
				go func() { _ = cmd.Wait() }()
				return
			}
		}
	}
	_ = base
}

// printStatus queries a running host through the pipe, or reports that none is
// running. Used by diagnostics and the release validation script.
func printStatus(base, corePath string) {
	timeout := 2 * time.Second
	conn, err := dialPipe(contract.PipeNameFor(base), timeout)
	if err != nil {
		out, _ := json.Marshal(map[string]any{
			"running": false,
			"reason":  err.Error(),
			"dir":     base,
			"core":    corePath,
		})
		fmt.Println(string(out))
		return
	}
	defer func() { _ = conn.Close() }()
	_ = conn.SetDeadline(time.Now().Add(timeout))
	req, _ := json.Marshal(contract.Request{
		V: contract.ProtocolVersion, ID: "status", Action: contract.ActionHostStatus,
	})
	_, _ = conn.Write(append(req, '\n'))
	var resp contract.Response
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		out, _ := json.Marshal(map[string]any{"running": false, "reason": err.Error()})
		fmt.Println(string(out))
		return
	}
	out, _ := json.Marshal(map[string]any{"running": true, "response": resp})
	fmt.Println(string(out))
}

// dialPipe is a tiny local wrapper so main need not import go-winio directly
// for the two diagnostic call sites.
func dialPipe(name string, timeout time.Duration) (net.Conn, error) {
	return winioDial(name, timeout)
}

// shutdownRunning asks the host that owns base to stop, waits for the process to
// disappear, and returns a process exit code: 0 when no host is left, 1 when one
// is still running.
//
// This is what the installer and the uninstaller call before replacing or
// deleting files. Terminating the process from outside (taskkill, or NSIS
// killing it) skips App.Shutdown: the system proxy stays pointed at a stopped
// core, so the machine loses its network the moment the uninstaller finishes.
// The host already has a shutdown path that restores the proxy and stops the
// core; this only asks it to run.
//
// "No host" is success, not an error: the installer calls this on a first
// install too, and a failing exit code there would abort an otherwise fine
// installation.
func shutdownRunning(base string) int {
	name := contract.PipeNameFor(base)
	conn, err := dialPipe(name, 2*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stdout, `{"stopped":false,"reason":"not-running"}`)
		return 0
	}
	_ = conn.SetDeadline(time.Now().Add(shutdownReplyTimeout))
	req, _ := json.Marshal(contract.Request{
		V: contract.ProtocolVersion, ID: "shutdown", Action: contract.ActionHostShutdown,
	})
	if _, err := conn.Write(append(req, '\n')); err != nil {
		_ = conn.Close()
	} else {
		// Read until the reply is in: the host broadcasts state changes and its
		// own host.exiting event on the same stream, so the first line is not
		// necessarily the answer. A read failure means the host went away, which
		// is the outcome asked for.
		decoder := json.NewDecoder(conn)
		for {
			var frame map[string]json.RawMessage
			if err := decoder.Decode(&frame); err != nil {
				break
			}
			if _, isReply := frame["ok"]; isReply {
				break
			}
		}
		_ = conn.Close()
	}

	// The reply is written before the teardown runs, so it does not mean the
	// process is gone. Wait for the pipe to stop accepting connections: a host
	// that closed it has finished, and one that still listens is not ours to
	// kill.
	deadline := time.Now().Add(shutdownExitTimeout)
	for time.Now().Before(deadline) {
		if _, err := dialPipe(name, time.Second); err != nil {
			fmt.Fprintln(os.Stdout, `{"stopped":true}`)
			return 0
		}
		time.Sleep(250 * time.Millisecond)
	}
	fmt.Fprintf(os.Stderr, "宿主在 %s 内没有退出：%s\n", shutdownExitTimeout, name)
	return 1
}

// captureStderr points the standard error handle at path.
//
// The host is a GUI-subsystem binary and is normally started detached, so it has
// no console and anything written to stderr is lost. The tray package reports
// its failures through its logger callback rather than by printing, but any
// other library that writes to stderr still lands in the host log this way.
func captureStderr(path string) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	// STD_ERROR_HANDLE is the pseudo-handle (DWORD)-12; syscall does not export
	// SetStdHandle, so the kernel32 entry point is called directly.
	const stdErrorHandle = uintptr(0xFFFFFFF4)
	setStdHandle := syscall.NewLazyDLL("kernel32.dll").NewProc("SetStdHandle")
	if r, _, _ := setStdHandle.Call(stdErrorHandle, f.Fd()); r == 0 {
		_ = f.Close()
		return
	}
	// Both the Go-level value and the OS handle now point at the log, so writes
	// through either route land in the same file.
	os.Stderr = f
}

// trayEnvironment summarises what the tray call depends on: the process
// integrity level (a low-integrity process may not add icons at all), the window
// station and desktop (a process on a non-interactive desktop has no tray), and
// whether the shell's taskbar window is reachable from here. All three change
// what "access denied" means, so the failure line carries them.
func trayEnvironment() string {
	parts := []string{
		"integrity=" + tokenIntegrityName(),
		"desktop=" + windowStationAndDesktop(),
		"taskbar=" + shellTaskbar(),
	}
	return strings.Join(parts, " ")
}

// tokenIntegrityName reads the integrity RID from the process token.
func tokenIntegrityName() string {
	advapi32 := syscall.NewLazyDLL("advapi32.dll")
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	const (
		tokenQuery          = 0x0008
		tokenIntegrityLevel = 25
	)
	proc, _, _ := kernel32.NewProc("GetCurrentProcess").Call()
	var token uintptr
	if ok, _, _ := advapi32.NewProc("OpenProcessToken").Call(
		proc, tokenQuery, uintptr(unsafe.Pointer(&token))); ok == 0 {
		return "unknown"
	}
	defer func() { _ = syscall.CloseHandle(syscall.Handle(token)) }()

	getInfo := advapi32.NewProc("GetTokenInformation")
	var needed uint32
	_, _, _ = getInfo.Call(token, tokenIntegrityLevel, 0, 0, uintptr(unsafe.Pointer(&needed)))
	if needed == 0 {
		return "unknown"
	}
	buf := make([]byte, needed)
	if ok, _, _ := getInfo.Call(token, tokenIntegrityLevel,
		uintptr(unsafe.Pointer(&buf[0])), uintptr(needed),
		uintptr(unsafe.Pointer(&needed))); ok == 0 {
		return "unknown"
	}
	// TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes } }
	// Keep the SID as an unsafe.Pointer and step through it with unsafe.Add:
	// casting a computed uintptr back to a pointer is what vet rightly flags.
	sid := *(*unsafe.Pointer)(unsafe.Pointer(&buf[0]))
	if sid == nil {
		return "unknown"
	}
	count := *(*byte)(unsafe.Add(sid, 1))
	if count == 0 {
		return "unknown"
	}
	rid := *(*uint32)(unsafe.Add(sid, 8+uintptr(count-1)*4))
	switch rid {
	case 0x1000:
		return "Low"
	case 0x2000:
		return "Medium"
	case 0x2100:
		return "MediumPlus"
	case 0x3000:
		return "High"
	case 0x4000:
		return "System"
	}
	return fmt.Sprintf("%#x", rid)
}

// windowStationAndDesktop names the window station and desktop this thread is on.
func windowStationAndDesktop() string {
	user32 := syscall.NewLazyDLL("user32.dll")
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	winsta, _, _ := user32.NewProc("GetProcessWindowStation").Call()
	tid, _, _ := kernel32.NewProc("GetCurrentThreadId").Call()
	desk, _, _ := user32.NewProc("GetThreadDesktop").Call(tid)
	return userObjectName(winsta) + `\` + userObjectName(desk)
}

// userObjectName resolves the UOI_NAME of a window station or desktop handle.
func userObjectName(h uintptr) string {
	if h == 0 {
		return "?"
	}
	buf := make([]uint16, 256)
	var needed uint32
	proc := syscall.NewLazyDLL("user32.dll").NewProc("GetUserObjectInformationW")
	ok, _, _ := proc.Call(h, 2 /*UOI_NAME*/, uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf)*2), uintptr(unsafe.Pointer(&needed)))
	if ok == 0 {
		return "?"
	}
	return windows.UTF16ToString(buf)
}

// shellTaskbar reports whether Explorer's taskbar window is visible from this
// process, which is a prerequisite for adding a notification icon.
func shellTaskbar() string {
	name, _ := syscall.UTF16PtrFromString("Shell_TrayWnd")
	h, _, _ := syscall.NewLazyDLL("user32.dll").NewProc("FindWindowW").Call(
		uintptr(unsafe.Pointer(name)), 0)
	if h == 0 {
		return "not-found"
	}
	return "found"
}

func fail(msg string, err error) {
	fmt.Fprintf(os.Stderr, "%s: %v\n", msg, err)
	os.Exit(1)
}
