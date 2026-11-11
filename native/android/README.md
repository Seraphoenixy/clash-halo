# Android 原生模块

`:vpn` 进程的 VPN 实现：`HaloVpnService` 集成 libbox（sing-box 移动库），
经 `VpnService.Builder` 建立 TUN。UI 进程通过 `MainActivity` 的平台通道
`clash_halo/android_vpn` 传配置、启停并读取状态；服务把状态写入应用私有目录
下的 `vpn-state.json`，不跨进程绑定 Binder。

## 已实现

- `:vpn` 独立进程（`android:process=":vpn"`）、`exported="false"`、仅本应用可绑定。
- `HaloVpnService` 实现 libbox 的 `PlatformInterface`（26 个方法，签名与
  libbox.aar 逐一核对）与 `CommandServerHandler`；`openTun` 用
  `VpnService.Builder` 建 TUN 并把 fd 交给内核；`autoDetectInterfaceControl`
  即 `protect(fd)`。
- libbox 来自**锁定的 sing-box v1.14.4 源码**，与 Windows 侧 `sing-box.exe`
  同版本同源；构建参数与官方 `build_libbox` 一致（arm64、androidapi 24，
  `-libname=box`）。产物解包为 `libs/libbox.jar`（绑定）+
  `src/main/jniLibs/arm64-v8a/libbox.so`（运行时）；`libs/` 与 `jniLibs/`
  都被 `.gitignore` 忽略，不随仓库分发。
- 配置经固定路径传递（两进程共享的 `getDir("halo")/config.json`），状态经同目录
  `vpn-state.json` 读取；通道与 Intent 不接受路径或命令行；`onRevoke` 置停并
  撤销 TUN，不假装仍在代理。
- 备份导出/恢复走 Storage Access Framework：`ACTION_CREATE_DOCUMENT` 让用户选择
  保存位置，`ACTION_OPEN_DOCUMENT` 选择恢复文件，内容经 `ContentResolver` 读写。
  不再写入不可访问的 `getDir("halo-data")` 私有目录；取消选择返回 null，不算失败。
  旧版本遗留的私有目录备份已一次性清理，当前版本不包含自动删除逻辑。
- UI 侧（apps/flutter）：`selectNode`/`startCore`/`stopCore` 在 Android 上
  改走本地路径——Dart 直接构建带 TUN inbound 的 sing-box 文档
  （`routing.build(node, withTun: true)`），经平台通道写入并等待
  `Started`/`Failed`；状态由控制器轮询后驱动总览、侧栏与状态栏。
- 移动端布局：窄窗口用抽屉导航，宽窗口的侧栏可折叠为图标栏；页面表头在窄屏
  拆成标题行与可横向滚动的操作行；节点/连接列表长按打开原右键菜单，键盘快捷键
  在触摸平台上隐藏；节点表在触摸平台上可横向拖动。
- 启动图标为方形圆角紫色底 + 猫头前景，覆盖 mdpi 到 xxxhdpi 的 legacy PNG；
  真机 MatePad 11 桌面已确认显示为方形圆角。
- 与 Windows 共用壳层：`HaloSidebar`、`HaloStatusBar`、`HaloPageScaffold`、
  `SectionCard`/`StatusChip`/`HaloSelector` 和总览的 `HaloNextStepCard`；
  两端只在状态来源与卡片集合上不同。
- 测速：Android 在本地串行执行。TCP 连通性用直连握手；延迟、下载与 UDP
  通过临时载入每个节点的配置、经 `127.0.0.1` 的 mixed inbound 探测，完成后
  恢复原来的节点。Windows 仍使用一次性探测内核，不切换正在使用的连接。
  测速结果保存在 `AppController`，页面切换不重置，进程退出后清空。

## 状态契约

`vpn-state.json`（`getDir("halo", MODE_PRIVATE)`，仅本应用可读）：

| 字段 | 含义 |
| --- | --- |
| `state` | `Stopped` / `Starting` / `Started` / `Failed` |
| `message` | 给用户看的一句话；失败时是具体原因 |
| `pid` | 写状态的 `:vpn` 进程；`Starting`/`Started` 时用于确认它仍存活 |
| `updatedAt` | 写入时刻（毫秒）；UI 用它忽略上一次运行留下的旧状态 |

