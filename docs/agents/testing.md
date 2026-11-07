# 测试与验证

## 范围按改动规模决定

- **普通改动**：只跑受影响的包或测试文件
- **架构级 / 跨模块改动**：才做全量

不要每改一行就全量跑一遍。

## 命令与工作目录

日常验证可以从仓库根目录用同一个入口。测试目标按各包目录填写。

```powershell
pwsh -NoProfile -File scripts/test.ps1 -Suite flutter -Target test/nodes_page_test.dart
pwsh -NoProfile -File scripts/test.ps1 -Suite domain -Target test/share_link_export_test.dart
pwsh -NoProfile -File scripts/test.ps1 -Suite config -Target test/config_test.dart -Filter 'passes sing-box check'
pwsh -NoProfile -File scripts/test.ps1 -Suite go -Target ./internal/app -Filter '^TestProbe'
```

- `-Suite` 支持 `flutter`、`cli`、`config`、`contracts`、`domain`、`storage` 和 `go`。
- Flutter 复用已解析的依赖，缺少依赖配置时会自动解析。修改依赖或迁移工作区后，运行时加 `-Pub`。
- 配置测试从仓库根目录运行，以便找到 `prototype/bin/sing-box.exe` 并执行真实内核校验。
- `-Filter` 在 Go 中使用正则，在 Dart 和 Flutter 中按普通文本匹配。

直接调用工具的写法如下。

```powershell
# Dart 层：必须在 apps/flutter 下
cd apps/flutter
..\..\.tools\flutter\bin\flutter.bat test test/nodes_page_test.dart

# 纯 Dart 包：在包目录下
cd packages/domain
..\..\.tools\flutter\bin\dart.bat test
cd packages/contracts
..\..\.tools\flutter\bin\dart.bat test

# Go：必须在 native/windows 下
cd native/windows
..\..\.tools\go\bin\go.exe test ./internal/app/ -run "TestProbe"
```

失败与陷阱：

- `flutter test` 不在 `apps/flutter` 下运行会报 `Does not exist`
- `flutter test` **不接受** `-n`，用 `--plain-name`；`dart test` 接受 `-n`
- 给可能挂起的命令加显式超时，卡住转后台 job 并收尾，不要无限等
- **点过的控件带双击识别器时，测试末尾要放掉双击计时器**：`tester.tap` 之后
  `await tester.pump(const Duration(milliseconds: 400))`，否则测试以
  `Pending timers` 失败（双击识别器会起一个 40ms 的计时器）。节点页的
  `settleTap()` 就是这件事。

## 验证 UI 的既定手法

不要靠看截图猜颜色下结论。红绿在延迟列表示快慢，在端口连通列表示成败，同一套
颜色有两种含义。要断言就取数值或读文本。

```powershell
pwsh -NoProfile -File scripts/capture-window.ps1         # → docs/images/ui-capture.png
pwsh -NoProfile -File scripts/click-window.ps1 -X <逻辑X> -Y <逻辑Y>
pwsh -NoProfile -File scripts/scroll-window.ps1 -X <逻辑X> -Y <逻辑Y> -Notches -8
pwsh -NoProfile -File scripts/host-action.ps1 -Action host.status
```

`scroll-window.ps1` 用同一套逻辑坐标与 DPI 换算发滚轮事件，用来看到折在窗口下方的
部分（设置页的「关于」「退出后台代理」就在首屏之外）。`-Notches` 为负向下滚。

截图写到 `docs/images/`，**该目录整体被忽略，不入库**（理由见
[repo.md](repo.md#界面截图不进仓库)）。它是核对用的临时产物，不是交付物；
需要留档时自己另存，不要 `git add`。

- **瞄准表格行时 x 要落在表格里**：节点页内容区左边距约 200 px，表格行从卡片左边缘
  （约 215）才开始。x=193 这类坐标打在页面的空白内边距上，行既不高亮也不选中，
  而脚本照样打印 `clicked` 且退出码为 0——和上面那条一样，最容易被误判成"点击失效"。
  实证办法：`capture-window.ps1` 看命中行的高亮带，或临时在行的
  `MouseRegion.onEnter` / `Listener.onPointerDown` 里 `debugPrint`，跑 release 版把
  stdout 重定向到文件，按日志定位（`buttons=1` 说明左键真的到了）。
- `click-window.ps1` 收**逻辑客户端坐标**（以 `ClientToScreen` 得到的内容区原点为基准），
  脚本内部按窗口 DPI 缩放（不是按 1180 假设）。**不要**再从 `GetWindowRect` 的原点算起：
  那个矩形包含标题栏，实测客户区原点是 `(13,58)`，于是一次瞄准 y=127 的点击落到
  y=156，打开了下一行。表现很阴险——脚本打印 `clicked` 且退出码为 0，但页面根本没变，
  截图哈希一模一样。看到哈希没变，先查这一点，不要先怀疑渲染。
- `capture-window.ps1` 用 `PrintWindow` + `PW_RENDERFULLCONTENT`。普通 BitBlt 对
  Flutter 这类 GPU 合成窗口只能得到黑图
- **两个脚本都必须先强制 DPI 感知**（`SetProcessDpiAwarenessContext`）：pwsh 默认
  不是 DPI 感知进程，150% 缩放下 `GetWindowRect` 会返回虚拟化尺寸，截图只拍到窗口
  左上角 2/3、点击坐标还会被放大 1.5 倍（点「节点」会打开「分流」）。这段已在脚本里
- **深色模式的标题栏要用 `capture-screen.ps1` 验证**：`PrintWindow` 画的是经典非
  客户区，深色标题栏在它里面永远是浅色，看起来像没生效
- **截图哈希相同 = 操作没生效**。先怀疑输入没送达（窗口未获焦点），不要先怀疑渲染
- 保存截图后若看不到变化，确认时间戳在更新，而不是读到了旧文件

## 验证前先确认激活节点

节点表里键盘 `Enter` 是「启用所选」。误按会把代理切到别的节点（曾把 `CN-WS-CDN`
切成 `US-Naive-H3`）。用 `host-action.ps1 -Action snapshot.get` 读 `activeNodeName`
确认，而不是看界面。

恢复方式：选中目标行后按 `Enter`，再读快照确认。

## 变更验证的最低标准

- **新增行为**：加测试，并做**反向验证**（把实现改回去，测试必须失败）。
  只加不验的测试经常是永远为真的装饰
- **修复缺陷**：先能复现，再修，再确认复现路径消失
- **UI 改动**：至少一次真实窗口截图确认，不能只依赖 widget test

反向验证的具体做法：备份实现 → 改成错误版本 → 跑测试确认失败 → 恢复。
