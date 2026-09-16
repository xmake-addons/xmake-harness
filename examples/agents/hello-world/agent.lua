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
-- every hook an agent may export, in one file, doing the least it can
--
-- this is a reference and not a useful agent. each function below is the
-- smallest thing which is obviously that hook's job, so that the shape is
-- readable without the work getting in the way — copy the file, delete what you
-- do not need, and what is left is a real agent.
--
-- they run in this order, @see harness.agents.lifecycle:
--
--   define    -> tools -> prompt -> before
--                                     [ the agent runs ]
--   validate  -> after
--   cleanup                            (always, however it ended)
--
-- every one of them is optional, every one runs inside a `try`, and one which
-- raises is reported and then ignored: an agent which cannot be improved is
-- better than a harness which cannot run one. so a mistake in here costs you
-- the hook, not the agent.
--
-- `context` carries `{harness, agent, prompt, description, cwd, progress, depth}`.
--

-- imports
import("harness.core.progress")

-- what a project's sources look like, wherever it is from
--
-- the extensions and not the patterns, because the pattern which finds all of
-- them is `**.c` and not `**/*.c`: the latter wants at least one directory in
-- between, so it misses the `main.c` which is sitting in the root
local SOURCES = {".c", ".cc", ".cpp", ".h", ".hpp", ".lua", ".rs", ".go", ".py"}

--------------------------------------------------------------------------------
-- before it runs
--------------------------------------------------------------------------------

-- define: change what the agent *is*, when frontmatter cannot know it
--
-- frontmatter is written once and this runs every time, so anything which
-- depends on the directory, the config or the machine belongs here. return only
-- the fields you are changing; `name`, `dir` and `filepath` are not yours to
-- change, because they are what the agent was resolved by.
--
function define(context)
    -- a project with nothing to read needs one step to say so, not eight. the
    -- budget is a cost and there is no reason to grant it before it is needed
    if #_sources(context.cwd) == 0 then
        return {maxsteps = 2}
    end
end

-- tools: the list alone, handed the one it would otherwise have had
--
-- `define` can return `tools` too, and does when tools are one of several
-- things you are deciding. this is for the agent whose *only* computed thing is
-- the list: you are given what the frontmatter said, so you can add to it
-- without having to repeat it.
--
function tools(context, current)
    -- there is no point offering a directory listing where there is no
    -- directory worth listing, and every tool is in every request
    if not os.isdir(path.join(context.cwd or os.curdir(), "src")) then
        return current
    end
    return table.join(current, {"list_dir"})
end

-- prompt: text appended to the agent's own instructions
--
-- it joins `AGENT.md`, so write it as more of the same document. use it for
-- what is true of *this* run and could not be written into the markdown: the
-- platform, the language of the project, a house rule from the config.
--
function prompt(context)
    return string.format(
        "The greeting is written in plain English, on %s, with no exclamation marks.",
        os.host())
end

-- before: what it has already found out, appended to the task
--
-- this is the useful one. an agent whose first two steps are always the same
-- two steps should arrive with the answers instead: they cost nothing here, and
-- there they cost two round trips of a conversation which is already long.
--
-- it is also where a slow thing says it is slow — `progress.stage` reaches
-- whatever is watching, the terminal's status line and the web ui alike.
--
function before(context)
    local rootdir = context.cwd or os.curdir()
    progress.stage(context.progress, "counting the sources")

    local sources = _sources(rootdir)
    local name = path.filename(rootdir)

    -- something for `cleanup` to take away again, so that the pair is visible.
    -- a real one would be a checkout, a temporary directory, a spawned server
    _scratch(context, string.format("%s: %d sources\n", name, #sources))
    progress.stage(context.progress, "counting the sources", "done")

    if #sources == 0 then
        return string.format(
            "The directory is `%s` and there is nothing in it which looks like source "
            .. "code. Say that, and do not go looking.", name)
    end
    return string.format(
        "I counted them for you, so do not go looking:\n\n"
        .. "- the project is **%s**\n- it has %d source file%s\n- the first of them is `%s`\n\n"
        .. "Read that one and greet the project.",
        name, #sources, #sources == 1 and "" or "s",
        path.relative(sources[1], rootdir))
end

--------------------------------------------------------------------------------
-- and after
--------------------------------------------------------------------------------

-- validate: is the report good enough, according to the agent which wrote it?
--
-- return nil when it will do, and the reason when it will not. the reason goes
-- back as part of the task and the agent answers again — **once**, because a
-- second answer you also refuse is an agent arguing with itself at full price.
--
-- the model is a poor judge of whether it answered the question. a script is a
-- good one whenever the answer has a shape it can check: json which has to
-- parse, a number which has to be a number, a name which has to be named.
--
function validate(context, result)
    local said = tostring(result and result.text or "")
    local name = path.filename(context.cwd or os.curdir())
    if not said:lower():find(name:lower(), 1, true) then
        return string.format("it never says the project's name, which is `%s`", name)
    end
end

-- after: the last word on the report
--
-- what you return is appended to what the agent said. it is for the fact which
-- belongs in the report and which the agent has no way of knowing: what it
-- cost, where the artifact went, which revision it was looking at.
--
function after(context, result)
    return string.format("_(greeted in %d step%s)_",
                         result.steps or 0, (result.steps or 0) == 1 and "" or "s")
end

-- cleanup: whatever the run set up, taken down again
--
-- it runs whether the agent finished, failed or was interrupted, so a `before`
-- which made a temporary directory can rely on it. it is the only hook which is
-- not about the answer.
--
function cleanup(context)
    local scratch = _scratchfile(context)
    if scratch and os.isfile(scratch) then
        os.tryrm(scratch)
    end
end

--------------------------------------------------------------------------------
-- the private half, which is just lua
--------------------------------------------------------------------------------

-- the source files of a project, or none
function _sources(rootdir)
    rootdir = rootdir or os.curdir()
    local found = {}
    for _, extension in ipairs(SOURCES) do
        for _, filepath in ipairs(os.files(path.join(rootdir, "**" .. extension))) do
            table.insert(found, filepath)
            if #found >= 4096 then
                return found
            end
        end
    end
    table.sort(found)
    return found
end

-- where this run keeps its scratch file
--
-- named after the agent and the directory, so two runs at once do not take each
-- other's away. `context` is a fresh table per run and is the natural place to
-- hang anything a later hook needs
--
function _scratchfile(context)
    return context._scratch
end

function _scratch(context, content)
    local filepath = os.tmpfile() .. ".hello-world"
    context._scratch = filepath
    try { function () io.writefile(filepath, content) end }
    return filepath
end
