# Architecture

English | [中文](architecture.zh.md)

Read this before changing anything under `src/modules/harness`.

## The layers

```
  xmake ai                          the only cli entry (src/plugins/ai)
 ─────────────────────────────────────────────────────────────────
  ui/app                            the terminal application
  cli/headless                      the non-interactive runner
 ─────────────────────────────────────────────────────────────────
  core/agent                        the turn/step loop
  core/graph                        the agent graph, a dag of subagents
  core/subagent                     one delegation: depth, signal, ui nesting
  core/session                      the append-only event log, per project
  prompt/system                     the system prompt assembly
  tools/pipeline                    the guarded tool execution
  context/window                    the projection and its optimization
  context/compact                   the context compaction
 ─────────────────────────────────────────────────────────────────
  core/context                      the services and the event bus
 ─────────────────────────────────────────────────────────────────
  llm/*  fs/*  shell/*  sandbox/*  permission/*  hooks/*   the seams
  util/parallel                     the one way anything fans out
```

Everything above `core/context` is composed at boot by `harness.harness.bootstrap()`,
and everything build-system specific is a plugin.

## The context

`core/context` is the shared runtime of one harness instance. It holds two things:

**Services** — the registries, addressed by name:

| service | what it holds |
| --- | --- |
| `tools` | the tool registry, `tools/registry.lua` |
| `skills` | the skill registry, `skills/registry.lua` |
| `agents` | the subagent definitions, `agents/registry.lua` |
| `commands` | the slash commands, `commands/registry.lua` |
| `skillsources` | the installable skill packs the plugins registered |
| `mcp` | the connected mcp clients, @see [mcp](mcp.md) |
| `plugins` | the loaded plugin descriptions |
| `notices` | the boot notices shown in the welcome panel |
| `todos` | the current task list |

```lua
harness:service("tools"):add(definition)
local skills = harness:service("skills"):all()
```

**Events** — the extension points. There are three shapes:

```lua
harness:emit(name, ...)             -- notify everyone, the results are ignored
harness:bail(name, ...)             -- stop at the first non-nil result
harness:waterfall(name, value, ..)  -- every listener may rewrite the value
```

| event | shape | purpose |
| --- | --- | --- |
| `harness/ready` | emit | the boot is done |
| `prompt/sections` | waterfall | add/rewrite/drop the system prompt sections |
| `prompt/environment` | waterfall | add the environment facts |
| `agent/request` | waterfall | rewrite the llm request before it is sent |
| `tools/pre-execute` | waterfall | rewrite the arguments, or reject the call |
| `tools/post-execute` | waterfall | rewrite the tool result |
| `turn/start`, `turn/end` | emit | the turn boundaries |
| `todos/changed` | emit | the task list changed |
| `skill/loaded` | emit | a skill was loaded by the model |

## The turn

One `agent.run()` is one turn, and a turn is one or more steps:

```
turn/start
  step
    core/guards               stop a turn which repeats itself or only fails
    context/window.optimize   prune the projection, and enforce the hard limit
    context/compact           summarize the history if the window is nearly full
    prompt/system.build       the sections + the tool schemas
    agent/request         (waterfall)
    llm.complete          the streaming request
    the assistant event is appended to the session
    for every tool call:
        tools/pre-execute -> hooks -> permission -> sandbox -> run
        tools/post-execute
        the tool event is appended to the session
  step (again while the model keeps calling the tools)
turn/end
```

The ui never talks to the model: it passes a handler table (`on_text`,
`on_tool_start`, `on_tool_result`, `confirm`, `ontick`, ...) into the loop, which is
why the same loop drives the tui, the headless runner and the subagents.

## The session log

The session is the single source of truth. Every fact the model may see is an event:

```
user       {text}
assistant  {text, reasoning, toolcalls, model}
tool       {id, name, arguments, output, iserror, duration, display}
notice     {text, level}                  -- local only, never sent to the model
compact    {summary}                      -- the compaction boundary
```

`session:messages()` projects the model history from the log, starting at the last
`compact` event, and `context/window.optimize()` shrinks that projection without
touching the log. The transcript, the resume, the export and the token statistics
are all derived from the same log, so nothing can drift apart.

The sessions are stored per project directory
(`~/.xmake/harness/projects/<slug>/<id>.json`), @see [sessions and context](context.md).

## The seams

A seam is a capability with a stable interface and a swappable implementation:

| seam | interface | implementations |
| --- | --- | --- |
| `llm/llm` | `buildrequest`/`parsechunk`/`parseresponse` | `providers/openai`, `providers/anthropic`, yours |
| `llm/transport` | `post(opt, handlers)` | curl subprocess streaming |
| `fs/fs` | resolve/read/write/walk + the workspace boundary | local filesystem |
| `shell/exec` | `run(context, opt)` | local subprocess with the timeout and the abort |
| `sandbox/sandbox` | `wrap(context, program, argv)` | `none`, `seatbelt` (macos), `bwrap` (linux) |
| `permission/policy` | `check(config, tool, args, opt)` | the modes and the allow/deny rules |
| `hooks/hooks` | `run(config, event, context)` | the user command hooks |
| `ui/terminal` | raw mode, key decoding | select + the peek of the c library |
| `mcp/client` | `tools()`, `calltool()` | one mcp server over its stdio |

Swapping one implementation changes the whole product: pointing `shell/exec` and
`fs/fs` at a container would move every tool with them.

## Why no third-party dependency

The whole harness runs inside the xmake lua runtime, which has no `pcall`, no
`setmetatable` and no socket tls. The consequences are visible in the code and are
deliberate:

- the classes use `core.base.object` instead of the metatables
- the error handling uses `try{}`/`utils.trycall` instead of `pcall`
- the llm transport drives `curl` as a subprocess and reads its stdout through a pipe
- the terminal input is relayed through a pipe on posix, because the stdio buffer
  hides the pending bytes from `select()`
- the token counting is a heuristic estimator, not a bpe tokenizer
- the syntax highlighting and the markdown rendering are small hand written
  tokenizers, both line based so the streaming output can be rendered as it arrives

## The fan-out

Everything which runs several things at once — the tool calls of one step, the
nodes of one agent graph — goes through `util/parallel`, on the xmake coroutine
scheduler. It takes a list of jobs, a concurrency cap and the abort signal.

The coroutine group it opens is named after the coroutine which opens it, never
a constant. A subagent runs its own tools while its parent waits for it, so this
code is inside itself two or three levels deep, and a shared group name makes the
inner `co_group_begin` fail with *already exists* — which the sandbox raises, so
the turn would die the moment two subagents reached for their tools at the same
moment. A coroutine is blocked while waiting for its own group, so it can only
have one open, which is what makes its identity a sufficient name.
