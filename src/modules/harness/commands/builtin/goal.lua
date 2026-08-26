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
-- @file        goal.lua
--

--
-- the goal command: /goal
--
-- `/loop` repeats a task on a clock: "check the ci every half hour" has no end
-- and is not supposed to have one. `/goal` is the other shape of the same
-- machinery — an objective which *does* have an end, worked at turn after turn
-- until it is reached:
--
--   /goal make the tests pass
--   /goal the web ui builds without warnings on linux
--
-- so it is the same armed state with a zero interval, @see harness.core.loop:
-- the next turn starts as soon as the last one ended, the agent says when the
-- objective is met, and it stops by itself when it is — or when it has spent
-- the turns it was given without getting there.
--
-- what it is not is a way to leave the machine unattended with a vague wish.
-- the permission mode still applies, every tool call is still judged, and a
-- turn count it cannot exceed is part of the arming rather than a thing to
-- remember to add.
--

-- imports
import("harness.core.loop")

-- how many turns an objective gets before we stop and say so
local MAXTURNS = 12

-- the commands of this group
function commands()
    return {
        {name = "goal", description = "Work at an objective until it is reached, e.g. /goal make the tests pass",
         run = _goal}
    }
end

-- /goal [objective] | /goal stop | /goal
function _goal(app, args)
    local line = (args or ""):trim()
    if line == "" then
        return _status(app)
    end
    if line == "stop" or line == "off" or line == "cancel" then
        return _stop(app)
    end

    -- an optional turn budget in front, e.g. `/goal 5 make the tests pass`
    local turns = MAXTURNS
    local budget, rest = line:match("^(%d+)%s+(.+)$")
    if budget then
        turns = math.max(1, math.min(50, tonumber(budget)))
        line = rest
    end

    if not app.setloop then
        return {kind = "message", text = "a goal needs the interactive tui or the web ui, "
            .. "run `xmake ai` or `xmake ai --web`.", iserror = true}
    end
    if app:getloop() then
        return {kind = "message", text = "something is already armed, /loop stop or /goal stop first.",
                iserror = true}
    end

    local state = loop.new(0, line, os.time(), {
        kind = "goal",
        maxruns = turns,
        followup = string.format([[Carry on with this objective:

%s

Check whether it is met. If it is, call `goal_done` with what was achieved and
stop. If it is not, do the next thing which moves it forward — do not repeat
what you have already done, and do not ask me what to do next.]], line)
    })
    app:setloop(state)
    _arm(app, state)
    return {kind = "message", text = string.format(
        "the goal is armed: %s\nit works at it turn after turn, at most %d of them.\n"
        .. "stop it with /goal stop, or with esc while it works.", line, turns)}
end

-- the tool which lets the agent say the objective is met
--
-- it exists only while a goal is armed, for the same reason the loop's does:
-- a tool which is almost never applicable still costs its schema in every
-- request and still invites the model to reach for it
--
function _arm(app, state)
    app.harness:service("tools"):add({
        name = "goal_done",
        group = "core",
        permission = "none",
        description = [[Say that the objective you were given has been reached.

You are working at an objective, turn after turn, until it is met. Call this
when it *is* met and you can say how you know — the tests pass and you ran them,
the build is clean and you saw it, the thing you were asked to make exists and
works.

Do not call it because you have run out of ideas, and do not call it on a
belief: check first, then call it with what you checked.]],
        parameters = {
            type = "object",
            properties = {
                reason = {type = "string",
                          description = "What was achieved and how you know, one short line."}
            },
            required = {"reason"}
        },
        render = function (args)
            return (args or {}).reason or "the objective is met"
        end,
        run = function (context, args)
            local armed = context.harness:service("loop")
            if not armed then
                raise("there is no objective to finish.")
            end
            loop.complete(armed, args.reason)
            return {output = "the goal will end after this turn.",
                    display = {title = "Goal", subject = args.reason or "", summary = "reached"}}
        end
    })
    app.harness:service("loop", state)
end

-- take the tool away again
function _disarm(app)
    app.harness:service("tools"):remove("goal_done")
    app.harness:service("loop", nil)
end

-- /goal
function _status(app)
    local state = app.getloop and app:getloop()
    if not state or state.kind ~= "goal" then
        return {kind = "message", text = "no goal is armed. /goal <what you want> to arm one."}
    end
    return {kind = "message", text = string.format("%s\n%s", state.prompt,
        loop.describe(state, os.time()))}
end

-- /goal stop
function _stop(app)
    local state = app.getloop and app:getloop()
    if not state or state.kind ~= "goal" then
        return {kind = "message", text = "no goal is armed."}
    end
    app:setloop(nil)
    _disarm(app)
    return {kind = "message", text = string.format("the goal is stopped after %d turn%s.",
        state.runs, state.runs == 1 and "" or "s")}
end
