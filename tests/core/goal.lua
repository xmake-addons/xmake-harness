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

-- imports
import("harness.core.loop")
import("harness.harness")

-- an app as a command sees one, with the two things a goal needs of it
function _app()
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    local app = {harness = instance, armed = nil, said = {}}
    app.setloop = function (self, state)
        self.armed = state
    end
    app.getloop = function (self)
        return self.armed
    end
    return app
end

function _run(app, args)
    return app.harness:service("commands"):run(app, "goal " .. (args or ""))
end

---------------------------------------------------------------------------------
-- arming one
---------------------------------------------------------------------------------

function test_a_goal_is_armed_with_what_was_asked_for()
    local app = _app()
    local result = _run(app, "make the tests pass")
    assert(result.kind == "message" and not result.iserror, tostring(result.text))
    assert(app.armed, "something must be armed")
    assert(app.armed.kind == "goal", app.armed.kind)
    assert(app.armed.prompt == "make the tests pass", app.armed.prompt)

    -- it runs one turn after another, so there is no waiting between them
    assert(app.armed.interval == 0, tostring(app.armed.interval))
    assert(loop.due(app.armed, os.time()), "the first turn is due at once")
end

function test_a_goal_has_a_turn_budget()
    local app = _app()
    _run(app, "make the tests pass")
    assert(app.armed.maxruns and app.armed.maxruns > 1, tostring(app.armed.maxruns))

    -- and it can be given one
    app.armed = nil
    _run(app, "3 make the tests pass")
    assert(app.armed.maxruns == 3, tostring(app.armed.maxruns))
    assert(app.armed.prompt == "make the tests pass", app.armed.prompt)
end

function test_the_agent_is_given_a_way_to_say_it_is_done()
    local app = _app()
    _run(app, "make the tests pass")
    local tool = app.harness:service("tools"):get("goal_done")
    assert(tool, "the tool exists while a goal is armed")

    -- and calling it ends the goal after the turn which called it
    tool.run({harness = app.harness}, {reason = "the tests pass, I ran them"})
    assert(app.armed.done, "the goal is marked as reached")
    local stopped = loop.finished(app.armed, os.time(), {})
    assert(stopped and stopped:find("the goal is reached", 1, true), tostring(stopped))
end

function test_the_tool_goes_away_with_the_goal()
    local app = _app()
    _run(app, "make the tests pass")
    _run(app, "stop")
    assert(app.armed == nil, "nothing is armed any more")
    assert(app.harness:service("tools"):get("goal_done") == nil, "and the tool is gone")
end

function test_two_things_cannot_be_armed_at_once()
    local app = _app()
    _run(app, "make the tests pass")
    local result = _run(app, "and also make it fast")
    assert(result.iserror, "the second one is refused")
    assert(app.armed.prompt == "make the tests pass", app.armed.prompt)
end

function test_nothing_armed_says_so()
    local app = _app()
    local result = _run(app, "")
    assert(result.text:find("no goal", 1, true), result.text)
    assert(_run(app, "stop").text:find("no goal", 1, true))
end

---------------------------------------------------------------------------------
-- how it differs from a schedule
---------------------------------------------------------------------------------

function test_the_first_turn_asks_and_the_ones_after_it_follow_up()
    -- a schedule sends the same thing every time; an objective does not — the
    -- first turn asks for it, the ones after it ask whether it is there yet
    local app = _app()
    _run(app, "make the tests pass")

    local first = loop.begin(app.armed)
    assert(first == "make the tests pass", first)

    loop.finished(app.armed, os.time(), {})
    local second = loop.begin(app.armed)
    assert(second ~= first, "the second turn says something else")
    assert(second:find("make the tests pass", 1, true), "and it still says what for")
    assert(second:find("goal_done", 1, true), "and how to end it")
end

function test_a_goal_which_is_not_reached_stops_by_itself()
    local app = _app()
    _run(app, "2 make the tests pass")

    loop.begin(app.armed)
    assert(loop.finished(app.armed, os.time(), {}) == nil, "one turn is not the end of it")
    loop.begin(app.armed)
    local stopped = loop.finished(app.armed, os.time(), {})
    assert(stopped and stopped:find("without reaching it", 1, true), tostring(stopped))
end

function test_a_schedule_still_repeats_for_ever()
    -- the budget belongs to the goal and not to the machinery under it
    local state = loop.new(600, "check the ci", os.time())
    assert(state.maxruns == nil, "a schedule has no turn budget")
    for _ = 1, 20 do
        loop.begin(state)
        assert(loop.finished(state, os.time(), {}) == nil, "and it keeps going")
    end
end

function test_what_it_says_it_is()
    local app = _app()
    _run(app, "4 make the tests pass")
    local said = loop.describe(app.armed, os.time())
    assert(said:find("goal", 1, true), said)
    assert(said:find("at most 4", 1, true), said)
end
