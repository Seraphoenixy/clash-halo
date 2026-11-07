package app

import "testing"

// The system proxy must follow the port the config actually listens on, which
// means the host has to read that port back out of the document it was given.
func TestMixedInboundPort(t *testing.T) {
	cases := []struct {
		name string
		doc  string
		want int
	}{
		{
			name: "mixed wins over socks and http",
			doc:  `{"inbounds":[{"type":"http","listen_port":7000},{"type":"mixed","listen_port":7891}]}`,
			want: 7891,
		},
		{
			name: "falls back to socks when there is no mixed inbound",
			doc:  `{"inbounds":[{"type":"socks","listen_port":1080}]}`,
			want: 1080,
		},
		{
			name: "falls back to http",
			doc:  `{"inbounds":[{"type":"http","listen_port":8080}]}`,
			want: 8080,
		},
		{
			name: "ignores inbounds without a port",
			doc:  `{"inbounds":[{"type":"mixed"},{"type":"socks","listen_port":1080}]}`,
			want: 1080,
		},
		{
			name: "no inbounds means no opinion",
			doc:  `{"inbounds":[]}`,
			want: 0,
		},
		{
			name: "invalid json is not a crash",
			doc:  `{`,
			want: 0,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mixedInboundPort(tc.doc); got != tc.want {
				t.Fatalf("mixedInboundPort = %d, want %d", got, tc.want)
			}
		})
	}
}
