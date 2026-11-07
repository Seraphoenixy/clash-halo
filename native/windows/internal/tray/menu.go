// Package tray implements the notification-area icon for halo-host.
//
// It replaces getlantern/systray, which on Windows cannot tell a left click
// from a right click: its window procedure handles WM_LBUTTONUP and
// WM_RBUTTONUP with the same branch and pops the menu for both
// (systray_windows.go: `case WM_RBUTTONUP, WM_LBUTTONUP: t.showMenu()`). That
// makes "left click opens the window" impossible, and it is exactly the
// behaviour users of Clash Verge Rev expect:
//
//   - left click  → show the main window (or bring it forward, never hide it)
//   - right click → native menu with modes, nodes and toggles
//
// The package therefore owns the window procedure itself. A Win32 menu is a
// finite resource rebuilt from a plain model on every right click, which has a
// useful side effect: check marks and labels are always read from the live
// state instead of being patched after the fact, so a menu can never claim the
// proxy is on when it is off.
package tray

// Kind is the visual and behavioural class of a menu entry.
type Kind int

const (
	// Normal is a plain command.
	Normal Kind = iota
	// Check is an independent on/off toggle drawn with a tick.
	Check
	// Radio is one of a mutually exclusive group drawn with a dot.
	Radio
	// Separator draws a horizontal rule; Label, ID and children are ignored.
	Separator
	// Submenu opens a nested menu built from Children.
	Submenu
)

// Item is one entry in a tray menu.
//
// ID is the stable identity handed back to the callback. It is deliberately a
// string: the menu is rebuilt on every open, so integer command ids are
// transient and callers must not persist them.
type Item struct {
	ID      string
	Label   string
	Kind    Kind
	Checked bool
	// Disabled renders the entry greyed out. It is phrased negatively so the
	// zero value means "clickable", which is the common case.
	Disabled bool
	// Default draws the entry in bold, the Windows convention for the action a
	// double click would perform.
	Default  bool
	Children []Item
}

// Sep draws a horizontal rule between command groups.
func Sep() Item { return Item{Kind: Separator} }

// Normal builds a plain command entry.
func NormalItem(id, label string) Item { return Item{ID: id, Label: label} }

// CheckItem builds an independent toggle.
func CheckItem(id, label string, checked, disabled bool) Item {
	return Item{ID: id, Label: label, Kind: Check, Checked: checked, Disabled: disabled}
}

// RadioItem builds one option of a mutually exclusive group.
func RadioItem(id, label string, checked bool) Item {
	return Item{ID: id, Label: label, Kind: Radio, Checked: checked}
}

// SubmenuItem builds a nested menu.
func SubmenuItem(label string, children ...Item) Item {
	return Item{Label: label, Kind: Submenu, Children: children}
}

// firstCommandID leaves room for the ids Windows reserves for predefined menu
// commands (0 and the 0xE000 range used by system menus).
const firstCommandID = 1000

// compile walks the tree and assigns a command id to every clickable entry.
//
// The returned slice mirrors the input so the Win32 builder can walk ids and
// items together, and the map lets the callback turn the id Windows gives back
// into the caller's stable identity.
func compile(items []Item) (ids []uint32, commands map[uint32]string) {
	commands = make(map[uint32]string)
	ids = make([]uint32, 0, len(items))
	next := uint32(firstCommandID)
	var walk func(list []Item, out *[]uint32)
	walk = func(list []Item, out *[]uint32) {
		for _, item := range list {
			*out = append(*out, 0)
			slot := len(*out) - 1
			if item.Kind == Submenu {
				walk(item.Children, out)
				continue
			}
			if item.Kind == Separator || item.ID == "" {
				continue
			}
			(*out)[slot] = next
			commands[next] = item.ID
			next++
		}
	}
	walk(items, &ids)
	return ids, commands
}
