package sysproxy

import (
	"os"
	"strings"
	"testing"
)

// Registry writes are skipped unless HALO_ALLOW_REGISTRY_TESTS is set, because
// a unit test must never change the developer's real proxy setting. The
// comparison logic — the part that decides whether a restore may proceed — is
// pure and always tested.
func registryTestsAllowed() bool {
	return os.Getenv("HALO_ALLOW_REGISTRY_TESTS") == "1"
}

func TestSameStateDetectsForeignChange(t *testing.T) {
	applied := State{Enable: true, Server: "127.0.0.1:7890"}
	cases := []struct {
		name     string
		current  State
		wantSame bool
	}{
		{"identical", State{Enable: true, Server: "127.0.0.1:7890"}, true},
		{"whitespace only", State{Enable: true, Server: " 127.0.0.1:7890 "}, true},
		{"scheme prefix", State{Enable: true, Server: "http=127.0.0.1:7890"}, true},
		{"disabled by user", State{Enable: false, Server: "127.0.0.1:7890"}, false},
		{"different port", State{Enable: true, Server: "127.0.0.1:7891"}, false},
		{"different host", State{Enable: true, Server: "10.0.0.1:7890"}, false},
		{"cleared", State{Enable: true, Server: ""}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := sameState(tc.current, applied); got != tc.wantSame {
				t.Fatalf("sameState(%+v) = %v, want %v", tc.current, got, tc.wantSame)
			}
		})
	}
}

func TestBypassIsNotAConflict(t *testing.T) {
	// Another app expanding the bypass list does not change who receives
	// traffic, so it must not block a legitimate restore.
	applied := State{Enable: true, Server: "127.0.0.1:7890", Bypass: DefaultBypass}
	current := State{Enable: true, Server: "127.0.0.1:7890", Bypass: DefaultBypass + ";example.com"}
	if !sameState(current, applied) {
		t.Fatal("bypass change should not count as a conflict")
	}
}

func TestEndpointFormatting(t *testing.T) {
	if got := Endpoint("", 7890); got != "127.0.0.1:7890" {
		t.Fatalf("got %q", got)
	}
	if got := Endpoint("127.0.0.1", 1080); got != "127.0.0.1:1080" {
		t.Fatalf("got %q", got)
	}
}

func TestDefaultBypassCoversLoopback(t *testing.T) {
	// The control API and the UI's own requests must not loop through the
	// tunnel, or applying a broken config would lock the user out.
	for _, want := range []string{"localhost", "127.*", "192.168.*", "<local>"} {
		if !strings.Contains(DefaultBypass, want) {
			t.Fatalf("bypass list missing %q: %s", want, DefaultBypass)
		}
	}
}

func TestNormalizeServer(t *testing.T) {
	if normalizeServer("HTTP=127.0.0.1:1") != "127.0.0.1:1" {
		t.Fatal("scheme prefix not stripped")
	}
	if normalizeServer("127.0.0.1:1") != normalizeServer(" 127.0.0.1:1 ") {
		t.Fatal("trim inconsistent")
	}
}

func TestSupported(t *testing.T) {
	if !Supported() {
		t.Fatal("windows host must report proxy support")
	}
}
