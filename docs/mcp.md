# MCP

English | [中文](mcp.zh.md)

The builtin tools stay native: they are lua, they run in process, and they are
what the agent uses for the everyday work. An MCP server is the other way in —
it brings the tools of a third party, and they join the same registry, so the
model, the permission policy, the confirmation dialog and the tool cards treat
them exactly like the native ones.

## Configuring a server

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

| key | meaning |
| --- | --- |
| `command` | the program which speaks the MCP stdio transport |
| `args` | its arguments |
| `envs` | the extra environment variables, e.g. the tokens |
| `cwd` | the working directory of the server |
| `enabled` | set it to `false` to keep the entry but not load it |
| `permission` | `none`/`read`/`write`/`exec`/`network`, `exec` by default |
| `timeout` | the request timeout in milliseconds, 30000 by default |
| `keepalive` | keep the server running after the tools are listed |

The servers can be declared in the user configuration
(`~/.xmake/harness/config.json`, for the ones you use everywhere) or in the
project one (`<project>/.xmake-harness/config.json`, for the ones this
repository needs).

## Using it

```
/mcp            the servers, their state and the tools they brought
/mcp reload     reconnect and refresh the tool list
```

The tools are named `<server>__<tool>`, e.g. `github__create_issue`, so two
servers can offer a `search` without colliding.

```bash
xmake ai --command=mcp
xmake ai --list=tools | grep github__
```

## What it costs

Nothing until you use it. A server is started to list its tools at boot and then
stopped again; it is started once more when the model actually calls one of its
tools. A session which never touches them never spawns anything (set
`keepalive` if a server is expensive to start).

## Permissions

An MCP server is a third party: the harness cannot know what one of its tools
really does, so they default to the `exec` permission — the user confirms every
call, exactly like a shell command:

```
 github__create_issue(repo: xmake-io/xmake)
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to run `github__create_issue`?
 ❯ 1. Yes
   2. Yes, and do not ask again for `github__create_issue`
   3. No, and tell the model what to do differently
```

Set `"permission": "read"` for a server which only reads, and its tools stop
asking (and may then run concurrently with the other read-only tools).

The usual rules apply too:

```json
{"permission": {"allow": ["sqlite__query"], "deny": ["github__delete_repo"]}}
```

## Writing a server

Any program which speaks the MCP stdio transport works. A minimal one in xmake
lua is in `tests/mcpserver.lua`: it reads one json-rpc message per line from the
stdin and answers `initialize`, `tools/list` and `tools/call`.

```bash
xmake ai --config=mcp.servers.demo.command=$(which xmake)
```

## The implementation

| module | what it does |
| --- | --- |
| `mcp/jsonrpc` | the json-rpc 2.0 framing, one message per line |
| `mcp/client` | one server: spawn, handshake, `tools/list`, `tools/call` |
| `mcp/mcp` | turns the mcp tools into harness tools and registers them |

The client talks through a pipe pair and its waits yield to the xmake scheduler,
so a slow server never blocks the ui or the other tools.
