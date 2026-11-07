# 仓库约定

## 换行符

`.gitattributes` 是唯一规则来源，`core.autocrlf` 已设为 `false`。

| 类型 | 规则 |
| --- | --- |
| 源码、文档 | LF |
| `*.ps1` `*.bat` `*.cmd` | CRLF（PowerShell 解析纯 LF 脚本会出错） |
| 图片、二进制 | `binary`，不转换 |

若 `git add` 出现 `LF will be replaced by CRLF` 之类警告，说明工作区与规则不一致。
应规范化文件，而不是改配置。

规范化某个文件：

```powershell
python -c "p='path'; b=open(p,'rb').read(); open(p,'wb').write(b.replace(b'\r\n', b'\n'))"
```

然后 `git add -A` 复查警告数应为 0。

## 根目录禁止出现 `nul`

`nul` 是 Windows 保留设备名。在 bash 里写 `>nul` 会生成一个真实文件，而 Git
无法索引它：

```text
error: short read while indexing nul
error: unable to index file 'nul'
fatal: adding files failed
```

后果是**整个 `git add -A` 失败**，一个文件都进不了索引。症状：暂存区始终为空，
所有文件都显示 untracked，`git log` 显示零提交。

这不是"没人提交"，而是提交根本不可能成功。

## 日志与本地数据不进仓库

```
*.log
**/halo-core.log
**/core-output.log
**/tun-core.log
**/host.log
*.db
*.db-wal
*.db-shm
```

内核日志按**当前工作目录**写盘，所以 `halo-core.log` 会出现在仓库任意子目录，
跑一次测试就生成一个。`.gitignore` 必须用 `**/` 规则，只匹配根目录会漏。

**`.gitignore` 只对未跟踪文件生效。** 已进索引的日志需先 `git rm --cached <file>`
才会被忽略，否则规则看起来写了却没起作用。

## 界面截图不进仓库

```text
docs/images/
```

`docs/images/` 整体忽略，包括 `ui-*.png`、`ui-capture.png`、`review/**` 和
`brand-cat*.png`。截图记录的是"本机某一刻的样子"——窗口尺寸、200% 缩放、当时
的节点与订阅全在像素里，入库的代价是：每次核对界面都改一堆二进制（diff 看不出
改了什么）、文档很快挂着旧界面、几 MB 历史永久留存。

需要时现生成（脚本会自建目录，clone 后目录不存在是正常的）：

```powershell
pwsh -NoProfile -File scripts/capture-window.ps1 -Out docs/images/ui-overview.png
py -3 tools/build-icons.py        # 顺带产出 docs/images/brand-cat*.png
```

文档里可以写 `![...](images/xxx.png)`，但**必须同时说明这张图不入库**，
否则读者会以为链接坏了。`docs/设计规范.md` 开头就是这么标的。

**UI 改动的验收标准不变**：仍然要至少一次真实窗口截图确认，只是截图不再进
仓库——存到 `docs/images/`（已被忽略）即可。

## 数据位置

```text
%LOCALAPPDATA%\clash-halo\        ← Local，不是 Roaming
  clash-halo.db                   ← SQLite
  configs\active.json             ← 正在运行的内核配置
  logs\host.log                   ← 宿主日志
  runtime.json
```

表：`meta` / `subscriptions` / `subscription_groups` / `nodes` / `settings` /
`applied_config` / `import_log`。

schema v6 起 `subscriptions` 多了 `kind`（`remote` / `local`）、`group_id`、
`use_proxy`、`proxy_url` 四列，并有 `subscription_groups` 表。**「本地」是一个
真实的订阅行**（`id = 'local'`，`kind = 'local'`），因此 `nodes.profile_id IS NULL`
不再是合法状态：任何写节点的路径都会把它归到 `local`（见
`NodeRepository.insertAll`）。旧的 `profile_id IS NULL` 行由 v6 迁移一次性收养，
迁移可重复执行。

`nodes.port` 存的是**字符串**（如 `'443'`），不是整数。

## 导入失败怎么记

订阅刷新时，**导入成功的节点、订阅行的更新时间、`import_log` 的一行记录在同一个事务里
写入**（`AppController.updateSubscription`）。记录含来源、格式、导入/跳过/失败数与
`detail`：按 `ImportFailureKind` 的统计，加前 20 条被拒条目的类型、原因、行号和原文
（每条截断到 240 字符）。`detail` 上限 8192 字符——旧的 512 会在第一条样本中间截断。

