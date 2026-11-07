package ipc

import (
	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

func openCurrentProcessToken() (windows.Token, error) {
	return windows.OpenCurrentProcessToken()
}

func closeToken(t windows.Token) { _ = t.Close() }

func tokenUserSID(t windows.Token) (string, error) {
	u, err := t.GetTokenUser()
	if err != nil {
		return "", err
	}
	return u.User.Sid.String(), nil
}

// DescriptorForCurrentUser is the production pipe ACL.
func DescriptorForCurrentUser() (string, error) {
	sid, err := CurrentUserSID()
	if err != nil {
		return "", err
	}
	return currentUserDescriptor(sid), nil
}

var _ = winio.PipeConfig{}
