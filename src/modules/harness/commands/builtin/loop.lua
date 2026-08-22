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
-- @file        loop.lua
--

--
-- the loop command: /loop
--

-- imports
import("harness.core.loop")

-- the commands of this group
function commands()
    return {
        {name = "loop", description = "Repeat a task on a schedule, e.g. /loop 30m check the ci", run = _loop}
    }
end

-- /loop [interval] [task] | /loop stop | /loop
function _loop(app, args)
    local line = (args or ""):trim()
    if line == "" then
        return _status(app)
    end
    if line == "stop" or line == "off" or line == "cancel" then
        return _stop(app)
    end

    local interval, task = line:match("^(%S+)%s*(.*)$")
    local seconds, errors = loop.parse(interval)
    if not seconds then
        return {kind = "message", text = errors, iserror = true}
    end
    task = (task or ""):trim()
    if task == "" then
        return {kind = "message", text = "what should it do? e.g. /loop 30m run the tests and report what broke",
                iserror = true}
    end
    if not app.setloop then
        return {kind = "message", text = "the loop needs the interactive tui, run `xmake ai` without --print.",
                iserror = true}
    end

    app:setloop(loop.new(seconds, task, os.time()))
    return {kind = "message", text = string.format("the loop is armed: every %s, starting now.\n"
        .. "stop it with /loop stop, or with esc while it works.", loop.duration(seconds))}
end

-- /loop
function _status(app)
    local state = app.getloop and app:getloop()
    if not state then
        return {kind = "message", text = "no loop is running. arm one with /loop 30m <task>"}
    end
    return {kind = "message", text = string.format("%s\n  %s\n\nstop it with /loop stop",
        loop.describe(state, os.time()), state.prompt)}
end

-- /loop stop
function _stop(app)
    local state = app.getloop and app:getloop()
    if not state then
        return {kind = "message", text = "no loop is running."}
    end
    app:setloop(nil)
    return {kind = "message", text = string.format("the loop is stopped after %d run%s.",
        state.runs, state.runs == 1 and "" or "s")}
end