写入采用临时文件 + `rename` 原子替换。UI 通过 `ActivityManager` 查询本应用的
进程列表判断 pid 是否存活：`/proc/<pid>` 在不同 SELinux 域之间不可靠，
同 UID 也可能被 `hidepid` 挡住。`Failed` 记录保留到下一次启动或用户主动停止，
所以启动失败的原因在服务退出后仍能看到。


## libbox 构建方式（内核版本变更时执行）

```bash
# 1. 取源码（goproxy 模块 zip 或 git clone v1.14.4），git init + tag v1.14.4
#    （让 libbox 上报正确版本号）
# 2. 工具链：sagernet gomobile fork v0.1.13（官方 Makefile 指定）、JDK 17
#    （build_libbox 硬校验 openjdk 17）、NDK、SDK
# 3. 在 sing-box 源码目录：
gomobile bind -v -o libbox.aar -target android/arm64 -androidapi 24 \
  -javapkg=io.nekohasekai -libname=box -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=1.14.4 -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
  -tags "with_gvisor,with_quic,with_wireguard,with_utls,with_naive_outbound,with_clash_api,with_usbip,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird" \
  ./experimental/libbox
# 4. 解包进模块：classes.jar → libs/libbox.jar；jni/arm64-v8a/*.so → src/main/jniLibs/
```

APK 只打包 `arm64-v8a`：`apps/flutter/android/app/build.gradle.kts` 用
`packaging.jniLibs.excludes` 去掉 Flutter 自带的 armeabi-v7a/x86_64 载荷。
在 x86_64 模拟器上运行需要自行构建对应 ABI 的 libbox；否则安装后启动 VPN 会
在 `:vpn` 进程里 `UnsatisfiedLinkError`。

## 未验证 / 已知边界

| 项 | 状态 |
| --- | --- |
| 真机端到端流量 | **已验证（2026-11-07）**：订阅导入 → 启用 → 授权 → curl 经隧道返回服务器出口 IP（43.131.227.96, 200）。**VLESS+WS+TLS、Naive-H2、Naive-H3(QUIC) 三种形态均实测通过** |
| Naive 节点在 Android | **可用，无需额外 .so**。cronet-go 有两个变体：`with_purego`（运行时 dlopen `libcronet.so`/`.dll`，官方 Windows 发布的 purego 变体才用，这就是 Windows 需要 libcronet.dll 的原因）与 CGO 静态链接（默认）。`build_libbox` 的 tags 不含 `with_purego`，cronet 经 CGO **静态编进 libbox.so**——SFA 仓库里 grep 不到 cronet 依赖也是这个原因。早前"Android 缺 cronet"的判断是错的：当时的失败源于接口列表为空的 bug（已修），修后 Naive-H2/H3 直接可用 |
| 状态与界面 | **已验证（2026-11-07）**：通知、总览、侧栏与状态栏随 `:vpn` 状态更新；UI 进程被杀后重开仍能恢复「已连接」；停止后 `tun0` 消失 |
| 后台存活、UI 退出后 VPN 独立存活、网络切换恢复 | 未验证（华为后台管制是重点场景）。`START_STICKY` 与状态文件已就位，但 `setUnderlyingNetworks` 后的真实切换行为尚未实测 |
| 测速 | **已验证（2026-11-08）**：延迟、下载、TCP/UDP 连通性均能在真机返回结果；下载约 3.67 MB/s；测速期间会短暂断开或切换 VPN，完成后恢复原节点 |
| 日志/连接页 | 依赖宿主协议，Android 未接 |
| Android 版本范围 | `minSdk=29`（Android 10）；API 28 及以下不在支持范围。连接归属查询在 API 29 起可用 |
| 鸿蒙 4 的 Android 兼容层 | **已验证（2026-11-09）**：Mate 60 Pro（ALN-AL00，HarmonyOS 4.2，API 31）。原先 VPN 连上后浏览器全部超时，根因与修复见下两行；修复后 VLESS 与 Naive 两种节点都能正常打开 Google，连续运行 9 分钟（含息屏 1 分钟）无中断 |

## 真机集成期间修复的缺陷（2026-11-07 首次真机暴露；最后两行 2026-11-09 鸿蒙 4）

