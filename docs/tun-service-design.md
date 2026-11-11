# TUN 模式：问题定位与一次性安装服务方案

本文记录 2026-11-06 对 TUN 模式的三类反馈（切换慢、有时不生效、转发慢）的定位结果、
已经完成的修复，以及对 `clash-verge-rev` 做法的调研结论与目标架构。

**当前状态：服务是唯一的 TUN 后端。** 构建只附带 `halo-tun-service.exe`：第一次
启用 TUN 时由宿主执行一次 `--install`，之后启用/关闭走命名管道。按需提权的
`halo-tun-helper.exe` 已于 2026-11-07 整体删除；缺少服务二进制的布局在启用前
直接报告 `tun_unavailable`，不会退回到第二条提权路径。核心进程由
`tunsup.Runner` 启动、持有和停止。

## 1. 改造前的形态

```text
halo-host.exe（普通权限）
  └─ runas halo-tun-helper.exe（每次启用弹一次 UAC，随本次 TUN 会话退出）
       └─ sing-box.exe（TUN 入站，作业对象持有）
```

当时宿主通过两个固定文件与助手通信：`tun-status.json`（助手 → 宿主）与
`tun-stop`（宿主 → 助手）。`tun.setEnabled` 在启用时阻塞到助手写出 `running`
或失败状态。这套助手路径已经删除，下面的证据与根因保留为方案依据。

这意味着每切换一次 TUN 都要付出：一次 UAC、一次进程创建、一次 wintun 适配器创建、
一次内核启动。关闭时还要等待助手轮询停止标记、内核收到 CTRL_BREAK、再恢复普通内核。

## 2. 证据（本机运行日志）

`build/windows-x64/user-data/logs/host.log`：

```text
08:55:57.940 [host] tun helper launched pid=27980
08:56:16.260 [host] tun enabled adapter=clash-halo pid=24940 elevated=true
```

一次启用耗时 **18.3 秒**。同一时刻的 `logs/tun-core.log`：

```text
16:55:58 INFO inbound/mixed[mixed-in]: tcp server started at 127.0.0.1:7890
16:56:08 WARN start inbound take too much time to finish!
16:56:08 WARN inbound/tun[tun-in]: open interface take too much time to finish!
16:56:08 FATAL start service: start inbound/tun[tun-in]: configure tun interface:
         (create adapter: Cannot create a file when that file already exists. |
          open existing adapter: Element not found.)
16:56:15 INFO inbound/tun[tun-in]: started at clash-halo
16:56:16 INFO sing-box started (1.07s)
```

第一次尝试在 wintun 适配器上等了约 10 秒后失败，重试才成功。另一次失败被报告为
“内核异常退出（exit status 1）”，详情里同时出现两段适配器冲突，说明失败分类和
重试判定没有覆盖真实日志。

`tun-core.log` 本身也能说明转发开销：日志级别被宿主强制成 `info`，每个 TCP 连接
写两行（`inbound` 与 `outbound`），UDP 包连接同样写。该文件没有轮转，单次运行就
写入了 112 KB。

## 3. 根因

### 3.1 切换慢

1. **每次启用都要 UAC 和一次助手启动**，这一段的耗时无法压缩到接近零；用户
   阅读提示或拒绝授权的时间也计入阻塞。
2. **`core.Supervisor.Stop()` 不等待进程退出**。它只发送 `Kill` 就返回，调用方
   随后以固定 `time.Sleep(300ms)`（`tunEnable`、`config.apply`）或 `400ms`
   （`coreRestart`）假定端口已释放。等待不足会端口冲突，等待过长则每次切换都
   多付 300–400 ms。
3. **停止标记可能被助手自己删掉**。助手启动时无条件删除 `tun-stop`；如果宿主在
   助手初始化期间写入停止请求，该请求被删除，宿主只能等满 15 秒超时后强杀。
4. **轮询间隔叠加**：助手 400 ms 看一次停止文件，宿主 200–250 ms 看一次状态文件。
   一次关闭至少多出数百毫秒。
5. **同一份配置被校验两次**。TUN 模式下切换节点时，`applyConfig` 先对基础文档
   执行一次 `sing-box check`，`reloadTunConfig` 又对注入 TUN 的运行时文档执行
   一次。生成文档约 1 MB，单次校验约 0.7–1 秒（`docs/agents/rules.md` 记录
   695 KB 配置实测 686 ms），这一步在每次节点切换上重复发生。

