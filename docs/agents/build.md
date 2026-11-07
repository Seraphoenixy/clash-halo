# 构建与部署

## 必须用 PowerShell 7

```powershell
pwsh -NoProfile -File scripts/build-windows.ps1
```

**不能用 Windows PowerShell 5.1。** 5.1 用旧 ANSI 代码页解码无 BOM 的 `.ps1`，
脚本里的中文和破折号会变成语法错误。脚本首行 `#Requires -Version 7.0` 把这种
版本不匹配变成一句可读的失败提示，而不是晦涩的解析错误。

产物在 `build/windows-x64/`（`README.txt` 所述的目录，也是应用实际运行目录）。
`-OutDir` 可覆盖，用于暂存发布。

## 内核二进制

`sing-box.exe`（79 MB）与 `libcronet.dll` 不入库（`.gitignore` 里的 `prototype/bin/`
和 `prototype/runtime/`），所以新 clone 的仓库里没有内核，`build-windows.ps1` 会以
「Verified sing-box binary missing」失败。这是有意的：本地构建不该悄悄换一个内核。

需要时用脚本获取，版本与 SHA-256 固定在里面：

```powershell
pwsh -NoProfile -File scripts/fetch-singbox.ps1           # 已就位则直接退出
pwsh -NoProfile -File scripts/fetch-singbox.ps1 -VerifyOnly   # 只检查，不下载
```

升级内核不是改个数字：`1.14.4` 是整套验证记录（docs/验证记录.md）测过的版本，换版本
要重跑那份记录。

## 持续集成

[.github/workflows/build.yml](../.github/workflows/build.yml)，与 `D:\project\Ygdria`
的 workflow 同构（`metadata → verify → windows → release`）：

| job | 触发 | 做什么 |
| --- | --- | --- |
| `metadata` | tag / 手动 | 读 `apps/flutter/pubspec.yaml` 的版本，剥掉 `+build`；tag 与它不一致就报错 |
| `verify` | tag / 手动 | Go 与 Flutter 全量测试（含 `apps/flutter` 的 330 项） |
| `windows` | tag / 手动 | `scripts/fetch-singbox.ps1` → `scripts/build-installer.ps1` → 校验载荷与版本 → 上传 |
| `release` | tag | 创建 **draft** release（安装包未签名，先起草再人工发布） |

与参考项目不同的三处，都是本项目的形态决定的：

1. **`verify` 也跑在 `windows-latest`**。`native/windows` 是 Windows-only（`x/sys/windows`、
   go-winio、提权检查），Linux runner 上连编译都过不去。
2. **内核从官方 release 下载并校验 digest**。这是产品的一部分，不能"拿不到就跳过"。
3. **版本号来自 pubspec，不是 tag 也不是日期**。安装包的 `DisplayVersion`、PE 版本属性、
   界面「关于」读同一个值；用日期会让它们互相矛盾，所以 tag 与 pubspec 不一致时直接失败。

日常验证用 `workflow_dispatch` 手动触发；只有 tag 才出包。

`verify` 里 `flutter analyze` 覆盖整个工作区。它以前会因 4 条既有告警（裸 `Map`、
像 HTML 的文档注释、下划线开头的局部变量、未声明的 `halo_config` 导入）返回非零——
这些是修掉的，不是在 CI 里加 `continue-on-error` 绕过的。

## 安装包

```powershell
pwsh -NoProfile -File scripts/build-installer.ps1              # 连应用一起构建
pwsh -NoProfile -File scripts/build-installer.ps1 -SkipBuild   # 只重新打包
```

产物在 `build/release/clash-halo-<版本>-setup.exe`。脚本做的事按顺序是：读版本、检查
运行目录的必装文件、取得 NSIS（没有就下载 3.12 到 `.tools/nsis` 并校验 SHA-256）、
编译 [installer/clash-halo.nsi](../installer/clash-halo.nsi)、用 7-Zip 把安装包当压缩包
读一遍确认载荷真的进去了、校验版本属性、可选签名。

三个曾经出错、现在由脚本强制保证的点：

