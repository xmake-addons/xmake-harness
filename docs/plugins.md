# Plugins

Everything above the context is a plugin, including the xmake support. A plugin is a
single `plugin.lua` exporting `define()` and `apply(harness, definition)`.

## Discovery

```
<addon>/modules/harness/plugins/<name>/plugin.lua    the builtin ones
~/.xmake/harness/plugins/<name>/plugin.lua           the user ones
<project>/.xmake-harness/plugins/<name>/plugin.lua   the project ones
plugins.dirs in the config                           the extra ones
```

The first plugin with a given name wins, and `plugins.disabled` skips one entirely.

## The api

```lua
function define()
    return {name = "mybuild", description = "the mybuild enhancement"}
end

function apply(harness, definition)

    -- the tools, @see docs/tools.md
    harness:service("tools"):add({...})

    -- the assets which ship with the plugin
    harness:service("skills"):adddir(path.join(definition.dir, "skills"), "plugin:mybuild")
    harness:service("agents"):adddir(path.join(definition.dir, "agents"), "plugin:mybuild")

    -- a slash command
    harness:service("commands"):add({
        name = "mybuild",
        description = "..",
        run = function (app, args)
            return {kind = "message", text = ".."}   -- message | prompt | exit | clear | none
        end
    })

    -- the system prompt
    harness:on("prompt/environment", function (lines, opt)
        table.insert(lines, "mybuild project: yes")
        return lines
    end, {owner = "mybuild"})

    harness:on("prompt/sections", function (sections, opt)
        table.insert(sections, {name = "mybuild", content = ".."})
        return sections
    end, {owner = "mybuild"})

    -- intercept the tool calls
    harness:on("tools/pre-execute", function (request)
        if request.tool.name == "run_command" and request.args.command:find("rm -rf /") then
            request.denied = "this command is not allowed by the mybuild plugin"
        end
        return request
    end, {owner = "mybuild"})
end
```

A plugin should stay inert when it does not apply: the cmake plugin returns
immediately when there is no `CMakeLists.txt`, so a non-cmake project never sees its
tools.

## Adding an llm provider

Drop a module into `harness/llm/providers/<kind>.lua` exporting `buildrequest`,
`parsechunk`, `parseresponse`, `normalizeusage` and `parseerror`, then point a
provider at it:

```json
{"providers": {"myllm": {"kind": "myllm", "baseurl": "..", "models": {"main": ".."}}}}
```

`kind` is resolved dynamically, so no core file changes.

## The hooks

The users can attach the external commands without writing any lua:

```json
{
    "hooks": {
        "pretooluse":  [{"matcher": "write_file|edit_file", "command": "xmake format $FILE"}],
        "posttooluse": [{"matcher": "run_command", "command": "echo done"}]
    }
}
```

A `pretooluse` hook which exits with the code `2` blocks the tool call, and its
stderr is returned to the model as the reason.
