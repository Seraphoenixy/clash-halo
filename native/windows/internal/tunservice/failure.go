package tunservice

import "strings"

// Known ways a core start fails because something beside it is missing.
//
// These are not configuration mistakes: the user did not write the config that
// needs a library, and cannot fix it by editing a node. They are install-time
// gaps, so the message has to say what the app will do about it rather than
// repeat the loader's English FATAL line as if it were the user's fault.
const (
	coreFailureCronet = "cronet: library not found"
)

// DescribeCoreFailure turns a `sing-box check` failure into a sentence that
// names the cause and the next step. It returns "" when the failure is not one
// it recognises, so the caller keeps the core's own words.
func DescribeCoreFailure(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return ""
	}
	lower := strings.ToLower(text)
	if strings.Contains(lower, coreFailureCronet) {
		return "TUN 服务缺少内核运行时组件 libcronet.dll（Naive 节点需要），" +
			"请重新启用 TUN 以自动补装；若仍然失败，请重新安装应用"
	}
	return ""
}

// coreFailureMessage composes what the service reports for a failed check.
//
// The core's own output stays attached: when the mapping above does not apply,
// it is the only evidence the user can send with a bug report, and when it does
// apply it is still how a maintainer confirms which library was missing.
func coreFailureMessage(raw string) string {
	detail := strings.TrimSpace(raw)
	if hint := DescribeCoreFailure(detail); hint != "" {
		return hint + "（内核输出：" + firstLine(detail) + "）"
	}
	return "配置未通过内核校验: " + detail
}

func firstLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}
