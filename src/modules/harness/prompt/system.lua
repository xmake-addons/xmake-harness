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
-- @file        system.lua
--

--
-- the system prompt assembly
--
-- the prompt is built from the named sections, and the plugins can add, rewrite
-- or drop any section through the `prompt/sections` waterfall event, e.g. the
-- xmake plugin appends the build environment of the current project.
--

-- imports
import("harness.util.util")
import("harness.util.language")
import("harness.permission.policy")

-- the context files which are loaded as the project instructions
local CONTEXT_FILES = {"XMAKE.md", "AGENTS.md", "CLAUDE.md", ".xmake-harness/HARNESS.md"}

-- build the system prompt
--
-- @param harness   the harness context
-- @param opt       the options, e.g. {agent = <definition>, mode = "default", tools = <registry>}
--
function build(harness, opt)
    opt = opt or {}
    local config = harness:config()
    local sections = {}

    -- the identity, a subagent brings its own one
    if opt.agent and opt.agent.prompt and opt.agent.prompt ~= "" then
        table.insert(sections, {name = "identity", content = opt.agent.prompt})
    else
        table.insert(sections, {name = "identity", content = _identity(config)})
        table.insert(sections, {name = "style", content = _style({language = _language(opt)})})
        table.insert(sections, {name = "workflow", content = _workflow()})
    end

    -- the tool policy
    table.insert(sections, {name = "tools", content = _tools(harness, opt)})

    -- the skills
    local skills = _skills(harness)
    if skills then
        table.insert(sections, {name = "skills", content = skills})
    end

    -- the subagents
    if not opt.agent then
        local agents = _agents(harness)
        if agents then
            table.insert(sections, {name = "agents", content = agents})
        end
    end

    -- the environment
    table.insert(sections, {name = "environment", content = _environment(harness, opt)})

    -- the project instructions
    local instructions = _instructions(harness)
    if instructions then
        table.insert(sections, {name = "instructions", content = instructions})
    end

    -- the todos
    local todos = harness:service("todos")
    if todos and #todos > 0 and not opt.agent then
        table.insert(sections, {name = "todos", content = _todos(todos)})
    end

    -- let the plugins rewrite the sections
    sections = harness:waterfall("prompt/sections", sections, opt)

    local results = {}
    for _, section in ipairs(sections) do
        if section.content and section.content ~= "" then
            table.insert(results, section.content)
        end
    end
    return table.concat(results, "\n\n")
end

-- get the language the user writes in
function _language(opt)
    if not opt.session then
        return nil
    end
    local name, label = language.ofsession(opt.session)
    if name == "en" then
        return nil
    end
    return label
end

-- the identity section
function _identity(config)
    local name = config.identity or "xmake ai"
    return string.format([[You are %s, an interactive CLI agent which helps the user with software engineering tasks.

You work directly in the user's terminal, inside their project. You can read and
change the files, run the commands, and explain what you did. You are precise,
honest and efficient: you never claim that something works until you verified it.]], name)
end

-- the style section
--
-- @param opt   the options, e.g. {language = "Chinese"}
--
function _style(opt)
    local language = opt and opt.language or nil
    return [[# Style

- ]] .. (language and string.format("The user writes in %s: answer in %s, and keep the\n"
        .. "  code, the paths and the identifiers as they are.", language, language)
        or "Answer in the language the user writes in.") .. [[
- Keep the answers short: the user reads them in a terminal. Skip the preambles
  like "Great question!" and the summaries of what you are about to do.
- Do not repeat the whole file content back to the user, they can see the diffs.
- Use the markdown sparingly: the short lists and the inline code are fine, the
  huge headings are not.
- When you report what you did, state the facts: what changed, what you ran, what
  the result was. If something failed, say so with the real output.]]
end

-- the workflow section
function _workflow()
    return [[# Working on a task

- Understand before changing: read the relevant files, search the codebase.
- Follow the conventions of the surrounding code: the naming, the comments, the
  structure. Never introduce a new dependency without checking that the project
  already uses it.
- Make the smallest change which does the job, then verify it: build it, run the
  tests, or run the command the user cares about.
- Use `todo_write` to track the multi-step work, and keep exactly one task
  `in_progress` at a time.
- Do what was asked, nothing more. Do not create the extra documentation files
  unless the user asked for them.]]