### 3.2 有时不生效

1. **适配器注册残留**。被强杀的内核不会删除 wintun 适配器注册，下一次创建会得到
   `create adapter: Cannot create a file when that file already exists` 与
   `open existing adapter: Element not found`。第一次尝试会先花约 10 秒才报错。
2. **重试预算错误**。旧实现只重试一次，且第二次沿用第一次的启动截止时间；第一次
   已经把 20 秒预算耗尽时，第二次必然超时。重试判定只读日志最后 400 字节，真实
   日志里两条关键信息相距约 200 字节，第一段会被截断，于是判定为“没有冲突”。
3. **状态没有存活检查**。宿主只读 `tun-status.json`。助手或内核被杀死而没有写出
   终止状态时，文件仍停在 `running`，界面继续显示已启用。
4. **启用是幂等短路**。快照记录为 `enabled` 时直接返回成功，不检查助手与内核是否
   还活着。
5. **失败分类不稳定**。同一次适配器冲突可能被报成“内核异常退出”，导致重试分支
   根本不执行。

### 3.3 转发慢

1. **强制 `info` 日志**。`prepareTunConfig` 把日志级别改写为 `info`，理由是“supervisor
   要从日志里读启动完成”。局域网和网页场景下连接数很高，每连接两行日志是持续的
   CPU 与磁盘开销；`tun-core.log` 也没有轮转。
2. **gvisor 承载全部 TCP**。宿主的默认 TUN 选项固定 `stack: gvisor`，所有 TCP 都
   经过用户态网络栈。sing-box 对 `mixed` 的定义是 TCP 走系统栈、UDP 走 gvisor，
   吞吐与单连接 CPU 成本都优于 gvisor。
3. **TUN 下的 DNS 走代理 DoH**。生成的配置里 `dns.final = remote`，`remote` 是带
   `detour: proxy` 的 DoH。系统代理模式下应用自己解析 DNS（直连），TUN 模式下
   每次解析都要经过节点；日志里可见 257 ms 与 1.65 s 的解析。这不是错误，而是
   两种模式下可感知的性能差异，也是 Clash Verge 用 fake-ip 规避的部分。

## 4. 本轮已完成的修复

| 位置 | 改动 | 验证 |
| --- | --- | --- |
| `internal/core` | `Stop()` 等待子进程退出（有上限）；`Start()` 容忍上一个进程正在退出 | `TestStopWaitsForChildExit`、`TestStartImmediatelyAfterStop`；反向验证均会失败 |
| `internal/core` | 停止信号按子进程隔离，请求停止不会被下一次启动重置后误报为崩溃 | `TestStopDoesNotReportUnexpectedExit`、`TestCrashStillReportsUnexpectedExit` |
| `internal/app` | 删除 `tunEnable` / `applyConfig` / `coreRestart` 里 300–400 ms 的固定等待 | 受影响的 app 测试全部通过 |
| `apps/flutter` | `node.select` 的客户端超时从默认 30 s 提到 60 s，与 TUN 重载的 50 s 预算匹配 | `dart analyze` 通过 |
| `internal/app` | 结束 TUN 后按 `coreWanted` 恢复内核，不再要求系统代理必须开启 | `TestShouldRestoreCore` |
| `internal/tunservice` | 运行时配置由服务在受保护目录内校验一次；宿主不再对同一文档重复跑 `sing-box check` | `TestCheckConfigForTunAcceptsFixture`、`TestCheckConfigForTunRejections` |
| `internal/app` | `reconcileTun` 读取服务状态并检查内核存活；启用时不再对失效的 `enabled` 直接返回成功 | `TestTunServiceFailureFoldsIntoSnapshot`、`TestTunServiceUnreachableIsToleratedThenFailed` |
| `internal/tunsup`、`internal/tunservice` | 适配器冲突改为整段启动输出识别（8 KB）；每次尝试使用独立截止时间；最多 3 次，总预算 50 s；失败状态携带内核原文 | `TestControllerRetriesAdapterConflict` |
| `internal/tunsup` | 就绪判定改为“适配器存在”（可注入 probe），不再依赖 INFO 日志；日志轮转，单文件上限 8 MiB | `TestControllerStartStop` |
| `internal/app` | 不再改写 `log.level`；保留用户设置 | 代码审阅 + 配置测试 |
| `internal/tunconfig`、`packages/config`、fixture | 默认 `stack` 由 `gvisor` 改为 `mixed` | Go fixture parity、Dart tun 测试；`sing-box 1.14.4 check` 接受 |

