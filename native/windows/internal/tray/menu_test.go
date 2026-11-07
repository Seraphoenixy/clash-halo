package tray

import "testing"

// TestCompileAssignsUniqueIDs pins the two properties the Win32 layer depends
// on: every clickable entry gets an id, and no two entries share one. A
// duplicate would make the wrong menu entry run, which is the kind of bug that
// only shows up as "the app switched mode when I clicked Exit".
func TestCompileAssignsUniqueIDs(t *testing.T) {
	items := []Item{
		NormalItem("open", "打开主界面"),
		Sep(),
		SubmenuItem("出站模式",
			RadioItem("mode:rule", "规则", true),
			RadioItem("mode:global", "全局", false),
		),
		Sep(),
		CheckItem("sysproxy", "系统代理", true, false),
		CheckItem("tun", "TUN", false, true),
		Item{Label: "版本 0.1.0", Disabled: true},
		NormalItem("quit", "退出"),
	}

	ids, commands := compile(items)

	// 7 clickable entries: open, rule, global, sysproxy, tun, quit — the
	// disabled version label has no id, so it stays at 0.
	want := map[string]bool{
		"open": true, "mode:rule": true, "mode:global": true,
		"sysproxy": true, "tun": true, "quit": true,
	}
	if len(commands) != len(want) {
		t.Fatalf("got %d commands, want %d: %v", len(commands), len(want), commands)
	}
	seen := map[uint32]bool{}
	for id, name := range commands {
		if seen[id] {
			t.Fatalf("duplicate command id %d", id)
		}
		seen[id] = true
		if !want[name] {
			t.Fatalf("unexpected command %q", name)
		}
	}
	// ids is the flattened walk (parents and children), so it has one slot per
	// entry in the whole tree: 8 top-level items plus the 2 options inside the
	// mode submenu.
	if len(ids) != 10 {
		t.Fatalf("got %d id slots, want 10", len(ids))
	}
	// A separator, a disabled label and a submenu title must never carry an id,
	// or clicking the group heading would fire a command. ids is a depth-first
	// walk, so the check is "as many non-zero slots as real commands".
	assigned := 0
	for _, id := range ids {
		if id != 0 {
			assigned++
		}
	}
	if assigned != len(commands) {
		t.Fatalf("got %d non-zero id slots for %d commands", assigned, len(commands))
	}
}

// TestCompileNestedIdsAreUnambiguous checks that ids from a submenu do not
// collide with the parent menu's, which is the failure mode of a builder that
// numbers each menu from zero independently.
func TestCompileNestedIdsAreUnambiguous(t *testing.T) {
	items := []Item{
		NormalItem("a", "A"),
		SubmenuItem("sub", NormalItem("b", "B"), NormalItem("c", "C")),
		NormalItem("d", "D"),
	}
	_, commands := compile(items)
	names := map[string]int{}
	for _, name := range commands {
		names[name]++
	}
	for _, n := range []string{"a", "b", "c", "d"} {
		if names[n] != 1 {
			t.Fatalf("command %q appears %d times", n, names[n])
		}
	}
}
