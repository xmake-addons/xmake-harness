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
-- @file        plan.lua
--

-- imports
import("harness.harness")
import("harness.core.plan")
import("harness.ui.dialog")
import("harness.tools.pipeline")
import("harness.core.session", {alias = "sessions"})

local PLAN = [[
# Add the query methods

- Declare `contains`, `size`, `empty` and `at` in the header
- `at` raises with the key or the index in the message
- `size` counts the elements, and the characters of a string
]]

-- a conversation to plan in
function _state()
    local rootdir = os.tmpfile() .. ".plan"
    os.mkdir(rootdir)
    local instance = harness.bootstrap({rootdir = rootdir, trusted = true})
    return {harness = instance, session = sessions.new({cwd = rootdir})}, rootdir
end

-- a tool context whose dialog answers with the given value
function _context(state, rootdir, answer, mode)
    local asked = {}
    local config = state.harness:config()

    -- the mode it is really in, so leaving it is a change and not a no-op
    config.permission = {mode = mode or "plan"}
    return {
        harness = state.harness, config = config, cwd = rootdir,
        session = state.session, signal = {}, depth = 0, mode = mode or "plan",
        ui = {
            confirm = function (request)
                table.insert(asked, request)
                return answer
            end,
            on_mode = function (now)
                asked.mode = now
            end
        }
    }, asked
end

---------------------------------------------------------------------------------
-- what a plan says
---------------------------------------------------------------------------------

function test_the_title_is_the_heading()
    local one = plan.parse(PLAN)
    assert(one.title == "Add the query methods", one.title)
end

