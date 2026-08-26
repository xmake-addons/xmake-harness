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
-- @file        xmakecmd.lua
--

--
-- the shared helper of the xmake tools
--
-- every tool of this plugin describes the command line it runs, and this module
-- turns it into a tool result: one place decides how xmake is invoked, how its
-- output is reported and what the card shows.
--

-- imports
import("harness.util.text")
import("harness.shell.exec")

-- get the command line of the given arguments, it is what the user sees
function commandline(argv)
    return table.concat(table.join({"xmake"}, argv), " ")
end

-- split an argument string, e.g. "-m debug --verbose"
function splitargs(str)
    local results = {}
    for item in (str or ""):gmatch("%S+") do
        table.insert(results, item)
    end
    return results
end

-- work on a project other than the one we are sitting in
--
-- `xmake create hello` leaves a project in a subdirectory, and every tool here
-- runs in the harness's own working directory: without this the thing which was
-- just created is the one thing which cannot be built
--
-- it is `-P <dir>` and it goes before the values, for the same reason `-y` does
--
function inproject(argv, dir)
    if dir and dir ~= "" then
        table.insert(argv, "-P")
        table.insert(argv, dir)
    end
    return argv
end

-- the arguments as they are really run: what the tool asked for, plus the
-- answer to whatever xmake is about to ask
--
-- xmake asks the user to confirm a few things, e.g. generating a missing
-- `xmake.lua` or installing the packages of a project. nobody is going to
-- answer here, so we always say yes and never let it wait.
--
-- it goes directly after the task name and not at the end, because the last
-- argument of most tasks is a value and not an option: `xmake build demo -y`
-- reads `-y` as a second target and fails with "'-y' is not a valid target
-- name", and `xrepo info zlib -y` looks for a package called `-y`
--
function confirmed(argv)
    local results = table.copy(argv or {})
    local position = 1
    if results[1] and not results[1]:startswith("-") then
        position = 2
    end
    table.insert(results, position, "-y")
    return results
end

-- run the given xmake command
--
-- @param context   the tool context
-- @param argv      the arguments, e.g. {"build", "-r"}
-- @param opt       the options, e.g. {timeout = 1800000, cwd = ".."}
--
-- @return          the tool result
--
function run(context, argv, opt)
    opt = opt or {}
    local result = exec.run(context, {
        program = exec.xmakeprogram(),
        argv = confirmed(argv),
        cwd = opt.cwd,
        timeout = opt.timeout,
        envs = {XMAKE_COLORTERM = "nocolor"}})

    local output = result.output
    if output == "" then
        output = result.exitcode == 0 and "(no output)" or string.format("(no output, exited with %d)", result.exitcode)
    end
    if result.exitcode ~= 0 then
        output = output .. string.format("\n\n[%s exited with %d]", commandline(argv), result.exitcode)
    end

    local lines = text.lines(output)
    return {
        output = output,
        iserror = result.exitcode ~= 0,
        display = {
            title = commandline(argv),
            summary = string.format("%s · %d line%s", result.exitcode == 0 and "ok" or "failed",
                #lines, #lines == 1 and "" or "s"),
            kind = "output",
            output = output
        }
    }
end