未做：DNS 改为 fake-ip 或本地解析。它影响泄漏与分流语义，需要单独设计。

## 5. Clash Verge Rev 的做法（调研结论）

Verge 的 TUN 不需要每次授权，原因是**提权发生在安装阶段，不在使用阶段**：

- 安装包含 `clash-verge-service.exe`（Windows 服务）与
  `clash-verge-service-install.exe`。按机器安装（`perMachine`）时 NSIS 以管理员
  权限运行（`RequestExecutionLevel admin`），安装阶段执行
  `clash-verge-service-install.exe --install-core <core> --sha256 <digest>`，
  把内核发布到服务的“已批准目录”，然后启动服务；按用户安装没有该权限，服务
  不可用，TUN 也就无法使用。
- 服务以 SYSTEM 运行。界面通过 IPC 请求服务启动/停止/重启内核，因此 TUN 的
  `runas` 只在这一步之前存在，日常切换没有 UAC。
- 服务只执行自己批准目录里的内核，且安装器把每个内核的 SHA-256 一起交给它；
  应用旁边的内核文件被替换不会被接受。这是对“SYSTEM 执行用户可写路径”的补偿。
- 服务不可用或内核未获批时，应用回退到 sidecar（普通权限的内核，无 TUN），并
  在界面提示原因，不会静默假装 TUN 可用。
- IPC 带调用方身份/会话凭据，服务不会接受其他本地账户的控制请求。

对本项目的含义：

- 可以消除 §3.1 的 UAC 与助手启动、§3.2 的“每次新建适配器”，因为服务可以
  串行管理内核生命周期，并在创建前清理残留适配器。
- 代价是引入一个常驻 SYSTEM 服务，与 `docs/架构.md` §5“不安装永久系统服务”的
  现值冲突。该约束需要显式修改，不能当成实现细节。
- 安装器当前是 `RequestExecutionLevel user`（按用户安装）。要像 Verge 一样在安装
  阶段装服务，需要改成按机器安装；或者保留按用户安装，在界面提供一次性的
  “安装 TUN 服务”操作（一次 UAC，之后不再询问）。

### 5.1 为什么只有“已提权组件”这一条路

Windows 上创建 wintun 适配器、安装路由与防火墙规则都需要管理员权限，普通权限
进程无法完成。因此“不每次申请”的唯一实现方式是：提前完成一次授权，并让一个
已提权的组件在之后代替普通进程执行这些操作。区别只在组件的形态：

| 方案 | 管理员授权次数 | 切换时的等待 | 可控性与监督 | 主要问题 |
| --- | --- | --- | --- | --- |
| 服务（手动安装时） | 安装 1 次 | 无 UAC、无新进程 | SCM 管理，可配置恢复策略，状态可查询 | 常驻 SYSTEM 进程；需要一次授权 |
| 计划任务（最高权限） | 创建时 1 次 | 无 UAC，但每次是新进程 | 任务计划程序管理 | 单次运行模型，持续通信与生命周期监督较弱；任务定义本身也是攻击面 |
| 整个应用以管理员运行 | 每次启动 1 次（会话内不再） | 无 UAC | 简单 | 界面与托盘长期高权限，且仍然“每次启动申请” |
| 每次启用时 `runas`（改造前，已删除） | 每次启用 1 次 | UAC + 进程创建 + 适配器创建 | 简单 | 即当初反馈的切换慢与不稳定 |
| `runas /savecred`、UIAccess 绕过 | 首次存凭据或绕过 | 无 | 无 | 凭据存储或绕过 UAC，不可接受 |

不是可行方案的其他想法：

- **预先创建 wintun 适配器**：适配器可以提前建好，但 sing-box 启动 TUN 时仍要求
  管理员权限，路由与防火墙规则同样需要；预建只减少创建适配器的时间，不减少授权。
- **把 sing-box 直接注册成服务**：配置由普通用户写入，等于让 SYSTEM 读取用户可写
  文件；必须同时加路径限制、配置内容校验与内核摘要批准，否则不是安全的提权通道。
