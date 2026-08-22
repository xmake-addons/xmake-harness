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

## 自己写一个 server

任何说 MCP stdio 协议的程序都可以。`tests/mcpserver.lua` 是一个用 xmake lua
写的最小实现：从 stdin 逐行读 json-rpc 消息，回应 `initialize`、`tools/list`
和 `tools/call`。

## 实现

| 模块 | 职责 |
| --- | --- |
| `mcp/jsonrpc` | json-rpc 2.0 分帧，一行一条消息 |
| `mcp/client` | 单个 server：启动、握手、`tools/list`、`tools/call` |
| `mcp/mcp` | 把 mcp 工具包装成 harness 工具并注册 |

client 通过管道对通信，等待会 yield 给 xmake 调度器，
所以慢的 server 不会卡住 UI 或其他工具。
