# 会话与上下文

[English](context.md) | 中文

## 会话日志

每一轮都追加进一份日志，这份日志是唯一的事实来源：

```
user       {text}
assistant  {text, reasoning, toolcalls, model}
tool       {id, name, arguments, output, iserror, duration, display}
notice     {text, level}      -- 仅本地显示，不会发给模型
compact    {summary}          -- 压缩边界
```

终端回显、会话恢复、导出、token 统计，以及模型看到的内容，全部从它派生，
因此不可能互相对不上。

## 按工程维护

会话按工程目录存储，和 claude code 一样：

```
~/.xmake/harness/projects/-Users-ruki-projects-foo/6a86cfc5-bbda-14ce.json
```

所以 `/sessions` 只列当前工程的历史，恢复会话也不会去扫其他工程。

```
/sessions              当前工程的最近会话
/sessions all          所有工程
/sessions remove <id>  删除某个会话
/resume <id>           恢复，并回放整个对话
/clear                 开新会话
/export [path]         导出成 markdown
```

```bash
xmake ai -c            # 继续当前目录的上一次会话
xmake ai -r <id>       # 恢复指定会话
xmake ai --list=sessions
```

## 上下文被什么占满了

```
/context
```

```
███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  12%

  █ system prompt     5.0k
  █ tool schemas      2.2k
  █ your messages       412
  █ model replies       890
  █ tool results       7.1k

  15.6k of 131.1k tokens · mode: auto
  6 old tool results pruned, 2 superseded reads dropped (~18.2k tokens saved)
```

## 上下文如何优化

日志保留一切，模型看到的是它的一份**优化投影**。三种机制按顺序生效，
一个比一个代价大：

**1. 工具输出截断** —— 单次工具输出在产生时就被限制在 `tools.maxoutput`
（默认 60000 字节），并在结尾注明截断了什么。

**2. 裁剪（microcompaction）** —— 超过 `context.prunethreshold`（窗口的 55%）后，
较早那些轮次的工具输出被替换成一句占位：

```
[the output of `read_file` was dropped to save the context: 24188 bytes,
 it is out of the recent context. run it again if you still need it.]
```

最近的若干轮（`context.keeprecent`）和最近的若干条工具结果
（`context.keepresults`）始终保持完整。同一个文件被读了两次时，旧的那份也会被丢掉。
**日志里什么都没丢** —— 只是投影变小了，并且明确告诉模型需要的话可以重新读。

**3. 压缩** —— 超过 `context.threshold`（82%）后，小模型把最近若干轮之前的内容
总结成摘要，并在日志里插入一个 `compact` 边界，之后的投影从摘要开始。

```
/compact                        立即压缩
/compact 重点关注链接错误        指定摘要的侧重点
```

## 两种模式

```
/context full     发送完整历史，不裁剪、不压缩
/context auto     默认，按需裁剪和压缩
```

`full` 适合那种短但每个细节都重要的会话。注意历史超出窗口时请求会失败，
所以要盯着 `/context`。

## 配置项

```json
{
    "context": {
        "mode": "auto",
        "threshold": 0.82,
        "prunethreshold": 0.55,
        "keeprecent": 6,
        "keepresults": 8,
        "toolresultlimit": 1200,
        "maxfilesize": 262144
    }
}
```

| 键 | 含义 |
| --- | --- |
| `mode` | `auto` 或 `full` |
| `threshold` | 触发压缩的占用比例 |
| `prunethreshold` | 触发裁剪的占用比例 |
| `keeprecent` | 最近多少轮用户消息永不动 |
| `keepresults` | 最近多少条工具结果永不裁剪 |
| `toolresultlimit` | 超过这个大小的工具结果才可能被裁剪 |
| `maxfilesize` | `read_file` 单次读取的文件大小上限 |

## Token 统计

每轮都会报告消耗，状态栏保留累计值：

```
25.0k tokens (↑ 24.9k · ↓ 150 · cache 88%) · 28.1s · 3 steps
```

缓存命中率来自服务端（deepseek 和 anthropic 都会返回），这是最值得盯的指标：
稳定的前缀 —— system prompt、工具 schema、早期历史 —— 才能命中缓存，
这也是裁剪从不改写最近消息的原因。

`/cost` 查看整个会话的汇总。