| 项 | 规则 | 出错的表现 |
| --- | --- | --- |
| 图标 | `MUI_ICON` 取 `apps/flutter/windows/runner/resources/app_icon.ico` | 不传 `-DAPP_ICON` 时 NSIS 用自己的蓝色地球，与应用窗口的紫色猫头不一致 |
| 安装目录 | `%LOCALAPPDATA%\Programs\Clash Halo`（带空格，与 DisplayName 一致） | 目录名改成 `ClashHalo` 后，用户在资源管理器里找不到自己要找的那个名字 |
| 版本号 | 显示用 `0.1.0`（三段），数值用 `0.1.0.1`（四段） | 把 pubspec 的 `0.1.0+1` 直接当版本，用户看到的版本号里带着 `+1` |

`pubspec.yaml` 的 `version: 0.1.0+1` 里，`+1` 是 build 号而不是版本号的一部分。它只
进 `VIProductVersion` 的第四段（Windows 要求四段数字），不进窗口标题、卸载列表和
`DisplayVersion`。

装到用户目录而不是 Program Files 是有意的：数据目录、HKCU 自启项、单实例锁和托盘
图标本来就按用户划分，装到 Program Files 只会让安装、升级、卸载各多一次 UAC，换不
来任何隔离。

升级与卸载都会先调 `halo-host.exe --shutdown` 让旧版本自己退出。**不要改成 taskkill**：
宿主的退出路径会停内核、拆 TUN 并把系统代理还原，直接杀进程会让注册表停在一个指向
已停止内核的值上，卸载完成后这台机器没有网。

## 构建前必须先退出程序

```powershell
pwsh -NoProfile -File scripts/host-action.ps1 -Action host.shutdown
# 等 2-3 秒，确认进程数为 0
Get-Process | Where-Object { $_.ProcessName -match 'clash-halo|halo-host|sing-box' } | Measure-Object
pwsh -NoProfile -File scripts/build-windows.ps1
```

原因：`halo-host.exe` / `sing-box.exe` 被占用时 `cp` 报 `Device or resource busy`，
**部署只完成一半**。症状是「改了 Go 代码却没生效」——实际上 `data/app.so` 换新了，
宿主还是旧的。这两个文件必须一起换。

`scripts/stop-running-host.ps1` 用于强制收尾。

## 没有 CMake 也能构建（Dart 层 + C++ 外壳都行）

Flutter 的 Windows 产物分两层：`clash-halo.exe` 是 C++ 外壳，`data/app.so` 才是
界面本身。两层都不需要 CMake：

- `data/app.so` ← `flutter assemble`，只要 Dart SDK
- `clash-halo.exe` ← `scripts/build-runner.ps1`，用 VS 的 `cl` / `link` / `rc`
  直接编译（11 个编译单元 + 1 个 `.rc`）。**只需要「使用 C++ 的桌面开发」工作负载，
  不需要「C++ CMake 工具」组件**

`scripts/build-windows.ps1` 的流程：

- 有 CMake 组件：走 `flutter build windows`，全量（与 Flutter 官方一致）
- 没有：跑 `flutter assemble`，把 `build\windows\app.so` 与 `build\flutter_assets`
  装进 `runner\Release\data`（这一步原本是 CMake 的 install），然后**只在**
  `apps\flutter\windows` 的源码比外壳 exe 新、或外壳缺失时，调用
  `build-runner.ps1` 重编外壳

装了 CMake 也想只重建界面：`pwsh -NoProfile -File scripts/build-windows.ps1 -DartOnly`。
只重建外壳：`pwsh -NoProfile -File scripts/build-runner.ps1`。

**`flutter assemble` 只写到 `build\`，不会更新 `runner\Release\data`**——那是
CMake 的 install 步骤。脚本补的正是这一步，漏掉就会「构建成功但界面还是旧的」。
判断是否真的编了，看 `data\app.so` 的时间戳晚于最近一次 Dart 改动。

`sqlite3` 3.x 通过 build hooks 选择原生库。本仓库在 workspace 根
[`pubspec.yaml`](../../pubspec.yaml) 的 `hooks.user_defines.sqlite3` 指定
`source: system` 和 Windows 的 `winsqlite3.dll`，因此不下载、不打包第二个 SQLite。
`flutter assemble` 把映射写进 `build\flutter_assets\NativeAssetsManifest.json`，
脚本随 `flutter_assets` 一起部署；`runner\Release\native_assets.json` 是旧 CMake
流程留下的空文件，不参与运行时加载。改回自带 SQLite 时必须同时删除该 hooks 段，
否则会在首次构建时下载二进制。

`build-runner.ps1` 是手写编译，有两处坑记在这里：`/Fo` 的目录参数**必须以两个反斜杠
结尾**（`/Fo"...\obj\\"`），否则 MSVC 把 `\"` 当成转义引号，后面的源文件全被吞进
`/Fo` 的值里，`cl` 报 D8003「缺少源文件名」；链接 Win32 导入库（`user32` `gdi32`
`advapi32` `shell32` `ole32` `uuid`）必须自己列，CMake 项目里是隐式带上的。

