# 测量语义

延迟、速度、连通性是三种不同的测量。任何把它们合并成"一个数"的做法都会得到
看起来正常、实际无意义的输出。这是本项目最容易反复犯的错误。

## 四种指标

| 指标 | 测什么 | 目标 | 预算 |
| --- | --- | --- | --- |
| `tcp` | 节点自身端口的 TCP 握手，不经代理 | `server:port` 直连 | 8s |
| `udp` | 经节点内核的真实往返（H3/Hysteria2 走 QUIC） | 204 | 8s |
| `proxy_latency` | 经节点临时内核的 HTTP 往返 | `gstatic.com/generate_204` | 8s |
| `download` | 真实字节吞吐 | `speed.cloudflare.com/__down?bytes=5000000` | 25s，上限 10 MiB |

定义在 `native/windows/internal/app/probe.go`，客户端镜像在
`packages/contracts/lib/src/speed.dart`。

## 测速流量不得经过当前代理

这是硬性要求，与 TUN 是否启用无关：

- **代理模式**：每个节点使用独立的临时内核和临时入站，配置里的入站、控制器与
  扩展段在启动前被替换或删除；宿主不会把当前系统代理入口当作测试代理，原始
  TCP/UDP 探测也不读系统代理设置。
- **TUN 模式**：绕过已**默认启用**（评估见
  [`docs/tun-measurement-bypass.md`](../tun-measurement-bypass.md)）。临时内核的
  出站绑定物理源地址，原始 TCP/UDP 探测同样绑定源地址；DNS 经回环中继转
  `https://223.5.5.5/dns-query`，从物理路径发出。找不到物理网卡或 DNS 中继失败
  时返回 `probe_isolation`，不会把经 TUN 的结果当成节点结果。注意：结果是节点
  裸路径，不等于开启 TUN 后的实际吞吐。
- **裸 endpoint**：只有节点自身地址可以直接探测；如果它与当前代理入口相同，
  宿主返回 `probe_failed`，不发起测量。测试配置里的出站如果指向当前代理入口，
  同样在启动测试内核之前被拒绝。

验证方式：`internal/app/probe_egress_test.go`（配置改写、代理入口拒绝、UDP 与
DoH 中继、物理网卡发现）以及 `HALO_PROBE_EGRESS_NET=1
HALO_PROBE_EGRESS_EXCLUDE=clash-halo` 的真实 TUN 测试（延迟、下载、原始 TCP）。

## 结果必须分开存放

```text
speedResults    延迟（proxy_latency）
downloadResults 吞吐（download）
reachability    连通（tcp / udp，再按 SpeedMetric 分键）
```

合并到一个 map 会让后跑的覆盖先跑的：测完延迟再测速度，延迟数字消失；反之亦然。
一个节点**同时**拥有延迟和吞吐，这是两个独立的槽位。

## 结果的归属与保存范围

结果由宿主保存，不放在界面进程里。界面是可关闭的客户端：关闭窗口不会取消正在
运行的批次，也不会清空已经完成的结果；宿主每完成一个探测就把结果写进会话。
重新打开界面后，`session.get` 取回结果与仍在运行的批次，节点页据此恢复进度和数字。

保存只到宿主退出为止，不写磁盘：托盘「退出」或 `host.shutdown` 后，下一次启动
是新的会话。删除节点时用 `speedtest.forget` 同步清理宿主中的该节点结果。

Windows 的流量统计同样由宿主每 2 秒采样一次，界面用 `traffic.get` 读取累计、
峰值和 40 点历史。界面关闭期间采样继续，重新打开不会从零开始。总览「实时流量」
与连接页顶部的速率、峰值、曲线、累计都读这一份宿主会话；连接页自己的采样器只
维护每行连接的速率，不再参与顶部统计。Android 没有独立宿主，应用进程结束即软件
结束，状态仍由 `AppController` 持有。

## 颜色不能共用

| 列 | 阈值 | 语义 |
| --- | --- | --- |
| 延迟 | `<=200` 绿 / `<=600` 黄 / `>600` 红 | 快慢 |
| 速度 | `>=2 MiB/s` 绿 / `>=500 KiB/s` 黄，其余红 | 快慢 |
| 端口连通 | "通"绿，"不通"**中性灰** | 成败 |

端口连通的"不通"故意不用红色：红色在延迟列已经表示"慢"，同一屏两套含义会误导。
"不通"由文字承担，颜色不再承载第二层语义。

## 状态必须可区分

