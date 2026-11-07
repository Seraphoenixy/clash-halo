package app

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// probeEgress is the physical path measurements must use.
//
// When TUN is active it owns the default route, so an unbound socket from the
// host (the TCP/UDP reachability checks) and an unbound outbound in the
// disposable probe core would both be captured by the tunnel — the test would
// silently measure the active node instead of the node under test. Binding the
// sockets and outbounds to the physical adapter keeps measurement traffic off
// both the system proxy and the tunnel.
type probeEgress struct {
	Name    string
	IPv4    net.IP
	IfIndex uint32
	// DNS is the upstream resolver host:port reachable from the physical
	// adapter. The relay below forwards loopback queries to it.
	DNS string
	// DNSListen is the loopback address the relay listens on while a probe run
	// is in flight. It is what the probe core is configured to use.
	DNSListen string
}

// discoverProbeEgress picks the physical adapter that should carry
// measurements, excluding the TUN adapter by name.
//
// Candidates must be up, not loopback or tunnel interfaces, and have a global
// IPv4 address. An adapter with a default gateway and a lower IPv4 metric wins;
// without a gateway the adapter is still usable on a single-homed machine, so
// it is kept as a fallback instead of failing the whole measurement.
func discoverProbeEgress(excludeAdapter string) (*probeEgress, error) {
	const flags = windows.GAA_FLAG_INCLUDE_GATEWAYS
	size := uint32(16 << 10)
	var first *windows.IpAdapterAddresses
	var buf []byte
	ok := false
	for attempt := 0; attempt < 4; attempt++ {
		buf = make([]byte, size)
		first = (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0]))
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, flags, 0, first, &size)
		if err == nil {
			ok = true
			break
		}
		if !errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) {
			return nil, fmt.Errorf("无法枚举网卡: %w", err)
		}
		if size < 8<<10 {
			size = 8 << 10
		}
	}
	if !ok || first == nil {
		return nil, errors.New("无法枚举网卡")
	}

	type candidate struct {
		egress  probeEgress
		score   uint64
		gateway bool
	}
	var best *candidate
	for adapter := first; adapter != nil; adapter = adapter.Next {
		if adapter.OperStatus != windows.IfOperStatusUp {
			continue
		}
		if adapter.IfType == windows.IF_TYPE_SOFTWARE_LOOPBACK ||
			adapter.IfType == windows.IF_TYPE_TUNNEL {
			continue
		}
		name := windows.UTF16PtrToString(adapter.FriendlyName)
		if excludeAdapter != "" && strings.EqualFold(name, excludeAdapter) {
			continue
		}
		ip := firstIPv4Unicast(adapter.FirstUnicastAddress)
		if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
			continue
		}
		gateway := hasIPv4Gateway(adapter.FirstGatewayAddress)
		score := uint64(adapter.Ipv4Metric)
		if !gateway {
			score += 1 << 40
		}
		if best != nil && score >= best.score {
			continue
		}
		dns := firstIPv4DNSServer(adapter.FirstDnsServerAddress)
		if dns == "" {
			dns = "223.5.5.5:53"
		}
		best = &candidate{
			egress: probeEgress{
				Name:    name,
				IPv4:    ip,
				IfIndex: adapter.IfIndex,
				DNS:     dns,
			},
			score:   score,
			gateway: gateway,
		}
	}
	if best == nil {
		return nil, fmt.Errorf("找不到可用的物理网卡（已排除 %q）", excludeAdapter)
	}
	return &best.egress, nil
}

func firstIPv4Unicast(list *windows.IpAdapterUnicastAddress) net.IP {
	for entry := list; entry != nil; entry = entry.Next {
		if ip := sockaddrIPv4(entry.Address); ip != nil {
			return ip
		}
	}
	return nil
}

func firstIPv4DNSServer(list *windows.IpAdapterDnsServerAdapter) string {
	for entry := list; entry != nil; entry = entry.Next {
		if ip := sockaddrIPv4(entry.Address); ip != nil {
			return net.JoinHostPort(ip.String(), "53")
		}
	}
	return ""
}

func hasIPv4Gateway(list *windows.IpAdapterGatewayAddress) bool {
	for entry := list; entry != nil; entry = entry.Next {
		if sockaddrIPv4(entry.Address) != nil {
			return true
		}
	}
	return false
}

func sockaddrIPv4(sa windows.SocketAddress) net.IP {
	if sa.Sockaddr == nil || sa.SockaddrLength < 2 {
		return nil
	}
	if sa.Sockaddr.Addr.Family != windows.AF_INET {
		return nil
	}
	if int(sa.SockaddrLength) < int(unsafe.Sizeof(syscall.RawSockaddrInet4{})) {
		return nil
	}
	v4 := (*syscall.RawSockaddrInet4)(unsafe.Pointer(sa.Sockaddr))
	return net.IPv4(v4.Addr[0], v4.Addr[1], v4.Addr[2], v4.Addr[3]).To4()
}

