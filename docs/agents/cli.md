# 命令行 `halo-cli`

用命令行导入订阅与节点，不必打开界面，也不必手写 SQL 改数据库。

**范围只有导入**：添加/更新/删除订阅、导入本地配置、列订阅和节点。延迟、速度、
连通性三种测量**不在 CLI 里**——它们是三个彼此独立的测量（见
[measurement.md](measurement.md)），各有一个实现；再抄一份到 CLI 是最容易报出
假数据的做法。

## 为什么 CLI 直接开 SQLite

它不是第二套存储层。当前代码里 Go 宿主**不打开** SQLite（`native/windows` 下没有
sqlite 依赖），节点与订阅的写入一直发生在 Dart 进程：界面的
`AppController._openStore()` 调 `HaloStore.open(dataDir/clash-halo.db)`。CLI 复用
`halo_storage` + `halo_domain`，所以 schema、迁移、导入器、指纹去重与界面完全同一份
代码——不会出现"CLI 导入的节点界面读不懂"。

另一条路是给宿主加管道动作，让 Go 解析 Clash YAML / sing-box JSON / Base64 / 分享
链接。那等于把 `packages/domain` 的导入器在 Go 里重写一遍，还要让
`packages/contracts` 与 `internal/contract` 同步加动作。为"导入"这一个需求增加两处
重复实现不划算。

## 数据目录

解析顺序与宿主 `resolveDir` 一致：

| 优先 | 来源 |
| --- | --- |
| 1 | `--dir <目录>` |
| 2 | `--db <文件>`（直接指定数据库） |
| 3 | 环境变量 `HALO_DATA_DIR` |
| 4 | 可执行文件旁的 `portable.flag` → `<exe 目录>/user-data` |
| 5 | `%LOCALAPPDATA%\clash-halo` |

编译产物放在 `build\windows-x64\` 时会自动命中第 4 条，不需要每次带 `--dir`。

## 命令

```powershell
# 列出订阅与节点
halo-cli sub list
halo-cli nodes list
halo-cli nodes list --sub 机场A --json

# 添加订阅：默认立即下载并写入节点
halo-cli sub add "https://example.com/sub" --name 机场A
halo-cli sub add "https://example.com/sub" --no-fetch   # 只加条目

# 更新（失败时保留旧节点，只在订阅行上记错误）
halo-cli sub update 机场A
halo-cli sub update --all

# 经本机内核的代理端口下载：直连下不动的订阅源用这个
halo-cli sub add "https://example.com/sub" --name 机场A --proxy 127.0.0.1:7890
halo-cli sub update 机场A --via-proxy     # 本次强制走代理，不改偏好
halo-cli sub update --all --via-proxy

# 删除（默认把节点归入「本地」订阅，避免代理突然断掉）
halo-cli sub remove 机场A
halo-cli sub remove 机场A --purge-nodes

# 订阅集合（单层分组）
halo-cli groups list
halo-cli groups add 工作
halo-cli groups rename 工作 公司      # 改名，成员与订阅都不变
halo-cli groups assign 机场A 工作
halo-cli groups assign 机场A none      # 移回未分组
halo-cli groups remove 工作            # 只删分组，订阅保留

