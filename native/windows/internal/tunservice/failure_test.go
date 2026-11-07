package tunservice

import (
	"strings"
	"testing"
)

func TestDescribeCoreFailure(t *testing.T) {
	// The observed output from sing-box 1.14.4 when libcronet.dll is absent
	// beside the approved core. Copied verbatim from the service log rather than
	// paraphrased: the check matches this exact wording.
	const observed = "FATAL[0000] initialize outbound[0]: cronet: library not found. " +
		"Place libcronet.dll in the executable directory or PATH"

	hint := DescribeCoreFailure(observed)
	if hint == "" {
		t.Fatal("the cronet failure must be recognised")
	}
	if !strings.Contains(hint, "libcronet.dll") {
		t.Fatalf("hint does not name the missing file: %q", hint)
	}
	// The next step has to be in the sentence; "missing library" alone leaves the
	// user with nothing to do.
	if !strings.Contains(hint, "重新启用 TUN") {
		t.Fatalf("hint does not say what to do: %q", hint)
	}

	if got := DescribeCoreFailure("FATAL[0000] decode config at line 3: unknown field"); got != "" {
		t.Fatalf("unrelated failures must not be reinterpreted: %q", got)
	}
	if got := DescribeCoreFailure("   "); got != "" {
		t.Fatalf("empty input must map to empty: %q", got)
	}
}

func TestCoreFailureMessageKeepsTheCoreOutput(t *testing.T) {
	const observed = "FATAL[0000] initialize outbound[0]: cronet: library not found. " +
		"Place libcronet.dll in the executable directory or PATH"

	msg := coreFailureMessage(observed)
	// A maintainer confirms the diagnosis from the raw line, so it must survive.
	if !strings.Contains(msg, "FATAL[0000]") {
		t.Fatalf("raw core output dropped: %q", msg)
	}
	if !strings.Contains(msg, "TUN 服务缺少内核运行时组件") {
		t.Fatalf("plain-language cause missing: %q", msg)
	}

	// An unrecognised failure keeps the previous shape so existing greps and
	// expectations still find "配置未通过内核校验".
	other := coreFailureMessage("decode config: unknown field \"foo\"")
	if !strings.HasPrefix(other, "配置未通过内核校验: ") {
		t.Fatalf("unrecognised failure changed shape: %q", other)
	}
}