- **只把 `halo-host` 提权**：界面与托盘依赖宿主，宿主长期高权限比一个功能单一的
  服务更难约束。

所以选择只剩“一次性安装什么”。对本项目，服务是其中监督能力、权限边界和故障
恢复都最容易做清楚的一种；计划任务适合只需要“跑一次”的场景，不适合长期持有
适配器与路由。

## 6. 已实现的架构

```text
Flutter UI ──pipe── halo-host.exe（普通权限）
                      │  命名管道（DACL：安装者 SID、SYSTEM、管理员）
                      ▼
                 halo-tun-service.exe（首次启用 TUN 时安装一次，LocalSystem）
                      └─ sing-box.exe（TUN，服务持有作业对象）
```

要点：

1. **服务只做三件事**：启动内核、停止内核、发布状态。配置由宿主生成，服务读取后
   用 `tunservice` 的闭集校验（单 tun 入站、`log.output` 受限、控制器仅回环），
   再复制到自己的受保护目录才开始运行；运行期间用户改不了这份副本。
2. **端点**：`\\.\pipe\clash-halo-tun-v1-<数据目录哈希>`。安装时记录安装者 SID，
   管道 DACL 只允许该 SID、SYSTEM 与管理员。
3. **内核批准**：构建时把随包 `sing-box.exe` 的 SHA-256 通过
   `-X ...approvedCoreSHA256=<hash>` 固定进服务二进制。安装器与每次启动都核对
   这个值；摘要不符就拒绝执行。这样即使用户目录里的内核在首次启用前被替换，
   也不会变成 LocalSystem 的执行目标。未 stamp 的开发构建退回到安装时记录的
   摘要。
4. **生命周期**：服务随安装登记为自动启动，空闲时只监听管道，不运行内核。宿主
   请求 `start` 时服务启动一个内核，并以 `hostPid` 监视宿主；宿主退出、断管或
   显式 `stop` 后，服务优雅结束内核、清理路由/适配器。服务自身停止/崩溃时作业
   对象随之结束内核；服务重启或机器重启后不恢复内核，等宿主重新请求。
5. **适配器冲突**：服务检测到 wintun 注册残留时，换一个带数字后缀的适配器名
   （`clash-halo-1`、`-2`）重试，并把实际名字写回状态；宿主与界面显示真实名字。
   这避免依赖删除残留设备所需的 SetupAPI 枚举，也避免每次失败先等十秒。
6. **唯一后端**：没有回退路径。缺少 `halo-tun-service.exe` 的布局在启用前直接
   返回 `tun_unavailable`。`tunAvailable` 先探测已安装服务，再看服务二进制与内核
   是否在预期位置，因此不会出现「开关可用、点了才失败」。
7. **安装时机**：安装包只附带 `halo-tun-service.exe`，**不注册服务**。第一次
   `tun.setEnabled {enabled:true}` 时，宿主通过一次 UAC 执行
   `halo-tun-service.exe --install --app-dir … --data-dir …`；安装器把服务、
   内核与内核的运行时组件复制到 `%ProgramFiles%\Clash Halo TUN`，登记 SCM、
   配置恢复策略并启动。之后启用/关闭 TUN 不再提权。应用更新后随包的
   `sing-box.exe` 变了，下一次启用会比较服务报告的摘要与本地内核摘要，不一致
   时用同样的安装流程更新服务一次。卸载由 `tun.serviceUninstall` 或
   `halo-tun-service.exe --uninstall` 完成；开发环境用 `--console` 运行控制器。

   内核不是自包含的：Naive 出站从**可执行文件所在目录**加载
   `libcronet.dll`，所以 `--install` 必须把它一并复制进受保护目录
   （`stageCoreRuntime`，清单见 `coreRuntimeFiles`）。只装 `sing-box.exe` 时，
   第一次 `sing-box check` 就会以 `FATAL … cronet: library not found` 失败，
   而用户看到的正是这行英文——不是他能修的东西。安装器在该文件缺失时**拒绝
   安装**，构建脚本也在缺失时直接失败，避免出现「装得上、一开 TUN 就坏」的包。

   `ping` 回复里的 `coreRuntime` 是运行时组件的版本号（`CoreRuntimeVersion`）。
   早期版本装的服务只复制了内核，内核摘要仍然匹配，只看摘要会误判为「无需
   更新」，于是继续在检查阶段失败。宿主因此同时比较 `coreRuntime`，低于当前
   版本时用一次授权补装。新增运行时组件时**必须**同步递增该常量，否则旧安装
   不会自愈。

