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
-- @file        window.lua
--

-- imports
import("harness.harness")
import("harness.context.window")
import("harness.core.session", {alias = "sessions"})

-- make a harness context for the tests
function _harness(contextconfig)
    local instance = harness.bootstrap({rootdir = os.tmpdir(), options = {context = contextconfig}})
    return instance
end

-- make a session with a long tool history
function _session(count, outputsize)
    local session = sessions.new({cwd = os.tmpdir()})
    for idx = 1, count do
        session:append("user", {text = "question " .. idx})
        session:append("assistant", {text = "", toolcalls = {{id = tostring(idx), name = "read_file"}}})
        session:append("tool", {id = tostring(idx), name = "read_file",
            arguments = {path = "src/file" .. idx .. ".c"},
            output = string.rep("x", outputsize)})
        session:append("assistant", {text = "answer " .. idx})
    end
    return session
end

function test_prune_old_results()
    local instance = _harness({prunethreshold = 0.0, keeprecent = 2, keepresults = 2, toolresultlimit = 100})
    local session = _session(10, 4000)
    local messages, stats = window.optimize(instance, session, session:messages())
    assert(stats.pruned > 0, "nothing was pruned")
    assert(stats.prunedtokens > 0)

    -- the recent results survive
    local last = messages[#messages - 1]
    assert(last.role == "tool" or messages[#messages].role == "assistant")
    for idx = #messages, 1, -1 do
        if messages[idx].role == "tool" then
            assert(#messages[idx].content == 4000, "the last tool result was pruned!")
            break
        end
    end
end

function test_dedup_reads()
    local instance = _harness({prunethreshold = 0.0, keeprecent = 1, keepresults = 1, toolresultlimit = 100000})
    local session = sessions.new({cwd = os.tmpdir()})
    for idx = 1, 6 do
        session:append("user", {text = "read it again"})
        session:append("assistant", {text = "", toolcalls = {{id = tostring(idx), name = "read_file"}}})
        session:append("tool", {id = tostring(idx), name = "read_file",
            arguments = {path = "src/same.c"}, output = string.rep("y", 3000)})
    end
    local _, stats = window.optimize(instance, session, session:messages())
    assert(stats.deduped > 0, "the superseded reads were not dropped")
end

function test_full_mode_keeps_everything()
    local instance = _harness({mode = "full", prunethreshold = 0.0})
    local session = _session(10, 4000)
    local messages, stats = window.optimize(instance, session, session:messages())
    assert(stats.pruned == 0 and stats.deduped == 0)
    assert(#messages == #session:messages())
end

function test_below_threshold_is_untouched()
    local instance = _harness({prunethreshold = 0.99})
    local session = _session(3, 500)
    local _, stats = window.optimize(instance, session, session:messages())
    assert(stats.pruned == 0)
end

function test_breakdown()
    local instance = _harness({})
    local session = _session(2, 200)
    local result = window.breakdown(instance, session, {})
    assert(result.limit > 0)
    assert(result.total > 0)
    assert(#result.sections >= 3)
    assert(#window.render(result, {width = 80}) > 3)
end

function test_a_full_window_does_not_stretch_the_bar()
    -- a conversation can be more than the window holds — that is what asks for
    -- the compaction — and a bar which grew past its own box to say so would
    -- wrap and take the rest of the panel with it
    local instance = _harness({})
    local session = _session(2, 200)
    local result = window.breakdown(instance, session, {})

    -- as if the conversation were half again as big as the window
    result.limit = math.max(1, math.floor(result.total / 1.5))
    result.ratio = result.total / result.limit
    assert(result.ratio > 1, tostring(result.ratio))

    local width = 60
    for _, line in ipairs(window.render(result, {width = width})) do
        local blocks = 0
        for _ in line:gmatch("█") do
            blocks = blocks + 1
        end
        for _ in line:gmatch("░") do
            blocks = blocks + 1
        end
        assert(blocks <= width, string.format("a bar of %d blocks in %d columns", blocks, width))
    end
end
