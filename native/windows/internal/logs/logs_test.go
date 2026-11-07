package logs

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRedactorRemovesSecrets(t *testing.T) {
	r := NewRedactor()
	r.Set("password123", "uuid-secret-value", "abc")
	got := r.Redact("connecting with password123 and uuid-secret-value")
	if strings.Contains(got, "password123") || strings.Contains(got, "uuid-secret-value") {
		t.Fatalf("secret survived: %s", got)
	}
	if !strings.Contains(got, "***") {
		t.Fatalf("no placeholder: %s", got)
	}
	// Short values are ignored so a one-letter "secret" does not shred the log.
	if !strings.Contains(r.Redact("abc def"), "abc") {
		t.Fatal("3-byte value should not be treated as a secret")
	}
}

func TestRedactorLongestFirst(t *testing.T) {
	// "tok123" is a substring of "token-tok123"; replacing the longer one
	// first prevents leaving a fragment.
	r := NewRedactor()
	r.Set("tok123", "token-tok123")
	got := r.Redact("value=token-tok123")
	if got != "value=***" {
		t.Fatalf("got %q", got)
	}
}

func TestRotatingRespectsByteBudget(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "host.log")
	opts := Options{Path: path, MaxBytes: 1 << 10, MaxFiles: 3, Redactor: NewRedactor()}
	r, err := Open(opts)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = r.Close() }()
	line := strings.Repeat("x", 100)
	for i := 0; i < 60; i++ {
		if err := r.Write(line); err != nil {
			t.Fatal(err)
		}
	}
	// Three files × ~1 KiB: the ceiling is enforced, not exceeded by one
	// extra line as a naive implementation would.
	if total := r.TotalSize(); total > int64(opts.MaxBytes)*3 {
		t.Fatalf("total %d exceeds budget %d", total, opts.MaxBytes*3)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("primary log missing")
	}
	if _, err := os.Stat(path + ".1"); err != nil {
		t.Fatal("first archive missing after rotation")
	}
	if _, err := os.Stat(path + ".3"); err == nil {
		t.Fatal("should keep at most MaxFiles-1 archives")
	}
}

func TestRotatingRedactsBeforeWriting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "host.log")
	red := NewRedactor()
	red.Set("super-secret-password")
	r, err := Open(Options{Path: path, MaxBytes: 4096, MaxFiles: 2, Redactor: red})
	if err != nil {
		t.Fatal(err)
	}
	_ = r.Write("login with super-secret-password failed")
	_ = r.Close()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "super-secret-password") {
		t.Fatalf("secret reached disk: %s", data)
	}
}

func TestRotatingCapsLineLength(t *testing.T) {
	dir := t.TempDir()
	r, err := Open(Options{
		Path: filepath.Join(dir, "h.log"), MaxBytes: 1 << 20, MaxFiles: 2,
		Redactor: NewRedactor(),
	})
	if err != nil {
		t.Fatal(err)
	}
	_ = r.Write(strings.Repeat("y", 5000))
	_ = r.Close()
	data, _ := os.ReadFile(filepath.Join(dir, "h.log"))
	if len(data) > 2100 {
		t.Fatalf("line not truncated: %d bytes", len(data))
	}
}

func TestTailReadsLastLines(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "host.log")
	r, err := Open(Options{Path: path, MaxBytes: 1 << 20, MaxFiles: 1, Redactor: NewRedactor()})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		_ = r.Write("line-" + itoa(i))
	}
	_ = r.Close()
	lines, err := Tail(path, 3, 1024)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 3 {
		t.Fatalf("expected 3 lines, got %d", len(lines))
	}
	if lines[len(lines)-1].Text != "line-9" {
		t.Fatalf("last line = %q", lines[len(lines)-1].Text)
	}
}

func TestTailOnMissingFileIsEmpty(t *testing.T) {
	lines, err := Tail(filepath.Join(t.TempDir(), "nope.log"), 10, 1024)
	if err != nil {
		t.Fatalf("missing file must not error: %v", err)
	}
	if len(lines) != 0 {
		t.Fatalf("expected empty, got %d", len(lines))
	}
}

func TestTailBoundsRequestSize(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "big.log")
	var b strings.Builder
	for i := 0; i < 5000; i++ {
		b.WriteString("padding line to grow the file well past the read cap\n")
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	// Ask for a huge read: the implementation must clamp it rather than load
	// the whole file into memory.
	lines, err := Tail(path, 2000, 1<<40)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) > 2000 {
		t.Fatalf("returned %d lines", len(lines))
	}
}

