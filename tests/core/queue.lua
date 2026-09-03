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
-- @file        queue.lua
--

--
-- what is typed while the harness is busy
--
-- a turn cannot be interleaved with another one and a clone cannot be paused, so
-- the answer to somebody typing during either is to keep it and send it after.
-- swallowing the key instead is the worst of the three: the message looks sent,
-- and it never was.
--

-- imports
import("harness.harness")
import("harness.ui.app", {alias = "uiapp"})
import("harness.ui.editor")
import("harness.core.session", {alias = "sessions"})

function _app()
    local rootdir = os.tmpfile() .. ".queue"
    os.mkdir(rootdir)
    local instance = harness.bootstrap({rootdir = rootdir, trusted = true})
    return uiapp.new(instance, sessions.new({cwd = rootdir}), "acceptedits",
                     editor.new(), {aborted = false})
end

function _typed(app, text)
    app.editor:insert(text)
    return app:queue()
end

---------------------------------------------------------------------------------
-- queuing it
---------------------------------------------------------------------------------

function test_what_was_typed_is_kept_and_the_editor_is_cleared()
    local app = _app()
    assert(_typed(app, "build it") == "build it")
    assert(app.editor:text() == "", string.format("%q", app.editor:text()))
end

function test_they_come_back_in_the_order_they_were_typed()
    local app = _app()
    _typed(app, "build it")
    _typed(app, "and test it")
    assert(app:dequeue() == "build it")
    assert(app:dequeue() == "and test it")
    assert(app:dequeue() == nil, "and then there are none")
end

function test_an_empty_line_is_not_a_message()
    local app = _app()
    assert(_typed(app, "   ") == nil)
    assert(app:dequeue() == nil)
end

function test_a_trailing_backslash_goes_on_instead_of_being_sent()
    -- the same continuation the editor has when nothing is running, so that a
    -- line which was meant to be two does not leave as one half of one
    local app = _app()
    assert(_typed(app, "one \\") == nil, "it was not queued")
    assert(app.editor:text() == "one \n", string.format("%q", app.editor:text()))
    app.editor:insert("two")
    assert(app:queue() == "one \ntwo")
end

function test_it_goes_into_the_history_like_anything_else_typed()
    local app = _app()
    _typed(app, "build it")
    assert(app.editor:history()[#app.editor:history()] == "build it",
           table.concat(app.editor:history(), "|"))
end

---------------------------------------------------------------------------------
-- and showing it
---------------------------------------------------------------------------------

function test_the_queue_is_visible_while_it_waits()
    -- the editor is cleared when it is queued, so without a line for it pressing
    -- enter looks exactly like pressing nothing
    local app = _app()
    _typed(app, "run the tests afterwards")
    local shown = false
    for _, line in ipairs(app:_livelines()) do
        if line:find("run the tests afterwards", 1, true) then
            shown = true
        end
    end
    assert(shown, "it is on the screen somewhere")
end

function test_a_long_one_does_not_break_the_layout()
    local app = _app()
    _typed(app, string.rep("a very long instruction ", 40))
    for _, line in ipairs(app:_livelines()) do
        assert(#line < 4000, string.format("a line of %d bytes", #line))
    end
end
