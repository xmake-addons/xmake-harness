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

-- how much of a skill description goes into the listing, @see _trigger
local SKILL_TRIGGER = 120

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

    -- how the code is written, which a subagent needs as much as we do: it is a
    -- fact about the codebase and not about whose turn it is to edit it
    table.insert(sections, {name = "codestyle", content = _codestyle(config)})

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

- ]] .. (language and string.format("The user writes in %s: answer in %s. That is what\n"
        .. "  you say, not what you write into the files: the code, the comments, the\n"
        .. "  identifiers and the commit messages are in English, @see the section on\n"
        .. "  writing the code.", language, language)
        or "Answer in the language the user writes in.") .. "\n" .. [[
- Keep the answers short: the user reads them in a terminal. Skip the preambles
  like "Great question!" and the summaries of what you are about to do.
- Do not repeat the whole file content back to the user, they can see the diffs.
- Use the markdown sparingly: the short lists and the inline code are fine, the
  huge headings are not.
- When you report what you did, state the facts: what changed, what you ran, what
  the result was. If something failed, say so with the real output.
- Say where something is with `path:line`, e.g. `src/main.cpp:42`, whenever your
  answer rests on a particular place in the code. Cite only what you have read in
  this session: the terminal checks every reference against the file, and one
  which points at nothing is worse than no reference at all.]]
end

-- the workflow section
function _workflow()
    return [[# Working on a task

- Understand before changing: read the relevant files, search the codebase.
- Read the file you are about to change before changing it, and write in the
  style it is already written in, @see the section below.
- Never introduce a new dependency without checking that the project already
  uses it.
- Make the smallest change which does the job, then verify it: build it, run the
  tests, or run the command the user cares about.
- Use `todo_write` to track the multi-step work, and keep exactly one task
  `in_progress` at a time.
- Do what was asked, nothing more. Do not create the extra documentation files
  unless the user asked for them.]]
end

-- the code style section
--
-- a model has a house style of its own — braces on the next line or not,
-- comments in the language of the conversation, a docstring on every function —
-- and it applies it to whatever it touches unless it is told not to. in a
-- codebase which has its own style that is not a preference, it is damage: the
-- diff of a one-line change carries a formatting argument with it
--
function _codestyle(config)
    local house = (config or {}).code or {}
    local comments = house.comments or "English"
    local braces = house.braces == "newline"
        and "the opening brace on a line of its own"
        or "the opening brace on the same line as what it opens"
    return [[# Writing the code

- The file you are editing decides the style, not you: the naming, the brace
  placement, the indentation, the quoting, the spacing, the width of a line.
  Match what is already there even where you would have written it differently.
- A new file follows the files next to it. Read one first — the closest sibling
  in the same directory — and write the new one the way it is written.
- ]] .. string.format("When there is nothing to match at all — the first file of a new project —\n"
        .. "  write %s:\n"
        .. "  `int main(void) {`, and not `int main(void)` with `{` alone on the next line.\n"
        .. "  This is the fallback and not a rule: any file you can see overrules it.", braces) .. "\n" .. [[
- ]] .. string.format("Every comment you write is in %s, including in a conversation held in\n"
        .. "  another language. You answer the user in theirs; the file is read by everybody.\n"
        .. "  A comment in the wrong language is a change the user has to undo by hand.", comments) .. "\n" .. [[
  The one exception is a project which already comments in another language, and
  you judge that from the files which were there before this conversation, never
  from the ones you wrote during it — comments you wrote an hour ago are not a
  convention.
- Comment as densely as the surrounding file does, and no more. Do not add a
  comment which restates the code, do not annotate a change with what it used to
  be, and do not leave notes to the user in the source — say those in the answer.
- Do not reformat, reorder or "tidy" the code you did not come to change, and do
  not fix an unrelated problem you noticed on the way — mention it instead.]]
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
        "them matches what you are about to do, load it with `use_skill` first and follow",
        "it. What is listed here is the trigger only, shortened: the skill itself says",
        "what it covers, and one which sounds close enough is worth opening.", ""}
    for _, skill in ipairs(skills) do
        table.insert(lines, string.format("- `%s`: %s", skill.name, _trigger(skill.description)))
    end
    return table.concat(lines, "\n")
end

-- the part of a skill description which says when to reach for it
--
-- a description is written for the skill's own page and says both when to use it
-- and what it covers — and the second half is of no use until it is open. with
-- fifty skills installed the full text is three quarters of the system prompt,
-- and it is sent again every turn, so what goes in the listing is the trigger:
-- the first clause, capped, with the "Use when" every one of them opens with
-- taken off
--
function _trigger(description, cap)
    cap = cap or SKILL_TRIGGER
    local text = (description or ""):trim()
    text = text:gsub("^[Uu]se when ", ""):gsub("^[Uu]se ", "")

    local cut = #text + 1
    for _, pattern in ipairs({"%.%s", "%s—%s", "%s–%s", "%s%-%s", ":%s"}) do
        local at = text:find(pattern)
        -- not the dot of an abbreviation: "built-in rules (e.g. `mode.debug`)"
        -- would otherwise be listed as "built-in rules (e.g"
        while at and text:sub(at - 2, at - 2) == "." do
            at = text:find(pattern, at + 1)
        end
        if at and at < cut then
            cut = at
        end
    end

    local head = text:sub(1, cut - 1)
    if #head > cap then
        head = head:sub(1, cap)
        local space = head:match("^.*()%s")
        if space and space > cap * 0.6 then
            head = head:sub(1, space - 1)
        end
        head = head .. "…"
    end
    return head
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
    -- an untrusted project does not get to write the system prompt
    if harness:config()._trusted == false then
        return nil
    end
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
