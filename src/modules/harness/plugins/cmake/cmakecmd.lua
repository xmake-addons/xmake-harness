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
-- @file        cmakecmd.lua
--

--
-- the shared helper of the cmake tools
--
-- every tool of this plugin describes the arguments it runs with, and this
-- module turns them into a tool result: one place decides how the program is
-- invoked and what the card shows.
--

-- imports
import("harness.util.text")
import("harness.shell.exec")
import("lib.detect.find_tool")

-- get the command line of the given call, it is what the user sees
function commandline(program, argv)
    return program .. " " .. table.concat(argv, " ")
end

-- split an argument string, e.g. "-DCMAKE_BUILD_TYPE=Debug -Wdev"
function splitargs(str)
    local results = {}
    for item in (str or ""):gmatch("%S+") do
        table.insert(results, item)
    end
    return results
end

-- run the given program
--
-- @param context   the tool context
-- @param program   the program name, e.g. "cmake"
-- @param argv      the arguments
-- @param opt       the options, e.g. {timeout = 1800000}
--
-- @return          the tool result
--
function run(context, program, argv, opt)
    opt = opt or {}
    local tool = find_tool(program)
    if not tool then
        raise("%s is not found!", program)
    end

    local result = exec.run(context, {program = tool.program, argv = argv, timeout = opt.timeout})
    local output = result.output ~= "" and result.output or "(no output)"
    if result.exitcode ~= 0 then
        output = output .. string.format("\n\n[%s exited with %d]", program, result.exitcode)
    end
    return {
        output = output,
        iserror = result.exitcode ~= 0,
        display = {
            title = commandline(program, argv),
            summary = string.format("%s · %d line%s", result.exitcode == 0 and "ok" or "failed",
                #text.lines(output), #text.lines(output) == 1 and "" or "s"),
            kind = "output",
            output = output
        }
    }
end