function test_the_steps_are_the_list()
    local one = plan.parse(PLAN)
    assert(#one.steps == 3, tostring(#one.steps))
    assert(one.steps[1]:find("contains", 1, true), one.steps[1])
    assert(one.steps[3]:find("counts the elements", 1, true), one.steps[3])
end

function test_a_numbered_list_is_a_list_too()
    local one = plan.parse("Do it\n\n1. first\n2. second\n3) third\n")
    assert(#one.steps == 3, tostring(#one.steps))
    assert(one.steps[2] == "second", one.steps[2])
end

function test_a_checkbox_is_not_part_of_the_step()
    local one = plan.parse("# Go\n\n- [ ] read it\n- [x] write it\n")
    assert(one.steps[1] == "read it", one.steps[1])
    assert(one.steps[2] == "write it", one.steps[2])
end

function test_a_plan_without_a_heading_still_has_a_title()
    local one = plan.parse("Rewrite the parser, carefully.\n\n- one\n")
    assert(one.title == "Rewrite the parser, carefully.", one.title)
end

function test_a_plan_with_nothing_in_it()
    local one = plan.parse("")
    assert(one.title == "the plan", one.title)
    assert(#one.steps == 0)
end

function test_one_line_which_says_what_it_is()
    assert(plan.describe(plan.parse(PLAN)) == "Add the query methods (3 steps)",
           plan.describe(plan.parse(PLAN)))
    assert(plan.describe(plan.parse("# Just this")) == "Just this")
    assert(plan.describe(nil) == nil)
end

---------------------------------------------------------------------------------
-- and where it is kept
---------------------------------------------------------------------------------

function test_a_plan_is_kept_with_the_rest_of_the_conversation()
    -- it survives a restart, `/resume` brings it back, and the web ui can draw
    -- what was agreed without having been running at the time
    local state = _state()
    plan.submit(state, PLAN)
    local kept = plan.current(state)
    assert(kept, "there is a plan")
    assert(kept.title == "Add the query methods", kept.title)
    assert(#kept.steps == 3)
    assert(kept.decision == nil, "nobody has decided yet")
end

function test_the_decision_is_kept_beside_it()
    local state = _state()
    local one = plan.submit(state, PLAN)
    plan.decide(state, one, "approved")
    assert(plan.current(state).decision == "approved")
end

function test_a_second_plan_starts_the_question_again()
    local state = _state()
    local first = plan.submit(state, PLAN)
    plan.decide(state, first, "rejected")
    plan.submit(state, "# Another way\n\n- do it differently\n")

    local now = plan.current(state)
    assert(now.title == "Another way", now.title)
    assert(now.decision == nil, "the new one has not been decided")
end

function test_no_plan_at_all()
    assert(plan.current(_state()) == nil)
end

---------------------------------------------------------------------------------
-- the way out of the plan mode
---------------------------------------------------------------------------------

function _submit(context, planned)
    return pipeline.execute(context, {id = "1", name = "submit_plan",
                                      arguments = {plan = planned or PLAN}})
end

function test_approving_it_ends_the_plan_mode()
    -- that is the whole point: the agent used to write the plan into the
    -- conversation and carry on reading files, because nothing told it to stop
    local state, rootdir = _state()
    local context = _context(state, rootdir, "allow")
    local result = _submit(context)

    assert(not result.iserror, result.output)
    assert(result.output:find("approved", 1, true), result.output)
    assert(context.config.permission.mode == "default", context.config.permission.mode)
    assert(context.mode == "default", context.mode)
    assert(plan.current(state).decision == "approved")
end

function test_approving_it_with_the_edits_accepted_goes_further()
    local state, rootdir = _state()
    local context = _context(state, rootdir, {answer = "always", rule = "@acceptedits"})
    assert(not _submit(context).iserror)
    assert(context.config.permission.mode == "acceptedits", context.config.permission.mode)
end

function test_not_approving_it_keeps_planning()
    local state, rootdir = _state()
    local context = _context(state, rootdir, "deny")
    local result = _submit(context)

    assert(result.output:find("still in the plan mode", 1, true), result.output)
    assert(context.config.permission.mode == "plan", context.config.permission.mode)
    assert(context.mode == "plan", context.mode)
    assert(plan.current(state).decision == "rejected")
end

function test_the_plan_reaches_whoever_is_asked()
    local state, rootdir = _state()
    local context, asked = _context(state, rootdir, "allow")
    _submit(context)
    assert(#asked == 1, tostring(#asked))
    assert(asked[1].plan, "the dialog is given the plan and not the raw arguments")
    assert(asked[1].plan.title == "Add the query methods", asked[1].plan.title)
    assert(#asked[1].plan.steps == 3)
end

function test_it_is_not_a_way_to_leave_a_mode_nobody_is_in()
    local state, rootdir = _state()
    local context = _context(state, rootdir, "allow", "default")
    local result = _submit(context)
    assert(result.iserror)
    assert(result.output:find("not active", 1, true), result.output)
end

function test_a_plan_asked_about_where_nobody_can_answer()
    local state, rootdir = _state()
    local context = _context(state, rootdir, "allow")
    context.ui = {}
    local result = _submit(context)
    assert(result.iserror)
    assert(result.output:find("nobody to show", 1, true), result.output)
end

---------------------------------------------------------------------------------
-- how it is worded
---------------------------------------------------------------------------------

function test_a_plan_is_not_asked_about_like_a_permission()
    local info = dialog.confirminfo({name = "submit_plan"}, {})
    assert(info.isplan)
    assert(info.question:find("carry this plan out", 1, true), info.question)

    -- "no" here is not "no, never again": it is "keep planning"
    assert(info.denytext == "No, keep planning", info.denytext)
end

---------------------------------------------------------------------------------
-- and how the terminal draws it
---------------------------------------------------------------------------------

import("harness.ui.app", {alias = "uiapp"})
import("harness.ui.keymap")

-- the dialog body, without the colours
function _drawn(one)
    local state, rootdir = _state()
    local app = uiapp.new(state.harness, {session = state.session})
    local plain = {}
    for _, line in ipairs(app:_confirmlines(dialog.confirminfo({name = "submit_plan"}, {}),
                                            {plan = one})) do
        table.insert(plain, (line:gsub("\027%[[%d;]*m", "")))
    end
    return plain, table.concat(plain, "\n")
end

function test_the_plan_mode_is_one_shift_tab_away()
    local state = {editor = uiapp.new(_state().harness, {}).editor, mode = "default"}
    local seen = {}
    for _ = 1, 3 do
        keymap.handle({name = "tab", shift = true}, state)
        table.insert(seen, state.mode)
    end
    assert(table.concat(seen, ",") == "acceptedits,plan,default", table.concat(seen, ","))
end

function test_the_terminal_renders_the_plan_as_markdown()
    -- the person is about to agree to it, and a wall of asterisks is not
    -- something anybody agrees to
    local _, drawn = _drawn(plan.parse(PLAN))
    assert(drawn:find("Add the query methods", 1, true), drawn)
    assert(drawn:find("Declare", 1, true), drawn)
    assert(not drawn:find("#", 1, true), "the heading is rendered, not quoted")
    assert(not drawn:find("- Declare", 1, true), "and so is the list")
end

function test_the_title_is_not_said_twice()
    -- it was read *out* of the plan, so the heading it came from is already the
    -- first thing rendered
    local lines = _drawn(plan.parse(PLAN))
    local count = 0
    for _, line in ipairs(lines) do
        if line:find("Add the query methods", 1, true) then
            count = count + 1
        end
    end
    assert(count == 1, tostring(count))
end

function test_a_plan_with_nothing_in_it_still_draws_something()
    local lines = _drawn(plan.parse(""))
    assert(#lines > 0)
    assert(lines[1]:find("the plan", 1, true), lines[1])
end
