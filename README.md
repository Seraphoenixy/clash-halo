# Clash Halo

Windows 桌面代理客户端。界面（Flutter）与后台宿主（Go）分进程运行，宿主启动并
管理 `sing-box`；关闭界面不会停止代理，可以从托盘重新打开。

当前版本 `0.1.0`。本文记录仓库的构建、测试与使用方式；设计与协议细节见
[`docs/`](docs/)。

## 功能

- **代理模式**：系统代理与 TUN。TUN 使用首次启用时安装的 LocalSystem 服务，
  之后启用/关闭不再请求管理员权限。
- **订阅与节点**：订阅 URL、分享链接和 v2rayN 配置导入；订阅定时刷新；节点
  分组、重命名、批量整理、搜索与筛选。
- **节点测量**：TCP/UDP 连通性、经节点的延迟、下载吞吐和解锁检测分开记录，
  不合并成单一分数。
- **托盘**：后台常驻，右键菜单切换节点、开关代理、打开界面；界面退出后宿主
  继续运行。
- **数据管理**：SQLite 保存节点、订阅与设置；支持加密备份、恢复预览与回滚备份。
- **命令行**：`apps/cli` 提供订阅与节点导入，不依赖界面。

## 架构

```text
Flutter UI（普通权限）
  │ 命名管道，NDJSON（仅当前用户可访问）
  ▼
halo-host.exe（托盘后台，普通权限）
  ├─ sing-box.exe（普通代理模式）
  ├─ 系统代理（注册表，记录原值）
  └─ halo-tun-service.exe（LocalSystem，首次启用 TUN 时安装）
       └─ sing-box.exe（TUN 入站）
```

- 运行状态只由 `halo-host.exe` 读写；界面通过管道请求，不直接操作内核。
- 业务数据（节点、订阅、设置）由 Dart 进程直接读写 SQLite；宿主不链接 SQLite。
- TUN 服务只执行受保护目录中、摘要与构建时固定值一致的内核；控制管道只允许
  安装者、SYSTEM 与管理员访问。
- 管道名字由数据目录派生，同一台机器上的多个安装互不干扰。

详细说明见 [`docs/架构.md`](docs/架构.md)、[`docs/契约.md`](docs/契约.md) 和
[`docs/tun-service-design.md`](docs/tun-service-design.md)。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `apps/flutter` | Flutter 界面（包名 `halo`） |
| `apps/cli` | 命令行导入工具（包名 `halo_cli`） |
| `packages/contracts` | IPC 协议、错误码、速度模型 |
| `packages/domain` | 节点与订阅模型、导入、指纹 |
| `packages/config` | sing-box 配置生成与能力检查 |
| `packages/storage` | SQLite schema、仓储、备份 |
| `native/windows` | Go 宿主、TUN 服务、IPC 与内核管理 |
| `native/android` | Android VPN 进程边界（脚手架，未验证） |
| `installer` | NSIS 安装脚本 |
| `scripts` | 构建、测试、签名、截图等脚本 |
| `docs` | 架构、契约、设计规范、验证记录 |
| `prototype` | 早期生命周期原型；同时是内核下载与测试的暂存目录 |

`prototype/bin`、`prototype/runtime`、`.tools`、`build`、`.tmp` 与运行日志/数据库
都不入库。

## 环境要求

- Windows 10/11 x64
- PowerShell 7（`pwsh`，不是 Windows PowerShell 5.1）
- Go 1.27.3
- Flutter 3.47.9 / Dart 3.13.7
- Visual Studio 2022 生成工具（“使用 C++ 的桌面开发”）。首次构建需要它编译
  窗口外壳；已有外壳时可用 `-DartOnly` 只重建界面
- 网络：首次拉取锁定版本的 sing-box；打包时下载 NSIS

构建脚本先在仓库的 `.tools` 下查找工具，找不到再使用 `PATH`：

```text
.tools/go/bin/go.exe
.tools/flutter/bin/flutter.bat
```

`.tools` 被忽略，可以按上面的路径放置项目专用工具链，也可以直接使用系统安装。

## 构建

```powershell
# 1. 下载并校验 sing-box 1.14.4（放入 prototype/bin）
pwsh -NoProfile -File scripts/fetch-singbox.ps1

# 2. 构建运行目录 build\windows-x64
pwsh -NoProfile -File scripts/build-windows.ps1

# 只重建界面（复用已有的 C++ 外壳）
pwsh -NoProfile -File scripts/build-windows.ps1 -DartOnly

# 3. 启动
.\build\windows-x64\clash-halo.exe
```

