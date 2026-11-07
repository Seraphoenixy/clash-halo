# Android 原生脚手架（未验证）

本目录只建立**进程与权限边界**，不含可工作的 VPN 实现。请勿据此宣称
Android 端已可用。

## 已实现（可静态核对）

- `:vpn` 独立进程声明（`android:process=":vpn"`），`android:exported="false"`，
  仅本应用可绑定。
- `HaloVpnService` 继承 `VpnService`，不加载任何 Flutter 类，因此满足
  “VPN 进程不得初始化 FlutterEngine”的约束。
- 前台通知包含状态文案、打开界面与停止入口。
- `onRevoke` 在 VPN 被撤销或被其他 VPN 接管时把状态置为 `Stopped`，不继续
  声称代理。
- Binder 契约（`VpnBinder.snapshot()`）只暴露状态查询、启动请求与停止请求，
  不接受路径或命令行。

## 未实现 / 未验证

| 项 | 原因 |
| --- | --- |
| libbox 接入 | 需要从锁定源码构建移动库；本仓库未构建 |
| `VpnService.Builder` 建立 TUN | 缺少可用的代理内核；建立空 TUN 会造成“已连接但无流量”的假象 |
| 连接保护 / 绕过列表 | 依赖 libbox 与真机验证 |
| 真机生命周期（后台存活、UI 退出后 VPN 独立存活） | 方案禁止安装 ADB，无法验证 |
| APK 构建 | 未安装 Android SDK/构建工具链 |

## 构建方式（未执行）

若后续获准安装 Android SDK，应在 `:vpn` 模块中：

1. 将锁定的 sing-box 源码构建为 AAR，放入 `vpn/libs/`；
2. 在 `HaloVpnService` 内用 `VpnService.Builder` 建立 TUN 并交给 libbox；
3. 用真机验证 `方案.md §13` 中的权限边界与网络恢复项；
4. 只有真机通过后，才把 `方案.md §12` 中对应行从“未验证”改为“已验证”。
