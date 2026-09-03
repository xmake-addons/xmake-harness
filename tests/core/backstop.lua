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
-- @file        backstop.lua
--

-- imports
import("harness.harness")
import("harness.util.tokens")
import("harness.context.window")
import("harness.core.session", {alias = "sessions"})

-- a harness whose provider has a small window, so the limits are easy to reach
function _harness(contextconfig)
    return harness.bootstrap({rootdir = os.tmpdir(), options = {
        providers = {deepseek = {apikey = "sk-test", contextsize = 4000}},
        context = contextconfig}})
end

-- a session with big tool outputs
function _session(turns, outputsize)
    local session = sessions.new({cwd = os.tmpdir()})
    for idx = 1, turns do
        session:append("user", {text = "question " .. idx})
        session:append("assistant", {text = "", toolcalls = {{id = tostring(idx), name = "read_file"}}})
        session:append("tool", {id = tostring(idx), name = "read_file",
            arguments = {path = "src/file" .. idx .. ".c"}, output = string.rep("x", outputsize)})
        session:append("assistant", {text = "answer " .. idx})
    end
    return session
end

function test_the_projection_always_fits()
    -- whatever the history looks like, what we send must fit the window
    local instance = _harness({})
    local session = _session(20, 8000)
    local messages, stats = window.optimize(instance, session, session:messages())
    local used = tokens.calibrated(messages, "deepseek-chat")
    assert(used <= 4000 * 0.92, string.format("used %d, hard limit %d", used, math.floor(4000 * 0.92)))
    assert(stats.enforced, "the backstop did not run")
end

function test_the_backstop_keeps_the_recent_turns()
    local instance = _harness({})
    local session = _session(20, 8000)
    local messages = window.optimize(instance, session, session:messages())
    assert(#messages >= 4, "everything was dropped: " .. #messages)

    -- the last message of the log is still the last message we send
    local events = session:messages()
    assert(messages[#messages].content == events[#events].content)
end

function test_full_mode_is_not_enforced()
    -- `full` means the user takes the risk on purpose
    local instance = _harness({mode = "full"})
    local session = _session(20, 8000)
    local messages, stats = window.optimize(instance, session, session:messages())
    assert(not stats.enforced)
    assert(#messages == #session:messages())
end

function test_small_sessions_are_untouched()
    local instance = _harness({})
    local session = _session(2, 100)
    local messages, stats = window.optimize(instance, session, session:messages())
    assert(#messages == #session:messages())
    assert(not stats.enforced)
end

function test_calibration_tightens_the_estimate()
    local model = "test-model-" .. os.time()
    assert(tokens.factor(model) == 1)

    -- the provider says we were sending 50% more than we thought
    for _ = 1, 10 do
        tokens.observe(model, 1000, 1500)
    end
    local factor = tokens.factor(model)
    assert(factor > 1.4 and factor < 1.6, "factor: " .. factor)

    local messages = {{role = "user", content = string.rep("a", 4000)}}
    assert(tokens.calibrated(messages, model) > tokens.estimate_messages(messages))
end

function test_calibration_clamps_outliers()
    local model = "test-outlier-" .. os.time()
    tokens.observe(model, 1000, 100000)
    assert(tokens.factor(model) <= 2.5, "factor: " .. tokens.factor(model))
    tokens.observe(model, 1000, 0)
    assert(tokens.factor(model) <= 2.5)
end
