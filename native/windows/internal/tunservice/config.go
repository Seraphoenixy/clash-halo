package tunservice

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

// ConfigVersion guards the on-disk install description.
const ConfigVersion = 1

// Config is what the elevated installer writes and the service reads. It lives
// in the protected directory, not the user-writable data directory: it names
// the executable the service is allowed to run and the digest that executable
// must have.
type Config struct {
	V            int    `json:"v"`
	DataDir      string `json:"dataDir"`
	ProtectedDir string `json:"protectedDir"`
	RunDir       string `json:"runDir"`
	CorePath     string `json:"corePath"`
	CoreSHA256   string `json:"coreSha256"`
	OwnerSID     string `json:"ownerSid"`
	PipeName     string `json:"pipeName"`
}

// DefaultProtectedDir is the directory owned by administrators, not by the
// user who installed the app. The service and its core are copied there so a
// medium-integrity process cannot replace the binary LocalSystem executes.
//
// The path comes from SHGetKnownFolderPath, never from %ProgramFiles%: the
// installer is launched from an unelevated process, and a user-level
// HKCU\Environment value for ProgramFiles overrides the machine one. An
// attacker who sets ProgramFiles=C:\Users\x\p would otherwise get the service
// binary and its pinned core installed into a directory they can rewrite,
// which defeats every hash pin downstream.
func DefaultProtectedDir() (string, error) {
	base, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return "", fmt.Errorf("tunservice: 无法解析 Program Files: %w", err)
	}
	base = strings.TrimSpace(base)
	if base == "" {
		return "", errors.New("tunservice: Program Files 为空")
	}
	return filepath.Join(base, "Clash Halo TUN"), nil
}

// NewConfig builds the install description for one app and data directory.
func NewConfig(protectedDir, dataDir, ownerSID, coreSHA256 string) (Config, error) {
	absProtected, err := filepath.Abs(protectedDir)
	if err != nil {
		return Config{}, err
	}
	absData, err := filepath.Abs(dataDir)
	if err != nil {
		return Config{}, err
	}
	cfg := Config{
		V:            ConfigVersion,
		DataDir:      absData,
		ProtectedDir: absProtected,
		RunDir:       filepath.Join(absProtected, "run"),
		CorePath:     filepath.Join(absProtected, "sing-box.exe"),
		CoreSHA256:   strings.ToLower(strings.TrimSpace(coreSHA256)),
		OwnerSID:     strings.TrimSpace(ownerSID),
		PipeName:     PipeNameFor(absData),
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// Validate refuses a config that would let the service execute or write
// outside the two roots it was installed with.
func (c Config) Validate() error {
	if c.V != ConfigVersion {
		return fmt.Errorf("tunservice: 安装配置版本不支持 (v=%d)", c.V)
	}
	for name, value := range map[string]string{
		"dataDir":      c.DataDir,
		"protectedDir": c.ProtectedDir,
		"runDir":       c.RunDir,
		"corePath":     c.CorePath,
	} {
		if !filepath.IsAbs(value) {
			return fmt.Errorf("tunservice: %s 必须是绝对路径", name)
		}
	}
	if !within(c.ProtectedDir, c.CorePath) {
		return errors.New("tunservice: 内核路径不在受保护目录内")
	}
	if !within(c.ProtectedDir, c.RunDir) {
		return errors.New("tunservice: 运行目录不在受保护目录内")
	}
	if len(c.CoreSHA256) != 64 {
		return errors.New("tunservice: 内核摘要格式无效")
	}
	if _, err := hex.DecodeString(c.CoreSHA256); err != nil {
		return errors.New("tunservice: 内核摘要不是十六进制")
	}
	if strings.TrimSpace(c.OwnerSID) == "" {
		return errors.New("tunservice: 缺少安装者 SID")
	}
	if c.PipeName != PipeNameFor(c.DataDir) {
		return errors.New("tunservice: 管道名与数据目录不匹配")
	}
	return nil
}

// Save writes the config beside the service binary.
func (c Config) Save(path string) error {
	if err := c.Validate(); err != nil {
		return err
	}
	body, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	body = append(body, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// LoadConfig reads and validates the install description.
func LoadConfig(path string) (Config, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var cfg Config
	if err := json.Unmarshal(body, &cfg); err != nil {
		return Config{}, fmt.Errorf("tunservice: 安装配置损坏: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// within reports whether candidate is inside root. A plain string prefix is
// not enough: "C:\thing-evil" shares a prefix with "C:\thing" but is not
// inside it.
func within(root, candidate string) bool {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	absCandidate, err := filepath.Abs(candidate)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(absRoot, absCandidate)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

// ComputeSHA256File hashes a file with a bounded read.
func ComputeSHA256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, io.LimitReader(f, 1<<30)); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// copyFile replaces dst with src atomically enough for an installer: a
// half-written service binary must never be registered with the SCM.
func copyFile(src, dst string, perm os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	// A unique temp name, not dst+".tmp": two installs (or an install racing
	// an uninstall) would otherwise write the same staging file.
	tmpFile, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := tmpFile.Name()
	out := tmpFile
	defer func() {
		if out != nil {
			_ = out.Close()
		}
	}()
	if err := out.Chmod(perm); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Sync(); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	out = nil
	// os.Rename replaces an existing file on Windows; removing dst first would
	// leave a window with no service binary at all.
	return os.Rename(tmp, dst)
}