措辞在 `packages/domain/lib/src/import/summary.dart`，窗口与 CLI 共用。**不要再把总数
写成「N 条不支持」**：这个集合里既有真正的协议缺失，也有格式损坏的坏行，两者对用户
意味着完全不同的处理。分项计数按数量倒序，最多列四类。

分享链接里的 `&amp;` 会在解析前还原（只还原 `#` 之前的部分，片段是节点名）。抓取来的
列表常用这种转义，不还原时参数会被并进相邻项，报「REALITY 客户端缺少公钥」而不是转义
问题。

**「未导入」里必须把重复和失败分开**：重复（`duplicate`）是同一份订阅里出现多次的节点，
已保留第一条；失败才是这条链接不可用。混在一起时，一份 2427 个节点、1580 条重复的列表
会显示成「1461 条未导入」，读起来像丢了 1461 个节点。窗口现在写「未导入 N 条（分类）,
重复 M 条」。

## 分享链接按生态的实际格式解析

`parseShareLink` 故意比 RFC 3986 宽松，因为生成这些链接的客户端都比 RFC 宽松。删掉下面
任何一条都会让一整批可用节点变成「格式损坏」——真实数据上曾因此一次拒掉 1300 条：

`packages/domain/lib/src/import/clash_yaml.dart` 的传输映射同样按 Clash Meta 的实际拼写：
`network: raw` 等价 `tcp`，`network: http` 用 `http-opts`（`path`/`headers` 是列表，
取首项）映射到 HTTP 传输。

| 形状 | 处理 |
| --- | --- |
| `trojan://密码含@...@host:port` | 取**最后一个** `@` 作 userinfo 分隔符，前面的 `@` 编码成 `%40` |
| `ss://aes-128-gcm:密码@host:port` | userinfo 含 `:` 时按明文 `method:password` 处理，不再 Base64 解码（2022-blake3 的密码本身就是 Base64） |
| 名字粘在端口上（`:443freenettir`、`:443<br/>`） | 端口只保留开头 1–5 位数字 |
| 链接体里混入空格、CJK、emoji、Markdown 括号 | 从第一个非法字符处截断，不整条拒绝 |
| `vmess://` 载荷后拖 emoji、`?fp=chrome`、乱码 | 解**最长的 Base64 前缀**，并先剥掉尾部 `=` 再补正确的 padding |
| `vmess://uuid@host:port?…`（URI 形式） | 载荷不是以 `{` 开头就不当 JSON 解，走 URI 分支 |
| `type=raw` | 等价 `tcp`（Xray 改名后的拼写） |
| 一行里粘了两条链接（`<base64>vless://…`） | 按 scheme 拆成多段，各自解析 |
| 缺 scheme 的 vmess Base64（整行只有 `eyJhZGQ…`） | 解码出含 `add` 与 `id` 的对象时按 vmess 解析 |

真正损坏的条目仍要报出来（例如发布方把 `#` 编码进 `type=`），而不是静默丢弃。

## 订阅下载走哪条渠道

每行 `subscriptions.use_proxy` 是三态：`1` 直连=否（强制代理）、`0` 强制直连、`NULL` 未选，
由来源策略决定（`raw.githubusercontent.com` 等 GitHub 内容域默认走代理，其余默认直连）。
**「全部更新」「更新所选」「定时更新」都按每行的值逐个下载**；只有工具栏的「代理更新」是
一次性覆盖（`viaProxy: true`），不改各行存储的值。页面的职责只是把行原样交给
`AppController.updateSubscription`，解析 `NULL` 发生在控制器里。

这条规则容易被误判成「全部更新不走代理」：行未选时是否走代理取决于来源域名，而不是按钮。
所以批量结果要把渠道写出来——`更新完成：成功 13（经代理 7，直连 6）`，行内的「更新」按钮
tooltip 也直接写该行会用的渠道；`import_log.detail` 的 `channel` 记录每条订阅实际用了哪种。
`apps/flutter/test/subscription_channel_test.dart` 用假代理和假源站从 socket 层验证四个方向
（行代理 / 行直连 / 未选按策略 / 强制代理），`subscriptions_batch_channel_test.dart` 验证
两个批量按钮传给控制器的参数和结果里的渠道计数。

## 仓库历史

当前零提交。首次提交前确认：

1. `nul` 不存在
2. `git add -A` 无警告
3. 日志与数据库文件未进入暂存区
4. `docs/images/` 下没有任何截图进暂存区（`git status --porcelain docs/images`
   应为空）
