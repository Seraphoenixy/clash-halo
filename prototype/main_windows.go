package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/Microsoft/go-winio"
	"github.com/getlantern/systray"
	"golang.org/x/sys/windows"
)

var pipeName = `\\.\pipe\clash-halo-lifecycle-prototype`
var mu sync.Mutex
var core *exec.Cmd
var listener net.Listener
var lastError string

func request(action string) map[string]any {
	timeout := 2 * time.Second
	c, err := winio.DialPipe(pipeName, &timeout)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(timeout))
	fmt.Fprintln(c, action)
	var reply map[string]any
	if err := json.NewDecoder(c).Decode(&reply); err != nil {
		return map[string]any{"error": err.Error()}
	}
	return reply
}

func stopCore() {
	mu.Lock()
	defer mu.Unlock()
	if core != nil {
		_ = core.Process.Kill()
	}
}

func handle(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	scanner := bufio.NewScanner(c)
	scanner.Buffer(make([]byte, 256), 1024)
	if !scanner.Scan() {
		return
	}
	action := scanner.Text()
	if action == "stop" {
		stopCore()
	}
	if action == "start" {
		startCore()
	}
	mu.Lock()
	pid := 0
	if core != nil {
		pid = core.Process.Pid
	}
	reply := map[string]any{"backendPid": os.Getpid(), "corePid": pid, "error": lastError, "systemProxyChanged": false, "tunEnabled": false}
	mu.Unlock()
	if action != "status" && action != "start" && action != "stop" && action != "quit" {
		reply["error"] = "unknown command"
	}
	_ = json.NewEncoder(c).Encode(reply)
	if action == "quit" {
		systray.Quit()
	}
}

func startCore() {
	mu.Lock()
	defer mu.Unlock()
	if core != nil {
		return
	}
	exe, _ := os.Executable()
	base := filepath.Dir(exe)
	cmd := exec.Command(filepath.Join(base, "sing-box.exe"), "run", "-c", filepath.Join(base, "config.json"))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	log, err := os.OpenFile(filepath.Join(base, "core.log"), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		lastError = err.Error()
		return
	}
	cmd.Stdout = log
	cmd.Stderr = log
	if err = cmd.Start(); err != nil {
		log.Close()
		lastError = err.Error()
		return
	}
	core = cmd
	lastError = ""
	go func() {
		err := cmd.Wait()
		log.Close()
		mu.Lock()
		defer mu.Unlock()
		if core == cmd {
			core = nil
		}
		if err != nil {
			lastError = err.Error()
		}
	}()
}

func main() {
	if len(os.Args) > 1 {
		reply := request(os.Args[1])
		b, _ := json.Marshal(reply)
		fmt.Println(string(b))
		return
	}
	token, err := windows.OpenCurrentProcessToken()
	if err != nil {
		panic(err)
	}
	user, err := token.GetTokenUser()
	token.Close()
	if err != nil {
		panic(err)
	}
	listener, err = winio.ListenPipe(pipeName, &winio.PipeConfig{SecurityDescriptor: "D:P(A;;GA;;;" + user.User.Sid.String() + ")", MessageMode: false})
	if err != nil {
		panic(err)
	}
	go func() {
		for {
			c, e := listener.Accept()
			if e != nil {
				return
			}
			go handle(c)
		}
	}()
	systray.Run(func() {
		// ICO with a single 1x1 BGRA pixel and transparency mask.
		icon := []byte{0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 32, 0, 48, 0, 0, 0, 22, 0, 0, 0, 40, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 32, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 200, 140, 40, 255, 0, 0, 0, 0}
		systray.SetIcon(icon)
		systray.SetTooltip("clash-halo lifecycle prototype")
		open := systray.AddMenuItem("Open Flutter UI", "")
		start := systray.AddMenuItem("Start local test core", "")
		stop := systray.AddMenuItem("Stop core", "")
		quit := systray.AddMenuItem("Stop and exit prototype", "")
		go func() {
			for {
				select {
				case <-open.ClickedCh:
					exe, _ := os.Executable()
					ui := exec.Command(filepath.Join(filepath.Dir(exe), "ui", "halo_lifecycle.exe"))
					if err := ui.Start(); err == nil {
						go ui.Wait()
					} else {
						mu.Lock()
						lastError = err.Error()
						mu.Unlock()
					}
				case <-start.ClickedCh:
					startCore()
				case <-stop.ClickedCh:
					stopCore()
				case <-quit.ClickedCh:
					systray.Quit()
					return
				}
			}
		}()
	}, func() { listener.Close(); stopCore() })
}