// tcpDialer binds to the physical adapter so the kernel does not send the SYN
// into the TUN default route.
func (e *probeEgress) tcpDialer(timeout time.Duration) *net.Dialer {
	return &net.Dialer{Timeout: timeout, LocalAddr: &net.TCPAddr{IP: e.IPv4}}
}

// udpListen binds a datagram socket to the physical adapter.
func (e *probeEgress) udpListen() (*net.UDPConn, error) {
	return net.ListenUDP("udp4", &net.UDPAddr{IP: e.IPv4})
}

// resolve resolves a node host through the physical path, not through the TUN's
// DNS hijack. Literal IPs are returned unchanged.
func (e *probeEgress) resolve(ctx context.Context, host string) (net.IP, error) {
	if ip := net.ParseIP(host); ip != nil {
		return ip, nil
	}
	if e.DNS == "" {
		return nil, errors.New("没有可用于测试的 DNS 服务器")
	}
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			dialer := &net.Dialer{Timeout: 4 * time.Second}
			switch {
			case strings.HasPrefix(network, "tcp"):
				dialer.LocalAddr = &net.TCPAddr{IP: e.IPv4}
			default:
				dialer.LocalAddr = &net.UDPAddr{IP: e.IPv4}
			}
			return dialer.DialContext(ctx, network, e.DNS)
		},
	}
	ips, err := resolver.LookupIPAddr(ctx, host)
	if err != nil {
		return nil, err
	}
	for _, addr := range ips {
		if v4 := addr.IP.To4(); v4 != nil {
			return v4, nil
		}
	}
	return nil, fmt.Errorf("%s 没有 IPv4 地址", host)
}

// dnsRelay forwards loopback DNS queries from the probe core to the physical
// resolver, from a socket bound to the physical adapter. The probe core sees a
// loopback server (never captured by the TUN); the wire query egresses on the
// physical path.
type dnsRelay struct {
	conn     *net.UDPConn
	upstream *net.UDPAddr
	local    net.IP
	once     sync.Once
}

func startDNSRelay(e *probeEgress) (*dnsRelay, error) {
	listen, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return nil, err
	}
	upstream, err := net.ResolveUDPAddr("udp4", e.DNS)
	if err != nil {
		_ = listen.Close()
		return nil, err
	}
	r := &dnsRelay{conn: listen, upstream: upstream, local: e.IPv4}
	go r.serve()
	return r, nil
}

func (r *dnsRelay) Addr() string { return r.conn.LocalAddr().String() }

func (r *dnsRelay) serve() {
	buf := make([]byte, 4096)
	for {
		n, from, err := r.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		query := append([]byte(nil), buf[:n]...)
		go r.forward(query, from)
	}
}

func (r *dnsRelay) forward(query []byte, from *net.UDPAddr) {
	conn, err := net.DialUDP("udp4", &net.UDPAddr{IP: r.local}, r.upstream)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(4 * time.Second))
	if _, err := conn.Write(query); err != nil {
		return
	}
	response := make([]byte, 4096)
	n, err := conn.Read(response)
	if err != nil {
		return
	}
	_, _ = r.conn.WriteToUDP(response[:n], from)
}

func (r *dnsRelay) Close() {
	r.once.Do(func() { _ = r.conn.Close() })
}

// applyProbeEgress rewrites a disposable probe config so every outbound and
// every DNS lookup uses the physical adapter and the relay.
func applyProbeEgress(config map[string]any, e *probeEgress, dnsAddr string) error {
	if e == nil {
		return errors.New("缺少测试出口")
	}
	outbounds, ok := config["outbounds"].([]any)
	if !ok || len(outbounds) == 0 {
		return errors.New("测试配置没有出站")
	}
	for _, raw := range outbounds {
		outbound, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		kind, _ := outbound["type"].(string)
		switch kind {
		case "block", "selector", "urltest":
			// No dial fields; adding them would fail validation.
			continue
		}
		outbound["bind_interface"] = e.Name
		outbound["inet4_bind_address"] = e.IPv4.String()
	}

	route, _ := config["route"].(map[string]any)
	if route == nil {
		route = map[string]any{}
		config["route"] = route
	}
	route["auto_detect_interface"] = false
	route["default_domain_resolver"] = map[string]any{"server": "probe-local"}

	host, portText, err := net.SplitHostPort(dnsAddr)
	if err != nil {
		return err
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return err
	}
	config["dns"] = map[string]any{
		"servers": []any{map[string]any{
			"type":        "udp",
			"tag":         "probe-local",
			"server":      host,
			"server_port": port,
		}},
		"final": "probe-local",
	}
	return nil
}