| 状态 | 含义 |
| --- | --- |
| `—` | 未测 |
| 测试中 | 正在测量 |
| 数值 | 测到了 |
| 不可用 / 不通 | 测了，失败 |
| 已取消 | 用户中止 |
| 不适用 | 这项检查对它没有意义（如对纯 UDP 协议做 TCP 握手） |
| 未确认 | UDP 静默，无法区分开放与屏蔽 |

**"测通了但很慢"不能渲染成 `—`**，那和"从没测过"长得一样。

`not_applicable` 和 `udp_unconfirmed` 都不是失败。把它们当失败会冤枉能用的节点。

## 传输方式由节点配置决定，不由协议名决定

Naive 同一台服务器可能是 HTTP/2（TCP）或 HTTP/3（UDP），区别在
`extras['v2rayn']['naiveQuic']`。也接受直接放在 `extras['naiveQuic']`，且字符串
`'true'` 与布尔 `true` 等效（`extras` 会经 JSON 往返）。

判断入口是 `ProxyNode.isUdpTransport`：

- Hysteria2 / TUIC：恒为 UDP
- Naive：看 `naiveQuic`
- 其余：看 `network` 是否为 `quic` / `kcp`
- 否则 TCP（WebSocket、gRPC、HTTP 都跑在 TCP 之上）

**用 TCP 去测 H3 节点会把好节点判成"不通"。** 实测证据：同一服务器同密码的
`CN-Naive-H3` 走 UDP 探测成功（930 ms），`CN-Naive-H2` 走 TCP 失败（EOF）——
传输方式判断错了，结论就完全相反。

## 为什么下载是 5 MB / 25 秒

实测本机线路约 0.24 MiB/s：10 MB 需要 40 s 以上，永远撞上限，每个慢节点都会
被判失败——而慢节点恰恰是测速要找的对象。

读取按**时间**截断，而不是按字节：超时时已收到的字节仍然用于计算速率。慢节点应
该报告它真实的慢速度，而不是"不可用"。

客户端**不要**给 `download` 传 `timeoutMs`。传了会覆盖宿主为该指标准备的预算
（曾经客户端硬编码 8000，把 25 s 预算压回 8 s，等于让该功能从未生效）。

下载默认逐个节点执行。节点共享出口带宽时，并行下载会压低各自的测量值。
界面的并发设置用于延迟和连通性：默认 8，可选 1/2/4/8/16/32，宿主在
`probeWorkers` 里再夹一次 1..32，所以手改设置文件或旧客户端都绕不过上限。
可用本地基准比较开销和读数，无需启用 TUN：

```powershell
cd native/windows
..\..\.tools\go\bin\go.exe test ./internal/app -run '^$' -bench 'BenchmarkProbeBatch|BenchmarkDownloadSharedLink' -benchtime=2x
```

## 解锁检测是第四类测量，同样不能合并

| 项 | 测什么 | 出口 |
| --- | --- | --- |
| 解锁 | 某服务在当前出口下是否可用、它认为你在哪个地区 | 运行中内核的 mixed 入站 |

13 项服务各自独立：同一节点可以解锁 Netflix 而 ChatGPT 报"地区不支持"；哔哩哔哩
大陆与港澳台是两道不同的题。这些结论不能折成一个"解锁分"，也不能与延迟/速度同列。

代码：判定在 `apps/flutter/lib/src/state/unlock_checks.dart`，并发/取消/持久化在
`unlock_controller.dart`，页面在 `ui/pages/unlock_page.dart`。

三条硬规则：

1. **必须经当前内核的 mixed 入站**（`UnlockController.proxyResolver`）。直连会把
   本机地区当成节点地区上报——这是唯一一种看起来完全合理的错误答案。
2. **内核没运行时拒绝执行**，而不是让 13 项全部报失败：后者读起来像"这个节点什么
   都解锁不了"，而真实原因是没人替它发请求。
3. **"未检测"是中性灰，不是红**。刚打开页面时的 13 张红卡是在对检查结果下结论，
   而不是对节点。

复合结论（`Failed (GraphQL: 403)`）原样显示：它本身就是诊断信息，翻译成标签只会
丢掉唯一有用的细节。

**地区只显示 alpha-2，不要加国旗 emoji。** 参考实现拼的是「旗帜 + 码」，但 Windows
没有旗帜字形，两个区域指示符会原样渲染成字母，`JP` 到屏幕上变成 `JPJP`，而 alpha-3
的 `KOR` 又没有旗帜，于是同一页出现 `JPJP / KRKR / KOR` 三种样子。`unlockRegionLabel`
因此只做 alpha-3 → alpha-2 的归一（对照表由 .NET `RegionInfo` 生成，不是手写），
不拼旗帜。
