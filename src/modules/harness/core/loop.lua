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
-- the repeating task
--
-- some work is not one question but the same question on a schedule: watch the
-- ci every half hour, re-run the build every ten minutes until it is green,
-- check the inbox of a queue. `/loop 30m <task>` arms it, and the idle terminal
-- fires the task itself instead of waiting for a keystroke.
--
-- an armed loop spends money on its own, so it is deliberately easy to see and
-- easy to stop: the status line always says what it is and when it fires next,
-- `esc` during an iteration ends the whole loop rather than only that turn, and
-- a run of failures ends it without asking.
--
-- it lives in the session it was armed in and nowhere else. nothing is written
-- to disk, and quitting is enough to be rid of it.
--

-- how long an interval may be
--
-- an interval below the floor is a typo, not an intention, and every iteration
-- is a real conversation with a real model
--
local MINIMUM = 10

-- how many failed iterations in a row end the loop
local MAXFAILURES = 3

-- parse an interval, e.g. "30m", "90s", "2h", "1h30m"
--
-- a bare number is refused: nobody agrees on whether `30` is seconds or
-- minutes, and guessing wrong is either a busy loop or a long wait
--
-- @return  the seconds, or nil and the reason
--
function parse(str)
    local text = (str or ""):trim():lower()
    if text == "" then
        return nil, "how often? e.g. /loop 30m <task>"
    end
    if text:match("^%d+$") then
        return nil, string.format("the interval needs a unit: %ss, %sm or %sh?", text, text, text)
    end

    local seconds = 0
    local rest = text
    while rest ~= "" do
        local value, unit, tail = rest:match("^(%d+)([smh])(.*)$")
        if not value then
            return nil, string.format("cannot read the interval(%s), e.g. 90s, 30m, 2h, 1h30m", str)
        end
        seconds = seconds + tonumber(value) * ({s = 1, m = 60, h = 3600})[unit]
        rest = tail
    end
    if seconds < MINIMUM then
        return nil, string.format("%s is too short, the shortest interval is %ds.", text, MINIMUM)
    end
    return seconds
end

-- arm a loop
--
-- the first iteration fires at once: the user asked for this task, waiting the
-- first interval out before doing anything would only look broken
--
function new(seconds, prompt, now)
    return {
        interval = seconds,
        prompt = prompt,
        next = now,
        runs = 0,
        failures = 0
    }
end

-- is it time to fire?
function due(state, now)
    return state ~= nil and now >= state.next
end

-- how long until the next iteration
function remaining(state, now)
    return math.max(0, state.next - now)
end

-- start one iteration
function begin(state)
    state.runs = state.runs + 1
    return state.prompt
end

-- one iteration is over
--
-- the next one is scheduled from the moment this one ended, not from the moment
-- it started: an iteration which takes longer than the interval would otherwise
-- fire the next one the instant it returns, and then never stop
--
-- @param result    the turn result, @see harness.core.agent.run
--
-- @return          the reason to stop, or nil to keep going
--
function finished(state, now, result)
    state.next = now + state.interval
    if (result or {}).aborted then
        return string.format("the loop is stopped after %d run%s.", state.runs, state.runs == 1 and "" or "s")
    end
    if not (result or {}).errors then
        state.failures = 0
        return nil
    end
    state.failures = state.failures + 1
    if state.failures < MAXFAILURES then
        return nil
    end
    return string.format("the loop is stopped: %d iterations in a row failed.", state.failures)
end

-- the interval as a human writes it, e.g. 5400 -> "1h30m"
function duration(seconds)
    if seconds < 60 then
        return string.format("%ds", seconds)
    end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local rest = seconds % 60
    local parts = {}
    if hours > 0 then
        table.insert(parts, string.format("%dh", hours))
    end
    if minutes > 0 then
        table.insert(parts, string.format("%dm", minutes))
    end
    if rest > 0 and hours == 0 then
        table.insert(parts, string.format("%ds", rest))
    end
    return table.concat(parts)
end

-- what the status line says
function describe(state, now)
    if not state then
        return nil
    end
    return string.format("loop every %s · next in %s · %d run%s",
        duration(state.interval), duration(remaining(state, now)),
        state.runs, state.runs == 1 and "" or "s")
end
