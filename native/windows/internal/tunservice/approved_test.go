package tunservice

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestApprovedCorePin(t *testing.T) {
	dir := t.TempDir()
	core := filepath.Join(dir, "sing-box.exe")
	if err := os.WriteFile(core, []byte("the approved bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	hash, err := ComputeSHA256File(core)
	if err != nil {
		t.Fatal(err)
	}
	if err := checkApprovedCore(core, hash); err != nil {
		t.Fatalf("matching manifest hash rejected: %v", err)
	}

	old := approvedCoreSHA256
	t.Cleanup(func() { approvedCoreSHA256 = old })
	approvedCoreSHA256 = strings.Repeat("a", 64)
	if err := checkApprovedCore(core, hash); err == nil {
		t.Fatal("a build pin must override the manifest hash")
	}
	approvedCoreSHA256 = hash
	if err := checkApprovedCore(core, strings.Repeat("b", 64)); err != nil {
		t.Fatalf("a matching build pin must be accepted: %v", err)
	}
}