## C++ 源文件里的中文注释必须配 `/utf-8`

`flutter_window.cpp` 的注释带中文和破折号，文件是 UTF-8 **无 BOM**。MSVC 默认按
系统 ANSI 代码页（本机 936）解码，报 C4819；CMake 的 `apply_standard_settings` 带
`/WX`，这个警告就升级成硬错误：

```text
flutter_window.cpp(1,1): error C2220: 以下警告被视为错误
flutter_window.cpp(1,1): warning C4819: 该文件包含不能在当前代码页(936)中表示的字符
Flutter build failed
```

两条外壳构建路径都要带 `/utf-8`：

| 路径 | 位置 |
| --- | --- |
| CMake（`flutter build windows`） | `apps/flutter/windows/runner/CMakeLists.txt` 的 `target_compile_options(${BINARY_NAME} PRIVATE /utf-8)` |
| 无 CMake（`build-runner.ps1`） | `cl` 命令行里的 `/utf-8` |

不要用「把注释改成英文」绕过去——仓库注释本来就是中文；只给单个文件加 BOM 也不行，
下一次新增源码会再踩一遍。

## 换了目录 / 复制仓库之后

`--no-pub` 不重新解析依赖。`.dart_tool\package_config.json` 里还是旧绝对路径时，
编译会报一堆看不出根因的错（例如 `The method 'Text' isn't defined`，实际是
`package:flutter/material.dart` 读不到）。脚本发现 `package_config.json` 里没有当前
仓库根路径，会先跑一次 `dart pub get`。手工修（**在仓库根目录**，工作区解析点在这，
不在 `apps/flutter`）：

```powershell
.tools\flutter\bin\dart.bat pub get
```

## 图标缺失：一条有两次不同成因的问题

侧栏某一项**图标位置在、但没有字形**，看起来像缩进或对齐错乱。本质是
`MaterialIcons-Regular.otf` 是**按代码里实际用到的码位裁剪过的子集**，而运行时
字体里没有那个码位。Flutter 找不到字形不报错，只画空白。

这类问题被误诊过一次（当成布局 bug），所以按下面的顺序排查，不要先改代码。

### 先量一下字体到底有哪些码位

```python
# 用法：python cmap.py <otf 路径>
import struct, sys
data = open(sys.argv[1], 'rb').read()
n = struct.unpack(">H", data[4:6])[0]
cmap = None
for i in range(n):
    base = 12 + i * 16
    if data[base:base + 4] == b"cmap":
        cmap = struct.unpack(">I", data[base + 8:base + 12])[0]
cps = set()
if cmap is not None:
    subs = struct.unpack(">H", data[cmap + 2:cmap + 4])[0]
    for i in range(subs):
        rec = data[cmap + 4 + i * 8: cmap + 12 + i * 8]
        off = cmap + struct.unpack(">I", rec[4:8])[0]
        if struct.unpack(">H", data[off:off + 2])[0] == 4:
            seg = struct.unpack(">H", data[off + 6:off + 8])[0] // 2
            ends = struct.unpack(">%dH" % seg, data[off + 14: off + 14 + seg * 2])
            so = off + 14 + seg * 2 + 2
            starts = struct.unpack(">%dH" % seg, data[so: so + seg * 2])
            for a, b in zip(starts, ends):
                if a != 0xFFFF:
                    cps.update(range(a, b + 1))
print(len(cps), "codepoints")
print("has 0xf0616:", 0xF0616 in cps)
```

码位查 `.tools/flutter/packages/flutter/lib/src/material/icons.dart` 里的
`IconData(0x...)`。

**`0xf0616` 这类大于 `0xFFFF` 的码位在 format 12 子表里，上面的脚本读不到。** 只解
format 4 会把这些图标误判成「缺失」：实测同一个人工字体用两种解析得到 67 和 69 个
码位，多出的 3 个正是 `0xF0616` `0xF062C` `0xF05BD`。判断前先确认脚本覆盖了
`(12, 3, 10)` 那张子表，否则会把正常字体当成坏的。

