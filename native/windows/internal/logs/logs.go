// Package logs implements a size-bounded rolling log with credential
// redaction.
//
// Three invariants:
//  1. the total on-disk footprint never exceeds a configured byte budget;
//  2. no credential ever reaches disk, because every line is redacted before
//     it is written, not filtered afterwards;
//  3. `log.tail` reads at most a bounded number of bytes so a huge file can
//     never be pulled into the UI in one response.
package logs

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Redactor replaces known secrets with a placeholder.
type Redactor struct {
	mu      sync.RWMutex
	secrets []string
}

// NewRedactor builds an empty redactor.
func NewRedactor() *Redactor { return &Redactor{} }

// Set replaces the registered secret list. Short values (< 4 bytes) are
// ignored so a one-character password does not turn every log line into noise.
func (r *Redactor) Set(secrets ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.secrets = r.secrets[:0]
	for _, s := range secrets {
		if len(s) >= 4 {
			r.secrets = append(r.secrets, s)
		}
	}
	// Longest first so a secret that is a substring of another cannot leave a
	// fragment behind.
	sort.Slice(r.secrets, func(i, j int) bool { return len(r.secrets[i]) > len(r.secrets[j]) })
}

// Redact applies the registered secret list.
func (r *Redactor) Redact(line string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, secret := range r.secrets {
		if strings.Contains(line, secret) {
			line = strings.ReplaceAll(line, secret, "***")
		}
	}
	return line
}

// Rotating is a bounded log sink.
type Rotating struct {
	mu       sync.Mutex
	path     string
	maxBytes int64
	maxFiles int
	size     int64
	redact   *Redactor
	file     *os.File
	// closed makes Close final. Without it a late Write would reopen the file
	// through openLocked and leak a handle past the owner's cleanup.
	closed bool
}

// Options configures a Rotating log.
type Options struct {
	Path     string
	MaxBytes int64
	MaxFiles int
	Redactor *Redactor
}

// DefaultOptions: 2 MiB × 3 files = 6 MiB ceiling.
func DefaultOptions(path string, redactor *Redactor) Options {
	return Options{Path: path, MaxBytes: 2 << 20, MaxFiles: 3, Redactor: redactor}
}

// Open prepares the log directory and rotates any oversized existing file.
func Open(opts Options) (*Rotating, error) {
	if opts.MaxBytes <= 0 {
		opts.MaxBytes = 2 << 20
	}
	if opts.MaxFiles < 1 {
		opts.MaxFiles = 1
	}
	if opts.Redactor == nil {
		opts.Redactor = NewRedactor()
	}
	if err := os.MkdirAll(filepath.Dir(opts.Path), 0o700); err != nil {
		return nil, err
	}
	r := &Rotating{
		path:     opts.Path,
		maxBytes: opts.MaxBytes,
		maxFiles: opts.MaxFiles,
		redact:   opts.Redactor,
	}
	if info, err := os.Stat(opts.Path); err == nil {
		r.size = info.Size()
		if r.size >= r.maxBytes {
			if err := r.rotateLocked(); err != nil {
				return nil, err
			}
		}
	}
	if r.file == nil {
		if err := r.openLocked(); err != nil {
			return nil, err
		}
	}
	return r, nil
}

// stampLayout is the per-line timestamp written in front of every line.
//
// UTC with milliseconds: sortable as plain text, unambiguous across DST and
// time zones, and fixed-width so parsing is a slice rather than a regexp.
const stampLayout = "2006-01-02T15:04:05.000Z"

// stampLen is len("2026-11-05T04:46:56.123Z"), the part before the separator.
const stampLen = 24

// Write appends one line (a trailing newline is added if missing), rotating
// before the write when the budget would be exceeded.
//
// The line gets a real timestamp stamped in front of it. Without one the reader
// had nothing to go on but the file's modification time, so every historical
// line appeared to move forward whenever anything else was appended, and the
// log page — which deduplicated on that time — could re-append whole batches.
func (r *Rotating) Write(line string) error {
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return nil
	}
	redacted := r.redact.Redact(line)
	if len(redacted) > 2048 {
		redacted = redacted[:2048] + "…"
	}
	payload := time.Now().UTC().Format(stampLayout) + " " + redacted + "\n"
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return errors.New("日志已关闭")
	}
	// A previous rotation may have failed to reopen the file; retry here so a
	// transient error (a scanner holding the file, a temporarily full disk)
	// does not keep the host logging into nothing forever.
	if r.file == nil {
		if err := r.openLocked(); err != nil {
			return err
		}
	}
	if r.size+int64(len(payload)) > r.maxBytes {
		_ = r.rotateLocked()
	}
	if r.file == nil {
		return errors.New("日志文件不可用，已跳过本次写入")
	}
	if _, err := r.file.WriteString(payload); err != nil {
		return err
	}
	r.size += int64(len(payload))
	return nil
}

// openLocked reopens the active file for append and re-reads its size.
// Callers hold r.mu.
func (r *Rotating) openLocked() error {
	if r.closed {
		return errors.New("日志已关闭")
	}
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	r.file = f
	if info, err := f.Stat(); err == nil {
		r.size = info.Size()
	}
	return nil
}

// Writef formats and writes a line.
func (r *Rotating) Writef(format string, args ...any) {
	_ = r.Write(fmt.Sprintf(format, args...))
}

