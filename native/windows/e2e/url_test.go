package e2e

import "net/url"

// urlpkgURL aliases the standard type so the proxy callback signature reads
// cleanly at the call site.
type urlpkgURL = url.URL

// parseURL adapts url.Parse for the proxy callback, which returns (*url.URL, error).
func parseURL(raw string) (*url.URL, error) { return url.Parse(raw) }