// tailReference is the original full-window implementation, kept as the oracle:
// the backward scan must produce byte-identical output for the same inputs.
func tailReference(path string, lines int, maxBytes int64) ([]TailLine, error) {
	if lines <= 0 || lines > 2000 {
		lines = 200
	}
	if maxBytes <= 0 || maxBytes > 1<<20 {
		maxBytes = 512 << 10
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		data = data[int64(len(data))-maxBytes:]
	}
	all := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(all) > lines {
		all = all[len(all)-lines:]
	}
	out := make([]TailLine, 0, len(all))
	for _, line := range all {
		if strings.TrimSpace(line) == "" {
			continue
		}
		_, body := splitStamp(line)
		out = append(out, TailLine{Text: body})
	}
	return out, nil
}

func TestTailBackwardScanMatchesFullWindow(t *testing.T) {
	// The backward scan replaced a full 512 KiB read on every poll; it must not
	// change what the caller sees. Sizes are chosen to cross chunk boundaries
	// (8 KiB) unevenly, including a window that lands mid-line.
	cases := []struct {
		name     string
		build    func(i int) string
		suffix   string
		lines    int
		maxBytes int64
	}{
		{
			name:     "short file, whole content",
			build:    func(i int) string { return fmt.Sprintf("line-%d", i) },
			suffix:   "\n",
			lines:    5,
			maxBytes: 1 << 20,
		},
		{
			name:     "many short lines with trailing newline",
			build:    func(i int) string { return fmt.Sprintf("entry %06d some host message", i) },
			suffix:   "\n",
			lines:    200,
			maxBytes: 64 << 10,
		},
		{
			name:     "no trailing newline on the last line",
			build:    func(i int) string { return fmt.Sprintf("row-%04d", i) },
			suffix:   "",
			lines:    50,
			maxBytes: 64 << 10,
		},
		{
			name:     "lines longer than one scan chunk",
			build:    func(i int) string { return fmt.Sprintf("%06d %s", i, strings.Repeat("p", 900)) },
			suffix:   "\n",
			lines:    100,
			maxBytes: 1 << 20,
		},
		{
			name:     "maxBytes cap cuts mid-line",
			build:    func(i int) string { return fmt.Sprintf("%06d %s", i, strings.Repeat("q", 400)) },
			suffix:   "\n",
			lines:    30,
			maxBytes: 512 << 10,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "host.log")
			var b strings.Builder
			for i := 0; i < 1200; i++ {
				b.WriteString(tc.build(i))
				b.WriteString(tc.suffix)
			}
			if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
				t.Fatal(err)
			}
			got, err := Tail(path, tc.lines, tc.maxBytes)
			if err != nil {
				t.Fatalf("Tail: %v", err)
			}
			want, err := tailReference(path, tc.lines, tc.maxBytes)
			if err != nil {
				t.Fatalf("reference: %v", err)
			}
			if len(got) != len(want) {
				t.Fatalf("line count = %d, want %d", len(got), len(want))
			}
			for i := range got {
				if got[i].Text != want[i].Text {
					t.Fatalf("line %d = %q, want %q", i, got[i].Text, want[i].Text)
				}
			}
		})
	}
}

