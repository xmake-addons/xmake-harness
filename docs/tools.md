# Tools

English | [中文](tools.zh.md)

## The builtin tools

| tool | permission | what it does |
| --- | --- | --- |
| `read_file` | read | read a file with the line numbers, with `offset`/`limit` |
| `write_file` | write | write a whole file, shows a diff |
| `edit_file` | write | replace an exact string, shows a diff |
| `list_dir` | read | list a directory |
| `glob_files` | read | find the files by a glob, newest first |
| `search_text` | read | search the contents: `content`, `files` or `count` mode, with context lines |
| `run_command` | exec | run a shell command with a timeout, or start it in the background |
| `job_output` | read | read what a background job printed since the last read |
| `job_list` | read | which background jobs there are and how they stand |
| `job_kill` | exec | stop a background job |
| `todo_write` | none | maintain the task list |
| `use_skill` | read | load a skill by name |
| `run_agent` | read | delegate a task to a subagent |
| `run_agents` | read | delegate a whole graph of subagents at once |
| `fetch_url` | network | fetch a page and strip the html |

`search_text` is driven by `ripgrep` when the machine has it and by our own
walker otherwise, and both produce the same results — so a big project stays
cheap to explore without reading whole files.

The xmake plugin adds `xmake_create`, `xmake_config`, `xmake_build`, `xmake_run`,
`xmake_test`, `xmake_show`, `xmake_lua`, `xrepo`, `xmake_docs` and the three
conversion tools `xmake_import`, `xmake_import_write` and `xmake_import_verify`
(@see [the xmake enhancement](xmake.md)); the cmake plugin adds
`cmake_configure`, `cmake_build` and `ctest`.

## The background jobs

A tool call which blocks holds the whole turn: nothing else runs, the model
waits, and you watch a spinner. That is the right trade for a command which takes
a second, and the wrong one for most of what a build system does — a link step of
twenty minutes, `xmake watch`, a server which is supposed to stay up.

So a command can be **started** instead of run:

```
run_command(command: "xmake build -r", background: true)   -> background job 1
job_output(job_id: "1")    what it has printed since you last looked
job_list()                 which jobs there are and how they stand
job_kill(job_id: "1")      stop one
```

`job_output` returns only the **delta** — what arrived since the previous read —
so following a long build costs one page at a time instead of the whole log
again. It never waits: a job which is still going returns whatever is there, and
every result ends with `[status: running for 2m03s]` or `[status: exited 0 after
5s]`. A read which would overflow keeps the **end** of the output, because that is
where the error is, and says how much it dropped.

A job which finishes while the model is busy elsewhere announces itself at the
top of the next step:

```
[harness] background job 1 finished: exited 0 after 5s
```

The notice goes into the conversation as well as onto your screen, so the model
knows to collect it — a result nobody is told about is a result nobody uses.

You see them too: the status line carries `2 jobs running`, and `/jobs` lists
them, with `/jobs kill <id>` to stop one. They belong to the session and all of
them are killed when it ends, so you are never left with a background process you
never started and cannot see.

The `timeout` of a foreground command does not apply to a job — a watch is
supposed to run until something stops it.

## The execution pipeline

Every call goes through `tools/pipeline.lua`:

```
decode the arguments
  -> tools/pre-execute      (waterfall, may rewrite the args or set request.denied)
  -> the pretooluse hooks   (a hook may block the call by exiting with 2)
  -> the permission policy  (allow / ask the user / deny)
  -> the sandbox wrapping   (for the tools which spawn a process)
  -> run
  -> truncate the output    (tools.maxoutput)
  -> tools/post-execute     (waterfall)
  -> the posttooluse hooks
```

A rejected call is not an error: the reason is returned to the model as the tool
result, so it can adapt instead of retrying blindly.

Whatever a tool prints is scrubbed before it reaches the model or the screen: the
escape sequences, the control characters, the zero-width characters and the
bidirectional overrides come off. That output is rarely ours — a compiler
message, a file we just read, somebody else's command — and it would otherwise
be a way to smuggle instructions in, or to make the screen say something other
than what the model was told.

## Running them together

The model usually asks for several things at once. Everything which cannot
change the world runs concurrently in the xmake scheduler: the read-only tools,
the subagents (`concurrent = true` in their definition), and anything the policy
already allows. The results are still reported in the original order, so the
session log stays deterministic.

A tool declares it explicitly when the default is wrong:

```lua
{name = "my_tool", permission = "read", concurrent = false, ..}
```

## Adding a tool

```lua
harness:service("tools"):add({
    name = "mybuild_build",
    group = "mybuild",
    permission = "exec",              -- none | read | write | exec | network
    description = [[Build the project ..]],
    parameters = {                    -- the json schema sent to the model
        type = "object",
        properties = {target = {type = "string", description = "The target."}},
        required = {}
    },
    preview = function (context, args) -- optional, shown in the permission dialog
        return {kind = "diff", filepath = "..", diff = ..}
    end,
    run = function (context, args)
        local exec = import("harness.shell.exec", {anonymous = true})
        local result = exec.run(context, {program = "mybuild", argv = {"build"}})
        return {
            output = result.output,               -- what the model sees
            iserror = result.exitcode ~= 0,
            display = {                           -- what the tui shows
                title = "Build",
                subject = args.target,
                summary = "ok",
                kind = "output",                  -- output | diff | todos
                output = result.output
            }
        }
    end
})
```

The `context` passed to `run` carries `harness`, `config`, `cwd`, `session`, `ui`,
`signal` (the abort flag), `mode` and `depth`.

Raising an error from `run` is fine: the message becomes the tool result and the
model sees it. Use it for the argument problems (`raise("%s does not exist", path)`).

A builtin tool is a module in `harness/tools/builtin/<name>.lua` exporting `define()`
and `run(context, args)`; the registry discovers them automatically.

## The guarantees a tool must respect

- resolve the paths through `harness.fs.fs` and never write outside the workspace
  (`fs.checkwritable`)
- spawn the processes through `harness.shell.exec`, never directly, so the sandbox,
  the timeout and the interrupt work
- keep the output useful for a model: the truncation notes must say what was cut