end

-- the tool policy section
function _tools(harness, opt)
    local mode = opt.mode or "default"
    local lines = {"# Tools", "",
        "- Prefer `read_file`, `glob_files` and `search_text` over the shell equivalents.",
        "- Ask for the independent tool calls in the same turn: the read-only ones and the",
        "  subagents run at the same time, so five of them cost about as much as one.",
        "- Never guess a file path, look it up first.", "",
        "In a big project, do not read whole files to find something:", "",
        "- `search_text` with `mode=files` tells you which files are involved,",
        "- `search_text` with `context=2` shows the matches with their surroundings,",
        "- `read_file` with `offset`/`limit` reads only the part you need.",
        "",
        "A temporary script is written in lua and run with `xmake_lua`: the whole xmake",
        "script api is there (`os`, `io`, `path`, `import`), it behaves the same on windows,",
        "macos and linux, and it needs nothing installed. Reach for python, node or a shell",
        "script only when lua really cannot do it, and say why."}
    if mode == "plan" then
        table.insert(lines, "")
        table.insert(lines, "The plan mode is active: you may only read and search. Do not edit the files")
        table.insert(lines, "and do not run the commands which change anything. Present the plan to the user")
        table.insert(lines, "and wait for the approval.")
    elseif mode == "acceptedits" then
        table.insert(lines, "")
        table.insert(lines, "The user accepts the file edits automatically, but still confirms the commands.")
    end
    return table.concat(lines, "\n")
end

-- the skills section
function _skills(harness)
    local registry = harness:service("skills")
    if not registry then
        return nil
    end
    local skills = registry:enabled(harness:config())
    if #skills == 0 then
        return nil
    end
    local lines = {"# Skills", "",
        "These skills hold the detailed instructions of the specific tasks. When one of",
        "them matches what you are about to do, load it with `use_skill` first and follow it:", ""}
    for _, skill in ipairs(skills) do
        table.insert(lines, string.format("- `%s`: %s", skill.name, skill.description))
    end
    return table.concat(lines, "\n")
end

-- the agents section
function _agents(harness)
    local registry = harness:service("agents")
    if not registry then
        return nil
    end
    local agents = registry:enabled(harness:config())
    if #agents == 0 then
        return nil
    end
    local lines = {"# Subagents", "",
        "Delegate the wide searches and the long explorations to a subagent with `run_agent`:", ""}
    for _, agent in ipairs(agents) do
        table.insert(lines, string.format("- `%s`: %s", agent.name, agent.description))
    end
    return table.concat(lines, "\n")
end

-- the environment section
function _environment(harness, opt)
    local config = harness:config()
    local lines = {"# Environment", ""}
    table.insert(lines, string.format("- working directory: %s", harness:rootdir()))
    table.insert(lines, string.format("- platform: %s/%s", os.host(), os.arch()))
    table.insert(lines, string.format("- date: %s", os.date("%Y-%m-%d")))
    table.insert(lines, string.format("- permission mode: %s (%s)", opt.mode or "default", policy.modedesc(opt.mode or "default")))
    local extra = harness:waterfall("prompt/environment", {}, opt)
    for _, item in ipairs(extra) do
        table.insert(lines, "- " .. item)
    end
    return table.concat(lines, "\n")
end

-- the project instruction section
function _instructions(harness)
    local rootdir = harness:rootdir()
    local results = {}
    for _, name in ipairs(CONTEXT_FILES) do
        local filepath = path.join(rootdir, name)
        if os.isfile(filepath) then
            local content = io.readfile(filepath) or ""
            if #content > 32768 then
                content = content:sub(1, 32768) .. "\n[truncated]"
            end
            table.insert(results, string.format("## %s\n\n%s", name, content:trim()))
        end
    end
    if #results == 0 then
        return nil
    end
    return "# Project instructions\n\nThese files come from the project, follow them:\n\n" .. table.concat(results, "\n\n")
end

-- the todos section
function _todos(todos)
    local lines = {"# Current task list", ""}
    for _, todo in ipairs(todos) do
        table.insert(lines, string.format("- [%s] %s", todo.status, todo.content))
    end
    return table.concat(lines, "\n")
end
