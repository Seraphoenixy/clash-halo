package tunservice

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// tunFixture loads the shared TUN inbound fixture.
//
// Using the fixture rather than inline JSON keeps this test and the Dart
// generator pinned to the same bytes: if either side drifts, one of the two
// suites fails instead of the mismatch reaching a user's machine.
func tunFixture(t *testing.T) string {
	t.Helper()
	for _, rel := range []string{
		filepath.Join("..", "..", "..", "..", "tests", "fixtures", "singbox", "tun_inbound.json"),
		filepath.Join("tests", "fixtures", "singbox", "tun_inbound.json"),
	} {
		b, err := os.ReadFile(rel)
		if err == nil {
			return string(b)
		}
	}
	t.Fatal("shared fixture tests/fixtures/singbox/tun_inbound.json not found")
	return ""
}

// configWithTun wraps the fixture inbound in a runnable config.
func configWithTun(t *testing.T, extra string) []byte {
	t.Helper()
	return []byte(`{
  "log": { "level": "warn" }` + extra + `,
  "inbounds": [ ` + tunFixture(t) + ` ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}`)
}

func TestCheckConfigForTunAcceptsFixture(t *testing.T) {
	dataDir := t.TempDir()
	adapter, err := CheckConfigForTun(dataDir, configWithTun(t, ""))
	if err != nil {
		t.Fatalf("fixture config rejected: %v", err)
	}
	if adapter != "clash-halo" {
		t.Fatalf("adapter = %q, want clash-halo", adapter)
	}
}

func TestCheckConfigForTunRejections(t *testing.T) {
	dataDir := t.TempDir()
	cases := []struct {
		name string
		body string
		want error
	}{
		{"empty", "", errEmptyPath},
		{"blank", "   \n", errEmptyPath},
		{"not json", "{nope", nil},
		{"json array", `[]`, nil},
		{
			// Nothing for an elevated process to do, so the service must refuse
			// rather than start a privileged core with no purpose.
			"no tun inbound",
			`{"inbounds":[{"type":"mixed","tag":"in"}],"outbounds":[]}`,
			errNoTunInbound,
		},
		{
			"two tun inbounds",
			`{"inbounds":[{"type":"tun","tag":"a","interface_name":"x"},
			              {"type":"tun","tag":"b","interface_name":"y"}]}`,
			nil,
		},
		{
			"adapter name missing",
			`{"inbounds":[{"type":"tun","tag":"tun-in"}]}`,
			nil,
		},
		{
			// log.output is the one field that makes the elevated core write a
			// file for us; it must not escape the data directory.
			"log.output outside data dir",
			`{"log":{"output":"C:\\Windows\\Temp\\pwn.log"},
			  "inbounds":[{"type":"tun","tag":"tun-in","interface_name":"ok"}]}`,
			errUnsafeConfigField,
		},
		{
			// A relative path is resolved against the data directory, so
			// traversal out of it has to be refused too — otherwise "..\\.."
			// would be an arbitrary write as LocalSystem.
			"relative log.output escaping data dir",
			`{"log":{"output":"..\\..\\pwn.log"},
			  "inbounds":[{"type":"tun","tag":"tun-in","interface_name":"ok"}]}`,
			errUnsafeConfigField,
		},
		{
			// An elevated controller listening on the LAN would hand proxy
			// control to the whole network.
			"controller on all interfaces",
			`{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090"}},
			  "inbounds":[{"type":"tun","tag":"tun-in","interface_name":"ok"}]}`,
			errUnsafeConfigField,
		},
		{
			// A non-tun inbound with no listen binds every interface.
			"mixed inbound without listen",
			`{"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"ok"},
			              {"type":"mixed","tag":"mixed-in"}]}`,
			errUnsafeConfigField,
		},
		{
			"mixed inbound on all interfaces",
			`{"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"ok"},
			              {"type":"mixed","tag":"mixed-in","listen":"0.0.0.0"}]}`,
			errUnsafeConfigField,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := CheckConfigForTun(dataDir, []byte(c.body))
			if err == nil {
				t.Fatal("expected an error")
			}
			if c.want != nil && !errors.Is(err, c.want) {
				t.Fatalf("want %v, got %v", c.want, err)
			}
		})
	}
}

