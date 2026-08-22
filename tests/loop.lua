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

-- imports
import("harness.core.loop")

function test_the_units()
    assert(loop.parse("90s") == 90)
    assert(loop.parse("30m") == 1800)
    assert(loop.parse("2h") == 7200)
    assert(loop.parse("1h30m") == 5400)
    assert(loop.parse("  10M  ") == 600, "it is case insensitive and trimmed")
end

function test_a_bare_number_is_refused()
    -- nobody agrees on whether `30` is seconds or minutes
    local seconds, errors = loop.parse("30")
    assert(seconds == nil)
    assert(errors:find("30s", 1, true) and errors:find("30m", 1, true), errors)
end

function test_a_too_short_interval_is_refused()
    local seconds, errors = loop.parse("1s")
    assert(seconds == nil)
    assert(errors:find("too short", 1, true), errors)
end

function test_garbage_is_refused()
    assert(loop.parse("soon") == nil)
    assert(loop.parse("") == nil)
    assert(loop.parse("30x") == nil)
    assert(loop.parse("m30") == nil)
end

function test_it_fires_at_once()
    -- the user just asked for this task, waiting the first interval out
    -- would only look broken
    local state = loop.new(1800, "check the ci", 1000)
    assert(loop.due(state, 1000), "the first iteration must not wait")
end

function test_it_waits_for_the_interval()
    local state = loop.new(600, "task", 1000)
    loop.begin(state)
    loop.finished(state, 1000, {})
    assert(not loop.due(state, 1599))
    assert(loop.due(state, 1600))
end

function test_the_next_one_is_scheduled_from_the_end()
    -- an iteration slower than the interval would otherwise fire the next one
    -- the instant it returns, and then never stop
    local state = loop.new(600, "task", 1000)
    loop.begin(state)
    loop.finished(state, 3000, {})
    assert(state.next == 3600, "the countdown starts when the work ended")
end

function test_the_runs_are_counted()
    local state = loop.new(600, "task", 0)
    for idx = 1, 3 do
        loop.begin(state)
        loop.finished(state, idx * 600, {})
    end
    assert(state.runs == 3)
end

function test_a_failing_streak_stops_it()
    local state = loop.new(600, "task", 0)
    assert(loop.finished(state, 1, {errors = "boom"}) == nil)
    assert(loop.finished(state, 2, {errors = "boom"}) == nil)
    local stopped = loop.finished(state, 3, {errors = "boom"})
    assert(stopped ~= nil, "three failures in a row must end it")
    assert(stopped:find("failed", 1, true), stopped)
end

function test_one_good_run_clears_the_streak()
    local state = loop.new(600, "task", 0)
    loop.finished(state, 1, {errors = "boom"})
    loop.finished(state, 2, {errors = "boom"})
    loop.finished(state, 3, {})
    assert(state.failures == 0)
    assert(loop.finished(state, 4, {errors = "boom"}) == nil, "the streak restarts from zero")
end

function test_an_abort_stops_the_whole_loop()
    -- esc means stop, not "skip this one"
    local state = loop.new(600, "task", 0)
    local stopped = loop.finished(state, 1, {aborted = true})
    assert(stopped ~= nil and stopped:find("stopped", 1, true), tostring(stopped))
end

function test_the_countdown()
    local state = loop.new(600, "task", 1000)
    loop.finished(state, 1000, {})
    assert(loop.remaining(state, 1300) == 300)
    assert(loop.remaining(state, 9999) == 0, "it never goes negative")
end

function test_the_durations_read_back()
    assert(loop.duration(30) == "30s")
    assert(loop.duration(600) == "10m")
    assert(loop.duration(3600) == "1h")
    assert(loop.duration(5400) == "1h30m")
end

function test_the_status_line()
    local state = loop.new(1800, "check the ci", 1000)
    loop.begin(state)
    loop.finished(state, 1000, {})
    local text = loop.describe(state, 1600)
    assert(text:find("every 30m", 1, true), text)
    assert(text:find("next in 20m", 1, true), text)
    assert(text:find("1 run", 1, true), text)
end
