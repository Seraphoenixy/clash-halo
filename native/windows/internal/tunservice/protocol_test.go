package tunservice

import (
	"encoding/json"
	"strings"
	"testing"

	"clash-halo/native/windows/internal/contract"
)

// The two packages derive pipe names with the same algorithm on purpose: a
// divergence would make the host talk to the wrong installation.
func TestPipeNameMatchesContractSuffix(t *testing.T) {
	t.Parallel()
	bases := []string{
		"",
		`C:\Users\x\AppData\Local\clash-halo`,
		`D:/project/clash-halo/build/windows-x64/user-data/`,
		`C:\Mixed\Case\Data`,
	}
	for _, base := range bases {
		got := strings.TrimPrefix(PipeNameFor(base), PipePrefix)
		want := strings.TrimPrefix(contract.PipeNameFor(base), contract.PipeName)
		if got != want {
			t.Errorf("base %q: suffix %q, contract says %q", base, got, want)
		}
	}
}

func TestDecodeRequest(t *testing.T) {
	t.Parallel()
	ok := []byte(`{"v":1,"id":"7","action":"status"}`)
	req, err := DecodeRequest(ok)
	if err != nil || req.ID != "7" || req.Action != ActionStatus {
		t.Fatalf("valid frame: %+v %v", req, err)
	}
	// A missing v is the historical shape and stays readable.
	if _, err := DecodeRequest([]byte(`{"id":"1","action":"ping"}`)); err != nil {
		t.Fatalf("missing version: %v", err)
	}
	if _, err := DecodeRequest([]byte(`{"v":2,"action":"status"}`)); err == nil {
		t.Fatal("a newer protocol must be rejected")
	}
	if _, err := DecodeRequest([]byte(`{"v":1}`)); err == nil {
		t.Fatal("a frame without an action must be rejected")
	}
	if _, err := DecodeRequest([]byte(`not json`)); err == nil {
		t.Fatal("broken JSON must be rejected")
	}
	big, _ := json.Marshal(map[string]string{"x": strings.Repeat("a", MaxFrameBytes+1)})
	if _, err := DecodeRequest(append([]byte(`{"v":1,"action":"start","params":`), append(big, '}')...)); err == nil {
		t.Fatal("oversized params must be rejected")
	}
}

func TestPipeSDDLRejectsInvalidSID(t *testing.T) {
	t.Parallel()
	if _, err := PipeSDDL("not-a-sid"); err == nil {
		t.Fatal("invalid SID must be rejected")
	}
	sid, err := CurrentUserSID()
	if err != nil {
		t.Skipf("cannot read current SID: %v", err)
	}
	sddl, err := PipeSDDL(sid)
	if err != nil {
		t.Fatalf("valid SID rejected: %v", err)
	}
	if !strings.Contains(sddl, sid) || !strings.Contains(sddl, ";;SY)") {
		t.Fatalf("unexpected SDDL: %s", sddl)
	}
}

func TestAdapterVariant(t *testing.T) {
	t.Parallel()
	if got := adapterVariant("clash-halo", 0); got != "clash-halo" {
		t.Fatalf("variant 0 = %q", got)
	}
	if got := adapterVariant("clash-halo", 2); got != "clash-halo-2" {
		t.Fatalf("variant 2 = %q", got)
	}
	long := strings.Repeat("a", 64)
	got := adapterVariant(long, 3)
	if len(got) > 64 || !strings.HasSuffix(got, "-3") {
		t.Fatalf("long variant = %q (%d bytes)", got, len(got))
	}
}
