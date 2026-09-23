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
--                  - command   the shell command, it replaces the program/argv
--                  - cwd       the working directory
--                  - timeout   the timeout in milliseconds
--                  - envs      the environment variables to override
--                  - stdin     the input, the null device by default
--                  - nosandbox do not wrap it with the sandbox
--
-- @return          {output = "..", exitcode = 0, timedout = false, duration = 12}
--
function run(context, opt)
    opt = opt or {}
    local program, argv = _argv(context, opt)
    local outfile = os.tmpfile()
    local errfile = os.tmpfile()

    -- the command never gets our terminal
    --
    -- a tool which inherits the stdin can stop and wait for an answer nobody is
    -- going to type: it would hold the terminal we are drawing on, eat the keys
    -- we need for the interrupt, and hang until the timeout. reading from the
    -- null device makes such a prompt fail at once instead
    --
    local starttime = os.mclock()
    local curdir = opt.cwd and path.absolute(opt.cwd, context.cwd) or context.cwd
    local proc, openerrors = _openv(program, argv, {
        stdin = opt.stdin or os.nuldev(),
        stdout = outfile, stderr = errfile,
        curdir = curdir,
        envs = _envs(opt.envs)})
    if not proc then
        os.tryrm(outfile)
        os.tryrm(errfile)
        raise("%s", spawnfailed(program, argv, curdir, openerrors))
    end

    local exitcode, timedout, detached = _wait(context, proc, opt, starttime, {outfile, errfile})

    -- the user asked for it to go on without them, so it keeps the process and
    -- the file it is writing into: whoever adopts it owns them now
    if detached then
        return {detached = true, proc = proc, outfile = outfile, errfile = errfile,
                duration = os.mclock() - starttime}
    end

    proc:close()
    local output = _output(outfile, errfile)
    os.tryrm(outfile)
    os.tryrm(errfile)
    return {
        output = output,
        exitcode = exitcode,
        timedout = timedout,
        duration = os.mclock() - starttime
    }
end

-- start a program and leave it running
--
-- the caller owns what comes back: it has to poll it, read it and reap it,
-- @see harness.shell.jobs. both streams go into one file, because a log which
-- interleaves them the way the terminal would is what somebody reading it later
-- actually wants
--
-- @return  {proc = .., outfile = ..}, or nil and the errors
--
function start(context, opt)
    opt = opt or {}
    local program, argv = _argv(context, opt)
    local outfile = os.tmpfile()
    local curdir = opt.cwd and path.absolute(opt.cwd, context.cwd) or context.cwd
    local proc, errors = _openv(program, argv, {
        stdin = opt.stdin or os.nuldev(),
        stdout = outfile, stderr = outfile,
        curdir = curdir,
        envs = _envs(opt.envs)})
    if not proc then
        os.tryrm(outfile)
        return nil, spawnfailed(program, argv, curdir, errors)
    end
    return {proc = proc, outfile = outfile}
end

-- start a process, and come back rather than raising when it will not start
--
-- the sandbox raises out of `process.openv`, so the `if not proc` which every
-- caller writes is unreachable and the reason reaches the user as whatever the
-- raise said — which, when the spawn itself failed, is `openv process(..)
-- failed!` and nothing else
--
-- @return  the process, or nil and the errors
--
function _openv(program, argv, opt)
    local proc, errors
    try {
        function ()
            proc, errors = process.openv(program, argv, opt)
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }
    return proc, errors
end

