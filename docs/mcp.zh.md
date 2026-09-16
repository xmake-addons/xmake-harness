# MCP

[English](mcp.md) | 中文

内置工具保持原生：它们是 lua、在进程内直接调用，日常工作都靠它们。
MCP 是另一个方向的入口 —— 它把第三方的工具接进来，进入**同一个注册表**，
因此模型、权限策略、确认框和工具卡片对待它们和原生工具完全一致。

## 配置一个 server

```json
{
    "mcp": {
        "servers": {
            "github": {
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-github"],
                "envs": {"GITHUB_TOKEN": "ghp_xxxxxx"}
            },
            "sqlite": {
                "command": "uvx",
                "args": ["mcp-server-sqlite", "--db-path", "./app.db"],
                "permission": "read"
            },
            "staging": {
                "command": "./tools/mcp-server",
                "enabled": false
            }
        }
    }
}
```

| 键 | 含义 |
| --- | --- |
| `command` | 说 MCP stdio 协议的程序 |
| `args` | 它的参数 |
| `envs` | 额外环境变量，比如 token |
| `cwd` | server 的工作目录 |
| `enabled` | 设为 `false` 保留配置但不加载 |
| `permission` | `none`/`read`/`write`/`exec`/`network`，默认 `exec` |
| `timeout` | 请求超时（毫秒），默认 30000 |
| `keepalive` | 列完工具后保持 server 常驻 |

可以写在用户配置（`~/.xmake/harness/config.json`，到处都用的）
或工程配置（`<project>/.xmake-harness/config.json`，这个仓库才需要的）里。

## 使用

```
/mcp            查看 server、状态和它们带来的工具
/mcp reload     重连并刷新工具列表
```

工具名是 `<server>__<tool>`，比如 `github__create_issue`，
所以两个 server 各自有 `search` 也不会撞名。

```bash
xmake ai --command=mcp
xmake ai --list=tools | grep github__
```

## 开销

用之前是零开销。启动时会拉起 server 列一次工具然后关掉；
模型真正调用某个工具时才再拉起来。整场会话没碰过就不会启动任何进程
（server 启动昂贵的话设 `keepalive`）。

## 权限

MCP server 是第三方，harness 无法知道它的工具究竟做什么，
所以默认按 `exec` 权限处理 —— 每次调用都要用户确认，和 shell 命令一样：

```
 github__create_issue(repo: xmake-io/xmake)
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to run `github__create_issue`?
 ❯ 1. Yes
   2. Yes, and do not ask again for `github__create_issue`
   3. No, and tell the model what to do differently
```

只读的 server 配 `"permission": "read"` 就不再询问
（并且可以和其他只读工具并行执行）。

常规规则同样适用：

```json
{"permission": {"allow": ["sqlite__query"], "deny": ["github__delete_repo"]}}
```

## 不用模型，单独试一个

一个跑不起来的 MCP server，失败方式是最没用的那种：harness 正常启动，工具悄悄不见了，
模型说它做不了这件事。所以 server 可以直接对话 —— 不过模型、不开对话、不花 token：

```bash
xmake ai mcp list                                  # 配置里有哪些，各自答不答话
xmake ai mcp tools demo                            # 某一个都提供什么，带参数签名
xmake ai mcp call demo echo '{"text":"hello"}'     # 用你手打的参数调一个工具
```

`list` 和 `tools` **复用 harness 已经启动的那个客户端**；启动失败的那个会在这里
重新启动一次，好让它的报错**摆在你面前**，而不是混在一条划过去的警告里。

## 用来对拍的那个 server

在上面这些有用之前，你需要一个**一定能用**的 server —— 否则工具没出现，可能是配置、
命令行、传输、server，也可能是 harness，根本分不清是谁的问题。内置了一个：

```bash
xmake ai mcp serve
```

它在自己的 stdin/stdout 上说 stdio 协议，不需要装任何东西。把 harness 指过去：

```json
{
  "mcp": {
    "servers": {
      "demo": {"command": "xmake", "args": ["ai", "mcp", "serve"]}
    }
  }
}
```

然后 `xmake ai mcp tools demo` 会列出四个工具。每个都有它的用意：

| 工具 | 为什么有它 |
| --- | --- |
| `echo` | 证明参数是按你发的样子到达的 |
| `now` | 一个完全不需要参数的工具 |
| `add` | **数字变成字符串**是 MCP 最常见的意外 |
| `fail` | 没人看过的错误路径，就是不能用的错误路径 |

`serve` **不会 bootstrap harness**：它不需要配置也不需要工具，而启动过程打印的任何东西
都会掉进它接下来要说的 json-rpc 流中间。

## 自己写一个 server

任何说 MCP stdio 协议的程序都可以。上面那个示例就是一百行左右的普通 xmake lua
（`harness/mcp/example.lua`）—— 想知道「一个 server 到底要做什么」，读它就够了：
从 stdin 逐行读 json-rpc 消息，回应 `initialize`、`tools/list`、`tools/call`，
忽略通知。

## 实现

| 模块 | 职责 |
| --- | --- |
| `mcp/jsonrpc` | json-rpc 2.0 分帧，一行一条消息 |
| `mcp/client` | 单个 server：启动、握手、`tools/list`、`tools/call` |
| `mcp/mcp` | 把 mcp 工具包装成 harness 工具并注册 |

client 通过管道对通信，等待会 yield 给 xmake 调度器，
所以慢的 server 不会卡住 UI 或其他工具。