### 成因一：部署没有同步字体

手工 `cp` 几个文件（exe、`app.so`、dll）会漏掉 `data/flutter_assets/`。用脚本自带
的暂存参数，它会整棵资源树一起写：

```powershell
pwsh -NoProfile -File scripts/build-windows.ps1 -OutDir "D:/software/clash-halo-build"
```

### 成因二：Flutter 缓存了旧的字体子集（构建脚本已自动处理）

**改了 `IconData` 但字体子集是旧的**，此时 `app.so` 是新的、字体不是。表现和成因一
一样，但重新部署无效——因为构建产物本身就是旧的。

根因在 `flutter_tools`：`IconTreeShaker` 的缓存键由 `BundleWindowsAssets.inputs`
决定，其中只有 `pubspec.yaml`、`build_hooks`、图标裁剪工具自身和
`IconTreeShaker.inputs`，**不含任何 Dart 源码**；`flutter_assets.d` 里也一个
`.dart` 都没有。所以「只换了 widget 用哪个 `Icons.*`」不会让这个 target 失效，旧子
集被原样复用。实测（2026-11-05）跨 3.5 小时的 Dart 改动一直沿用 9180 字节的旧子集，
有 4 个在用码位缺失。

`scripts/build-windows.ps1` 现在在 `flutter assemble` 之前删除整棵
`apps/flutter/build/flutter_assets`，强制重新裁剪；构建末尾再校验字体是本次产出的，
否则直接失败而不是产出一个界面有空白图标的包。

手工排查时仍然可以只删字体（等价，但覆盖面更小）：

```powershell
rm apps/flutter/build/flutter_assets/fonts/MaterialIcons-Regular.otf
rm apps/flutter/build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf
pwsh -NoProfile -File scripts/build-windows.ps1 -OutDir "D:/software/clash-halo-build"
```

重建后用上面的脚本确认目标码位在、旧码位不在。**旧图标码位消失**是判断「确实
重新裁剪过」的最直接信号。

注意 `const_finder` 只收集**被实例化**的 `IconData`。写在构造函数默认值里、但没有
任何调用点显式传参的图标不会进子集——那是正确行为，不是缺陷。本项目实测：
`EmptyState` 的默认值 `Icons.inbox_outlined`（`0xF126`）全部 8 处调用都显式传了
`icon:`，所以它不在字体里是正常的。

### 判断产物是否真的更新

构建脚本末尾会自动校验并失败（字体或快照不是本次产出的、快照比源码旧），所以
「脚本退出 0」现在本身就意味着资源与产物都是新的。手工核对时：

`-OutDir` 会**直接写目标目录**，`build/windows-x64` 停留在上一次默认构建的产物。
拿它比新旧会得出错误结论。正确的判断方法是看有没有源码比部署产物新：

```powershell
# 部署产物时间 vs 全部 Dart 源码
find apps/flutter/lib packages -name "*.dart" -newer "D:/software/clash-halo-build/data/app.so"
```

输出为空即说明产物已包含全部改动。

## 部署不是全部替换 exe

运行目录（本机 `D:\software\clash-halo-build`，在仓库之外）：

| 文件 | 说明 |
| --- | --- |
| `clash-halo.exe` | 仅约 146 KB 的启动器 |
| `data/app.so` | **真正的 UI**，Flutter 产物 |
| `halo-host.exe` | Go 宿主 |
| `sing-box.exe` | 内核（服务安装时会复制到受保护目录） |
| `libcronet.dll` | Naive 支持 |
| `data/icudtl.dat` | ICU 数据 |

只替换 `clash-halo.exe` 看不到任何界面改动。部署后建议用
`certutil -hashfile` 比对源与目标的 `data/app.so`，确认一致。

## 工具链不在 PATH

```text
.tools/go/bin/go.exe
.tools/flutter/bin/flutter.bat
.tools/flutter/bin/dart.bat
```

`.tools/` 被 `.gitignore` 忽略，不随仓库分发。

## 两件容易踩的事

**`go build ./...` 必须在 `native/windows` 下执行**，否则报
`directory prefix . does not contain main module`。

**构建脚本会先删除目标 exe**，这是有意为之：某些工具链下 `go build -o` 不会真正
替换已有的 PE 文件（时间戳变了但字节和大小没变），已损坏的二进制会躲过每次重建，
最后在签名阶段报 "not a valid Win32 application"。从干净路径开始才能复现构建。
