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
-- @file        session.lua
--

-- imports
import("harness.core.session", {alias = "sessions"})

function test_append()
    local session = sessions.new({cwd = "/tmp"})
    session:append("user", {text = "hello"})
    session:append("assistant", {text = "hi"})
    assert(#session:events() == 2)
    assert(session:events()[1].seq == 1)
end

function test_messages()
    local session = sessions.new({cwd = "/tmp"})
    session:append("user", {text = "hello"})
    session:append("assistant", {text = "", toolcalls = {{id = "1", name = "read_file", arguments_text = "{}"}}})
    session:append("tool", {id = "1", name = "read_file", output = "content"})
    session:append("assistant", {text = "done"})
    local messages = session:messages()
    assert(#messages == 4, "messages: " .. #messages)
    assert(messages[1].role == "user")
    assert(messages[3].role == "tool" and messages[3].toolcallid == "1")
    assert(messages[4].content == "done")
end

function test_notice_is_local()
    local session = sessions.new({cwd = "/tmp"})
    session:append("user", {text = "hello"})
    session:append("notice", {text = "interrupted"})
    assert(#session:messages() == 1)
end

function test_compact()
    local session = sessions.new({cwd = "/tmp"})
    for idx = 1, 5 do
        session:append("user", {text = "question " .. idx})
        session:append("assistant", {text = "answer " .. idx})
    end
    local dropped = session:compact("the summary", 4)
    assert(dropped > 0)
    local messages = session:messages()
    assert(messages[1].content == "the summary")
    assert(#messages <= 8, "messages: " .. #messages)
end

function test_usage()
    local session = sessions.new({cwd = "/tmp"})
    session:usage_update({input = 100, output = 20, cachehit = 80, cachemiss = 20})
    session:usage_update({input = 100, output = 20, cachehit = 90, cachemiss = 10})
    local usage = session:usage()
    assert(usage.input == 200 and usage.output == 40)
    assert(usage.requests == 2)
    local rate = session:cacherate()
    assert(rate > 0.8 and rate < 0.9, tostring(rate))
end

function test_saveload()
    local session = sessions.new({cwd = "/tmp", title = "the test session"})
    session:append("user", {text = "hello"})
    session:save()
    local loaded = sessions.load(session:id())
    assert(loaded ~= nil)
    assert(loaded:title() == "the test session")
    assert(#loaded:events() == 1)
    os.tryrm(session:filepath())
end
