package tunservice

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc/mgr"
)

func TestPrepareFilesStagesBothExecutables(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "app")
	protected := filepath.Join(root, "protected")
	dataDir := filepath.Join(root, "data")
	for _, dir := range []string{appDir, dataDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	coreBody := []byte("fake sing-box binary for the installer test")
	if err := os.WriteFile(filepath.Join(appDir, "sing-box.exe"), coreBody, 0o600); err != nil {
		t.Fatal(err)
	}
	// The approved core is not self-contained; staging it without its runtime
	// is covered by TestPrepareFilesRejectsMissingCoreRuntime.
	if err := os.WriteFile(filepath.Join(appDir, cronetDLLName), []byte("fake libcronet"), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := prepareFiles(InstallOptions{
		AppDir:       appDir,
		DataDir:      dataDir,
		ProtectedDir: protected,
		skipACLCheck: true,
	}, t.Logf)
	if err != nil {
		t.Fatalf("prepareFiles: %v", err)
	}
	if cfg.ProtectedDir != protected {
		t.Fatalf("protected = %q", cfg.ProtectedDir)
	}
	if got, err := os.ReadFile(cfg.CorePath); err != nil || string(got) != string(coreBody) {
		t.Fatalf("approved core = %q, %v", got, err)
	}
	hash, err := ComputeSHA256File(cfg.CorePath)
	if err != nil || hash != cfg.CoreSHA256 {
		t.Fatalf("hash = %s, want %s (%v)", hash, cfg.CoreSHA256, err)
	}
	// The service binary is the running executable, copied into the protected
	// directory so SCM never runs a file the user can replace.
	servicePath := filepath.Join(protected, ServiceExeName)
	self, _ := os.Executable()
	selfInfo, err := os.Stat(self)
	if err != nil {
		t.Fatal(err)
	}
	serviceInfo, err := os.Stat(servicePath)
	if err != nil {
		t.Fatalf("service copy missing: %v", err)
	}
	if serviceInfo.Size() != selfInfo.Size() {
		t.Fatalf("service copy is %d bytes, executable is %d", serviceInfo.Size(), selfInfo.Size())
	}
	if _, err := LoadConfig(filepath.Join(protected, ConfigFileName)); err != nil {
		t.Fatalf("saved config unreadable: %v", err)
	}
}

func TestPrepareFilesRejectsMissingCore(t *testing.T) {
	root := t.TempDir()
	_, err := prepareFiles(InstallOptions{
		AppDir:       filepath.Join(root, "app"),
		DataDir:      filepath.Join(root, "data"),
		ProtectedDir: filepath.Join(root, "protected"),
		skipACLCheck: true,
	}, t.Logf)
	if err == nil {
		t.Fatal("a missing core must fail the install")
	}
}

// The approved core is not self-contained: the Naive outbound loads
// libcronet.dll from the directory the executable lives in. Installing only
// sing-box.exe made every TUN enable that used a Naive node fail with
// "cronet: library not found" — the exact string users reported — because the
// protected copy had no DLL beside it.
func TestPrepareFilesStagesTheCoreRuntime(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "app")
	protected := filepath.Join(root, "protected")
	dataDir := filepath.Join(root, "data")
	for _, dir := range []string{appDir, dataDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(appDir, "sing-box.exe"), []byte("core"), 0o600); err != nil {
		t.Fatal(err)
	}
	dllBody := []byte("fake libcronet")
	if err := os.WriteFile(filepath.Join(appDir, cronetDLLName), dllBody, 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := prepareFiles(InstallOptions{
		AppDir:       appDir,
		DataDir:      dataDir,
		ProtectedDir: protected,
		skipACLCheck: true,
	}, t.Logf); err != nil {
		t.Fatalf("prepareFiles: %v", err)
	}

	staged, err := os.ReadFile(filepath.Join(protected, cronetDLLName))
	if err != nil {
		t.Fatalf("runtime component not staged: %v", err)
	}
	if string(staged) != string(dllBody) {
		t.Fatalf("staged = %q, want %q", staged, dllBody)
	}
}

// A build that ships the core without its runtime must fail the install, not
// succeed and fail later at the first check with a message about a file the user
// never had a chance to install.
func TestPrepareFilesRejectsMissingCoreRuntime(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "app")
	dataDir := filepath.Join(root, "data")
	for _, dir := range []string{appDir, dataDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(appDir, "sing-box.exe"), []byte("core"), 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := prepareFiles(InstallOptions{
		AppDir:       appDir,
		DataDir:      dataDir,
		ProtectedDir: filepath.Join(root, "protected"),
		skipACLCheck: true,
	}, t.Logf)
	if err == nil {
		t.Fatal("a missing core runtime must fail the install")
	}
	if !strings.Contains(err.Error(), cronetDLLName) {
		t.Fatalf("error does not name the missing file: %v", err)
	}
}

// Install and Uninstall must refuse to touch the SCM without elevation. The
// elevated path is covered by the admin-only verification checklist.
func TestInstallRequiresElevation(t *testing.T) {
	if isElevated() {
		t.Skip("this test only checks the unelevated refusal")
	}
	if _, err := Install(InstallOptions{}, nil); err == nil {
		t.Fatal("unelevated Install must fail")
	}
	if err := Uninstall(nil); err == nil {
		t.Fatal("unelevated Uninstall must fail")
	}
}

// mgr.CreateService substitutes SERVICE_WIN32_OWN_PROCESS for a zero
// ServiceType, but mgr.UpdateConfig does not: it passes the zero to
// ChangeServiceConfig, which fails with "The parameter is incorrect." A fresh
// install therefore worked while every upgrade failed, and an app update is
// exactly an upgrade. The registration must carry the type explicitly.
func TestServiceConfigNamesTheServiceType(t *testing.T) {
	cfg := serviceConfig()
	if cfg.ServiceType != windows.SERVICE_WIN32_OWN_PROCESS {
		t.Fatalf("ServiceType = %d, want SERVICE_WIN32_OWN_PROCESS", cfg.ServiceType)
	}
	if cfg.StartType != mgr.StartAutomatic {
		t.Fatalf("StartType = %d, want automatic", cfg.StartType)
	}
	if cfg.ServiceStartName != "LocalSystem" {
		t.Fatalf("ServiceStartName = %q", cfg.ServiceStartName)
	}
	// Both registration paths must share one description, or an upgrade would
	// quietly drop the display name the first install set.
	if cfg.DisplayName == "" || cfg.Description == "" {
		t.Fatalf("display name or description empty: %+v", cfg)
	}
}
