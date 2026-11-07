package tunservice

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// TestMain doubles as the fake core and the fake host.
//
// The real core needs administrator rights to create an adapter, so the tests
// replace only that one fact: the stand-in writes a marker when it is ready and
// the controller's adapter probe is pointed at that marker. Process start,
// job-object containment, config validation, staging, retries and the host
// watchdog all run for real.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "check", "version":
			os.Exit(0)
		case "run":
			runFakeCore(os.Args[2:])
			return
		case "sleep-host":
			time.Sleep(60 * time.Second)
			os.Exit(0)
		}
	}
	os.Exit(m.Run())
}

func runFakeCore(args []string) {
	configPath := ""
	for i := 0; i+1 < len(args); i++ {
		if args[i] == "-c" {
			configPath = args[i+1]
		}
	}
	adapter := "unknown"
	if body, err := os.ReadFile(configPath); err == nil {
		var doc struct {
			Inbounds []struct {
				Type          string `json:"type"`
				InterfaceName string `json:"interface_name"`
			} `json:"inbounds"`
		}
		if json.Unmarshal(body, &doc) == nil {
			for _, in := range doc.Inbounds {
				if in.Type == "tun" {
					adapter = in.InterfaceName
				}
			}
		}
	}
	if path := os.Getenv("HALO_TEST_CORE_ATTEMPT_FILE"); path != "" {
		if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
			fmt.Fprintln(f, adapter)
			_ = f.Close()
		}
	}
	if os.Getenv("HALO_TEST_CORE_MODE") == "conflict" {
		fmt.Fprintln(os.Stderr, "FATAL[0015] start service: start inbound/tun[tun-in]: "+
			"configure tun interface: (create adapter: Cannot create a file when that file already exists. | "+
			"open existing adapter: Element not found.)")
		os.Exit(1)
	}
	if path := os.Getenv("HALO_TEST_CORE_MARKER"); path != "" {
		_ = os.WriteFile(path, []byte(adapter), 0o600)
	}
	time.Sleep(60 * time.Second)
	os.Exit(0)
}

// A config that passes CheckConfigForTun and the core's structural check.
const fakeTunConfig = `{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "interface_name": "clash-halo",
     "address": ["172.19.0.1/30"], "auto_route": true, "stack": "mixed"},
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890}
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}`

