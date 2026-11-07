package tunconfig

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode"
)

// minimalBaseConfig is the shape the host actually writes: a mixed inbound, a
// direct outbound and a route, with no tun anywhere.
const minimalBaseConfig = `{"log":{"level":"warn","timestamp":true},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":17890}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`

// richConfig carries everything a real user config might: extra inbounds and
// outbounds, nested objects, and top-level keys this build does not model.
const richConfig = `{"log":{"level":"warn","timestamp":true},"dns":{"servers":[{"tag":"dns-remote","address":"1.1.1.1"}]},"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}},"future_top_level_key":{"nested":[1,2,3],"deep":{"x":true}},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":17890},{"type":"socks","tag":"socks-in","listen":"127.0.0.1","listen_port":17891}],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"final":"direct","auto_detect_interface":false,"rules":[{"protocol":"dns","outbound":"direct"}],"rule_set":[{"type":"remote","tag":"geosite","url":"https://example.invalid/geosite.srs","download_detour":"direct"}]},"endpoints":[{"type":"wireguard","tag":"wg","address":["10.0.0.2/32"]}]}`

// --- helpers ---------------------------------------------------------------

func docOf(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("not a JSON object: %v\n%s", err, raw)
	}
	return doc
}

func inboundsOf(t *testing.T, doc map[string]any) []any {
	t.Helper()
	raw, ok := doc["inbounds"]
	if !ok {
		return nil
	}
	list, ok := raw.([]any)
	if !ok {
		t.Fatalf("inbounds is %T, want array", raw)
	}
	return list
}

func tunIndexes(list []any) []int {
	var idx []int
	for i, el := range list {
		if m, ok := el.(map[string]any); ok && m["type"] == "tun" {
			idx = append(idx, i)
		}
	}
	return idx
}

func tagsOf(list []any) []string {
	out := make([]string, 0, len(list))
	for _, el := range list {
		m, ok := el.(map[string]any)
		if !ok {
			out = append(out, "<not-an-object>")
			continue
		}
		tag, _ := m["tag"].(string)
		out = append(out, tag)
	}
	return out
}

func mustInject(t *testing.T, in string, opts Options) []byte {
	t.Helper()
	out, err := Inject([]byte(in), opts)
	if err != nil {
		t.Fatalf("Inject: %v", err)
	}
	if !json.Valid(out) {
		t.Fatalf("Inject produced invalid JSON: %s", out)
	}
	return out
}

// readFixture loads the pinned tun inbound fixture.
//
// Relative to this package the repo root is four levels up; the three-level
// path and a bare repo-relative path are tried as well so the test survives
// being run from a different working directory.
func readFixture(t *testing.T) []byte {
	t.Helper()
	candidates := []string{
		filepath.Join("..", "..", "..", "tests", "fixtures", "singbox", "tun_inbound.json"),
		filepath.Join("..", "..", "..", "..", "tests", "fixtures", "singbox", "tun_inbound.json"),
		filepath.Join("tests", "fixtures", "singbox", "tun_inbound.json"),
	}
	for _, candidate := range candidates {
		if b, err := os.ReadFile(candidate); err == nil {
			return b
		}
	}
	t.Fatalf("fixture not found; tried %v", candidates)
	return nil
}

// --- fixture parity --------------------------------------------------------

func TestInjectMatchesFixtureInbound(t *testing.T) {
	var want any
	if err := json.Unmarshal(readFixture(t), &want); err != nil {
		t.Fatalf("fixture is not valid JSON: %v", err)
	}
	out := mustInject(t, minimalBaseConfig, DefaultOptions())
	list := inboundsOf(t, docOf(t, out))
	idx := tunIndexes(list)
	if len(idx) != 1 {
		t.Fatalf("want exactly one tun inbound, got %d in %s", len(idx), out)
	}
	// Compare parsed structures, not bytes: Go sorts map keys when marshalling
	// while the fixture is pretty-printed, so byte comparison would fail for a
	// config that is in fact identical.
	if !reflect.DeepEqual(list[idx[0]], want) {
		t.Errorf("injected tun inbound differs from fixtures/singbox/tun_inbound.json\n got: %#v\nwant: %#v",
			list[idx[0]], want)
	}
}

