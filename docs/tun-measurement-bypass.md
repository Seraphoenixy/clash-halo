# 测速流量绕过 TUN：评估

本文评估“TUN 开启时，节点测速流量绕过 TUN”这个功能。它不涉及 TUN 本身是否
需要——TUN 是必需功能，服务方案已启用。本文只讨论测速路径。

当前状态：**已启用**（`internal/app/probe.go` 的 `probeTunBypassEnabled = true`）。
TUN 开启时，测速内核与原始探测绑定物理源地址，DNS 经回环中继转 DoH 后从物理
路径发出；不会把经 TUN 的结果当成节点结果。节点裸路径与 TUN 实际路径仍是两个
不同口径，节点排名使用前者。

## 1. 为什么需要

代理模式不拦截套接字，宿主和临时测试内核可以直连；TUN 不同，它通过默认路由
接管整机流量。TUN 开启时：

- 原始 TCP/UDP 探测（`tcp` / `udp`）从宿主直接 dial，目标 SYN 会进入 TUN，经当前
  节点出站。测的是“当前节点 + 被测地址”，不是被测节点。
- 临时测试内核的出站同样走系统路由，会进入 TUN；DNS 也可能被 TUN 劫持。
- 结果不只是变慢：一个死节点可能因为当前节点可达而显示“通”，把最需要发现的
  问题掩盖掉。

因此“绕过”不是性能优化，而是测量正确性的前提。

## 2. 实现方式

1. **选择物理网卡**：`GetAdaptersAddresses` 枚举适配器，要求 up、非 loopback、
   非 tunnel、有全局 IPv4；优先有默认网关且 `Ipv4Metric` 最低的，排除快照中的
   TUN 适配器名（快照缺失时从 TUN 运行时配置读取名字）。
2. **测试内核出站**：给每个可拨号的出站写入 `inet4_bind_address`，把
   `route.auto_detect_interface` 置为 false。**不写 `bind_interface`**：真实 TUN
   下该项会让 direct 出站超时，即使源地址已经正确；Windows 会按绑定的源地址
   选择物理网卡。
3. **DNS**：用本地 UDP 中继替代测试配置的 DNS；中继把查询从绑定物理源地址的
   TCP 连接发往 `https://223.5.5.5/dns-query`，再以 DNS 报文返回。TUN 会拦截
   物理源地址的明文 UDP/53，DoH 走 443，节点域名与目标域名都不经过 TUN。
4. **原始探测**：TCP 绑定物理 IPv4 后拨号，UDP 从绑定物理 IPv4 的 socket 发出；
   域名通过上述回环中继解析。
5. **裸 endpoint**（没有节点配置时）：TUN 开启一律拒绝，因为它无法被重新绑定。

代理模式不需要这套绑定；它只需要“测试内核使用自己的配置、不把当前系统代理入口
当测试代理”，这部分是独立且已强制执行的。

## 3. 收益

- TUN 开启时仍能测到被测节点本身，而不是当前出口。
- 测速不会给当前隧道额外增加流量，也不会干扰正在使用的节点。
- 失败是显式的：找不到物理网卡或绑定失败时报告“未执行”，不会给出错误数字。

## 4. 代价

- 约 350 行 Windows 专用代码（IP Helper 枚举、绑定、DNS 中继）与对应测试。
- 多网卡/VPN/热切换场景需要选择策略：当前选“有默认网关且 metric 最低的非 TUN
  网卡”，多宿主或另一层 VPN 下可能选错；选错会失败或绕到另一条路径。
- 测试内核必须支持 `inet4_bind_address`（已在 sing-box 1.14.4 上用 direct 出站
  验证）。真实 TUN 下验证了延迟、下载与原始 TCP；VMess/Trojan/Hysteria2 等节点
  协议的完整连接仍未端到端验证。
- DNS 依赖 `223.5.5.5:443` 的 DoH 可达。该地址或 443 被阻断时，测速会失败而
  不是退回经 TUN 测量；明文 UDP/53 在真实 TUN 下不可用。

## 5. 已完成的验证

- 测试配置改写：活动内核的入站、控制器与 `services` 不进入测试配置
  （`TestPrepareProbeDocumentDropsActiveCore`）。
- 物理绑定字段、DNS 中继、`auto_detect_interface` 改写
  （`TestPrepareProbeDocumentBindsEgress`）。
- DNS 中继把查询从绑定 socket 转发（`TestDNSRelayForwardsThroughBoundSocket`）。
- 物理网卡发现（`TestDiscoverProbeEgressFindsAPhysicalPath`）。
- 真实内核经物理网卡出站（opt-in）：
  `HALO_PROBE_EGRESS_NET=1 HALO_PROBE_EGRESS_EXCLUDE=clash-halo go test ./internal/app -run TestProbeConfigThroughPhysicalEgress -v`
  → `egress WLAN (192.168.31.126): 289 ms PASS`。
- 2026-11-08 真实 TUN（`strict_route:true`、适配器 `clash-halo`、物理网卡
  `WLAN 192.168.31.126`）：
  - `TestDNSRelayPublicUnderTun`：DoH 中继返回 `www.baidu.com` 的 A/AAAA。
  - `TestTunBypassRunsProbeWithRealTun`：延迟 292 ms，`runProbes` 全链路通过。
  - `TestTunBypassDownloadWithRealTun`：`9,693,741 B/s`。
  - `TestTunBypassRawTCPWithRealTun`：`www.baidu.com:443` 17 ms。
  - `go test ./internal/app -count=1` 通过。
- 未验证：真实节点协议（VMess/Trojan/Hysteria2 等）经物理源地址的完整连接、
  多网卡/另一层 VPN 下的网卡选择、UDP 节点协议。

## 6. 结论

**收益明确，代价局限在测量路径。** 该功能用于“测节点本身、比较节点快慢”，
已经默认启用；它不改变正常代理或 TUN 流量。

节点排名使用节点裸路径；如果需要“用户经 TUN 后的实际速度”，必须另设指标，
不能与这里的数字合并。节点协议的完整端到端、多网卡选择和 UDP 节点协议仍需
继续验证，失败时宿主显式报告 `probe_isolation` 或 `probe_failed`，不会把经
TUN 的结果当成节点结果。

## 7. 不改变的部分

- **代理模式的测速流量必须直连**：测试内核使用自己的临时入站与配置，活动的
  系统代理入口不会被当作测试代理；裸 endpoint 或测试出站指向前者时直接拒绝。
- **解锁检测**仍经当前内核的 mixed 入站，因为它要测的就是当前出口地区，与测速
  是两类测量。
