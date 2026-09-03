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
-- @file        language.lua
--

-- imports
import("harness.util.language")
import("harness.core.session", {alias = "sessions"})

function test_english()
    assert(language.detect("build the project and run the tests") == "en")
    assert(language.detect("") == "en")
    assert(language.detect("xmake f -m debug") == "en")
end

function test_chinese()
    local name, label = language.detect("帮我编译一下这个工程")
    assert(name == "zh", name)
    assert(label == "Chinese", label)
end

function test_mixed_code_stays_english()
    -- a command with one stray character is not a chinese question
    assert(language.detect("run `xmake build` now") == "en")
end

function test_mixed_prose_is_detected()
    assert(language.detect("帮我看下 xmake.lua 里的 add_requires 配置") == "zh")
end

function test_session_follows_the_recent_messages()
    local session = sessions.new({cwd = os.tmpdir()})
    session:append("user", {text = "hello, build it"})
    assert(language.ofsession(session) == "en")

    session:append("user", {text = "编译失败了，帮我看下"})
    assert(language.ofsession(session) == "zh")

    -- the user switches back
    session:append("user", {text = "ok, now run the tests"})
    session:append("user", {text = "and format the sources"})
    session:append("user", {text = "then commit it"})
    assert(language.ofsession(session) == "en")
end

function test_session_without_messages()
    assert(language.ofsession(sessions.new({cwd = os.tmpdir()})) == "en")
    assert(language.ofsession(nil) == "en")
end
