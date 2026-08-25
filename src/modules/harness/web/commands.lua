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
-- @file        commands.lua
--

--
-- the slash commands, in a browser
--
-- the commands are written against the terminal app: they call `app:notify`,
-- `app:ask`, `app:setmode` and read `app.session`. none of that is about a
-- terminal — it is about *an application which has a conversation and can put a
-- question to somebody* — and a browser is one of those too.
--
-- so this is an adapter and not a second set of commands: `/compact`, `/model`,
-- `/permissions`, `/rewind` and the ones a plugin adds all run here, unchanged,
-- and anything they learn to do they do in both places at once.
--
-- what a command may use of the app, and what it becomes here:
--
--   app.harness / app.session / app.mode   the state of this conversation, live
--   app:notify(text)                       a notice in the conversation
--   app:ask(request)                       the same card a confirmation uses
--   app:setmode(mode)                      the mode, and the page is told
--   app:newsession() / app:setsession(s)   the conversation, and the page redraws
--   app:setloop(s) / app:getloop()         the armed /loop
--   app:runcaptured(program, argv)         run something and show its output
--

-- imports
import("core.base.json")

-- is this line a command?
function iscommand(prompt)
    return type(prompt) == "string" and prompt:startswith("/") and not prompt:startswith("//")
end

-- the commands this harness has, as the page lists them
function describe(harness)
    local registry = harness:service("commands")
    local commands = {}
    for _, command in ipairs(registry and registry:all() or {}) do
        table.insert(commands, {
            name = command.name,
            description = command.description,
            source = command.source,
            arguments = command.arguments
        })
    end
    table.sort(commands, function (a, b) return a.name < b.name end)
    return commands
end

-- run one command line, e.g. "/compact keep the plan"
--
-- @param state   the web conversation, @see harness.web.session
-- @param line    the line the user typed, with the leading slash
-- @param hooks   what the adapter needs from the session:
--                {notify = f(text, iserror), ask = f(request) -> value,
--                 changed = f() -- the session or the mode was swapped}
--
-- @return  the command result, `{kind = "prompt"/"message"/"none", text = ..}`
--
function run(state, line, hooks)
    local registry = state.harness:service("commands")
    if not registry then
        return {kind = "message", text = "this harness has no commands", iserror = true}
    end

    local app = _app(state, hooks)
    local result
    try {
        function ()
            result = registry:run(app, line:sub(2))
        end,
        catch {
            function (errors)
                result = {kind = "message", text = tostring(errors), iserror = true}
            end
        }
    }
    return result or {kind = "none"}
end

-- an app, as a command sees one
--
-- it is a proxy and not a copy: `app.session` reads the conversation which is
-- live right now, and a command which assigns a new one — `/clear` does, and so
-- does `/resume` — changes it here and the page is told at that moment. a copy
-- would have to be read back afterwards, and would be wrong for the whole time
-- the command was still running.
--
-- `debug.setmetatable` because that is the one the xmake sandbox keeps, and the
-- backing table is separate because there is no `rawget` to reach past a
-- metatable with, @see xmake/core/sandbox
--
function _app(state, hooks)
    local methods = {}
    local app = {}
    debug.setmetatable(app, {
        __index = function (_, key)
            if key == "session" then
                return state.session
            elseif key == "mode" then
                return state.mode
            elseif key == "harness" then
                return state.harness
            elseif key == "web" then
                return true
            end
            return methods[key]
        end,
        __newindex = function (_, key, value)
            if key == "session" then
                state.session = value
                hooks.changed("session")
            elseif key == "mode" then
                state.mode = value
                hooks.changed("mode")
            else
                methods[key] = value
            end
        end
    })

    methods.notify = function (self, message, style)
        hooks.notify(tostring(message or ""), style == "error")
    end

    methods.ask = function (self, request)
        return hooks.ask(request)
    end

    methods.setmode = function (self, mode)
        local config = state.harness:config()
        config.permission = config.permission or {}
        config.permission.mode = mode
        self.mode = mode
        return self
    end

    methods.newsession = function (self)
        local sessions = import("harness.core.session", {anonymous = true})
        state.session:save()
        state.harness:service("todos", {})
        self.session = sessions.new({cwd = state.harness:rootdir()})
        return self.session
    end

    methods.setsession = function (self, session)
        state.session:save()
        state.harness:service("todos", {})
        self.session = session
        return self
    end

    methods.setloop = function (self, loop)
        state.loop = loop
    end

    methods.getloop = function (self)
        return state.loop
    end

    -- run a program and show what it printed
    --
    -- the terminal ui hands the terminal over for this and the output scrolls
    -- past; a browser has nowhere to hand over, so it is captured and pushed
    -- into the conversation as the card of a command which ran
    --
    methods.runcaptured = function (self, program, argv, opt)
        return hooks.captured(program, argv, opt)
    end
    return app
end
