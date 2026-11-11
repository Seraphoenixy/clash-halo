# AGENTS.md

面向在本仓库工作的 AI 代理。**本文件只放必须每轮知道的事**；细节在
`docs/agents/`，按需读取，不要一次性全部载入。

## 这是什么

Windows 桌面代理客户端，两个进程：

```text
Flutter UI (apps/flutter)  ──命名管道 NDJSON──▶  halo-host.exe (native/windows)
                                                    └─ sing-box.exe
```

核心不变量：**运行状态只有 `halo-host.exe` 读写**，UI 一律通过管道请求；业务数据
（SQLite 节点、订阅、设置）由 Dart 进程直接读写，宿主不链接 SQLite。详见
[docs/架构.md](docs/架构.md)。UI 退出不停止代理。测速结果与 Windows 流量统计也
归宿主所有：UI 关闭不取消任务、不清空结果，宿主退出才结束会话。

Android 端没有 `halo-host`：Flutter UI 经平台通道驱动独立 `:vpn` 进程里的
libbox，状态写在应用私有目录的 `vpn-state.json`。见
[native/android/README.md](native/android/README.md)。

## 五条硬约束

1. **工具不在 PATH**：`.tools/go/bin/go.exe`、`.tools/flutter/bin/flutter.bat`、
   `.tools/flutter/bin/dart.bat`
2. **构建用 `pwsh`**（不是 Windows PowerShell 5.1），且**必须先退出正在运行的程序**，
   否则部署只完成一半
3. **测试范围按改动规模决定**，普通改动只跑受影响的包，不要全量
4. **大范围替换前先备份**，本项目曾因此删掉 260 行且无备份可恢复
5. **三种测量不能合并**：延迟、速度、连通性各自独立

## 索引

| 何时读 | 文档 |
| --- | --- |
| 要构建、部署、改 Go 二进制 | [docs/agents/build.md](docs/agents/build.md) |
| 要改 CI、发版、获取内核二进制 | [docs/agents/build.md](docs/agents/build.md#持续集成) |
| 要跑测试、用截图验证 UI | [docs/agents/testing.md](docs/agents/testing.md) |
| 要改测速 / 延迟 / 连通性相关代码 | [docs/agents/measurement.md](docs/agents/measurement.md) |
| 要处理换行符、`.gitignore`、日志、数据目录 | [docs/agents/repo.md](docs/agents/repo.md) |
| 要做脚本化批量改写 | [docs/agents/editing.md](docs/agents/editing.md) |
| 要用命令行导入订阅 / 节点 | [docs/agents/cli.md](docs/agents/cli.md) |
| 要改分流规则 / 内置规则集 | [docs/agents/rules.md](docs/agents/rules.md) |
| 要改 TUN 服务 / 安装时机 / 后端回退 | [docs/tun-service-design.md](docs/tun-service-design.md) |

设计与架构背景（面向人，非操作约束）：

- [docs/架构.md](docs/架构.md) — 进程模型、状态与意图
- [docs/契约.md](docs/契约.md) — 管道协议规格
- [docs/设计规范.md](docs/设计规范.md) — 界面规范

## 代码分布

| 位置 | 职责 |
| --- | --- |
| `apps/flutter` | UI，包名 `halo` |
| `apps/cli` | 命令行，包名 `halo_cli`（只做订阅/节点导入，不做测量） |
| `packages/contracts` | 管道协议、错误码、速度模型 |
| `packages/domain` | 节点模型、导入、指纹、批处理 |
| `packages/config` | sing-box 配置生成 |
| `packages/storage` | SQLite schema 与仓储 |
| `native/windows` | Go 宿主，模块 `clash-halo/native/windows` |
| `native/windows/internal/contract` | 与 `packages/contracts` 一一对应 |
| `native/android` | Android VPN 模块（`:vpn` 进程 + libbox），见其 README |

**`packages/contracts` 与 `native/windows/internal/contract` 必须同步改**，
否则 UI 连不上或读不懂。

## 验证的标准

改完要能回答"我怎么知道它生效了"，而不是"代码看起来对"：

- 新增行为：加测试 **并做反向验证**（把实现改回去，测试必须失败）
- 修复缺陷：先能复现，再修，再确认复现路径消失
- UI 改动：至少一次真实窗口截图确认

## 当前状态

仓库已有初始提交；后续改动已暂存，尚未提交。