| 缺陷 | 修复 |
| --- | --- |
| R8 把 `go.Seq$Ref` 当死代码剥掉，`:vpn` 进程 SIGABRT "failed to find method Seq.getRef" | `consumer-rules.pro` keep `go.**` 与 `io.nekohasekai.libbox.**`（手工拆包 AAR 会丢自带规则） |
| libbox `Setup` 不建 BasePath，`command.sock` bind 失败崩服务 | Kotlin 侧 `mkdirs()` 后再传入 |
| Go 侧无条件解引用 `OverrideOptions`，Kotlin 传 null 即 panic | 传真实实例 + 空迭代器 |
| 接口地址带 IPv6 zone（`fe80::..%wlan0/64`），Go `netip.MustParsePrefix` panic | 用裸字节重建 Inet6Address 剥 zone（同官方 SFA） |
| `:vpn` 进程缺 `ACCESS_NETWORK_STATE`，网络监控初始化失败 | vpn 模块清单补声明 |
| 接口 `flags` 恒 0，`NetworkManager.UpdateInterfaces` 按 `IFF_UP` 过滤后缓存为空，所有拨号报 "no available network interface" | 按官方 SFA 语义设置 IFF_UP/RUNNING/LOOPBACK/POINTOPOINT/MULTICAST |
| 接口监控把本应用自己的 VPN 网络上报为默认网络 → 内核出站绑进隧道自环（TUN 只进不出） | NetworkRequest 加 `NOT_VPN` 能力过滤 + `bestUnderlyingNetwork()` 选最优非 VPN 上联网 |
| 鸿蒙 4 上 VPN 建立后物理网络从 `ConnectivityManager.allNetworks` 与 `getLinkProperties` 的可见集合里消失，内核报 `no available network interface`，随后所有出站拨号失败；蜂窝换 IP 后还会继续用旧接口地址，表现为 `dial rmnet0: i/o timeout` | 在 `NetworkCallback` 里维护非 VPN 上联网登记表（含 `onLinkPropertiesChanged`），`getInterfaces()` 优先用它；接口表为空时退回 `NetworkInterface.getNetworkInterfaces()` 内核枚举；上联网短暂不可读时沿用上一次成功解析的默认接口，不再上报空接口名 |
| 代理服务器域名解析自引用：Naive 出站用系统解析器解析 `server` 域名，查询进入本 VPN 的 DNS 模块后又交给经代理的 DoH，而 DoH 需要先连上代理 → 双方互等，拨号超时 | 生成器在 `dns.rules` 里为节点 `server` 域名加一条 `server: local` 规则，固定走直连解析（`packages/config/lib/src/generator.dart` 的 `_domainOf`） |
| 生成器 `auto_detect_interface: !tun.enabled` 是 Windows 语义（服务自管接口）；Android 照搬导致 protect 不生效（同上自环） | `routing.build(withTun: true)` 构建后强制 `route.auto_detect_interface = true` |
| 数据目录落在 `code_cache`（`Directory.systemTemp` 在 Android 的回退），应用更新即被清空 | 平台通道 `dataDir` 返回持久目录（`getDir("halo-data")`），main.dart Android 分支改用 |
| UI 跨进程绑定 `VpnBinder`，实际拿到 `BinderProxy`，状态恒为「未运行」 | 状态改由 `vpn-state.json` + `ActivityManager` pid 判断；启停走显式 Intent |
| 通知在 `startForeground` 时按 `Stopped` 生成，之后不再更新，永远显示「未连接」 | 每次状态迁移 `publishState` 同时刷新通知 |
| 停止只 `stopSelf`，系统 VPN 绑定使服务与 `tun0` 留在后台 | `closeService()` 后关闭 `ParcelFileDescriptor`，撤销 TUN、释放系统绑定 |
| `/proc/<pid>` 在 `:vpn` 与 UI 进程之间读不到，已连接被误判为 Stopped | 用 `ActivityManager.runningAppProcesses` 判断本应用进程，`/proc` 仅作回退 |
| 触摸设备没有右键，节点/连接菜单无法打开 | 行增加 `onLongPressStart`，与桌面右键共用同一菜单；触摸平台隐藏键盘快捷键 |
| 窄屏固定 200px 侧栏挤压页面，多个表头按钮溢出 | 宽度 <760 用抽屉 + 标题行菜单按钮；宽屏侧栏可折叠为 56px 图标栏；表头操作行可横向滚动；表格在触摸平台允许横向拖动 |
