---
name: harness-extending
description: Use when extending the xmake-harness itself - writing a harness plugin, adding a tool, a skill, a subagent, a slash command, an llm provider or a permission rule.
---

# Extending the harness

Everything above the context is a plugin. A plugin is one lua file which exports
`define()` and `apply(harness, definition)`, and it is discovered from:

```
<addon>/modules/harness/plugins/<name>/plugin.lua   the builtin ones
~/.xmake/harness/plugins/<name>/plugin.lua          the user ones
<project>/.xmake-harness/plugins/<name>/plugin.lua  the project ones
```

```lua
function define()
    return {name = "mybuild", description = "the mybuild enhancement"}
end

function apply(harness, definition)
    harness:service("tools"):add({ ... })
    harness:service("skills"):adddir(path.join(definition.dir, "skills"), "plugin:mybuild")
    harness:service("agents"):adddir(path.join(definition.dir, "agents"), "plugin:mybuild")
    harness:service("commands"):add({name = "mybuild", description = "..", run = function (app, args) end})
    harness:on("prompt/sections", function (sections, opt) return sections end, {owner = "mybuild"})
end
```

## Adding a tool

```lua
harness:service("tools"):add({
    name = "mybuild_build",             -- what the model calls
    group = "mybuild",
    permission = "exec",                -- none | read | write | exec | network
    description = "Build the project ..",
    parameters = {                      -- the json schema of the arguments
        type = "object",
        properties = {target = {type = "string", description = ".."}},
        required = {}
    },
    run = function (context, args)      -- context: {harness, config, cwd, session, ui, signal, mode}
        local exec = import("harness.shell.exec", {anonymous = true})
        local result = exec.run(context, {program = "mybuild", argv = {"build"}})
        return {
            output = result.output,                       -- what the model sees
            iserror = result.exitcode ~= 0,
            display = {title = "Build", subject = args.target, summary = "ok",
                       kind = "output", output = result.output}   -- what the tui shows
        }
    end
})
```

The `display.kind` drives the tui rendering: `output` prints the first lines,
`diff` renders a colored diff (`display.diff` from `harness.ui.diff`), `todos`
renders the task list.

Never spawn a process directly: `harness.shell.exec` applies the sandbox, the
timeout and the abort signal.

## Adding a skill

A skill is a directory with a `SKILL.md`, the same format as the claude code
skills, so an existing skill repository works as is:

```
skills/mybuild-packages/SKILL.md
---
name: mybuild-packages
description: Use when adding a dependency to a mybuild project.
---
# ..the instructions..
```

Only the name and the description reach the system prompt, the body is loaded by
the `use_skill` tool on demand, so a large library costs almost no context.

## Adding a subagent

An agent is a markdown file with the frontmatter (`name`, `description`, `tools`,
`model`), the body is its system prompt. It runs in its own context window and
only its final message returns to the caller.

## Adding an llm provider

Drop a module into `harness/llm/providers/<kind>.lua` which exports
`buildrequest(provider, req)`, `parsechunk(state, obj)`, `parseresponse(obj)` and
`normalizeusage(usage)`, then point a provider at it from the config:

```json
{"providers": {"myllm": {"kind": "myllm", "baseurl": "..", "models": {"main": ".."}}}}
```

## The events

```
harness:on("tools/pre-execute",  function (request) ... end)   -- rewrite or reject a tool call
harness:on("tools/post-execute", function (result, info) ... end)
harness:on("agent/request",      function (req, info) ... end) -- rewrite the llm request
harness:on("prompt/sections",    function (sections, opt) ... end)
harness:on("prompt/environment", function (lines, opt) ... end)
harness:on("turn/start" / "turn/end" / "todos/changed" / "skill/loaded", ..)
```

A `tools/pre-execute` listener returns `request.denied = "reason"` to reject a
call, which is how a policy plugin blocks the dangerous commands.
