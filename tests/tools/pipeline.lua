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
-- @file        pipeline.lua
--

-- imports
import("harness.harness")
import("harness.tools.pipeline")
import("harness.core.session", {alias = "sessions"})

-- a project with one header in it, and a context to run tool calls against
function _context(opt)
    opt = opt or {}
    local rootdir = os.tmpfile() .. ".pipeline"
    os.mkdir(rootdir)
    io.writefile(path.join(rootdir, "a.h"), "#pragma once\n")

    local instance = harness.bootstrap({rootdir = rootdir, trusted = true})
    return {harness = instance, config = instance:config(), cwd = rootdir,
            session = sessions.new({cwd = rootdir}), signal = {},
            mode = opt.mode or "bypass", depth = 0, ui = opt.ui or {}}, rootdir
end

-- run one call, as the model would have written it
function _call(context, name, arguments)
    return pipeline.execute(context, {id = "1", name = name, arguments_text = arguments})
end

---------------------------------------------------------------------------------
-- the arguments the model left out
---------------------------------------------------------------------------------

function test_a_missing_argument_names_itself()
    local result = _call(_context(), "edit_file",
                         '{"old_string":"a","new_string":"b"}')
    assert(result.iserror)

    -- the tool and the argument, because "the path is required!" says neither
    assert(result.output:find("edit_file", 1, true), result.output)
    assert(result.output:find("path", 1, true), result.output)
end

function test_more_than_one_of_them()
    local result = _call(_context(), "edit_file", '{"path":"a.h"}')
    assert(result.iserror)
    assert(result.output:find("old_string", 1, true), result.output)
    assert(result.output:find("new_string", 1, true), result.output)
end

function test_an_empty_argument_is_not_a_missing_one()
    -- `edit_file` requires `new_string`, and an empty one is how the model
    -- deletes the old text: refusing it would refuse a whole kind of edit
    local context, rootdir = _context()
    local result = _call(context, "edit_file",
                         '{"path":"a.h","old_string":"#pragma once","new_string":""}')
    assert(not result.iserror, result.output)
    assert(io.readfile(path.join(rootdir, "a.h")) == "\n",
           string.format("%q", io.readfile(path.join(rootdir, "a.h"))))
end

function test_the_calls_which_are_complete_are_left_alone()
    local context, rootdir = _context()
    local result = _call(context, "edit_file",
        '{"path":"a.h","old_string":"#pragma once","new_string":"#pragma once\\nint x;"}')
    assert(not result.iserror, result.output)
    assert(io.readfile(path.join(rootdir, "a.h")):find("int x;", 1, true))
end

---------------------------------------------------------------------------------
-- and the ones which go wrong further in
---------------------------------------------------------------------------------

function test_a_tool_which_throws_is_a_failed_call_and_not_a_failed_turn()
    -- an empty path is not a missing one, so nothing catches it until `fs`
    -- does, by raising. that must reach the model, which can correct it
    local result = _call(_context(), "edit_file",
                         '{"path":"","old_string":"a","new_string":"b"}')
    assert(result.iserror)
    assert(result.output ~= "")
    assert(result.id == "1")
    assert(result.name == "edit_file")
end

function test_a_tool_nobody_has_heard_of()
    local result = _call(_context(), "no_such_tool", "{}")
    assert(result.iserror)
    assert(result.output:find("no_such_tool", 1, true), result.output)
end

function test_arguments_which_are_not_json()
    local result = _call(_context(), "read_file", "not json at all")
    assert(result.iserror)
end

---------------------------------------------------------------------------------
-- what the dialog is decorated with
---------------------------------------------------------------------------------

function test_a_preview_which_throws_still_asks()
    -- the preview reads the model's arguments too, and a dialog which cannot
    -- be decorated must still be asked, or nobody is asked anything again
    local asked = {}
    local context = _context({mode = "default", ui = {confirm = function (request)
        table.insert(asked, {name = request.tool.name, preview = request.preview})
        return "allow"
    end}})

    local result = _call(context, "edit_file",
                         '{"path":"","old_string":"a","new_string":"b"}')
    assert(#asked == 1, tostring(#asked))
    assert(asked[1].name == "edit_file")
    assert(asked[1].preview == nil)

    -- and the call itself still comes back as an error rather than a crash
    assert(result.iserror)
end
