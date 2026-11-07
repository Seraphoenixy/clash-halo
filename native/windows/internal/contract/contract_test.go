package contract

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDecodeRequestAcceptsValid(t *testing.T) {
	req, errObj := DecodeRequest([]byte(`{"v":1,"id":"a1","action":"snapshot.get"}`))
	if errObj != nil {
		t.Fatalf("unexpected error: %v", errObj)
	}
	if req.Action != ActionSnapshotGet || req.ID != "a1" || req.V != ProtocolVersion {
		t.Fatalf("decoded wrong: %+v", req)
	}
}

func TestDecodeRequestRejectsWrongVersion(t *testing.T) {
	_, errObj := DecodeRequest([]byte(`{"v":9,"id":"x","action":"snapshot.get"}`))
	if errObj == nil {
		t.Fatal("expected version rejection")
	}
	if errObj.Code != ErrProtocolVersion {
		t.Fatalf("code = %s", errObj.Code)
	}
	if !strings.Contains(errObj.Detail, "v=9") {
		t.Fatalf("detail should name the received version: %s", errObj.Detail)
	}
}

func TestDecodeRequestRejectsMissingAction(t *testing.T) {
	cases := []string{
		`{"v":1,"id":"x"}`,
		`{"v":1,"action":""}`,
		`not json at all`,
		`{"v":"1","action":"snapshot.get"}`,
		`[]`,
	}
	for _, raw := range cases {
		if _, errObj := DecodeRequest([]byte(raw)); errObj == nil {
			t.Fatalf("%s should be rejected", raw)
		}
	}
}

func TestDecodeParams(t *testing.T) {
	req := &Request{Params: json.RawMessage(`{"mode":"global"}`)}
	var p struct {
		Mode string `json:"mode"`
	}
	if e := DecodeParams(req, &p); e != nil {
		t.Fatalf("unexpected: %v", e)
	}
	if p.Mode != "global" {
		t.Fatalf("mode = %q", p.Mode)
	}
	// Absent params is not an error.
	req.Params = nil
	if e := DecodeParams(req, &p); e != nil {
		t.Fatalf("absent params should be fine: %v", e)
	}
	// Wrong type is an error carrying the code.
	req.Params = json.RawMessage(`{"mode":5}`)
	if e := DecodeParams(req, &p); e == nil || e.Code != ErrBadRequest {
		t.Fatalf("expected bad_request, got %v", e)
	}
}

func TestEncodeNeverEmbedsRawNewline(t *testing.T) {
	b, err := Encode(Response{V: 1, ID: "x", Ok: true,
		Result: map[string]any{"msg": "line1\nline2"}})
	if err != nil {
		t.Fatal(err)
	}
	body := strings.TrimSuffix(string(b), "\n")
	if strings.Count(body, "\n") != 0 {
		t.Fatalf("payload contains a raw newline: %q", body)
	}
	var back map[string]any
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("encoded frame is not valid JSON: %v", err)
	}
	if back["ok"] != true {
		t.Fatalf("ok lost: %v", back)
	}
}

func TestEncodeSingleLinePerFrame(t *testing.T) {
	b, _ := Encode(Event{V: 1, Event: EventStateChanged, Seq: 3,
		Data: map[string]any{"coreState": "running"}})
	if !strings.HasSuffix(string(b), "\n") {
		t.Fatal("frame must end with a newline")
	}
	if strings.Count(string(b), "\n") != 1 {
		t.Fatalf("frame must contain exactly one newline: %q", string(b))
	}
}

func TestParseLines(t *testing.T) {
	lines, rest, errObj := ParseLines([]byte("a\nb\npartial"), 64)
	if errObj != nil {
		t.Fatalf("unexpected: %v", errObj)
	}
	if len(lines) != 2 || string(lines[0]) != "a" || string(lines[1]) != "b" {
		t.Fatalf("lines = %q", lines)
	}
	if string(rest) != "partial" {
		t.Fatalf("rest = %q", rest)
	}
	// CRLF is tolerated.
	lines, _, _ = ParseLines([]byte("x\r\n"), 64)
	if string(lines[0]) != "x" {
		t.Fatalf("CRLF not stripped: %q", lines[0])
	}
	// Blank lines are dropped rather than dispatched.
	lines, _, _ = ParseLines([]byte("\n\n\n"), 64)
	if len(lines) != 0 {
		t.Fatalf("blank lines should be skipped: %d", len(lines))
	}
	// Oversized input is refused instead of buffered forever.
	if _, _, e := ParseLines([]byte(strings.Repeat("x", 100)), 64); e == nil {
		t.Fatal("oversize line should be rejected")
	}
}

func TestErrorObjFormatting(t *testing.T) {
	e := &ErrorObj{Code: "bad", Message: "坏了", Detail: "ctx"}
	if !strings.Contains(e.Error(), "bad") || !strings.Contains(e.Error(), "坏了") {
		t.Fatalf("error string = %s", e.Error())
	}
	if (&ErrorObj{Code: "c", Message: "m"}).Error() != "c: m" {
		t.Fatal("no-detail formatting changed")
	}
}

func TestResponseShapeMatchesDart(t *testing.T) {
	// The Dart side reads exactly v, id, ok, result, error, stateVersion.
	b, _ := Encode(OK("x", map[string]any{"a": 1}, 7))
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	for _, key := range []string{"v", "id", "ok", "stateVersion"} {
		if _, ok := m[key]; !ok {
			t.Fatalf("response missing %q: %v", key, m)
		}
	}
	if _, ok := m["error"]; ok {
		t.Fatalf("success response must not carry error: %v", m)
	}
	b, _ = Encode(Fail("x", NewError("c", "m"), 7))
	// Fresh map: Unmarshal into a populated map would retain the old keys
	// and make this assertion meaningless.
	m = nil
	_ = json.Unmarshal(b, &m)
	if _, ok := m["result"]; ok {
		t.Fatalf("failure response must not carry result: %v", m)
	}
	if _, ok := m["error"]; !ok {
		t.Fatalf("failure response must carry error: %v", m)
	}
}
