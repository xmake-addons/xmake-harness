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
-- @file        exec.lua
--

--
-- the process execution seam
--
-- every tool which spawns a process goes through this module, so the sandbox
-- wrapping, the timeout, the abort signal and the output capture live in one
-- place, and a remote/container backend can replace it later.
--

-- imports
import("core.base.process")
import("harness.util.util")
import("harness.sandbox.sandbox")

-- run a program and capture its output
--
-- @param context   the tool context
-- @param opt       the options
--                  - program   the program to run, e.g. "xmake"
--                  - argv      the arguments list
--                  - command   the shell command, it is used instead of the program/argv
--                  - cwd       the working directory
--                  - timeout   the timeout in milliseconds
--                  - nosandbox do not wrap it with the sandbox
--
-- @return          {output = "..", exitcode = 0, timedout = false, duration = 12}
--
function run(context, opt)
    opt = opt or {}
    local cwd = opt.cwd and path.absolute(opt.cwd, context.cwd) or context.cwd
    local timeout = math.min(opt.timeout or (context.config.tools or {}).timeout or 300000, 3600000)

    local program, argv
    if opt.command then
        program, argv = shell(), {shellflag(), opt.command}
    else
        program, argv = opt.program, opt.argv or {}
    end
    if not opt.nosandbox then
        program, argv = sandbox.wrap(context, program, argv)
    end

    local outfile = os.tmpfile()
    local errfile = os.tmpfile()
    local starttime = os.mclock()
    local proc, openerrors = process.openv(program, argv, {stdout = outfile, stderr = errfile,
        curdir = cwd, envs = _envs(opt.envs)})
    if not proc then
        os.tryrm(outfile)
        os.tryrm(errfile)
        raise("failed to run: %s (%s)", opt.command or program, openerrors or "unknown")
    end

    local exitcode = -1
    local timedout = false
    while true do
        local ok, status = proc:wait(200)
        if ok > 0 then
            exitcode = status or 0
            break
        elseif ok < 0 then
            break
        end
        if os.mclock() - starttime > timeout then
            timedout = true
            proc:kill()
            proc:wait(1000)
            break
        end
        if context.signal and context.signal.aborted then
            proc:kill()
            proc:wait(1000)
            os.tryrm(outfile)
            os.tryrm(errfile)
            raise("the command is interrupted by the user.")
        end
        if context.ontick then
            context.ontick()
        end
    end
    proc:close()

    local stdoutdata = os.isfile(outfile) and io.readfile(outfile) or ""
    local stderrdata = os.isfile(errfile) and io.readfile(errfile) or ""
    os.tryrm(outfile)
    os.tryrm(errfile)

    local outputs = {}
    if stdoutdata and stdoutdata:trim() ~= "" then
        table.insert(outputs, stdoutdata:trim())
    end
    if stderrdata and stderrdata:trim() ~= "" then
        table.insert(outputs, stderrdata:trim())
    end
    return {
        output = table.concat(outputs, "\n"),
        exitcode = exitcode,
        timedout = timedout,
        duration = os.mclock() - starttime
    }
end

-- convert the environment map to the `KEY=VALUE` list which process.openv expects
--
-- @param envs  the environment variables to override, e.g. {XMAKE_COLORTERM = "nocolor"}
--
function _envs(envs)
    if not envs then
        return nil
    end
    local envars = os.getenvs()
    for name, value in pairs(envs) do
        if type(value) == "table" then
            value = path.joinenv(value)
        end
        envars[name] = value
    end
    local results = {}
    for name, value in pairs(envars) do
        table.insert(results, name .. "=" .. value)
    end
    return results
end

-- get the shell program
function shell()
    if os.host() == "windows" then
        return os.getenv("COMSPEC") or "cmd"
    end
    return os.getenv("SHELL") or "/bin/sh"
end

-- get the shell flag which runs a command string
function shellflag()
    return os.host() == "windows" and "/c" or "-c"
end

-- get the xmake program which is running us
function xmakeprogram()
    local program = os.getenv("XMAKE_PROGRAM_FILE")
    if program and os.isexec(program) then
        return program
    end
    local tool = import("lib.detect.find_tool", {anonymous = true})("xmake")
    return tool and tool.program or "xmake"
end
