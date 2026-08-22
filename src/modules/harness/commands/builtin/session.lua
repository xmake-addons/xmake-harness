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
-- @file        session.lua
--

--
-- the session commands: /clear, /sessions, /resume, /export, /exit
--

-- imports
import("harness.util.util")
import("harness.util.text")
import("harness.ui.theme")
import("harness.core.session", {alias = "sessions"})

-- the commands of this group
function commands()
    return {
        {name = "clear",    description = "Clear the conversation and start a new session",     run = _clear},
        {name = "sessions", description = "List the sessions of this project",                  run = _sessions},
        {name = "resume",   description = "Resume a session of this project, it asks which one", run = _resume},
        {name = "export",   description = "Export the current conversation to a markdown file", run = _export},
        {name = "exit",     description = "Exit the tui",                                       run = _exit},
        {name = "quit",     description = "Exit the tui",                                       run = _exit}
    }
end

-- /clear
--
-- it starts a new session, the previous one stays on the disk and can be resumed
--
function _clear(app)
    local previous = app.session:id()
    local session = app:newsession()
    return {kind = "clear", text = string.format(
        "a new session is started (%s)\nthe previous one is saved, resume it with `/resume %s`",
        session:id(), previous)}
end

-- /exit
function _exit()
    return {kind = "exit"}
end

-- /sessions [all|remove <id>]
function _sessions(app, args)
    local action, spec = (args or ""):match("^(%S+)%s*(.*)$")
    if action == "remove" or action == "rm" then
        local ok, errors = sessions.remove((spec or ""):trim(), app.harness:rootdir())
        return {kind = "message", iserror = not ok,
                text = ok and string.format("the session %s is removed", spec) or errors}
    end

    local all = (action == "all")
    local items = sessions.list({cwd = app.harness:rootdir(), all = all, limit = 20})
    if #items == 0 then
        return {kind = "message", text = all and "no session yet."
            or string.format("no session for %s yet.", app.harness:rootdir())}
    end

    local lines = {all and "the recent sessions of every project:"
        or string.format("the recent sessions of %s:", app.harness:rootdir()), ""}
    for _, meta in ipairs(items) do
        table.insert(lines, _sessionline(meta))
        if all and meta.cwd then
            table.insert(lines, theme.styled("dim", string.rep(" ", 40) .. util.shortpath(meta.cwd, "")))
        end
    end
    table.insert(lines, "")
    table.insert(lines, "resume one with `/resume <id>`, remove one with `/sessions remove <id>`")
    table.insert(lines, "`/sessions all` lists every project · `xmake ai -c` continues the last one")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- render one session of the list
function _sessionline(meta)
    return string.format("  %s  %s  %s  %s", meta.id,
        os.date("%m-%d %H:%M", meta.updatetime or 0),
        text.pad(string.format("%d msgs", meta.events or 0), 9),
        text.truncate(meta.title or "(no title)", 52))
end

-- /resume [id]
--
-- without an id it lets the user pick one of this project, exactly like
-- `xmake ai -r` does on the command line
--
function _resume(app, args)
    local id = (args or ""):trim()
    if id == "" then
        id = _pick(app)
        if not id then
            return {kind = "message", text = "cancelled."}
        end
    end
    local session, errors = sessions.load(id, app.harness:rootdir())
    if not session then
        return {kind = "message", text = tostring(errors), iserror = true}
    end
    app:setsession(session)
    return {kind = "resumed", text = string.format("the session %s is resumed (%d messages)",
        session:id(), #session:events())}
end

-- ask the user which session to resume
function _pick(app)
    local items = sessions.list({cwd = app.harness:rootdir(), limit = 12})
    if #items == 0 or not app.ask then
        return nil
    end
    local options = {}
    for _, meta in ipairs(items) do
        table.insert(options, {
            text = string.format("%s  %s  %s", os.date("%m-%d %H:%M", meta.updatetime or 0),
                text.pad(string.format("%d msgs", meta.events or 0), 9),
                text.truncate(meta.title or "(no title)", 44)),
            value = meta.id})
    end
    table.insert(options, {text = "Cancel", value = false})
    local answer = app:ask({
        lines = {theme.styled("dim", app.harness:rootdir())},
        question = "Which session do you want to resume?",
        options = options})
    return answer or nil
end

-- /export [path]
function _export(app, args)
    local filepath = (args or ""):trim()
    if filepath == "" then
        filepath = path.join(app.harness:rootdir(), string.format("harness-%s.md", os.date("%Y%m%d-%H%M%S")))
    end
    local lines = {string.format("# %s", app.session:title() or "conversation"), ""}
    for _, event in ipairs(app.session:events()) do
        local rendered = _exportevent(event)
        if rendered then
            table.insert(lines, rendered)
        end
    end
    io.writefile(filepath, table.concat(lines, "\n\n"))
    return {kind = "message", text = "the conversation is exported to " .. filepath}
end

-- render one event for the export
function _exportevent(event)
    if event.kind == "user" then
        return "## User\n\n" .. (event.text or "")
    elseif event.kind == "assistant" and event.text and event.text ~= "" then
        return "## Assistant\n\n" .. event.text
    elseif event.kind == "tool" then
        return string.format("### Tool: %s\n\n```\n%s\n```", event.name, (event.output or ""):sub(1, 2000))
    end
end