func TestFixtureAndOutputHaveNoLegacyAddressFields(t *testing.T) {
	fixture := readFixture(t)
	for _, key := range []string{"inet4_address", "inet6_address"} {
		if bytes.Contains(fixture, []byte(key)) {
			t.Errorf("fixture still contains %q, removed in sing-box 1.12.0", key)
		}
	}
	out := mustInject(t, minimalBaseConfig, DefaultOptions())
	for _, key := range []string{"inet4_address", "inet6_address"} {
		if bytes.Contains(out, []byte(key)) {
			t.Errorf("Inject emitted %q, which sing-box 1.14.4 refuses: %s", key, out)
		}
		var parsed any
		if err := json.Unmarshal(fixture, &parsed); err != nil {
			t.Fatalf("fixture: %v", err)
		}
		if m, ok := parsed.(map[string]any); ok {
			if _, present := m[key]; present {
				t.Errorf("fixture declares %q", key)
			}
		}
	}
}

// --- append / replace ------------------------------------------------------

func TestInjectAppendsOrReplacesExactlyOneTun(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string // inbound tags in order, after Inject
	}{
		{
			name: "appends when no tun exists",
			in:   `{"inbounds":[{"type":"mixed","tag":"mixed-in"}]}`,
			want: []string{"mixed-in", TunTag},
		},
		{
			name: "appends when inbounds key is absent",
			in:   `{"outbounds":[{"type":"direct","tag":"direct"}]}`,
			want: []string{TunTag},
		},
		{
			name: "appends when inbounds is empty",
			in:   `{"inbounds":[]}`,
			want: []string{TunTag},
		},
		{
			name: "replaces the first tun in place",
			in:   `{"inbounds":[{"type":"tun","tag":"old-tun","interface_name":"old"},{"type":"mixed","tag":"mixed-in"}]}`,
			want: []string{TunTag, "mixed-in"},
		},
		{
			name: "replaces a tun in the middle",
			in:   `{"inbounds":[{"type":"mixed","tag":"a"},{"type":"tun","tag":"old"},{"type":"socks","tag":"b"}]}`,
			want: []string{"a", TunTag, "b"},
		},
		{
			name: "collapses duplicate tun inbounds",
			in:   `{"inbounds":[{"type":"tun","tag":"one"},{"type":"tun","tag":"two"},{"type":"mixed","tag":"mixed-in"}]}`,
			want: []string{TunTag, "mixed-in"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := mustInject(t, tc.in, DefaultOptions())
			list := inboundsOf(t, docOf(t, out))
			if got := tunIndexes(list); len(got) != 1 {
				t.Fatalf("want exactly one tun inbound, got %d: %s", len(got), out)
			}
			if got := tagsOf(list); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("inbound tags = %v, want %v (%s)", got, tc.want, out)
			}
			// The remaining tun must carry the requested fields, not the old ones.
			tun := list[tunIndexes(list)[0]].(map[string]any)
			if tun["interface_name"] != DefaultOptions().AdapterName {
				t.Errorf("interface_name = %v, want %v", tun["interface_name"], DefaultOptions().AdapterName)
			}
		})
	}
}

func TestInjectRepairsPreviouslyGeneratedDoH(t *testing.T) {
	const base = `{"dns":{"final":"remote","servers":[
		{"type":"https","tag":"remote","server":"https://[2001:db8::1]:8443/custom","detour":"proxy"},
		{"type":"https","tag":"modern","server":"dns.example","path":"/existing"},
		{"type":"udp","tag":"local","server":"223.5.5.5"}
	]}}`
	out := mustInject(t, base, DefaultOptions())
	dns := docOf(t, out)["dns"].(map[string]any)
	want := docOf(t, []byte(`{"final":"remote","servers":[
		{"type":"https","tag":"remote","server":"2001:db8::1","server_port":8443,"path":"/custom","detour":"proxy"},
		{"type":"https","tag":"modern","server":"dns.example","path":"/existing"},
		{"type":"udp","tag":"local","server":"223.5.5.5"}
	]}`))
	if !reflect.DeepEqual(dns, want) {
		t.Fatalf("dns = %#v, want %#v", dns, want)
	}
}