# 从本地文件导入节点（Clash YAML / sing-box / v2rayN / Base64 / 分享链接）
halo-cli import .\nodes.txt
```

选择器可以是订阅 **id**、**完整名称**，或唯一的名称/URL 片段；命中多条时报错并列出
候选，不猜。

其他选项：`--proxy <地址>`、`--via-proxy`、`--timeout <秒>`（单次等待上限，默认 20；
整次下载上限是其 3 倍）、`--json`、`--help`、`--version`。

## 集合只是标签

集合只有一层，用来把长列表切成几段。两条硬规则：

- **删除集合不会删除订阅**，成员只是回到未分组。
- **改名按 id 进行**，所以成员关系原样保留。界面里是「集合」对话框每行的铅笔图标；
  CLI 是 `groups rename <id|名称> <新名>`。两边都不提供"删了重建"的捷径，因为那会把
  组内订阅全部打回未分组。
- 重名会被拒绝而不是静默合并：合并会移动用户没有选择的订阅，且没有撤销。

集合 id 用**微秒**时间戳并在生成时避让已占用的值。曾经的毫秒版本让同一 tick 内创建的
第二个集合复用第一个的 id，`upsert` 于是把它**改名**而不是新增一行——表现为"我建了
「工作」和「公司」，却只剩「公司」"。回归测试连续建 200 个集合并断言 200 个不同 id
（反向验证：换回毫秒后只剩 96 个）。

## 经代理下载

`--proxy <地址>` 与 `--via-proxy` 的区别是**是否记住**：

| 选项 | 本次传输 | 是否写进订阅行 |
| --- | --- | --- |
| `--proxy 127.0.0.1:7890` | 经该代理 | 是（`use_proxy` + `proxy_url`） |
| `--via-proxy` | 经代理（端点取该订阅已存的值，否则 `127.0.0.1:7890`） | 否 |

界面里对应两处：操作栏的「代理更新」按钮（一次性），以及每行右侧的锁形图标
（长期偏好）。端点存在订阅行上而不是硬编码，因为内核端口用户可以改；一个只会
退回硬编码端口的开关，恰好在用户改过端口的机器上永远失败。

传输实现见 `packages/domain/lib/src/subscription_fetch.dart`：`HttpClient.findProxy`
对 https 发 `CONNECT host:port` 并在隧道内做 TLS（`packages/domain/test/subscription_fetch_test.dart`
用一个真 CONNECT 服务器验证过，反向验证：去掉 `findProxy` 后该测试失败）。

退出码：`0` 成功，`1` 命令执行失败（例如下载失败），`2` 用法错误。

## 与界面同时使用

SQLite 在 WAL 模式下允许多进程读写，CLI 与界面可以同时存在。但界面在内存里缓存了
订阅/节点目录，CLI 写入的内容要**重启界面**（或等界面的下次目录失效）才显示。
导入完再开界面是最省心的顺序。

## 本地是订阅

自 schema v6 起，`profile_id IS NULL` 不再是一个合法状态：「本地」是一个真正的
订阅行（id 固定为 `local`，`kind = 'local'`）。`import` 与界面里的粘贴导入都会
按需创建它，所以本地节点可以改名、可以进集合，也能在 `sub list` / `nodes list`
里和其他来源一样列出。

`sub remove` 默认把它名下的节点改归「本地」而不是置空；要连节点一起删，用
`--purge-nodes`。内置的 `local` 行本身删不掉（仓储层直接忽略），否则本地节点
会变成孤儿。

## 已知限制

- **不走系统代理**：`dart:io` 的 `HttpClient` 不读系统代理，界面同样如此。订阅源
  在直连下超时的时候，CLI 会明确提示，而不是让超时看起来像站点挂了。
- **输出被提前关闭算正常结束**：`halo-cli nodes list | head` 时下游关管道，Dart 把
  写失败当成异步异常抛给 zone（不是 `writeln` 同步抛出），所以入口用
  `runZonedGuarded` 识别并直接以 0 退出，不打印栈。
- **日期随链接写死的订阅源不会自动换日期**。部分公共源（如 `.../node/20261105.txt`）
  只在当天有效，过了当天就是 404；这类源要么每天重新添加，要么在源本身提供稳定
  地址时改用稳定地址。
- **`--via-proxy` 的默认端点写死在 7890**。CLI 在解析命令行时还没打开 settings 表，
  读一次默认值就会让 `--help` 也碰数据库。订阅行里存过端点时优先用它，所以长期
  用法不受影响；只有首次、且内核端口不在 7890 时才需要显式 `--proxy`。

## 构建与测试

```powershell
cd apps\cli
..\..\.tools\flutter\bin\dart.bat analyze
..\..\.tools\flutter\bin\dart.bat test

# 发布版单文件（产物约 7.6 MB，不依赖 Dart SDK）
..\..\.tools\flutter\bin\dart.bat compile exe bin\halo_cli.dart -o ..\..\build\windows-x64\halo-cli.exe
```

CLI 是 workspace 成员（根 `pubspec.yaml` 的 `workspace`），改 `packages/storage` 或
`packages/domain` 后无需单独 `pub get`；新增依赖时在 `apps/cli` 下跑一次
`dart.bat pub get`。

## 验证要点

- 测试用本地假 fetcher（`test/cli_test.dart` 的 `FakeFetcher`），不打真实网络：
  真实源的 404/超时会让测试结果随网络变化。
- 失败更新必须**保留旧节点**——这条用例是"订阅更新失败不能清空用户节点"的唯一保障。
- 选择器歧义必须报错而不是取第一条：取第一条会让脚本静默更新错订阅。

## 日期模板与代理默认

订阅地址可以带 `{date}`，更新时展开成本地日期（`yyyyMMdd`）。当日文件未发布时
向前回退最多 **7 天**，并在行上留下「已使用 N 天前的文件」——不回退的话，日期型
源每天早上都会 404，直到发布者上传。

只有 **404** 触发回退。超时、DNS 失败、5xx 对所有候选都一样，重试只会把报错时间
拖长 7 倍。

代理开关是**三态**：

| 值 | 含义 |
| --- | --- |
| `use_proxy = 1` | 用户明确开启 |
| `use_proxy = 0` | 用户明确关闭 |
| `use_proxy = NULL` | 没表过态，由来源策略决定 |

来源策略：`raw.githubusercontent.com`、`github.com` 及其内容域名默认走代理（实测
直连被重置，经代理约 1 秒）。列表里自动态标 `[经代理·自动]`，显式态标 `[经代理]`。

v7 迁移把「`use_proxy = 0` 且从未记录过端点」的旧行转为 NULL：旧列是
`NOT NULL DEFAULT 0`，那个 0 从来分不清「用户关掉」和「默认」，而端点只在真正开启
过代理时才写入，所以它是可靠的判别依据。曾经开过又关掉的行保留端点，仍是明确的关闭。
