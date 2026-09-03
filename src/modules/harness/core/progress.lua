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
-- @file        progress.lua
--

--
-- what is happening right now, and how long it has been happening
--
-- something which runs for minutes and says nothing is indistinguishable from
-- something which has hung, and the difference matters most exactly when the
-- wait is longest: a subagent exploring a large project, a conversion working
-- through a hundred targets.
--
-- so there is one channel per running thing, everything which knows something
-- reports into it, and the front ends read it. the reporter does not know
-- whether anybody is watching and the watcher does not know who is reporting,
-- which is what lets an agent's own lua say `progress.stage(..)` and have it
-- appear in a terminal it has never heard of.
--
-- the elapsed time is worked out when the channel is *read* and not when it is
-- written. a number which stops moving between two events reads as a harness
-- which has stopped, and the gap between two events is exactly where the doubt
-- lives.
--

-- create a channel
--
-- @param opt   {label = "porter", onchange = function (channel) .. end}
--
function new(opt)
    opt = opt or {}
    return {
        label = opt.label,
        stage = opt.stage or "starting",
        detail = nil,
        step = 0,
        starttime = os.time(),
        stagetime = os.time(),
        onchange = opt.onchange,
        history = {}
    }
end

-- say what is happening now
--
-- @param what      the stage, e.g. "reading the project"
-- @param detail    what it is doing within it, e.g. "CMakeLists.txt"
--
function stage(channel, what, detail)
    if not channel then
        return
    end
    if channel.stage ~= what then
        table.insert(channel.history, {stage = channel.stage, seconds = os.time() - channel.stagetime})
        channel.stagetime = os.time()
    end
    channel.stage = what
    channel.detail = detail
    _changed(channel)
end

-- say which step of the loop it is on
function step(channel, number)
    if not channel then
        return
    end
    channel.step = number or (channel.step + 1)
    _changed(channel)
end

-- it is over
function done(channel)
    if not channel then
        return
    end
    channel.finished = true
    _changed(channel)
end

-- how long it has been going, worked out now
function elapsed(channel)
    if not channel then
        return 0
    end
    return math.max(0, os.time() - channel.starttime)
end

-- a duration, as somebody watching it reads one
function duration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds < 60 then
        return string.format("%ds", seconds)
    end
    if seconds < 3600 then
        return string.format("%dm%02ds", seconds // 60, seconds % 60)
    end
    return string.format("%dh%02dm", seconds // 3600, (seconds % 3600) // 60)
end

-- the one line a status bar shows
--
-- @param opt   {elapsed = true, step = true}
--
function describe(channel, opt)
    if not channel then
        return nil
    end
    opt = opt or {}
    local parts = {}
    if channel.label and channel.label ~= "" then
        table.insert(parts, channel.label)
    end
    if opt.step ~= false and channel.step > 0 then
        table.insert(parts, string.format("step %d", channel.step))
    end
    local what = channel.stage
    if channel.detail and channel.detail ~= "" then
        what = string.format("%s %s", what, channel.detail)
    end
    if what and what ~= "" then
        table.insert(parts, what)
    end
    if opt.elapsed ~= false then
        table.insert(parts, duration(elapsed(channel)))
    end
    return table.concat(parts, " · ")
end

-- what it did, and for how long, once it is over
--
-- it is the answer to "where did those four minutes go", which is a question
-- worth being able to answer about anything which took four minutes
--
function summary(channel)
    if not channel then
        return {}
    end
    local out = {}
    for _, one in ipairs(channel.history) do
        table.insert(out, {stage = one.stage, seconds = one.seconds})
    end
    table.insert(out, {stage = channel.stage, seconds = os.time() - channel.stagetime})
    return out
end

-- tell whoever is watching, without letting them break the reporter
function _changed(channel)
    if not channel.onchange then
        return
    end
    try { function () channel.onchange(channel) end }
end

-- the handlers of an agent turn, reporting into this channel
--
-- it is here rather than in a front end because every front end wants the same
-- thing from it, and one which wrote its own would drift from the others
--
-- @param opt   {ontick = function () .. end}
-- @return      a ui handler table, @see harness.core.agent
--
function handlers(channel, opt)
    opt = opt or {}
    return {
        on_step_start = function (state)
            step(channel, state and state.step or nil)
            stage(channel, "thinking")
        end,
        on_text = function ()
            stage(channel, "writing")
        end,
        on_reasoning = function ()
            stage(channel, "reasoning")
        end,
        on_tool_start = function (call)
            stage(channel, opt.verb and opt.verb(call.name) or call.name,
                  opt.subject and opt.subject(call) or nil)
        end,
        on_tool_result = function ()
            stage(channel, "thinking")
        end,
        on_retry = function (count)
            stage(channel, string.format("reconnecting (%d)", count))
        end,
        ontick = opt.ontick
    }
end
