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
-- the session log
--
-- the session is an append-only event log, it is the single source of truth:
-- the model history, the tui transcript, the token statistics and the resume
-- are all derived from it.
--
-- the event kinds:
--
--   user       {text}                             the user message
--   assistant  {text, reasoning, toolcalls}       the assistant message
--   tool       {id, name, arguments, output, iserror, duration}
--   notice     {text, level}                      the local notice, it is not sent to the model
--   compact    {summary, dropped}                 the context compaction boundary
--

-- imports
import("core.base.json")
import("core.base.object")
import("harness.util.text")
import("harness.util.util")
import("harness.util.tokens")
import("harness.config.config")

-- define the session class
local session = session or object {_init = {"_id", "_events", "_meta"}}

-- get the root directory of all the projects
function projectsdir()
    return path.join(config.homedir(), "projects")
end

-- get the slug of the given project directory
--
-- the sessions are kept per project, exactly like claude code does, so listing
-- and resuming never scans the sessions of the other projects:
--
--   ~/.xmake/harness/projects/-Users-ruki-projects-foo/<session id>.json
--
function slug(cwd)
    cwd = path.normalize(cwd or os.curdir())
    local result = cwd:gsub("[/\\:]", "-"):gsub("%s", "_")
    return result
end

-- get the sessions directory of the given project
function dir(cwd)
    return path.join(projectsdir(), slug(cwd))
end

-- get the legacy flat sessions directory
--
-- the early versions kept every session in one directory, we still read them so
-- an existing history is not lost
--
function legacydir()
    return path.join(config.homedir(), "sessions")
end

-- create a new session
function new(opt)
    opt = opt or {}
    local instance = session {opt.id or util.uuid(), {}, {}}
    instance._meta = {
        id = instance._id,
        title = opt.title,
        cwd = opt.cwd or os.curdir(),
        provider = opt.provider,
        model = opt.model,
        createtime = os.time(),
        updatetime = os.time(),
        usage = {input = 0, output = 0, cachehit = 0, cachemiss = 0, requests = 0}
    }
    return instance
end

-- get the session id
function session:id()
    return self._id
end

-- get the metadata
function session:meta()
    return self._meta
end

-- get/set the title
function session:title(title)
    if title ~= nil then
        self._meta.title = title
    end
    return self._meta.title
end

-- get the working directory
function session:cwd()
    return self._meta.cwd
end

-- get all the events
function session:events()
    return self._events
end

-- append an event
--
-- @param kind  the event kind, e.g. "user", "assistant", "tool"
-- @param data  the event data
-- @return      the appended event
--
function session:append(kind, data)
    local event = table.clone(data or {}, 1)
    event.kind = kind
    event.seq = #self._events + 1
    event.time = os.time()
    table.insert(self._events, event)
    self._meta.updatetime = event.time

    -- a conversation is named after the first thing which was asked of it
    --
    -- it happens here so that every front end gets it: a session started in a
    -- browser and one started in a terminal are listed side by side by
    -- `--resume`, and "(untitled)" for half of them is nobody's idea of a list
    if kind == "user" and not self._meta.title and (event.text or "") ~= "" then
        self:title(text.truncate((event.text:gsub("%s+", " ")), 60))
    end
    return event
end

