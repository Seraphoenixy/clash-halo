package elevate

import "strings"

// quoteArgs builds the command-line tail ShellExecuteEx wants.
//
// The shell takes one string rather than an argv, so the standard Windows
// quoting rules have to be applied here: a path containing a space must survive
// as a single argument, and a path ending in a backslash must not have that
// backslash eat the closing quote. Getting this wrong would silently pass the
// wrong config path to an elevated process.
func quoteArgs(args []string) string {
	parts := make([]string, 0, len(args))
	for _, a := range args {
		parts = append(parts, quoteArg(a))
	}
	return strings.Join(parts, " ")
}

// quoteArg quotes one argument following the CommandLineToArgvW rules.
func quoteArg(a string) string {
	if a != "" && !strings.ContainsAny(a, " \t\n\v\"") {
		return a
	}
	var b strings.Builder
	b.WriteByte('"')
	backslashes := 0
	for i := 0; i < len(a); i++ {
		switch c := a[i]; c {
		case '\\':
			backslashes++
		case '"':
			// Double the preceding backslashes, then escape the quote itself.
			b.WriteString(strings.Repeat(`\`, backslashes*2+1))
			backslashes = 0
			b.WriteByte('"')
		default:
			if backslashes > 0 {
				b.WriteString(strings.Repeat(`\`, backslashes))
				backslashes = 0
			}
			b.WriteByte(c)
		}
	}
	// Trailing backslashes must be doubled so they do not escape the closing
	// quote, which is what turns "C:\dir\" into the argument "C:\dir".
	if backslashes > 0 {
		b.WriteString(strings.Repeat(`\`, backslashes*2))
	}
	b.WriteByte('"')
	return b.String()
}