func (r *Rotating) rotateLocked() error {
	if r.file != nil {
		_ = r.file.Close()
		r.file = nil
	}
	// Shift .1 -> .2, ... keeping at most maxFiles-1 archives.
	for i := r.maxFiles - 1; i >= 1; i-- {
		src := r.path
		if i > 1 {
			src = archivePath(r.path, i-1)
		}
		dst := archivePath(r.path, i)
		if _, err := os.Stat(src); err == nil {
			_ = os.Remove(dst)
			_ = os.Rename(src, dst)
		}
	}
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		// Do not retry the archive shift on every subsequent line: Write
		// reopens before rotating, and a nil file here means the next Write
		// retries a plain open rather than running this loop again.
		return err
	}
	r.file = f
	r.size = 0
	return nil
}

func archivePath(path string, index int) string {
	return path + "." + itoa(index)
}

func itoa(n int) string {
	if n <= 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

// Size returns the current primary file size.
func (r *Rotating) Size() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.size
}

// TotalSize sums the primary file and every archive, for the memory budget
// report in the snapshot.
func (r *Rotating) TotalSize() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	var total int64
	for i := 0; i < r.maxFiles; i++ {
		p := r.path
		if i > 0 {
			p = archivePath(r.path, i)
		}
		if info, err := os.Stat(p); err == nil {
			total += info.Size()
		}
	}
	return total
}

// Close flushes and closes the primary file.
func (r *Rotating) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	if r.file == nil {
		return nil
	}
	err := r.file.Close()
	r.file = nil
	return err
}

// Tail returns the last n lines of the primary log, capped at maxBytes read so
// a large file cannot stall a request.
//
// The window is found by scanning backward from the end instead of reading the
// whole maxBytes range up front: the log page tails every 1.5 s, and the last
// 200 lines almost never need 512 KiB. The scan walks 8 KiB chunks counting
// newlines until the window is guaranteed to hold more than `lines` complete
// lines (a newline terminates a line, so `lines` lines need `lines` newlines —
// counting one extra keeps a partial line at the window's left edge out of the
// result even when the file has content before it), or maxBytes is reached, or
// the file start is hit. The window is then read in one pass and split with the
// same trim/split/keep-last logic as before, so the output is byte-identical to
// the full-window read.
//
// Every line carries its own timestamp in front (see [stampLayout]); the
// returned [TailLine.AtMs] is that stamp, not the file's modification time. A
// line without a parsable stamp — an older log file, or a line written before
// this format existed — reports the file time as before, so nothing turns into
// a zero that the UI would render as 1970.
func Tail(path string, lines int, maxBytes int64) ([]TailLine, error) {
	if lines <= 0 || lines > 2000 {
		lines = 200
	}
	if maxBytes <= 0 || maxBytes > 1<<20 {
		maxBytes = 512 << 10
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	size := info.Size()

	const chunkSize = 8 << 10
	start := size
	found := 0
	for start > 0 && found <= lines && size-start < maxBytes {
		step := int64(chunkSize)
		if step > start {
			step = start
		}
		if step > maxBytes-(size-start) {
			step = maxBytes - (size - start)
		}
		if step <= 0 {
			break
		}
		buf := make([]byte, step)
		if _, err := f.ReadAt(buf, start-step); err != nil && !errors.Is(err, io.EOF) {
			return nil, err
		}
		for i := len(buf) - 1; i >= 0; i-- {
			if buf[i] == '\n' {
				found++
			}
		}
		start -= step
	}

	window := size - start
	buf := make([]byte, window)
	if _, err := f.ReadAt(buf, start); err != nil && len(buf) > 0 {
		// A short read at EOF is acceptable; only true errors matter.
		if !strings.Contains(err.Error(), "EOF") {
			return nil, err
		}
	}
	text := string(buf)
	all := strings.Split(strings.TrimRight(text, "\n"), "\n")
	// The byte offset of the window inside the file. `start` already accounts
	// for the backward scan; lines dropped by the `lines` cap below must still
	// advance it, or every kept line would report the wrong position.
	offset := start
	if len(all) > lines {
		for _, dropped := range all[:len(all)-lines] {
			offset += int64(len(dropped)) + 1
		}
		all = all[len(all)-lines:]
	}
	out := make([]TailLine, 0, len(all))
	for _, line := range all {
		lineLen := int64(len(line)) + 1 // the newline this line was split on
		if strings.TrimSpace(line) == "" {
			offset += lineLen
			continue
		}
		atMs, body := splitStamp(line)
		if atMs == 0 {
			atMs = info.ModTime().UnixMilli()
		}
		out = append(out, TailLine{
			Seq:  offset,
			AtMs: atMs,
			Text: body,
		})
		offset += lineLen
	}
	return out, nil
}

// splitStamp separates the leading timestamp from a stored line.
//
// Returns (0, line) when the prefix is missing or not a valid stamp, which is
// the case for the whole of a log written by an older build. Parsing is
// deliberately strict about the format we write and silent about anything else:
// a malformed line must still be displayed, never dropped.
func splitStamp(line string) (int64, string) {
	if len(line) < stampLen+1 || line[stampLen] != ' ' {
		return 0, line
	}
	stamp := line[:stampLen]
	t, err := time.Parse(stampLayout, stamp)
	if err != nil {
		return 0, line
	}
	return t.UnixMilli(), line[stampLen+1:]
}

// TailLine is one log line returned by log.tail.
type TailLine struct {
	// Seq is the byte offset of the line inside the file. It is stable for a
	// given line and strictly increasing across the file, so the UI can append
	// only the lines with Seq greater than the last one it already holds
	// instead of pattern-matching text.
	Seq  int64  `json:"seq"`
	AtMs int64  `json:"atMs"`
	Text string `json:"text"`
}