func TestCheckConfigForTunAllowsHarmlessFields(t *testing.T) {
	dataDir := t.TempDir()
	// log.output inside the data directory and a loopback controller are both
	// legitimate: the rule is containment, not prohibition.
	body := `{
  "log": { "level": "info", "output": "core.log" },
  "experimental": { "clash_api": { "external_controller": "127.0.0.1:9090",
                                   "secret": "s" } },
  "inbounds": [ ` + tunFixture(t) + ` ]
}`
	if _, err := CheckConfigForTun(dataDir, []byte(body)); err != nil {
		t.Fatalf("legitimate config rejected: %v", err)
	}
	// A loopback mixed inbound is legitimate.
	mixed := `{"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"ok"},
	                      {"type":"mixed","tag":"mixed-in","listen":"127.0.0.1"}]}`
	if _, err := CheckConfigForTun(dataDir, []byte(mixed)); err != nil {
		t.Fatalf("loopback mixed inbound rejected: %v", err)
	}
	// localhost and [::1] are loopback too.
	for _, ctl := range []string{"localhost:9090", "[::1]:9090", "127.5.5.5:1"} {
		body := `{"experimental":{"clash_api":{"external_controller":"` + ctl + `"}},
		  "inbounds":[{"type":"tun","tag":"tun-in","interface_name":"ok"}]}`
		if _, err := CheckConfigForTun(dataDir, []byte(body)); err != nil {
			t.Errorf("controller %q rejected: %v", ctl, err)
		}
	}
}

func TestCheckConfigForTunRejectsOversize(t *testing.T) {
	dataDir := t.TempDir()
	big := make([]byte, maxConfigBytes+1)
	for i := range big {
		big[i] = ' '
	}
	if _, err := CheckConfigForTun(dataDir, big); err == nil {
		t.Fatal("an oversized config must be refused before parsing")
	}
}

func TestResolveUnderRootRejectsEscapes(t *testing.T) {
	root := t.TempDir()
	ok := filepath.Join(root, "core.log")
	if _, err := resolveUnderRoot(root, ok); err != nil {
		t.Fatalf("path inside root rejected: %v", err)
	}
	relative := filepath.Join("logs", "core.log")
	if got, err := resolveUnderRoot(root, relative); err != nil ||
		!strings.EqualFold(got, filepath.Join(root, relative)) {
		t.Fatalf("relative path: got %q, err %v", got, err)
	}
	for _, bad := range []string{
		filepath.Join(root, "..", "evil.log"),
		`..\..\Windows\Temp\pwn.log`,
		"",
		"   ",
		// A sibling directory sharing the string prefix must not pass.
		filepath.Join(filepath.Dir(root), filepath.Base(root)+"-evil", "x.log"),
	} {
		if _, err := resolveUnderRoot(root, bad); err == nil {
			t.Fatalf("escaping path accepted: %q", bad)
		}
	}
}

func TestIsLoopbackEndpoint(t *testing.T) {
	loop := []string{"127.0.0.1:9090", "localhost:9090", "[::1]:9090", "127.0.0.1", "::1"}
	for _, e := range loop {
		if !isLoopbackEndpoint(e) {
			t.Errorf("isLoopbackEndpoint(%q) = false, want true", e)
		}
	}
	notLoop := []string{"0.0.0.0:9090", "192.168.1.10:9090", ":9090", "", "example.com:9090"}
	for _, e := range notLoop {
		if isLoopbackEndpoint(e) {
			t.Errorf("isLoopbackEndpoint(%q) = true, want false", e)
		}
	}
}

func TestValidateAdapterName(t *testing.T) {
	valid := []string{"clash-halo", "Clash Halo", "tun0", "a"}
	for _, name := range valid {
		if err := validateAdapterName(name); err != nil {
			t.Errorf("validateAdapterName(%q) = %v, want nil", name, err)
		}
	}
	invalid := []string{
		"", "   ", ".", "..",
		`a\b`, "a/b", "a:b", "a*b", "a?b", `a"b`, "a<b", "a>b", "a|b",
		"a\x00b", "a\nb", "a\x7fb",
		strings.Repeat("x", maxAdapterNameLen+1),
	}
	for _, name := range invalid {
		if err := validateAdapterName(name); err == nil {
			t.Errorf("validateAdapterName(%q) = nil, want an error", name)
		}
	}
}