-- insert the compaction boundary
--
-- the recent events are kept after the boundary, and the boundary is always
-- moved to the start of a user turn, so an assistant tool call never gets
-- separated from its tool results
--
-- @return  the number of the dropped events
--
function session:compact(summary, keeprecent)
    local events = self._events
    local boundary = math.max(1, #events - (keeprecent or 6) + 1)
    local safe = nil
    for idx = boundary, 2, -1 do
        if events[idx].kind == "user" then
            safe = idx
            break
        end
    end
    if not safe then
        for idx = boundary, #events do
            if events[idx].kind == "user" then
                safe = idx
                break
            end
        end
    end
    safe = safe or (#events + 1)
    table.insert(events, safe, {kind = "compact", summary = summary, time = os.time()})
    for idx, event in ipairs(events) do
        event.seq = idx
    end
    self._meta.updatetime = os.time()
    return safe - 1
end

-- update the token usage statistics
function session:usage_update(usage)
    if not usage then
        return
    end
    local total = self._meta.usage
    total.input = total.input + (usage.input or 0)
    total.output = total.output + (usage.output or 0)
    total.cachehit = total.cachehit + (usage.cachehit or 0)
    total.cachemiss = total.cachemiss + (usage.cachemiss or 0)
    total.requests = total.requests + 1
    total.lastinput = usage.input or 0
    total.lastoutput = usage.output or 0
    total.lastcachehit = usage.cachehit or 0
    total.lastcachemiss = usage.cachemiss or 0
end

-- get the token usage statistics
function session:usage()
    return self._meta.usage
end

-- get the cache hit rate of the whole session, e.g. 0.86
function session:cacherate()
    local usage = self._meta.usage
    local total = (usage.cachehit or 0) + (usage.cachemiss or 0)
    if total <= 0 then
        return nil
    end
    return usage.cachehit / total
end

-- derive the model messages from the event log
--
-- @param opt   the options, e.g. {maxevents = 100}
-- @return      the messages, e.g. {{role = "user", content = ".."}}
--
function session:messages(opt)
    opt = opt or {}
    local messages = {}
    local events = self._events
    local startidx = 1

    -- start from the last compaction boundary
    for idx = #events, 1, -1 do
        if events[idx].kind == "compact" then
            startidx = idx
            break
        end
    end

    for idx = startidx, #events do
        local event = events[idx]
        if event.kind == "compact" then
            table.insert(messages, {role = "user", content = event.summary})
            table.insert(messages, {role = "assistant", content = "Understood, I will continue from this summary."})
        elseif event.kind == "user" then
            table.insert(messages, {role = "user", content = event.text})
        elseif event.kind == "assistant" then
            if (event.text and event.text ~= "") or (event.toolcalls and #event.toolcalls > 0) then
                table.insert(messages, {
                    role = "assistant",
                    content = event.text or "",
                    toolcalls = event.toolcalls})
            end
        elseif event.kind == "tool" then
            table.insert(messages, {
                role = "tool",
                toolcallid = event.id,
                toolname = event.name,
                toolpath = (event.arguments or {}).path,
                iserror = event.iserror,
                content = event.output or ""})
        end
    end
    return messages
end

-- estimate the context tokens of the current messages
function session:contexttokens()
    return tokens.estimate_messages(self:messages())
end

-- get the file path of this session
function session:filepath()
    return path.join(dir(self._meta.cwd), self._id .. ".json")
end

-- save the session to the disk
function session:save()
    local filepath = self:filepath()
    os.mkdir(path.directory(filepath))
    local data = {meta = self._meta, events = self._events}
    return try {
        function ()
            json.savefile(filepath, data)
            return true
        end
    }
end

-- clear all the events, it keeps the metadata
function session:clear()
    self._events = {}
    return self
end

-- find the file of the given session id
--
-- the current project is searched first, then the other projects and the
-- legacy directory, so an id from `/sessions` always resolves
--
function find(id, cwd)
    local candidates = {path.join(dir(cwd), id .. ".json"), path.join(legacydir(), id .. ".json")}
    for _, filepath in ipairs(candidates) do
        if os.isfile(filepath) then
            return filepath
        end
    end
    for _, projectdir in ipairs(os.dirs(path.join(projectsdir(), "*"))) do
        local filepath = path.join(projectdir, id .. ".json")
        if os.isfile(filepath) then
            return filepath
        end
    end
end

-- load the session from the disk
function load(id, cwd)
    local filepath = find(id, cwd)
    if not filepath then
        return nil, string.format("session(%s) not found!", id)
    end
    local data = try { function () return json.loadfile(filepath) end }
    if type(data) ~= "table" then
        return nil, string.format("session(%s) is broken!", id)
    end
    local instance = session {data.meta and data.meta.id or id, data.events or {}, data.meta or {}}
    instance._meta.usage = instance._meta.usage or {input = 0, output = 0, cachehit = 0, cachemiss = 0, requests = 0}
    return instance
end

-- list the sessions
--
-- @param opt   the options, e.g. {cwd = "/path/to/project", limit = 20, all = false}
--              - cwd   only the sessions of this project, the current one by default
--              - all   every project instead
--
function list(opt)
    opt = opt or {}
    local dirs = {}
    if opt.all then
        for _, projectdir in ipairs(os.dirs(path.join(projectsdir(), "*"))) do
            table.insert(dirs, projectdir)
        end
        table.insert(dirs, legacydir())
    else
        table.insert(dirs, dir(opt.cwd))
        table.insert(dirs, legacydir())
    end

    local results = {}
    for _, sessiondir in ipairs(dirs) do
        for _, filepath in ipairs(os.files(path.join(sessiondir, "*.json"))) do
            local data = try { function () return json.loadfile(filepath) end }
            if type(data) == "table" and data.meta then
                local meta = data.meta
                if opt.all or not opt.cwd or not meta.cwd or path.normalize(meta.cwd) == path.normalize(opt.cwd) then
                    meta.events = #(data.events or {})
                    meta.filepath = filepath
                    table.insert(results, meta)
                end
            end
        end
    end
    table.sort(results, function (a, b)
        return (a.updatetime or 0) > (b.updatetime or 0)
    end)
    if opt.limit and #results > opt.limit then
        local limited = {}
        for idx = 1, opt.limit do
            table.insert(limited, results[idx])
        end
        results = limited
    end
    return results
end

-- get the last session of the given working directory
function last(cwd)
    local sessions = list({cwd = cwd, limit = 1})
    if #sessions > 0 then
        return load(sessions[1].id, cwd)
    end
end

-- remove a session
function remove(id, cwd)
    local filepath = find(id, cwd)
    if not filepath then
        return nil, string.format("session(%s) not found!", id)
    end
    os.tryrm(filepath)
    return true
end
