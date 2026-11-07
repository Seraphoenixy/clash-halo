# 源码编辑纪律

## 大范围替换前先备份

本项目曾发生一次事故：用 Python 脚本做整段替换，`str.index()` 定位到文件中另一个
同名的 `Tooltip(`，把 `nodes_page.dart` 中间约 260 行整段删除——包括 `_Col`、
`_ColumnWidths`、`_HeaderRow`、`_NodeRow` 及所有单元格组件。当时仓库零提交、无备份，
只能凭对读过内容的记忆重建，非常被动。

规则：

- 优先用精确的 `edit` 工具（要求 `old_string` 在文件中唯一）
- 必须脚本化时，先 `assert old in s` 再写回，不要盲替换
- 改动前 `cp file .tmp/file.bak`，验证通过后删除备份
- 替换后立刻 `dart analyze` 或 `go build`，不要攒到最后

## 定位要唯一，不要用第一个匹配

```python
# 危险：可能命中文件中完全不同的位置
i = s.index("    return Tooltip(")

# 安全：带上足够上下文，或先断言数量
assert s.count("    return Tooltip(") == 1
```

## 替换后立即验证结构

删掉一整段类定义后，`analyze` 会报一堆"未定义类"——这是好情况。坏情况是语法仍
合法但逻辑错位，只有测试能发现。所以**替换后先编译/分析，再跑相关测试**。

## 换行符规范化不算代码修改

批量把 CRLF 转成 LF 是安全的（不改变语义），但会触及大量文件。做完仍应跑一次
受影响的测试确认——尤其 `.dart` 和 `.go` 文件。

## 不要凭空断言文件内容

修改前先读。同一文件可能在本次会话中被改过，凭记忆写 `old_string` 会失败
（`file changed since it was read`）。重新读取再编辑。
