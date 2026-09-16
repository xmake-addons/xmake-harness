--!A generic AI agent harness framework based on xmake lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      ruki
-- @file        agent.lua
--

--
-- `xmake ai agent ...` — one subagent, on its own
--
-- a subagent is normally something the model decides to use, which is a poor
-- way to find out whether the one you just wrote works: you ask for something
-- you hope will make it delegate, it delegates to a different one, and you
-- learn nothing. so it can be run directly, by name, with the task spelled out.
--
-- what it prints is what the caller would have received — the report, and
-- nothing else. the twenty steps behind it stay where they belong.
--
-- this module is imported only when the first word is `agent`, @see
-- harness.cli.ai: nothing here is loaded by a run which is not about agents.
--

-- imports
import("harness.util.util")
import("harness.util.text")
import("harness.ui.theme")
import("harness.cli.setup")
import("harness.agents.script")
import("harness.core.subagent")
import("harness.agents.registry", {alias = "agentregistry"})
import("harness.core.progress")
import("harness.config.config", {alias = "harnessconfig"})

-- the verbs, and what each of them takes
--
-- a table and not a chain of `elseif`, so that adding one is adding a row and
-- `xmake ai agent` can print them without a second list to keep in step
local VERBS = {
    {name = "list", usage = "xmake ai agent list",
     about = "the subagents this project can use"},
    {name = "show", usage = "xmake ai agent show <name|path>",
     about = "one of them: its tools, its model, its hooks, its instructions"},
    {name = "run",  usage = "xmake ai agent run <name|path> <task>",
     about = "run one directly and print its report"}
}

-- is this word one of ours?
function isverb(word)
    for _, verb in ipairs(VERBS) do
        if verb.name == word then
            return true
        end
    end
    return false
end

-- run `xmake ai agent <verb> ...`
--
-- @param context   a function which brings the harness up, called only by the
--                  verbs which need one
-- @param args      the words after `agent`
--
function run(context, args, options)
    local verb = args[1]
    if verb == "list" then
        return _list(context())
    elseif verb == "show" then
        return _show(context(), args[2])
    elseif verb == "run" then
        return _run(context(), args[2], table.concat(table.slice(args, 3), " "), options)
    end
    return usage()
end

-- what there is to do
--
-- @param mistaken   the word which was typed where a verb goes, if there was one
--
function usage(mistaken)
    cprint("")
    if mistaken then
        cprint("${color.error}`%s` is not one of the things `agent` does.${clear}", mistaken)

        -- and it may not have been meant as one at all: a sentence which
        -- happens to start with this word is a question, and there has to be a
        -- way to ask it which does not begin by arguing about grammar
        cprint("${dim}(to ask it as a question instead: xmake ai --print '<the question>')${clear}")
        cprint("")
    end
    cprint("${bright}xmake ai agent${clear} — run one subagent on its own")
    cprint("")
    for _, verb in ipairs(VERBS) do
        cprint("  ${bright}%-40s${clear} %s", verb.usage, verb.about)
    end
    cprint("")
    cprint("  ${dim}e.g. xmake ai agent run explorer 'where is the http server started'${clear}")
    cprint("")
    cprint("  ${dim}a path works where a name does, so one you are writing can be tried${clear}")
    cprint("  ${dim}without installing it first:${clear}")
    cprint("  ${dim}    xmake ai agent run ./examples/agents/hello-world 'greet this project'${clear}")
    cprint("")

    -- the word was a name, or a path to one: say the command they meant rather
    -- than making them read the list above and work it out
    if mistaken and (_ispath(mistaken) or _named(mistaken)) then
        cprint("  ${bright}did you mean:${clear}")
        cprint("      xmake ai agent run %s '<what it should do>'", mistaken)
        cprint("      xmake ai agent show %s", mistaken)
        cprint("")
    end
end

-- is there an agent of that name, without bringing the harness up to find out?
--
-- the usage is printed before anything is loaded, and loading the whole harness
-- to improve an error message would be paying for the mistake twice. the
-- directories are the ones agents live in and reading their names is a listing
--
function _named(name)
    for _, dir in ipairs({path.join(os.scriptdir(), "..", "assets", "agents"),
                          path.join(harnessconfig.homedir(), "agents")}) do
        if os.isfile(path.join(dir, name .. ".md"))
            or os.isfile(path.join(dir, name, "AGENT.md")) then
            return true
        end
        for _, filepath in ipairs(os.files(path.join(dir, "*", name, "AGENT.md"))) do
            return true
        end
    end
    return false
end

