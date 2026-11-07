package tunservice

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testConfig(t *testing.T) Config {
	t.Helper()
	root := t.TempDir()
	protected := filepath.Join(root, "protected")
	data := filepath.Join(root, "data")
	if err := os.MkdirAll(protected, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(data, 0o755); err != nil {
		t.Fatal(err)
	}
	core := filepath.Join(protected, "sing-box.exe")
	if err := os.WriteFile(core, []byte("core"), 0o600); err != nil {
		t.Fatal(err)
	}
	sid, err := CurrentUserSID()
	if err != nil {
		t.Fatalf("sid: %v", err)
	}
	cfg, err := NewConfig(protected, data, sid, strings.Repeat("a", 64))
	if err != nil {
		t.Fatalf("NewConfig: %v", err)
	}
	return cfg
}

func TestConfigRoundTrip(t *testing.T) {
	cfg := testConfig(t)
	path := filepath.Join(cfg.ProtectedDir, "service.json")
	if err := cfg.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got != cfg {
		t.Fatalf("round trip mismatch:\n got %+v\nwant %+v", got, cfg)
	}
	if got.PipeName != PipeNameFor(cfg.DataDir) {
		t.Fatalf("pipe name %q does not follow the data dir", got.PipeName)
	}
}

func TestConfigRejectsEscapes(t *testing.T) {
	base := testConfig(t)

	outside := base
	outside.CorePath = filepath.Join(t.TempDir(), "sing-box.exe")
	if err := outside.Validate(); err == nil {
		t.Fatal("a core outside the protected directory must be rejected")
	}

	badHash := base
	badHash.CoreSHA256 = "xyz"
	if err := badHash.Validate(); err == nil {
		t.Fatal("a malformed digest must be rejected")
	}

	badPipe := base
	badPipe.PipeName = `\\.\pipe\elsewhere`
	if err := badPipe.Validate(); err == nil {
		t.Fatal("a pipe name that does not follow the data dir must be rejected")
	}

	relative := base
	relative.RunDir = "run"
	if err := relative.Validate(); err == nil {
		t.Fatal("a relative run directory must be rejected")
	}

	noOwner := base
	noOwner.OwnerSID = ""
	if err := noOwner.Validate(); err == nil {
		t.Fatal("a config without an owner SID must be rejected")
	}
}

func TestWithin(t *testing.T) {
	root := t.TempDir()
	cases := []struct {
		candidate string
		want      bool
	}{
		{filepath.Join(root, "a.json"), true},
		{root, true},
		{filepath.Join(root, "..", "evil.json"), false},
		{root + "-evil", false},
	}
	for _, tc := range cases {
		if got := within(root, tc.candidate); got != tc.want {
			t.Errorf("within(%q) = %v, want %v", tc.candidate, got, tc.want)
		}
	}
}

func TestCopyFileReplaces(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	dst := filepath.Join(dir, "dst")
	if err := os.WriteFile(src, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, []byte("old-and-longer"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(src, dst, 0o600); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(dst)
	if err != nil || string(body) != "new" {
		t.Fatalf("dst = %q, %v", body, err)
	}
	if _, err := os.Stat(dst + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("temporary file left behind")
	}
}