-- why it could not be started
--
-- `openv process(C:\Program Files\Git\cmd\git.exe, clone ..) failed!` is the
-- whole of what the platform gives us: no errno, and on windows the call which
-- failed is CreateProcess, which fails for a dozen reasons that look identical
-- from here.
--
-- so we ask the questions we can answer and say which ones came back wrong. a
-- message which names the directory that is not there, or the dll which is
-- missing, is the difference between a bug report and a fix
--
function spawnfailed(program, argv, curdir, errors)
    local reasons = {}
    if not program or program == "" then
        table.insert(reasons, "there is no program to run")
    elseif not os.isfile(program) and not _onpath(program) then
        table.insert(reasons, string.format("`%s` is not there", program))
    elseif os.isfile(program) and not os.isexec(program) then
        table.insert(reasons, string.format("`%s` is not executable", program))
    end
    if curdir and not os.isdir(curdir) then
        table.insert(reasons, string.format("its working directory `%s` does not exist", curdir))
    end
    for _, dll in ipairs(_missingdlls(program)) do
        table.insert(reasons, string.format("`%s` needs `%s`, which is not on the path", program, dll))
    end

    -- windows takes the program and every argument as one string and stops at
    -- 32767 characters of it. a long file list gets there
    local length = #tostring(program or "")
    for _, arg in ipairs(argv or {}) do
        length = length + #tostring(arg) + 3
    end
    if length > 30000 then
        table.insert(reasons, string.format("the command line is %d characters, "
            .. "which is past what windows will take", length))
    end

    if #reasons == 0 then
        return string.format("%s\nthe program is there and so is its directory, so the "
            .. "system refused to start it for a reason it did not give.",
            tostring(errors or "the process could not be started"))
    end
    return string.format("%s could not be started: %s", program, table.concat(reasons, "; "))
end

-- is it a bare name which the path will resolve?
function _onpath(program)
    if program:find("[/\\]") then
        return false
    end
    return os.getenv("PATH") ~= nil
end

-- the libraries it needs and cannot find
--
-- this is the windows answer more often than anything else here, and it is the
-- one nothing else will tell you: the exe is there, it is executable, and it
-- will not start. every part of it is guarded — working out why a spawn failed
-- must not be a second thing which fails
--
function _missingdlls(program)
    if os.host() ~= "windows" or not program or not os.isexec(program) then
        return {}
    end
    local missing = {}
    try {
        function ()
            local deplibs = import("utils.binary.deplibs", {anonymous = true, try = true})
            if not deplibs then
                return
            end
            local paths = path.splitenv(os.getenv("PATH") or "")
            table.insert(paths, 1, path.directory(program))
            for _, library in ipairs(deplibs(program, {recursive = false}) or {}) do
                local name = path.filename(library)
                local found = false
                for _, dir in ipairs(paths) do
                    if os.isfile(path.join(dir, name)) then
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(missing, name)
                end
            end
        end
    }
    return missing
end

-- get the program and the arguments to spawn
function _argv(context, opt)
    local program, argv
    if opt.command then
        program, argv = shell(), {shellflag(), opt.command}
    else
        program, argv = opt.program, opt.argv or {}
    end
    if opt.nosandbox then
        return program, argv
    end
    return sandbox.wrap(context, program, argv)
end

-- wait for the process
--
-- @return  the exit code, whether it timed out, and whether the user detached it
--
function _wait(context, proc, opt, starttime, tmpfiles)
    local timeout = math.min(opt.timeout or (context.config.tools or {}).timeout or 300000, 3600000)
    while true do
        -- one short wait at a time, so the ui stays alive and the user can
        -- interrupt a long command
        local ok, status = proc:wait(200)
        if ok > 0 then
            return status or 0, false
        elseif ok < 0 then
            return -1, false
        end
        if os.mclock() - starttime > timeout then
            _kill(proc)
            return -1, true
        end
        -- ctrl+b: stop waiting, but leave it running
        if context.signal and context.signal.background then
            context.signal.background = false
            return 0, false, true
        end
        if context.signal and context.signal.aborted then
            _kill(proc)
            proc:close()
            for _, filepath in ipairs(tmpfiles) do
                os.tryrm(filepath)
            end
            raise("the command is interrupted by the user.")
        end
        if context.ontick then
            context.ontick()
        end
    end
end

-- kill the process and reap it
function _kill(proc)
    proc:kill()
    proc:wait(1000)
end

-- read what the process wrote
function _output(outfile, errfile)
    local outputs = {}
    for _, filepath in ipairs({outfile, errfile}) do
        local data = os.isfile(filepath) and io.readfile(filepath) or nil
        if data and data:trim() ~= "" then
            table.insert(outputs, data:trim())
        end
    end
    return table.concat(outputs, "\n")
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
        envars[name] = type(value) == "table" and path.joinenv(value) or value
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