func TestInjectPreservesEverythingElse(t *testing.T) {
	before := docOf(t, []byte(richConfig))
	out := mustInject(t, richConfig, DefaultOptions())
	after := docOf(t, out)

	if len(after) != len(before) {
		t.Errorf("top-level key count changed: %d -> %d (%s)", len(before), len(after), out)
	}
	for key, want := range before {
		if key == "inbounds" || key == "route" {
			continue
		}
		got, ok := after[key]
		if !ok {
			t.Errorf("top-level key %q was dropped", key)
			continue
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("top-level key %q changed\n got: %#v\nwant: %#v", key, got, want)
		}
	}

	if got, want := tagsOf(inboundsOf(t, after)), []string{"mixed-in", "socks-in", TunTag}; !reflect.DeepEqual(got, want) {
		t.Errorf("inbound tags = %v, want %v", got, want)
	}

	beforeRoute := before["route"].(map[string]any)
	afterRoute := after["route"].(map[string]any)
	for key, want := range beforeRoute {
		if key == "auto_detect_interface" {
			continue
		}
		if !reflect.DeepEqual(afterRoute[key], want) {
			t.Errorf("route.%s changed\n got: %#v\nwant: %#v", key, afterRoute[key], want)
		}
	}
	if afterRoute["auto_detect_interface"] != true {
		t.Errorf("route.auto_detect_interface = %v, want true", afterRoute["auto_detect_interface"])
	}

	// Unknown keys must survive a full round trip, which is the point of the
	// package: a config is user data we must not quietly rewrite.
	if !reflect.DeepEqual(after["future_top_level_key"], before["future_top_level_key"]) {
		t.Errorf("unknown top-level key did not survive: %#v", after["future_top_level_key"])
	}
	if !reflect.DeepEqual(after["endpoints"], before["endpoints"]) {
		t.Errorf("endpoints did not survive: %#v", after["endpoints"])
	}
}

