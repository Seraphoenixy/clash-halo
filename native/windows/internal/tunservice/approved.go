package tunservice

import (
	"fmt"
	"os"
	"strings"
)

// approvedCoreSHA256 is stamped at link time by the release build:
//
//	-X=clash-halo/native/windows/internal/tunservice.approvedCoreSHA256=<hash>
//
// It is the strongest form of "approved core": the hash is part of the signed
// service binary, so replacing sing-box.exe in the user-writable app directory
// before the first TUN enable cannot hand LocalSystem a different executable.
// An empty value means the binary was built without stamping (development);
// then the hash recorded at install time is used, which only protects against
// post-install replacement.
var approvedCoreSHA256 = ""

// ApprovedCoreHash returns the build-time pin, or "" when the build did not
// carry one.
func ApprovedCoreHash() string { return strings.TrimSpace(approvedCoreSHA256) }

// checkApprovedCore verifies a staged core against the build-time pin when one
// exists, and against the install manifest otherwise.
func checkApprovedCore(path, manifestHash string) error {
	want := strings.ToLower(strings.TrimSpace(ApprovedCoreHash()))
	if want == "" {
		want = strings.ToLower(strings.TrimSpace(manifestHash))
	}
	if want == "" {
		return fmt.Errorf("没有可用的内核摘要，拒绝执行")
	}
	got, err := ComputeSHA256File(path)
	if err != nil {
		return fmt.Errorf("无法读取内核摘要: %w", err)
	}
	if !strings.EqualFold(got, want) {
		return fmt.Errorf("内核摘要不匹配（期望 %s，实际 %s），拒绝执行", short(want), short(got))
	}
	return nil
}

func short(hash string) string {
	if len(hash) > 12 {
		return hash[:12]
	}
	return hash
}

// statCore rejects a missing, empty or absurdly large core before hashing.
func statCore(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("找不到已批准的内核: %w", err)
	}
	if info.Size() <= 0 || info.Size() > 200<<20 {
		return fmt.Errorf("已批准的内核大小异常（%d 字节）", info.Size())
	}
	return nil
}
