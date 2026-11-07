package tunservice

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// writeAccessMask is what an ordinary (medium-integrity) process needs in order
// to replace a file or drop a new one beside it.
const writeAccessMask = windows.FILE_WRITE_DATA |
	windows.FILE_APPEND_DATA |
	windows.FILE_WRITE_EA |
	windows.FILE_WRITE_ATTRIBUTES |
	0x00010000 | // DELETE
	0x00040000 | // WRITE_DAC
	0x00080000 | // WRITE_OWNER
	0x00000040 // FILE_DELETE_CHILD

// trusteesWithWrite are the broad groups that would make the protected
// directory writable by any process running as the installing user. A direct
// ACE for the user's own SID is checked separately.
var broadWriteTrustees = []uint32{
	windows.WinWorldSid,             // Everyone
	windows.WinBuiltinUsersSid,      // BUILTIN\Users
	windows.WinAuthenticatedUserSid, // NT AUTHORITY\Authenticated Users
	windows.WinInteractiveSid,       // NT AUTHORITY\INTERACTIVE
}

// VerifyProtectedDir refuses an install directory that the installing user can
// still write.
//
// Program Files is protected by an ACL, not by its name. If the directory is
// created somewhere the user controls — the %ProgramFiles% override this code
// used to read is one way — the service binary and its pinned core can be
// replaced afterwards, and every downstream hash pin becomes theatre. The check
// is deliberately about the ACL and not about the path string.
func VerifyProtectedDir(dir string) error {
	sd, err := windows.GetNamedSecurityInfo(
		dir,
		windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.OWNER_SECURITY_INFORMATION,
	)
	if err != nil {
		return fmt.Errorf("无法读取受保护目录的 ACL: %w", err)
	}
	if sd == nil {
		return fmt.Errorf("受保护目录没有安全描述符: %s", dir)
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return fmt.Errorf("无法读取受保护目录的 DACL: %w", err)
	}
	if dacl == nil {
		return fmt.Errorf("受保护目录的 DACL 为空，拒绝安装: %s", dir)
	}
	token, err := windows.OpenCurrentProcessToken()
	if err != nil {
		return fmt.Errorf("无法打开当前进程令牌: %w", err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return fmt.Errorf("无法读取当前用户 SID: %w", err)
	}
	// CREATOR OWNER is an inherited ACE on Program Files. If the directory's
	// owner were the installing user, that ACE would grant them full control
	// even though no explicit ACE names their SID — so ownership is part of
	// the check, not just the DACL entries.
	if owner, _, err := sd.Owner(); err == nil && owner != nil {
		if owner.Equals(user.User.Sid) {
			return fmt.Errorf("受保护目录的所有者是当前用户，拒绝安装: %s", dir)
		}
		for _, wellKnown := range broadWriteTrustees {
			broad, err := windows.CreateWellKnownSid(windows.WELL_KNOWN_SID_TYPE(wellKnown))
			if err != nil {
				continue
			}
			if owner.Equals(broad) {
				return fmt.Errorf("受保护目录的所有者是 %s，拒绝安装: %s",
					owner.String(), dir)
			}
		}
	}
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil || ace == nil {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			continue
		}
		if ace.Mask&writeAccessMask == 0 {
			continue
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if sid.Equals(user.User.Sid) {
			return fmt.Errorf("受保护目录对当前用户可写，拒绝安装: %s", dir)
		}
		for _, wellKnown := range broadWriteTrustees {
			broad, err := windows.CreateWellKnownSid(windows.WELL_KNOWN_SID_TYPE(wellKnown))
			if err != nil {
				continue
			}
			if sid.Equals(broad) {
				return fmt.Errorf("受保护目录对 %s 可写，拒绝安装: %s",
					sid.String(), dir)
			}
		}
	}
	return nil
}