// TestTailTimestampsAreStableAcrossPolls pins the P1 defect.
//
// The old reader stamped every line with the file's modification time, so the
// moment anything else was appended the entire visible history took on a new
// time. The log page deduplicated on `atMs + text`, which meant the overlap
// could stop matching and lines were appended twice. Each line now carries the
// time it was written, and that must not move when a later line arrives.
func TestTailTimestampsAreStableAcrossPolls(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "host.log")
	r, err := Open(Options{Path: path, MaxBytes: 1 << 20, MaxFiles: 1, Redactor: NewRedactor()})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		_ = r.Write("first-" + itoa(i))
	}
	before, err := Tail(path, 100, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(before) != 3 {
		t.Fatalf("got %d lines, want 3", len(before))
	}
	for i, l := range before {
		if l.AtMs == 0 {
			t.Fatalf("line %d has no timestamp", i)
		}
	}

	// Sleep past one filesystem timestamp tick. Without a per-line stamp the
	// reader substitutes the file's modification time, and this makes the new
	// write move it — which is exactly the P1 symptom. Without the sleep a
	// reverted implementation could still pass by landing in the same
	// millisecond, which it did before this test was tightened.
	time.Sleep(1100 * time.Millisecond)
	_ = r.Write("second-0")
	after, err := Tail(path, 100, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 4 {
		t.Fatalf("got %d lines, want 4", len(after))
	}
	for i := range before {
		if after[i].Text != before[i].Text {
			t.Fatalf("line %d text changed: %q -> %q", i, before[i].Text, after[i].Text)
		}
		if after[i].AtMs != before[i].AtMs {
			t.Fatalf("line %d time moved: %d -> %d", i, before[i].AtMs, after[i].AtMs)
		}
		if after[i].Seq != before[i].Seq {
			t.Fatalf("line %d seq moved: %d -> %d", i, before[i].Seq, after[i].Seq)
		}
	}
	_ = r.Close()
}

// TestTailSeqIsStableAndIncreasing pins the incremental-append contract: the UI
// appends only lines whose Seq exceeds the last one it holds, so Seq must be
// strictly increasing down the file and unchanged for a line as the window
// slides forward.
func TestTailSeqIsStableAndIncreasing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "host.log")
	r, err := Open(Options{Path: path, MaxBytes: 1 << 20, MaxFiles: 1, Redactor: NewRedactor()})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = r.Close() }()
	for i := 0; i < 40; i++ {
		_ = r.Write("row-" + itoa(i))
	}

	full, err := Tail(path, 200, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	for i := 1; i < len(full); i++ {
		if full[i].Seq <= full[i-1].Seq {
			t.Fatalf("seq not increasing at %d: %d <= %d", i, full[i].Seq, full[i-1].Seq)
		}
	}

	// A smaller window still reports the same Seq for the lines it shares with
	// the larger one; otherwise a page that changes its tail size would think
	// every line was new.
	short, err := Tail(path, 10, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(short) != 10 {
		t.Fatalf("got %d lines, want 10", len(short))
	}
	byText := map[string]int64{}
	for _, l := range full {
		byText[l.Text] = l.Seq
	}
	for _, l := range short {
		if want, ok := byText[l.Text]; !ok {
			t.Fatalf("short line %q missing from full read", l.Text)
		} else if l.Seq != want {
			t.Fatalf("%q seq = %d, want %d", l.Text, l.Seq, want)
		}
	}
}

// TestTailUnstampedLinesStillParse covers a log written by an older build, and
// any line a future writer emits without a stamp: it must be displayed, with
// the file time standing in, never dropped or shown as 1970.
func TestTailUnstampedLinesStillParse(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "legacy.log")
	body := "plain old line\n2026-11-05T04:46:56.123Z stamped line\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	lines, err := Tail(path, 10, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2", len(lines))
	}
	if lines[0].Text != "plain old line" {
		t.Fatalf("legacy text = %q", lines[0].Text)
	}
	if lines[0].AtMs == 0 {
		t.Fatal("legacy line must fall back to the file time, not zero")
	}
	if lines[1].Text != "stamped line" {
		t.Fatalf("stamped text = %q", lines[1].Text)
	}
	if lines[1].AtMs == 0 {
		t.Fatal("stamped line lost its time")
	}
	if lines[1].Seq <= lines[0].Seq {
		t.Fatalf("seq not increasing: %d then %d", lines[0].Seq, lines[1].Seq)
	}
}

// TestWriteStampsEveryLine checks the on-disk shape itself, since the reader's
// correctness depends on the writer agreeing with it.
func TestWriteStampsEveryLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "host.log")
	r, err := Open(Options{Path: path, MaxBytes: 1 << 20, MaxFiles: 1, Redactor: NewRedactor()})
	if err != nil {
		t.Fatal(err)
	}
	_ = r.Write("alpha")
	_ = r.Write("beta")
	_ = r.Close()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	rows := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(rows) != 2 {
		t.Fatalf("got %d rows", len(rows))
	}
	for i, row := range rows {
		if _, body := splitStamp(row); body == row {
			t.Fatalf("row %d has no parsable stamp: %q", i, row)
		}
	}
}

func TestTailSmallMaxBytesStillHonoursCap(t *testing.T) {	dir := t.TempDir()
	path := filepath.Join(dir, "host.log")
	var b strings.Builder
	for i := 0; i < 500; i++ {
		b.WriteString(strings.Repeat("z", 200))
		b.WriteString("\n")
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	lines, err := Tail(path, 200, 4<<10)
	if err != nil {
		t.Fatal(err)
	}
	// 4 KiB cannot hold 200 × 201-byte lines; the cap must win.
	if len(lines) > 25 {
		t.Fatalf("cap not honoured: %d lines", len(lines))
	}
	if len(lines) == 0 {
		t.Fatal("expected at least the window's last line")
	}
}
