package connapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"clash-halo/native/windows/internal/contract"
)

type staticSource struct {
	path    string
	running bool
}

func (s staticSource) ConnectionsConfig() (string, bool) { return s.path, s.running }

func writeConfig(t *testing.T, dir, controller, secret string) string {
	t.Helper()
	doc := map[string]any{
		"experimental": map[string]any{
			"clash_api": map[string]string{
				"external_controller": controller,
				"secret":              secret,
			},
		},
	}
	body, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "runtime.json")
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// A secret in the config must reach the request. Reading it and dropping it
// left the controller answering 401, which the UI showed as an empty page.
func TestListSendsBearerSecret(t *testing.T) {
	var gotAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"connections":[],"uploadTotal":1,"downloadTotal":2}`))
	}))
	t.Cleanup(server.Close)

	dir := t.TempDir()
	cfg := writeConfig(t, dir, strings.TrimPrefix(server.URL, "http://"), "s3cret")
	svc := New(staticSource{path: cfg, running: true}, nil)

	snap, errObj := svc.List()
	if errObj != nil {
		t.Fatalf("List: %v", errObj)
	}
	if gotAuth != "Bearer s3cret" {
		t.Fatalf("Authorization = %q", gotAuth)
	}
	if snap.UploadTotal != 1 || snap.DownloadTotal != 2 {
		t.Fatalf("totals = %d/%d", snap.UploadTotal, snap.DownloadTotal)
	}
}

func TestListRejectsNonLoopbackController(t *testing.T) {
	dir := t.TempDir()
	cfg := writeConfig(t, dir, "192.168.1.10:9090", "")
	svc := New(staticSource{path: cfg, running: true}, nil)

	_, errObj := svc.List()
	if errObj == nil {
		t.Fatal("a LAN controller must be refused")
	}
	if errObj.Code != contract.ErrUnsupported {
		t.Fatalf("code = %q", errObj.Code)
	}
}

func TestListWithoutRunningCore(t *testing.T) {
	svc := New(staticSource{running: false}, nil)
	_, errObj := svc.List()
	if errObj == nil || errObj.Code != contract.ErrCoreNotRunning {
		t.Fatalf("got %v, want core_not_running", errObj)
	}
}

func TestCloseEscapesIDAndSendsSecret(t *testing.T) {
	var gotPath, gotAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.EscapedPath()
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)

	dir := t.TempDir()
	cfg := writeConfig(t, dir, strings.TrimPrefix(server.URL, "http://"), "s3cret")
	svc := New(staticSource{path: cfg, running: true}, nil)

	got, errObj := svc.Close("a/b")
	if errObj != nil {
		t.Fatalf("Close: %v", errObj)
	}
	if got.(map[string]any)["closed"] != "a/b" {
		t.Fatalf("closed = %v", got)
	}
	if gotPath != "/connections/a%2Fb" {
		t.Fatalf("path = %q", gotPath)
	}
	if gotAuth != "Bearer s3cret" {
		t.Fatalf("Authorization = %q", gotAuth)
	}
}

// Stat-keyed cache: the same file must not be re-read, and a changed file must
// be picked up on the next call.
func TestControllerCacheInvalidatesOnChange(t *testing.T) {
	dir := t.TempDir()
	first := writeConfig(t, dir, "127.0.0.1:1", "a")
	svc := New(staticSource{path: first, running: true}, nil)
	if _, err := svc.controllerForConfig(first); err != nil {
		t.Fatal(err)
	}
	svc.mu.Lock()
	addr := svc.cache.addr
	svc.mu.Unlock()
	if addr != "127.0.0.1:1" {
		t.Fatalf("cached addr = %q", addr)
	}

	// Rewrite with a different size so the stat key changes even when the
	// filesystem timestamp granularity hides the modification.
	second := writeConfig(t, dir, "127.0.0.1:2", "bb")
	if len(second) == 0 {
		t.Fatal("writeConfig returned an empty path")
	}
	if _, err := svc.controllerForConfig(second); err != nil {
		t.Fatal(err)
	}
	svc.mu.Lock()
	defer svc.mu.Unlock()
	if svc.cache.addr != "127.0.0.1:2" || svc.cache.secret != "bb" {
		t.Fatalf("cache did not refresh: %+v", svc.cache)
	}
}
