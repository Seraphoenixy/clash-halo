# halo（Flutter 界面）

Clash Halo 的 Windows 界面。构建与运行说明以仓库根目录的
[`README.md`](../../README.md) 为准。

- 入口：`lib/main.dart`
- 状态与协议：`lib/src/state/`、`lib/src/ipc/`
- 页面与组件：`lib/src/ui/`
- 测试：`test/`

常用命令（在仓库根目录执行）：

```powershell
pwsh -NoProfile -File scripts/test.ps1 -Suite flutter
pwsh -NoProfile -File scripts/test.ps1 -Suite flutter -Target test/nodes_page_test.dart
pwsh -NoProfile -File scripts/build-windows.ps1 -DartOnly
```

界面退出后宿主继续运行；不要在这里直接启动 `sing-box` 或写运行状态。
