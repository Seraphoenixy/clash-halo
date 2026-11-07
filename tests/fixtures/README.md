# Clash Halo 测试语料

这些文件是各包 `test/` 的共同输入。约定：

- 每个文件只验证一件事，失败时能直接看出是哪种输入的哪条规则出了问题。
- `golden/` 下的期望值与实现分开存放，避免“把实际输出写成期望值”的自我确认。
- 所有凭据均为占位值，不含真实服务地址或密码。

## 目录

| 路径 | 用途 |
| --- | --- |
| `share_links/basic.txt` | 常见协议的分享链接，每行一条 |
| `share_links/bad_lines.txt` | 结构错误、不应被静默丢弃的行 |
| `share_links/base64.txt` | Base64 包裹的订阅正文 |
| `clash/yaml_basic.yaml` | Clash 风格 `proxies:` 列表 |
| `clash/yaml_bad.yaml` | 缺字段 / 类型错误 |
| `singbox/json_basic.json` | sing-box `outbounds` |
| `singbox/json_bad.json` | 非法结构 |
| `singbox/tun_inbound.json` | TUN 入站默认值契约：Dart 生成与 host 注入必须逐字节一致 |
| `malformed/empty.txt` | 空正文 |
| `malformed/random.txt` | 无可用节点 |
