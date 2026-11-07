package ipc

import (
	"net"
	"time"

	"github.com/Microsoft/go-winio"
)

// winioDialForTest connects to a test pipe with a bounded timeout so a missing
// server fails the test instead of hanging it.
func winioDialForTest(name string) (net.Conn, error) {
	t := 2 * time.Second
	return winio.DialPipe(name, &t)
}