-- the agents there are
function _list(harness)
    local registry = harness:service("agents")
    local agents = registry and registry:all() or {}
    if #agents == 0 then
        cprint("${dim}no subagents. `/agents install <pack>` brings some.${clear}")
        return true
    end
    cprint("")
    for _, agent in ipairs(agents) do
        cprint("  ${bright}%-22s${clear} ${dim}%s${clear}%s", agent.name, agent.source or "user",
               script.has(agent) and "  ${color.warning}+script${clear}" or "")
        cprint("    %s", text.truncate(agent.description or "", 96))
    end
    cprint("")
    cprint("  ${dim}%d agent%s · `xmake ai agent show <name>` for one of them${clear}",
           #agents, #agents == 1 and "" or "s")
    cprint("")
    return true
end

-- resolve a name, or a path to one which is not installed
--
-- the loop for writing an agent is write, run, read, change, and installing it
-- between every two of those is three commands where there should be one. so a
-- path is a name too: the bundle directory, or the markdown file itself.
--
-- it is registered into a registry of its own and not the harness's, because it
-- is being tried and not adopted: nothing about this run changes what the next
-- one can see
--
-- @return  the definition, or nil and why not
--
function _resolve(harness, name)
    if not _ispath(name) then
        return subagent.resolve(harness, name)
    end

    local filepath = path.absolute(name)
    if os.isdir(filepath) then
        filepath = path.join(filepath, "AGENT.md")
    end
    if not os.isfile(filepath) then
        return nil, string.format("there is no agent at `%s`: a directory with an "
            .. "`AGENT.md` in it, or the markdown file itself", name)
    end

    local registry = agentregistry.new()
    registry:addfile(filepath, "path")
    for _, agent in ipairs(registry:all()) do
        return agent
    end
    for _, broken in ipairs(registry:broken()) do
        return nil, string.format("`%s` cannot be used: %s", name, broken.why)
    end
    return nil, string.format("`%s` is not an agent", name)
end

-- is that a path rather than a name?
--
-- a name is a word: `explorer`, `xmake-porter`. anything with a separator in it
-- or ending in `.md` was meant as a place, and saying "there is no agent called
-- ./hello-world" to somebody who pointed at a directory helps nobody
--
function _ispath(name)
    if type(name) ~= "string" then
        return false
    end
    return name:find("[/\\]") ~= nil or name:endswith(".md")
        or name == "." or name == ".."
end

-- one of them, as it was loaded
function _show(harness, name)
    if not name then
        cprint("${color.error}say which one${clear}, e.g. `xmake ai agent show explorer`")
        return true
    end
    local definition, errors = _resolve(harness, name)
    if not definition then
        cprint("${color.error}%s${clear}", errors)
        return true
    end

    cprint("")
    cprint("${bright}%s${clear}  ${dim}(%s)${clear}", definition.name, definition.source or "user")
    cprint("  %s", definition.description or "")
    cprint("")
    _field("file", definition.filepath)
    _field("tools", #(definition.tools or {}) > 0
        and table.concat(definition.tools, ", ") or "everything the main agent has")
    _field("model", definition.model or "the main one")
    _field("maxsteps", tostring(definition.maxsteps or "the default"))

    -- the hooks it takes part in, which is the thing you actually want to know
    -- about an agent you have just written a script for
    local hooks = _hooks(definition)
    _field("script", #hooks > 0 and table.concat(hooks, ", ")
        or (script.has(definition) and "an agent.lua which exports nothing" or "none"))
    cprint("")
    cprint("${dim}--- the instructions ---${clear}")
    print(definition.prompt or "")
    return true
end

-- which hooks its `agent.lua` actually exports
function _hooks(definition)
    local module = script.load(definition)
    if not module then
        return {}
    end
    local found = {}
    for _, name in ipairs({"define", "tools", "prompt", "before",
                           "validate", "after", "cleanup"}) do
        if type(module[name]) == "function" then
            table.insert(found, name)
        end
    end
    return found
end

-- one of them, run
function _run(harness, name, task, options)
    if not name then
        cprint("${color.error}say which one${clear}, e.g. `xmake ai agent run explorer 'find the parser'`")
        return true
    end
    if task == "" then
        cprint("${color.error}say what to do${clear}, e.g. `xmake ai agent run %s 'find the parser'`", name)
        return true
    end
    local definition, errors = _resolve(harness, name)
    if not definition then
        cprint("${color.error}%s${clear}", errors)
        return true
    end
    if not setup.ensurekey(harness, {interactive = io.isatty()}) then
        return true
    end

    cprint("${dim}%s: %s${clear}", definition.name, task)
    local started = os.mclock()
    local result = subagent.spawn({
        harness = harness,
        config = harness:config(),
        cwd = harness:rootdir(),
        mode = options and options.mode or "default",
        depth = 0,
        signal = {aborted = false},
        ui = _ui(definition)
    }, {agent = definition, prompt = task, description = task})

    cprint("")
    print(result.text or "")
    cprint("")
    if result.errors then
        cprint("${color.error}%s${clear}", tostring(result.errors))
    end
    cprint("${dim}%d step%s · %s tokens · %s${clear}",
        result.steps or 0, (result.steps or 0) == 1 and "" or "s",
        util.count(subagent.tokensof(result)), util.duration(os.mclock() - started))
    return true
end

-- what it says for itself while it works
--
-- one line, rewritten in place, and nothing when this is a pipe: the report is
-- what somebody redirecting the output asked for, and progress on top of it is
-- something they have to filter back out
--
function _ui(definition)
    local handlers = {}
    if not io.isatty() then
        return handlers
    end

    local channel = progress.new({label = definition.name})
    handlers.subagent = function ()
        local nested = progress.handlers(channel, {})
        nested.progress = channel
        return nested
    end
    handlers.on_step_start = function (step)
        io.write(string.format("\r\027[K  %s… (step %d)",
                               definition.name, (step or {}).step or 0))
        io.flush()
    end
    handlers.on_tool_start = function (call)
        io.write(string.format("\r\027[K  %s… (%s)", definition.name, call.name or ""))
        io.flush()
    end
    handlers.on_notice = function (message)
        io.write("\r\027[K")
        cprint("  ${dim}%s${clear}", tostring(message))
    end
    handlers.on_error = function (errs)
        io.write("\r\027[K")
        cprint("  ${color.error}%s${clear}", tostring(errs))
    end
    return handlers
end

-- one aligned line of a listing
function _field(name, value)
    if value and value ~= "" then
        cprint("  ${dim}%-10s${clear} %s", name, tostring(value))
    end
end
