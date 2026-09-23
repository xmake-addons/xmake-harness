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

---------------------------------------------------------------------------------
-- an output too big to show
---------------------------------------------------------------------------------

import("harness.tools.registry", {alias = "toolregistry"})

-- a context whose one tool returns however many bytes it is asked for
function _noisy(bytes)
    local context, rootdir = _context()
    local tools = toolregistry.new()
    tools:add({
        name = "noisy", permission = "none", description = "it says a lot",
        parameters = {type = "object", properties = {}},
        run = function ()
            local out = {}
            local index = 0
            while #table.concat(out, "\n") < bytes do
                index = index + 1
                table.insert(out, string.format("line %d: something happened here", index))
            end
            return {output = table.concat(out, "\n")}
        end})
    context.harness:service("tools", tools)
    return context, rootdir
end

function test_a_small_output_is_left_alone()
    local context = _noisy(200)
    local result = _call(context, "noisy", "{}")
    assert(not result.truncated, "nothing was cut")
    assert(not result.spilled, "and nothing was written down")
    assert(result.output:find("line 1:", 1, true), result.output)
end

function test_an_output_too_big_to_show_is_written_down()
    -- it used to be cut off at the limit and the rest thrown away, which tells
    -- the model the answer is incomplete and gives it no way to complete it
    local context = _noisy(200 * 1024)
    local result = _call(context, "noisy", "{}")

    assert(result.truncated and result.truncated > 200 * 1024, tostring(result.truncated))
    assert(result.spilled, "it went somewhere")
    assert(os.isfile(result.spilled), result.spilled)

    -- all of it, and not the part which fitted
    assert(os.filesize(result.spilled) == result.truncated,
           string.format("%d vs %d", os.filesize(result.spilled) or -1, result.truncated))
end

function test_the_model_is_told_where_it_is_and_how_to_read_it()
    local context = _noisy(200 * 1024)
    local result = _call(context, "noisy", "{}")

    assert(result.output:find(result.spilled, 1, true), "it names the file")
    assert(result.output:find("read_file", 1, true), "and the tool which opens it")
    assert(result.output:find("offset", 1, true), "and that it takes a window")

    -- with enough of it to decide what to read
    assert(result.output:find("line 1:", 1, true), "the head is there")
    assert(#result.output < 16 * 1024, tostring(#result.output))
end

function test_what_is_written_down_is_beside_the_conversation()
    local context = _noisy(200 * 1024)
    local result = _call(context, "noisy", "{}")
    assert(result.spilled:find("outputs", 1, true), result.spilled)
    assert(result.spilled:find(context.session:id(), 1, true), result.spilled)
    assert(result.spilled:find("noisy", 1, true), result.spilled)
end

function test_it_can_really_be_read_back()
    -- the envelope is a promise and this is the promise being kept
    local context = _noisy(200 * 1024)
    local result = _call(context, "noisy", "{}")

    local tools = toolregistry.new()
    tools:load_builtin()
    context.harness:service("tools", tools)

    local read = pipeline.execute(context, {id = "2", name = "read_file",
        arguments = {path = result.spilled, offset = 900, limit = 3}})
    assert(not read.iserror, read.output)
    assert(read.output:find("line 900:", 1, true), read.output)
end

function test_nowhere_to_write_it_is_still_said_plainly()
    local context = _noisy(200 * 1024)
    context.session = nil
    local result = _call(context, "noisy", "{}")
    assert(result.truncated)
    assert(not result.spilled)
    assert(result.output:find("could not be written down", 1, true), result.output)
end
