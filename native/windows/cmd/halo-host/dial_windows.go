package main

import (
	"net"
	"time"

	"github.com/Microsoft/go-winio"

	"clash-halo/native/windows/internal/app"
)

func winioDial(name string, timeout time.Duration) (net.Conn, error) {
	return winio.DialPipe(name, &timeout)
}

var _ = app.DefaultPaths
