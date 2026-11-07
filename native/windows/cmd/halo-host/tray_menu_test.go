package main

import (
	"path/filepath"
	"strings"
	"testing"

	"clash-halo/native/windows/internal/app"
	"clash-halo/native/windows/internal/state"
	"clash-halo/native/windows/internal/tray"
)

// TestBuildTrayMenuMatchesVergeLayout pins the top-level shape against Clash
// Verge Rev's tray menu (src-tauri/src/core/tray/mod.rs, create_tray_menu).
//
// The menu cannot be clicked in a test — TrackPopupMenuEx blocks until the user
// picks something — so what is checkable mechanically is also exactly what goes
// wrong when someone edits it carelessly: the order, the labels users reach for
// from muscle memory, and which entries are ticked. Verge's users open this menu
// dozens of times a day and hit 出站模式 third from the top without reading, so a
// reordering is a real regression even though nothing crashes.
func TestBuildTrayMenuMatchesVergeLayout(t *testing.T) {
	a := newTrayTestApp(t)
	a.SetTrayCatalog(app.TrayCatalog{
		Nodes: []app.TrayNode{
			{ID: "n1", Name: "香港 01", Group: "机场 A"},
			{ID: "n2", Name: "日本 01", Group: "机场 B"},
		},
		ActiveNodeID: "n1",
		Profiles: []app.TrayProfile{
			{ID: "p1", Name: "机场 A"},
			{ID: "p2", Name: "机场 B"},
		},
		ActiveProfile: "p1",
	})

	items := buildTrayMenu(a)

	// The exact top-level order Verge uses. Separators are part of the shape:
	// they group 窗口 / 模式 / 订阅+代理 / 开关 / 管理 / 退出.
	wantOrder := []struct {
		label string
		sep   bool
	}{
		{"仪表板", false},
		{"", true},
		{"出站模式（规则）", false},
		{"", true},
		{"订阅", false},
		{"代理", false},
		{"", true},
		{"系统代理", false},
		{"TUN 模式", false},
		{"", true},
		{"轻量模式", false},
		{"打开目录", false},
		{"更多", false},
		{"", true},
		{"退出", false},
	}
	if len(items) != len(wantOrder) {
		t.Fatalf("menu has %d entries, Verge's layout has %d:\n%s",
			len(items), len(wantOrder), describe(items))
	}
	for i, want := range wantOrder {
		got := items[i]
		if want.sep {
			if got.Kind != tray.Separator {
				t.Fatalf("entry %d should be a separator, got %+v", i, got)
			}
			continue
		}
		if got.Label != want.label {
			t.Fatalf("entry %d = %q, want %q", i, got.Label, want.label)
		}
	}

	if last := items[len(items)-1]; last.ID != "quit" || last.Label != "退出" {
		t.Fatalf("last entry = %+v, want 退出 (Verge's label, not 退出（断开代理）)", last)
	}
}

// TestTrayMenuModeSubmenu: Verge puts the three modes in a submenu whose title
// carries the current one, as mutually exclusive radios.
func TestTrayMenuModeSubmenu(t *testing.T) {
	a := newTrayTestApp(t)
	if e := a.SwitchMode(string(state.ModeGlobal)); e != nil {
		t.Fatalf("SwitchMode: %v", e.Message)
	}
	modes := findSubmenu(t, buildTrayMenu(a), "出站模式")
	if modes.Label != "出站模式（全局）" {
		t.Fatalf("mode title = %q", modes.Label)
	}
	// Verge's labels, verbatim.
	want := []string{"规则模式", "全局模式", "直连模式"}
	if len(modes.Children) != len(want) {
		t.Fatalf("mode submenu has %d options", len(modes.Children))
	}
	for i, item := range modes.Children {
		if item.Label != want[i] {
			t.Fatalf("mode[%d] = %q, want %q", i, item.Label, want[i])
		}
		if item.Kind != tray.Radio {
			t.Fatalf("%q is not a radio entry", item.Label)
		}
		if item.Checked != (item.ID == "mode:global") {
			t.Fatalf("%q checked=%v", item.Label, item.Checked)
		}
	}
}

