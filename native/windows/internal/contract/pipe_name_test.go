package contract

import (
	"strings"
	"testing"
)

// TestPipeNameForVectors pins the names that both sides of the boundary must
// agree on.
//
// The UI derives the pipe name itself, so a divergence here does not fail
// loudly in production — it shows up as "the UI cannot find its host". Only the
// Dart side pinned these vectors before, which meant a Go-side change could
// break every real installation without a single Go test failing.
//
// The third vector is the important one. This hash's value is 0x0a8b226546c3c1b3a,
// and PowerShell rendered it with a leading zero ("0a8b…", 17 digits) while Go
// and Dart emit the minimal form ("a8b…", 16 digits). The other two vectors are
// values whose top nibble is non-zero, so they cannot tell the two renderings
// apart — which is exactly how a PowerShell client came to compute a pipe name
// the host had never created.
func TestPipeNameForVectors(t *testing.T) {
	vectors := map[string]string{
		`D:\project\clash-halo`:              "3f9aa21224b50de8",
		"a":                                  "af63dc4c8601ec8c",
		`D:\project\clash-halo\.tmp\rt\data`: "a8b226546c3c1b3a",
		`D:/project/clash-halo/.tmp/rt/data`: "a8b226546c3c1b3a",
	}
	for base, want := range vectors {
		if got, expected := PipeNameFor(base), PipeName+"-"+want; got != expected {
			t.Errorf("PipeNameFor(%q) = %q, want %q", base, got, expected)
		}
	}
	// Guard the point of the third vector directly: the zero-padded rendering
	// must not come back.
	got := PipeNameFor(`D:\project\clash-halo\.tmp\rt\data`)
	if strings.HasSuffix(got, "-0a8b226546c3c1b3a") {
		t.Errorf("pipe name uses the zero-padded hash: %q", got)
	}
}

// TestPipeNameForNormalises covers the equivalences the UI depends on: the same
// directory written differently must reach the same host.
func TestPipeNameForNormalises(t *testing.T) {
	same := []string{
		`D:\project\clash-halo\.tmp\live\data`,
		`D:/project/clash-halo/.tmp/live/data`,
		`d:\PROJECT\clash-halo\.tmp\live\data`,
		`D:\\project\\clash-halo\\.tmp\\live\\data`,
	}
	want := PipeNameFor(same[0])
	for _, s := range same[1:] {
		if got := PipeNameFor(s); got != want {
			t.Errorf("PipeNameFor(%q) = %q, want %q", s, got, want)
		}
	}

	// Different directories must not share a pipe, or two installations would
	// fight over one host.
	if PipeNameFor("a") == PipeNameFor("b") {
		t.Error("distinct directories produced the same pipe name")
	}
	// The empty base keeps the historical name for the default install layout.
	if got := PipeNameFor(""); got != PipeName {
		t.Errorf("PipeNameFor(\"\") = %q, want %q", got, PipeName)
	}
}
