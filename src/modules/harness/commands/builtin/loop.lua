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

    local state = loop.new(seconds, task, os.time())
    app:setloop(state)
    _arm(app, state)
    return {kind = "message", text = string.format("the loop is armed: every %s, starting now.\n"
        .. "stop it with /loop stop, with esc while it works, or let the agent end it "
        .. "when the task is done.", loop.duration(seconds))}
end

-- the tool which lets the agent end the loop
--
-- it exists only while a loop is armed. a tool which is almost never applicable
-- still costs its schema in every request and still invites the model to reach
-- for it, so this one is added when the loop starts and taken away when it
-- stops rather than living in the registry all day
--
function _arm(app, state)
    app.harness:service("tools"):add({
        name = "loop_stop",
        group = "core",
        permission = "none",
        description = [[End the repeating task you are running under.

You are being run on a schedule. Call this when the objective is met and running
the same prompt again would achieve nothing — the build is green, the migration
is finished, the thing you were watching for has happened.

Do not call it because one iteration went badly: a schedule exists precisely so
that the next one can go better.]],
        parameters = {
            type = "object",
            properties = {
                reason = {type = "string", description = "What was achieved, one short line."}
            },
            required = {"reason"}
        },
        render = function (args)
            return (args or {}).reason or "the task is complete"
        end,
        run = function (context, args)
            local armed = context.harness:service("loop")
            if not armed then
                raise("there is no repeating task to end.")
            end
            loop.complete(armed, args.reason)
            return {output = "the repeating task will end after this turn.",
                    display = {title = "Loop", subject = args.reason or "", summary = "done"}}
        end
    })
    app.harness:service("loop", state)
end

-- take the tool away again
function _disarm(app)
    app.harness:service("tools"):remove("loop_stop")
    app.harness:service("loop", nil)
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
    _disarm(app)
    return {kind = "message", text = string.format("the loop is stopped after %d run%s.",
        state.runs, state.runs == 1 and "" or "s")}
end