// TestTrayMenuProfilesAndProxies: Verge's 订阅 lists subscriptions with the
// current one ticked, and 代理 nests one submenu per group holding its nodes.
func TestTrayMenuProfilesAndProxies(t *testing.T) {
	a := newTrayTestApp(t)
	a.SetTrayCatalog(app.TrayCatalog{
		Nodes: []app.TrayNode{
			{ID: "n1", Name: "香港 01", Group: "机场 A"},
			{ID: "n2", Name: "香港 02", Group: "机场 A"},
			{ID: "n3", Name: "日本 01", Group: "机场 B"},
			// A pasted link: no subscription, so it belongs to the local group.
			{ID: "n4", Name: "本地 01", Group: ""},
		},
		ActiveNodeID: "n2",
		Profiles: []app.TrayProfile{
			{ID: "p1", Name: "机场 A"},
			{ID: "p2", Name: "机场 B"},
		},
		ActiveProfile: "p1",
	})

	items := buildTrayMenu(a)

	profiles := findSubmenu(t, items, "订阅")
	if len(profiles.Children) != 2 {
		t.Fatalf("订阅 has %d entries", len(profiles.Children))
	}
	if profiles.Children[0].Label != "机场 A" || !profiles.Children[0].Checked {
		t.Fatalf("current profile not ticked: %+v", profiles.Children[0])
	}
	if profiles.Children[1].Checked {
		t.Fatal("only one subscription may be ticked")
	}

	proxies := findSubmenu(t, items, "代理")
	if len(proxies.Children) != 3 {
		t.Fatalf("代理 has %d groups, want 3 (机场 A, 机场 B, 本地)", len(proxies.Children))
	}
	for _, g := range proxies.Children {
		if g.Kind != tray.Submenu {
			t.Fatalf("group %q is not a submenu", g.Label)
		}
	}
	if groupA := proxies.Children[0]; groupA.Label != "机场 A" || len(groupA.Children) != 2 {
		t.Fatalf("first group = %q with %d nodes", groupA.Label, len(groupA.Children))
	}
	// The active node is ticked, and only it.
	var ticked []string
	for _, g := range proxies.Children {
		for _, n := range g.Children {
			if n.Checked {
				ticked = append(ticked, n.Label)
			}
		}
	}
	if len(ticked) != 1 || ticked[0] != "香港 02" {
		t.Fatalf("ticked nodes = %v, want [香港 02]", ticked)
	}
	// The local group is labelled rather than left blank: an empty submenu title
	// is unreadable.
	if local := proxies.Children[2]; local.Label != "本地" {
		t.Fatalf("local group label = %q", local.Label)
	}
}

// TestTrayMenuTogglesAndManagement: the switch block and 更多 must carry every
// entry Verge has an equivalent for, under Verge's labels.
func TestTrayMenuTogglesAndManagement(t *testing.T) {
	a := newTrayTestApp(t)
	items := buildTrayMenu(a)

	for _, id := range []string{"sysproxy", "tun", "lightweight"} {
		if findItem(t, items, id).Kind != tray.Check {
			t.Fatalf("%q is not a check item", id)
		}
	}

	openDir := findSubmenu(t, items, "打开目录")
	wantDirs := []string{"配置目录", "内核目录", "日志目录", "应用日志", "内核日志"}
	if len(openDir.Children) != len(wantDirs) {
		t.Fatalf("打开目录 has %d entries, want %d", len(openDir.Children), len(wantDirs))
	}
	for i, label := range wantDirs {
		if openDir.Children[i].Label != label {
			t.Fatalf("打开目录[%d] = %q, want %q", i, openDir.Children[i].Label, label)
		}
	}

	more := findSubmenu(t, items, "更多")
	wantMore := []string{"复制环境变量", "关闭所有连接", "重启 Clash 内核", "重启应用"}
	if len(more.Children) < len(wantMore)+1 { // +1 for the version entry
		t.Fatalf("更多 has %d entries", len(more.Children))
	}
	for i, label := range wantMore {
		if more.Children[i].Label != label {
			t.Fatalf("更多[%d] = %q, want %q", i, more.Children[i].Label, label)
		}
	}
	// The version entry is present but not clickable, as in Verge.
	version := more.Children[len(more.Children)-1]
	if !version.Disabled {
		t.Fatalf("version entry must be disabled: %+v", version)
	}
}

// TestBuildTrayMenuWithoutNodesKeepsTheEntry: with no published catalogue the
// proxy submenu must still explain itself instead of vanishing, otherwise the
// menu's shape changes depending on whether the UI happens to be running.
func TestBuildTrayMenuWithoutNodesKeepsTheEntry(t *testing.T) {
	a := newTrayTestApp(t)
	var found bool
	for _, item := range buildTrayMenu(a) {
		if item.Label == "代理（打开界面后可切换）" {
			found = true
			if !item.Disabled {
				t.Fatal("the placeholder must be disabled")
			}
		}
	}
	if !found {
		t.Fatal("no proxy placeholder in the menu")
	}
}