type fixture struct {
	ctl      *Controller
	cfg      Config
	root     string
	dataDir  string
	marker   string
	attempts string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	protected := filepath.Join(root, "protected")
	for _, dir := range []string{dataDir, protected, filepath.Join(protected, "run")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	hash, err := ComputeSHA256File(self)
	if err != nil {
		t.Fatal(err)
	}
	sid, err := CurrentUserSID()
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := NewConfig(protected, dataDir, sid, hash)
	if err != nil {
		t.Fatal(err)
	}
	// The test binary is the core stand-in; the path checks are covered by the
	// config tests, and keeping the real executable avoids a 10 MB copy.
	cfg.CorePath = self

	f := &fixture{
		cfg:      cfg,
		root:     root,
		dataDir:  dataDir,
		marker:   filepath.Join(root, "ready-marker"),
		attempts: filepath.Join(root, "attempts"),
	}
	t.Setenv("HALO_TEST_CORE_MARKER", f.marker)
	t.Setenv("HALO_TEST_CORE_ATTEMPT_FILE", f.attempts)
	t.Setenv("HALO_TEST_CORE_MODE", "")
	f.ctl = NewController(cfg, t.Logf)
	f.ctl.grace = 500 * time.Millisecond
	f.ctl.ready = func(name string) bool {
		body, err := os.ReadFile(f.marker)
		return err == nil && strings.TrimSpace(string(body)) == name
	}
	t.Cleanup(f.ctl.Shutdown)
	return f
}

func (f *fixture) writeConfig(t *testing.T, name, body string) string {
	t.Helper()
	path := filepath.Join(f.dataDir, name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func (f *fixture) attemptNames(t *testing.T) []string {
	t.Helper()
	body, err := os.ReadFile(f.attempts)
	if err != nil {
		return nil
	}
	return strings.Fields(string(body))
}

func TestControllerStartStop(t *testing.T) {
	f := newFixture(t)
	path := f.writeConfig(t, "runtime.json", fakeTunConfig)
	if e := f.ctl.Start(path, os.Getpid()); e != nil {
		t.Fatalf("Start: %v", e)
	}
	st := f.ctl.Status()
	if st.State != "running" || st.PID <= 0 || st.Adapter != "clash-halo" {
		t.Fatalf("status = %+v", st)
	}
	if !processAlive(t, st.PID) {
		t.Fatal("status reports a running core whose process is gone")
	}
	if got := f.attemptNames(t); len(got) != 1 || got[0] != "clash-halo" {
		t.Fatalf("attempts = %v", got)
	}

	// A second start with the same host and document must not recreate the
	// adapter or restart the core.
	if e := f.ctl.Start(path, os.Getpid()); e != nil {
		t.Fatalf("second Start: %v", e)
	}
	if again := f.ctl.Status(); again.PID != st.PID {
		t.Fatalf("second start restarted the core: %d -> %d", st.PID, again.PID)
	}
	if got := f.attemptNames(t); len(got) != 1 {
		t.Fatalf("second start launched another core: %v", got)
	}

	if e := f.ctl.Stop(""); e != nil {
		t.Fatalf("Stop: %v", e)
	}
	if got := f.ctl.Status(); got.State != "stopped" || got.PID != 0 {
		t.Fatalf("status after stop = %+v", got)
	}
	if processAlive(t, st.PID) {
		t.Fatalf("core %d survived Stop", st.PID)
	}
}

func TestControllerRetriesAdapterConflict(t *testing.T) {
	f := newFixture(t)
	t.Setenv("HALO_TEST_CORE_MODE", "conflict")
	path := f.writeConfig(t, "runtime.json", fakeTunConfig)
	e := f.ctl.Start(path, os.Getpid())
	if e == nil {
		t.Fatal("a conflicting adapter must not report success")
	}
	if e.Code != CodeStartFailed || !strings.Contains(e.Message, "create adapter") {
		t.Fatalf("error = %+v", e)
	}
	names := f.attemptNames(t)
	want := []string{"clash-halo", "clash-halo-1", "clash-halo-2"}
	if len(names) != len(want) {
		t.Fatalf("attempts = %v, want %v", names, want)
	}
	for i := range want {
		if names[i] != want[i] {
			t.Fatalf("attempts = %v, want %v", names, want)
		}
	}
	if st := f.ctl.Status(); st.State != "failed" || st.PID != 0 {
		t.Fatalf("status = %+v", st)
	}
}

func TestControllerRejectsInvalidConfig(t *testing.T) {
	f := newFixture(t)
	outside := filepath.Join(t.TempDir(), "runtime.json")
	if err := os.WriteFile(outside, []byte(fakeTunConfig), 0o600); err != nil {
		t.Fatal(err)
	}
	if e := f.ctl.Start(outside, os.Getpid()); e == nil || e.Code != CodeRejected {
		t.Fatalf("config outside the data directory: %+v", e)
	}

	noTun := strings.Replace(fakeTunConfig, `"type": "tun"`, `"type": "direct"`, 1)
	path := f.writeConfig(t, "no-tun.json", noTun)
	if e := f.ctl.Start(path, os.Getpid()); e == nil || e.Code != CodeRejected {
		t.Fatalf("config without a tun inbound: %+v", e)
	}
	if got := f.attemptNames(t); len(got) != 0 {
		t.Fatalf("a rejected config started a core: %v", got)
	}
}

func TestControllerStopsWhenHostExits(t *testing.T) {
	f := newFixture(t)
	host := exec.Command(os.Args[0], "sleep-host")
	if err := host.Start(); err != nil {
		t.Fatal(err)
	}
	hostPID := host.Process.Pid
	defer func() { _ = host.Process.Kill(); _, _ = host.Process.Wait() }()

	path := f.writeConfig(t, "runtime.json", fakeTunConfig)
	if e := f.ctl.Start(path, hostPID); e != nil {
		t.Fatalf("Start: %v", e)
	}
	corePID := f.ctl.Status().PID
	if err := host.Process.Kill(); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		st := f.ctl.Status()
		if st.State == "failed" && strings.Contains(st.Message, "宿主已退出") {
			if processAlive(t, corePID) {
				t.Fatalf("host exit left core %d running", corePID)
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("host exit was not observed; status = %+v", f.ctl.Status())
}

func TestPipeRoundTrip(t *testing.T) {
	f := newFixture(t)
	srv, err := Listen(f.ctl, f.cfg.OwnerSID, t.Logf)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	go srv.Serve()
	defer srv.Close()

	client := NewClient(f.cfg.PipeName, 3*time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ping, err := client.Ping(ctx)
	if err != nil || ping.Protocol != ProtocolVersion {
		t.Fatalf("ping = %+v, %v", ping, err)
	}
	if st, err := client.Status(ctx); err != nil || st.State != "stopped" {
		t.Fatalf("initial status = %+v, %v", st, err)
	}
	path := f.writeConfig(t, "runtime.json", fakeTunConfig)
	st, err := client.Start(ctx, path, os.Getpid())
	if err != nil || st.State != "running" {
		t.Fatalf("start = %+v, %v", st, err)
	}
	st, err = client.Stop(ctx)
	if err != nil || st.State != "stopped" {
		t.Fatalf("stop = %+v, %v", st, err)
	}
}

func TestUnknownActionIsRejected(t *testing.T) {
	f := newFixture(t)
	if _, e := f.ctl.Handle(&Request{Action: "exec"}); e == nil || e.Code != CodeUnknownAction {
		t.Fatalf("unknown action = %+v", e)
	}
}

func processAlive(t *testing.T, pid int) bool {
	t.Helper()
	if pid <= 0 {
		return false
	}
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	var code uint32
	if err := windows.GetExitCodeProcess(h, &code); err != nil {
		return false
	}
	return code == 259
}

// Stopping the service (SCM stop or shutdown) must end the core and leave no
// process behind, even when the host is still alive.
func TestControllerShutdownStopsCore(t *testing.T) {
	f := newFixture(t)
	path := f.writeConfig(t, "runtime.json", fakeTunConfig)
	if e := f.ctl.Start(path, os.Getpid()); e != nil {
		t.Fatalf("Start: %v", e)
	}
	pid := f.ctl.Status().PID
	f.ctl.Shutdown()
	if got := f.ctl.Status(); got.State != "stopped" || got.PID != 0 {
		t.Fatalf("status after shutdown = %+v", got)
	}
	if processAlive(t, pid) {
		t.Fatalf("core %d survived service shutdown", pid)
	}
	// No further start is accepted after shutdown.
	if e := f.ctl.Start(path, os.Getpid()); e == nil || e.Code != CodeServiceStopping {
		t.Fatalf("start after shutdown = %+v", e)
	}
}