func TestInjectSetsAutoDetectInterface(t *testing.T) {
	cases := []struct {
		name string
		in   string
	}{
		{name: "route absent", in: `{"inbounds":[]}`},
		{name: "route null", in: `{"inbounds":[],"route":null}`},
		{name: "route empty", in: `{"inbounds":[],"route":{}}`},
		{name: "route with other keys", in: `{"inbounds":[],"route":{"final":"direct","rules":[{"outbound":"direct"}]}}`},
		{name: "already true", in: `{"inbounds":[],"route":{"auto_detect_interface":true}}`},
		{name: "explicitly false", in: `{"inbounds":[],"route":{"auto_detect_interface":false,"final":"proxy"}}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := mustInject(t, tc.in, DefaultOptions())
			doc := docOf(t, out)
			route, ok := doc["route"].(map[string]any)
			if !ok {
				t.Fatalf("route is %T: %s", doc["route"], out)
			}
			if route["auto_detect_interface"] != true {
				t.Errorf("auto_detect_interface = %v, want true (%s)", route["auto_detect_interface"], out)
			}
			if tc.name == "route with other keys" && route["final"] != "direct" {
				t.Errorf("route.final = %v, want direct", route["final"])
			}
			if tc.name == "explicitly false" && route["final"] != "proxy" {
				t.Errorf("route.final = %v, want proxy", route["final"])
			}
		})
	}
}

func TestInjectDoesNotMutateInput(t *testing.T) {
	for _, in := range []string{minimalBaseConfig, richConfig, `{"inbounds":[{"type":"tun","tag":"old"}]}`} {
		raw := []byte(in)
		snapshot := append([]byte(nil), raw...)
		var before map[string]any
		if err := json.Unmarshal(raw, &before); err != nil {
			t.Fatalf("fixture: %v", err)
		}

		out, err := Inject(raw, DefaultOptions())
		if err != nil {
			t.Fatalf("Inject: %v", err)
		}
		if !bytes.Equal(raw, snapshot) {
			t.Errorf("Inject mutated its input slice:\n got: %s\nwant: %s", raw, snapshot)
		}
		if len(raw) > 0 && len(out) > 0 && &raw[0] == &out[0] {
			t.Error("Inject returned a slice aliasing its input")
		}

		stripped, err := Strip(raw)
		if err != nil {
			t.Fatalf("Strip: %v", err)
		}
		if !bytes.Equal(raw, snapshot) {
			t.Errorf("Strip mutated its input slice:\n got: %s\nwant: %s", raw, snapshot)
		}
		if len(raw) > 0 && len(stripped) > 0 && &raw[0] == &stripped[0] {
			t.Error("Strip returned a slice aliasing its input")
		}

		var after map[string]any
		if err := json.Unmarshal(raw, &after); err != nil {
			t.Fatalf("input no longer parses: %v", err)
		}
		if !reflect.DeepEqual(before, after) {
			t.Errorf("input map changed\n got: %#v\nwant: %#v", after, before)
		}
	}
}

// --- strip -----------------------------------------------------------------

func TestStripRemovesEveryTun(t *testing.T) {
	in := `{"log":{"level":"warn"},"inbounds":[{"type":"tun","tag":"one"},{"type":"mixed","tag":"mixed-in"},{"type":"tun","tag":"two"}],"route":{"final":"direct","auto_detect_interface":true},"future":{"a":1}}`
	before := docOf(t, []byte(in))

	out, err := Strip([]byte(in))
	if err != nil {
		t.Fatalf("Strip: %v", err)
	}
	after := docOf(t, out)

	if got := tunIndexes(inboundsOf(t, after)); len(got) != 0 {
		t.Errorf("tun inbounds remain: %s", out)
	}
	if got, want := tagsOf(inboundsOf(t, after)), []string{"mixed-in"}; !reflect.DeepEqual(got, want) {
		t.Errorf("inbound tags = %v, want %v", got, want)
	}
	if !reflect.DeepEqual(after["route"], before["route"]) {
		t.Errorf("route changed\n got: %#v\nwant: %#v", after["route"], before["route"])
	}
	if !reflect.DeepEqual(after["future"], before["future"]) {
		t.Errorf("unknown key changed: %#v", after["future"])
	}
	if !reflect.DeepEqual(after["log"], before["log"]) {
		t.Errorf("log changed: %#v", after["log"])
	}
	if ok, err := HasTunInbound(out); err != nil || ok {
		t.Errorf("HasTunInbound after Strip = %v, %v", ok, err)
	}
}

func TestStripKeepsEmptyInboundsArray(t *testing.T) {
	out, err := Strip([]byte(`{"inbounds":[{"type":"tun","tag":"one"}],"route":{"final":"direct"}}`))
	if err != nil {
		t.Fatalf("Strip: %v", err)
	}
	doc := docOf(t, out)
	raw, ok := doc["inbounds"]
	if !ok {
		t.Fatalf("inbounds key disappeared: %s", out)
	}
	list, ok := raw.([]any)
	if !ok || list == nil {
		t.Fatalf("inbounds = %#v, want an empty array", raw)
	}
	if len(list) != 0 {
		t.Fatalf("inbounds = %#v, want empty", raw)
	}
}

func TestStripIsNoOpWithoutTun(t *testing.T) {
	for _, in := range []string{
		minimalBaseConfig,
		richConfig,
		`{"outbounds":[]}`,
		`{"inbounds":[]}`,
		`{"inbounds":[{"type":"mixed","tag":"m"}]}`,
	} {
		out, err := Strip([]byte(in))
		if err != nil {
			t.Fatalf("Strip(%s): %v", in, err)
		}
		if string(out) != in {
			t.Errorf("Strip is not a no-op\n got: %s\nwant: %s", out, in)
		}
		if len(out) > 0 && &out[0] == &[]byte(in)[0] {
			t.Error("Strip returned a slice aliasing its input")
		}
	}
}

// --- query helpers ---------------------------------------------------------

func TestHasTunInboundAndAdapterName(t *testing.T) {
	cases := []struct {
		name        string
		in          string
		wantTun     bool
		wantAdapter string
		wantErr     bool
	}{
		{
			name:        "tun present",
			in:          `{"inbounds":[{"type":"mixed","tag":"m"},{"type":"tun","tag":"tun-in","interface_name":"clash-halo"}]}`,
			wantTun:     true,
			wantAdapter: "clash-halo",
		},
		{
			name:    "no tun",
			in:      `{"inbounds":[{"type":"mixed","tag":"m"}]}`,
			wantTun: false,
		},
		{
			name:    "no inbounds key",
			in:      `{"outbounds":[{"type":"direct","tag":"direct"}]}`,
			wantTun: false,
		},
		{
			name:    "inbounds null",
			in:      `{"inbounds":null}`,
			wantTun: false,
		},
		{
			name:    "inbounds empty",
			in:      `{"inbounds":[]}`,
			wantTun: false,
		},
		{
			name:    "tun without interface_name",
			in:      `{"inbounds":[{"type":"tun","tag":"t"}]}`,
			wantTun: true,
		},
		{
			name:        "first tun wins",
			in:          `{"inbounds":[{"type":"tun","tag":"a","interface_name":"first"},{"type":"tun","tag":"b","interface_name":"second"}]}`,
			wantTun:     true,
			wantAdapter: "first",
		},
		{
			name:        "non-object element is skipped",
			in:          `{"inbounds":["junk",{"type":"tun","tag":"t","interface_name":"clash-halo"}]}`,
			wantTun:     true,
			wantAdapter: "clash-halo",
		},
		{
			// The canonical fixture is a bare inbound; wrapped in inbounds it
			// must be recognised as the tun inbound it is.
			name:        "canonical fixture wrapped in inbounds",
			in:          `{"inbounds":[` + string(bytes.TrimSpace(readFixture(t))) + `]}`,
			wantTun:     true,
			wantAdapter: "clash-halo",
		},
		{name: "malformed JSON", in: `{"inbounds":`, wantErr: true},
		{name: "not an object", in: `[1,2]`, wantErr: true},
		{name: "literal null", in: `null`, wantErr: true},
		{name: "empty input", in: ``, wantErr: true},
		{name: "inbounds not an array", in: `{"inbounds":5}`, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotTun, err := HasTunInbound([]byte(tc.in))
			if tc.wantErr {
				if err == nil {
					t.Fatalf("HasTunInbound accepted %s", tc.in)
				}
				if _, err := AdapterName([]byte(tc.in)); err == nil {
					t.Fatalf("AdapterName accepted %s", tc.in)
				}
				return
			}
			if err != nil {
				t.Fatalf("HasTunInbound: %v", err)
			}
			if gotTun != tc.wantTun {
				t.Errorf("HasTunInbound = %v, want %v", gotTun, tc.wantTun)
			}
			adapter, err := AdapterName([]byte(tc.in))
			if err != nil {
				t.Fatalf("AdapterName: %v", err)
			}
			if adapter != tc.wantAdapter {
				t.Errorf("AdapterName = %q, want %q", adapter, tc.wantAdapter)
			}
		})
	}
}

// --- rejections ------------------------------------------------------------

func TestInjectRejectsInvalidOptions(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Options)
		want   error
	}{
		{"empty adapter name", func(o *Options) { o.AdapterName = "" }, ErrInvalidAdapterName},
		{"blank adapter name", func(o *Options) { o.AdapterName = "   " }, ErrInvalidAdapterName},
		{"adapter name with pipe", func(o *Options) { o.AdapterName = "clash|halo" }, ErrInvalidAdapterName},
		{"adapter name with backslash", func(o *Options) { o.AdapterName = `clash\halo` }, ErrInvalidAdapterName},
		{"adapter name with slash", func(o *Options) { o.AdapterName = "clash/halo" }, ErrInvalidAdapterName},
		{"adapter name with colon", func(o *Options) { o.AdapterName = "clash:halo" }, ErrInvalidAdapterName},
		{"adapter name with quote", func(o *Options) { o.AdapterName = `clash"halo` }, ErrInvalidAdapterName},
		{"adapter name with control character", func(o *Options) { o.AdapterName = "clash\nhalo" }, ErrInvalidAdapterName},
		{"adapter name too long", func(o *Options) { o.AdapterName = strings.Repeat("a", MaxAdapterNameBytes+1) }, ErrInvalidAdapterName},
		{"unknown stack", func(o *Options) { o.Stack = "quic" }, ErrInvalidStack},
		{"empty stack", func(o *Options) { o.Stack = "" }, ErrInvalidStack},
		{"uppercase stack", func(o *Options) { o.Stack = "Gvisor" }, ErrInvalidStack},
		{"MTU 100", func(o *Options) { o.MTU = 100 }, ErrInvalidMTU},
		{"MTU 70000", func(o *Options) { o.MTU = 70000 }, ErrInvalidMTU},
		{"MTU 1279", func(o *Options) { o.MTU = MinMTU - 1 }, ErrInvalidMTU},
		{"negative MTU", func(o *Options) { o.MTU = -1 }, ErrInvalidMTU},
		{"address without prefix", func(o *Options) { o.Address = "172.19.0.1" }, ErrInvalidAddress},
		{"address prefix out of range", func(o *Options) { o.Address = "172.19.0.1/33" }, ErrInvalidAddress},
		{"garbage address", func(o *Options) { o.Address = "not-an-address" }, ErrInvalidAddress},
		{"empty address", func(o *Options) { o.Address = "" }, ErrInvalidAddress},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			opts := DefaultOptions()
			tc.mutate(&opts)
			out, err := Inject([]byte(minimalBaseConfig), opts)
			if err == nil {
				t.Fatalf("Inject accepted invalid options: %s", out)
			}
			if !errors.Is(err, tc.want) {
				t.Fatalf("error = %v, want %v", err, tc.want)
			}
			if out != nil {
				t.Errorf("Inject returned bytes alongside an error: %s", out)
			}
			if err := Validate(opts); !errors.Is(err, tc.want) {
				t.Errorf("Validate = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestInjectAcceptsBoundaryOptions(t *testing.T) {
	for _, mtu := range []int{0, MinMTU, MaxMTU} {
		opts := DefaultOptions()
		opts.MTU = mtu
		out := mustInject(t, minimalBaseConfig, opts)
		tun := inboundsOf(t, docOf(t, out))[1].(map[string]any)
		if mtu == 0 {
			if _, present := tun["mtu"]; present {
				t.Errorf("MTU 0 must omit the key, got %#v", tun["mtu"])
			}
			continue
		}
		if tun["mtu"] != float64(mtu) {
			t.Errorf("mtu = %v, want %d", tun["mtu"], mtu)
		}
	}
	for _, stack := range []string{StackSystem, StackGvisor, StackMixed} {
		opts := DefaultOptions()
		opts.Stack = stack
		out := mustInject(t, minimalBaseConfig, opts)
		tun := inboundsOf(t, docOf(t, out))[1].(map[string]any)
		if tun["stack"] != stack {
			t.Errorf("stack = %v, want %s", tun["stack"], stack)
		}
	}
	// An IPv6 prefix is a valid CIDR and must round-trip unchanged.
	opts := DefaultOptions()
	opts.Address = "fdfe:dcba:9876::1/126"
	out := mustInject(t, minimalBaseConfig, opts)
	tun := inboundsOf(t, docOf(t, out))[1].(map[string]any)
	if !reflect.DeepEqual(tun["address"], []any{"fdfe:dcba:9876::1/126"}) {
		t.Errorf("address = %#v", tun["address"])
	}
	// Exactly the byte limit, and spaces inside the name, are both allowed.
	opts = DefaultOptions()
	opts.AdapterName = strings.Repeat("a", MaxAdapterNameBytes)
	mustInject(t, minimalBaseConfig, opts)
	opts.AdapterName = "clash halo"
	mustInject(t, minimalBaseConfig, opts)
	// Surrounding whitespace is trimmed rather than rejected.
	opts.AdapterName = "  clash-halo  "
	opts.Address = "  172.19.0.1/30  "
	out = mustInject(t, minimalBaseConfig, opts)
	tun = inboundsOf(t, docOf(t, out))[1].(map[string]any)
	if tun["interface_name"] != "clash-halo" {
		t.Errorf("interface_name = %v, want clash-halo", tun["interface_name"])
	}
	if !reflect.DeepEqual(tun["address"], []any{"172.19.0.1/30"}) {
		t.Errorf("address = %#v", tun["address"])
	}
}

func TestMalformedInputIsRejectedNotPanicked(t *testing.T) {
	inputs := []string{
		"",
		"   ",
		"not json",
		"{",
		`{"inbounds":`,
		"[1,2]",
		"null",
		`"str"`,
		"42",
		`{"inbounds": 5}`,
		`{"inbounds": {}}`,
		`{"inbounds": "tun"}`,
	}
	for _, in := range inputs {
		if _, err := Inject([]byte(in), DefaultOptions()); err == nil {
			t.Errorf("Inject accepted %q", in)
		}
		if _, err := Strip([]byte(in)); err == nil {
			t.Errorf("Strip accepted %q", in)
		}
		if _, err := HasTunInbound([]byte(in)); err == nil {
			t.Errorf("HasTunInbound accepted %q", in)
		}
		if _, err := AdapterName([]byte(in)); err == nil {
			t.Errorf("AdapterName accepted %q", in)
		}
	}
}

func TestInjectRejectsBrokenRoute(t *testing.T) {
	for _, in := range []string{
		`{"inbounds":[],"route":[]}`,
		`{"inbounds":[],"route":5}`,
		`{"inbounds":[],"route":"direct"}`,
	} {
		if _, err := Inject([]byte(in), DefaultOptions()); err == nil {
			t.Errorf("Inject accepted broken route: %s", in)
		}
	}
}

// --- output shape ----------------------------------------------------------

func TestInjectReturnsCompactJSON(t *testing.T) {
	out := mustInject(t, minimalBaseConfig, DefaultOptions())
	if bytes.ContainsAny(out, "\n\r\t") {
		t.Errorf("output is not compact: %s", out)
	}
}

// --- real core -------------------------------------------------------------

// TestCoreCheckInjectedConfig validates the injected config with the real
// locked core. It is skipped unless HALO_SINGBOX is set, matching the
// repository convention; the fixture parity test above is what guards the
// field names when no binary is available.
func TestCoreCheckInjectedConfig(t *testing.T) {
	core := coreBinary(t)
	out := mustInject(t, minimalBaseConfig, DefaultOptions())

	// The config must live inside the repo: child processes are confined to
	// the workspace, so %TEMP% writes are denied.
	dir := repoScratchDir(t)
	file, err := os.CreateTemp(dir, "tunconfig-core-*.json")
	if err != nil {
		t.Fatalf("create temp config in %s: %v", dir, err)
	}
	path := file.Name()
	defer os.Remove(path)
	if _, err := file.Write(out); err != nil {
		file.Close()
		t.Fatalf("write config: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("close config: %v", err)
	}

	combined, err := exec.Command(core, "check", "-c", path).CombinedOutput()
	if err != nil {
		t.Fatalf("sing-box check failed: %v\nconfig: %s\noutput:\n%s", err, out, combined)
	}
	if len(bytes.TrimSpace(combined)) != 0 {
		t.Fatalf("sing-box check printed output for a valid config:\n%s", combined)
	}
}

// coreBinary resolves HALO_SINGBOX, tolerating an MSYS-style /c/... path.
func coreBinary(t *testing.T) string {
	t.Helper()
	raw := strings.TrimSpace(os.Getenv("HALO_SINGBOX"))
	if raw == "" {
		t.Skip("HALO_SINGBOX is not set; skipping the real sing-box check")
	}
	tried := []string{raw}
	if alt := msysPath(raw); alt != "" {
		tried = append(tried, alt)
	}
	for _, candidate := range tried {
		if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
			abs, err := filepath.Abs(candidate)
			if err == nil {
				return abs
			}
		}
	}
	t.Fatalf("HALO_SINGBOX=%q is not an existing file (tried %v)", raw, tried)
	return ""
}

// repoScratchDir returns a writable directory inside the repository.
func repoScratchDir(t *testing.T) string {
	t.Helper()
	candidates := []string{
		filepath.Join("..", "..", "..", "..", ".tmp"), // repo root
		filepath.Join("..", "..", "..", ".tmp"),       // native/
	}
	for _, candidate := range candidates {
		if err := os.MkdirAll(candidate, 0o755); err != nil {
			continue
		}
		if abs, err := filepath.Abs(candidate); err == nil {
			return abs
		}
	}
	t.Fatalf("no writable scratch directory inside the repo (tried %v)", candidates)
	return ""
}

// msysPath converts "/d/project/x" to "D:\\project\\x", or returns "".
func msysPath(p string) string {
	if len(p) < 3 || p[0] != '/' || p[2] != '/' {
		return ""
	}
	drive := rune(p[1])
	if !unicode.IsLetter(drive) {
		return ""
	}
	return strings.ToUpper(string(drive)) + ":" + filepath.FromSlash(p[2:])
}