func newTrayTestApp(t *testing.T) *app.App {
	t.Helper()
	dir := t.TempDir()
	paths := app.DefaultPaths(dir, filepath.Join(dir, "sing-box.exe"))
	a, err := app.New(paths, "test")
	if err != nil {
		t.Fatalf("app.New: %v", err)
	}
	t.Cleanup(a.Shutdown)
	return a
}

func findSubmenu(t *testing.T, items []tray.Item, prefix string) tray.Item {
	t.Helper()
	for _, item := range items {
		if item.Kind == tray.Submenu && len(item.Label) >= len(prefix) &&
			item.Label[:len(prefix)] == prefix {
			return item
		}
	}
	t.Fatalf("no submenu starting with %q\n%s", prefix, describe(items))
	return tray.Item{}
}

func findItem(t *testing.T, items []tray.Item, id string) tray.Item {
	t.Helper()
	for _, item := range items {
		if item.ID == id {
			return item
		}
		if item.Kind == tray.Submenu {
			if got := findItemQuiet(item.Children, id); got != nil {
				return *got
			}
		}
	}
	t.Fatalf("no menu entry with id %q\n%s", id, describe(items))
	return tray.Item{}
}

func findItemQuiet(items []tray.Item, id string) *tray.Item {
	for i := range items {
		if items[i].ID == id {
			return &items[i]
		}
		if items[i].Kind == tray.Submenu {
			if got := findItemQuiet(items[i].Children, id); got != nil {
				return got
			}
		}
	}
	return nil
}

// describe renders the menu as indented text so a failed assertion shows the
// whole shape rather than one field.
func describe(items []tray.Item) string {
	var b []byte
	var walk func(list []tray.Item, depth int)
	walk = func(list []tray.Item, depth int) {
		for _, item := range list {
			for i := 0; i < depth; i++ {
				b = append(b, ' ', ' ')
			}
			switch item.Kind {
			case tray.Separator:
				b = append(b, '-', '-', '-', '\n')
			default:
				if item.Checked {
					b = append(b, '[', 'x', ']', ' ')
				}
				b = append(b, item.Label...)
				if item.ID != "" {
					b = append(b, " ("...)
					b = append(b, item.ID...)
					b = append(b, ')')
				}
				b = append(b, '\n')
				if item.Kind == tray.Submenu {
					walk(item.Children, depth+1)
				}
			}
		}
	}
	walk(items, 0)
	return string(b)
}

// The state package is imported for its zero-value snapshot semantics used by
// the menu; keep the reference explicit so a future refactor does not silently
// drop the import and change what "idle" means.
var _ = state.CoreStopped

// The two switches are one choice, but the system-proxy entry stays clickable
// while TUN is up: ticking it is how the user switches back to ordinary proxy
// mode. Greying it made TUN the only reachable mode from the menu.
func TestTrayMenuKeepsSystemProxyClickableUnderTUN(t *testing.T) {
	a := newTrayTestApp(t)
	_, _ = a.Store.Update(func(s *state.Snapshot) {
		s.SystemProxy = state.SystemProxy{Supported: true, Enabled: false}
		s.TunState = state.TunEnabled
		s.TunSupported = true
	})

	var sysProxy, tun tray.Item
	for _, item := range buildTrayMenu(a) {
		switch item.ID {
		case "sysproxy":
			sysProxy = item
		case "tun":
			tun = item
		}
	}
	if sysProxy.Disabled {
		t.Fatal("the system proxy must stay clickable: it is how the user leaves TUN")
	}
	if sysProxy.Checked {
		t.Fatal("the system proxy is off while TUN carries the traffic")
	}
	// The consequence is in the label, because the click stops the tunnel.
	if !strings.Contains(sysProxy.Label, "关闭 TUN") {
		t.Fatalf("label %q does not say it stops TUN", sysProxy.Label)
	}
	if !tun.Checked {
		t.Fatal("TUN is the mode in effect and must be ticked")
	}

	// With TUN off the entry returns to Verge's bare label.
	_, _ = a.Store.Update(func(s *state.Snapshot) { s.TunState = state.TunDisabled })
	for _, item := range buildTrayMenu(a) {
		if item.ID == "sysproxy" {
			sysProxy = item
		}
	}
	if sysProxy.Label != "系统代理" {
		t.Fatalf("label = %q, want the bare 系统代理", sysProxy.Label)
	}
	if sysProxy.Disabled {
		t.Fatal("with TUN off the system proxy must be clickable")
	}
}