构建完成后 `build\windows-x64` 包含界面、宿主、TUN 服务、内核与运行库。构建脚本
会校验本次产出的 `data/app.so`、图标字体与 `NativeAssetsManifest.json`（SQLite
映射），避免出现“构建成功但启动后数据库打不开”的产物。

### 安装包

```powershell
pwsh -NoProfile -File scripts/build-installer.ps1
```

输出 `build\release\clash-halo-<版本>-setup.exe`。脚本会先重建运行目录，再调用
NSIS，并用 7-Zip 校验载荷与版本属性。安装包不注册 TUN 服务；第一次启用 TUN 时
由宿主执行一次 `halo-tun-service.exe --install`。

### 签名

```powershell
pwsh -NoProfile -File scripts/sign-windows.ps1 -Report
pwsh -NoProfile -File scripts/sign-windows.ps1 -PfxPath .\codesign.pfx -PfxPassword '***'
pwsh -NoProfile -File scripts/trust-local-cert.ps1   # 自签名证书仅用于本机
```

签名对象与注意事项见 [`docs/发布与签名.md`](docs/发布与签名.md)。

## 测试

日常验证从仓库根目录使用同一入口：

```powershell
pwsh -NoProfile -File scripts/test.ps1 -Suite flutter
pwsh -NoProfile -File scripts/test.ps1 -Suite domain
pwsh -NoProfile -File scripts/test.ps1 -Suite contracts
pwsh -NoProfile -File scripts/test.ps1 -Suite storage
pwsh -NoProfile -File scripts/test.ps1 -Suite config
pwsh -NoProfile -File scripts/test.ps1 -Suite cli
pwsh -NoProfile -File scripts/test.ps1 -Suite go -Target ./...
```

`-Target` 可以是测试文件或包路径；`-Filter` 在 Go 中是正则，在 Dart/Flutter 中
按普通文本匹配。直接调用工具时需要遵守各测试的工作目录，见
[`docs/agents/testing.md`](docs/agents/testing.md)。

Go 的静态检查：

```powershell
cd native/windows
go vet ./...
go test -count=1 -timeout 10m ./...
```

配置与真实内核相关的测试需要先执行 `scripts/fetch-singbox.ps1`。提权 TUN 的
端到端测试默认跳过，需要管理员机器显式设置 `HALO_TUN_E2E=1` 并接受 UAC。

## 数据目录

默认 `%LOCALAPPDATA%\clash-halo`，其中包含 `clash-halo.db`、`configs/`、`logs/`
与 `runtime.json`。

- 可执行文件旁存在 `portable.flag` 时使用 `<exe 目录>\user-data`
- 环境变量 `HALO_DATA_DIR` 覆盖以上规则
- 界面、宿主与 CLI 使用同一套解析逻辑

## 文档

- [`docs/架构.md`](docs/架构.md)：进程模型、状态与模块边界
- [`docs/契约.md`](docs/契约.md)：命名管道与 NDJSON 协议
- [`docs/设计规范.md`](docs/设计规范.md)：界面与颜色规范
- [`docs/验证记录.md`](docs/验证记录.md)：已执行的验证、证据与未验证项
- [`docs/tun-service-design.md`](docs/tun-service-design.md)：TUN 服务方案
- [`docs/tun-measurement-bypass.md`](docs/tun-measurement-bypass.md)：TUN 下的测速隔离评估
- [`docs/agents/build.md`](docs/agents/build.md)：构建、CI 与工具链细节
- [`docs/agents/testing.md`](docs/agents/testing.md)：测试与界面核对手法
- [`AGENTS.md`](AGENTS.md)：面向 AI 代理的仓库约束

## 当前边界

- TUN 服务的真实 SCM 安装/卸载、真实 wintun 适配器与路由清理仍需在管理员机器上
  验收；当前验证范围见 `docs/验证记录.md`。
- TUN 开启时的测速绕过已实现但默认关闭，需要真实 TUN 端到端验证后才能启用。
- Android 端只有进程与权限边界，不含可用的 VPN 实现，不能据此宣称 Android 可用。
- 仓库未包含代码签名证书；`scripts/sign-windows.ps1` 只提供签名流程，实际证书
  由发布者提供。
- `packages/domain/test/fixtures/tls/` 中的自签名证书与私钥仅用于本机测试，
  不用于生产。

## 许可

仓库当前未包含 `LICENSE` 文件。公开发布或分发前需要确定许可证；在补充许可证
之前，默认保留所有权利。
