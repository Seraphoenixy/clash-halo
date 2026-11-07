# 分流规则与内置规则集

规则页的分流来自 Clash Verge Rev 的实测配置：18 个规则集、37,828 条条目，按
`rule_set` 引用后交给 sing-box 匹配。

## 数据从哪来

`packages/config/lib/src/builtin_rulesets.dart` 是**生成文件**，不要手改：

```powershell
python tools/gen_builtin_rulesets.py
```

脚本读 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml` 的
`rule-providers` 段，把每个 provider 转成 sing-box `inline` 规则集。参考配置变了
就重跑一次，diff 会直接显示哪些条目增减。

## 为什么是 inline，不是 local 或远程

| 方案 | 结论 |
| --- | --- |
| `type: inline` | **采用**。规则集随 `active.json` 一起下发，宿主零改动。 |
| `type: local` | 需要把规则集文件一起落地，但宿主只拷贝单个 `active.json`（`app.go` 的 `promoteConfig`）。要改 Go 与契约。 |
| 远程 provider | 让分流依赖一次网络请求：拉取失败就会退化成"全部走代理"，比固定快照更糟。这个客户端也没有 provider 拉取器。 |

代价是体积：18 个集合内联约 **641 KB**。实测（`sing-box 1.14.4`）加载 695 KB
配置约 **686 ms** 启动，可以接受。生成器**只内联被规则引用的集合**，所以只加
「AI 服务」时文档只多 3.5 KB，不是 641 KB。

## sing-box 与 mihomo 的差异（实测）

照抄 Verge 的 provider 格式会直接失败：

```text
decode config: route.rule_set[0].behavior: json: unknown field "behavior"
```

`behavior` 是 mihomo 的概念。sing-box 的规则集靠 `rules` 里的匹配键区分域名与
IP，所以生成器把 `+.suffix` / `*.suffix` 归到 `domain_suffix`、其余归到
`domain`、ipcidr 归到 `ip_cidr`。

## 验证方式

不是"JSON 看起来对"，而是让内核真的跑：

```powershell
cd packages\config
..\..\.tools\flutter\bin\dart.bat test test\ruleset_test.dart
```

- 用 `sing-box check` 校验全量内联文档（>500 KB）
- 反向验证：把 payload 换成一个 `bogus_matcher` 键，两条内核校验用例必须失败
- 端到端：起内核、把「AI 服务」指向一个死端口，`claude.ai` 得到 502 而
  `example.com` 正常 200 —— 证明规则集真的参与匹配，而不只是被解析

## 规则数量与体积的关系

| 集合 | 条目 | 内联体积 |
| --- | --- | --- |
| Netflix | 24 | 0.5 KB |
| Telegram | 21 | 0.4 KB |
| AI 服务 | 179 | 3.5 KB |
| Google | 898 | 15.8 KB |
| 中国大陆 IP | 9,651 | 169 KB |
| 地理定位/广告 | 22,891 | 369 KB |

规则集下拉里直接显示条目数，因为 24 与 22,891 是"几乎免费"和"配置明显变大"的
区别，用户在选择时就应该看得到。

## 默认全部启用

首次启动会把 **18 个规则集各生成一条规则并全部启用**，与参考客户端的意图一致：
私网与 CN 走直连，其余走代理（本项目 `route.final` 本来就是 `proxy`，所以真正改变
行为的只有直连那三条）。

走向按 **tag** 决定，不按位置：

| 直连 | 代理 |
| --- | --- |
| `geosite-private`、`geoip-private`、`geoip-cn` | 其余 15 个 |

按 tag 而不是按列表下标，是因为目录重新生成后顺序可能变化，按下标会让私网流量
突然走代理。

### 三个必须守住的边界

1. **"从未设置" 与 "用户删光了" 不能混为一谈。** 只有前者种入默认值。把后者也
   种入，用户就永远删不掉规则——每次启动都会复活。测试 `a user who deleted every
   rule does not get them back` 钉住这条，反向验证：改成"空也种"后该用例立即失败。
2. **种入必须被应用一次。** 规则只写进数据库、不进内核时，界面显示 18 条已启用而
   内核只有 4 条内置规则，差异直到有人发现"规则不生效"才会暴露。`_applySeededRules`
   在连接建立、快照到达后执行一次（一次性标记，重连不会重复写配置）。
   触发点不能放在 `ensureCoreRunningForLaunch` 里：内核已在运行时它提前 return，
   而那正是热启动的常态。
3. **悬空的 `activeNodeId` 要修。** 宿主的快照里可能留着一个本机数据库已不存在的
   节点 id（节点被删或重新导入后 id 变了），`reapplyRoutingIfPossible` 会因此
   静默返回 false。现在发现失效就改选第一个可用节点。

验证方式是看内核而不是看数据库：

```powershell
curl -sS http://127.0.0.1:9090/rules
```

18 条规则集 + 4 条内置 = 22 条，`active.json` 里能看到 18 个 `rule_set`。

## 交互上的两个决定

- **票选而不是手填**：`geosite-category-ai` 这种 tag 不该让人凭记忆输入，所以
  「内置规则集」类型把输入框换成下拉。
- **切换类型清空值**：从规则集切回域名时清空，否则域名规则里会残留
  `geosite-youtube`，校验才报错，而用户已经选完了。
- 规则行显示「AI 服务 · 179 条（geosite-category-ai）」而不是裸 tag；tag 已不存在
  时显示「（已不存在）」，让人还能删掉它。