### 6.1 常驻范围与生命周期

| 对象 | 何时运行 | 何时停止 |
| --- | --- | --- |
| 服务进程 | 首次启用 TUN 时安装，登记为开机自启；空闲时只等待管道请求 | 卸载、手动停止，或通过 `tun.serviceUninstall` |
| sing-box 内核 | 仅在宿主发出 `start` 请求之后 | 宿主退出 / 断管、显式 `stop`、服务停止或重启 |
| 受保护目录的内核副本 | 只在磁盘上，不是进程 | 卸载或升级时替换 |

安装器不会启动内核，服务启动也不会：前者只复制文件并登记摘要，后者只监听管道。
TUN 是否启用仍由 `halo-host` 决定。服务常驻的代价与边界：

- 内存与 CPU：不加载规则集、不监听网络端口；空闲时只有服务进程和一条命名管道。
- 攻击面：SYSTEM 进程加管道。缓解来自 DACL、闭集命令、路径限制、构建时内核
  摘要、配置内容校验。
- 服务没有实现“空闲退出”：它由 SCM 管理，停止后普通用户不一定有权限重新启动。
  自动启动加空闲零内核是当前取舍；如果以后要改成手动启动，需要同时给服务安全
  描述符授予安装者启动权限，并接受启用时的 SCM 延迟。

### 6.2 已实现的范围

| 位置 | 内容 |
| --- | --- |
| `native/windows/cmd/halo-tun-service` | `--service` / `--console` / `--install` / `--uninstall` / `--status` |
| `native/windows/internal/tunservice` | 协议、命名管道、控制器、内核作业对象与就绪探测、SCM 安装/恢复策略、构建时摘要固定 |
| `native/windows/internal/app` | 首次启用自动安装、服务启停编排、状态同步、15 秒不可达容忍、安装/卸载动作 |
| `packages/contracts`、`native/windows/internal/contract` | `tun.serviceStatus` / `tun.serviceInstall` / `tun.serviceUninstall` |
| `scripts/build-windows.ps1` | 构建并以实际内核摘要 stamp 服务二进制 |
| `scripts/sign-windows.ps1` | 服务二进制加入签名清单 |
| `installer/clash-halo.nsi` | 附带 `halo-tun-service.exe`，不注册服务 |
| `docs/架构.md`、`docs/契约.md` | 进程模型、权限边界与 TUN 契约更新 |

### 6.3 验证情况

已执行（本机普通权限，详见 `docs/验证记录.md`）：

- `internal/tunservice`：配置/权限边界、管道协议、控制器的启动/停止/幂等/
  适配器冲突重试/宿主退出清理/失败状态，使用测试进程作为内核替身 + 真实命名管道。
- `internal/app`：首次启用自动安装、取消授权不二次弹窗、缺少服务二进制时报告
  `tun_unavailable`、服务状态折叠、服务重载、安装/卸载动作、应用更新后更新服务、
  摘要一致不重复安装。
- `go build ./...`、`go vet`、`go test ./internal/...`。

需要管理员机器验证（未执行）：

- SCM 创建/更新/删除、服务自启动与恢复策略；
- 服务以 LocalSystem 创建真实 wintun 适配器、真实流量与路由清理；
- 手动执行 `--install` 的完整链路（安装→启动内核→关闭→卸载）；
- 软件签名与构建时摘要 stamp 在发布包中的实际值。

## 7. 实现状态与后续

服务已按“首次启用 TUN 时安装”的方式启用，默认自动启动、空闲不运行内核。仍需在
管理员机器上完成 §6.3 的验收（SCM 安装/删除、真实 wintun 适配器与路由清理、
手动安装全链路、发布包中的摘要 stamp）。

测速流量是否绕过 TUN 是另一个独立功能，评估与决定见
[`docs/tun-measurement-bypass.md`](tun-measurement-bypass.md)：
实现已默认启用；TUN 开启时测速内核与原始探测绑定物理源地址，DNS 经 DoH 中继，
不会经过 TUN 测量。
