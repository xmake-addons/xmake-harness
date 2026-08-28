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
-- @file        gitpack.lua
--

-- imports
import("lib.detect.find_tool")
import("harness.util.gitpack")

function _context(opt)
    opt = opt or {}
    return {config = {}, cwd = os.curdir(), signal = opt.signal, ontick = opt.ontick}
end

---------------------------------------------------------------------------------
-- a clone is a process like any other
---------------------------------------------------------------------------------

function test_the_output_comes_back()
    local git = find_tool("git")
    if not git then
        return
    end
    local ok, errors, output = gitpack.run(git, {"--version"}, {context = _context()})
    assert(ok, tostring(errors))
    assert(output and output:find("git version", 1, true), tostring(output))
end

function test_a_failure_is_reported_and_not_raised()
    -- it used to be `os.iorunv`, which raises: every caller then had to wrap it
    -- and none of them could say what git actually complained about
    local git = find_tool("git")
    if not git then
        return
    end
    local ok, errors = gitpack.run(git, {"not-a-subcommand"}, {context = _context()})
    assert(not ok, "it fails")
    assert(errors and errors ~= "", "and says why")
end

function test_it_can_be_interrupted()
    -- this is the whole point: a clone of a large repository over a slow line
    -- used to freeze the terminal for a minute with no way out, because the key
    -- which would interrupt it was never read
    if os.host() == "windows" then
        return
    end
    local sleep = find_tool("sleep")
    if not sleep then
        return
    end

    local ticks = 0
    local signal = {aborted = false}
    local starttime = os.mclock()
    local errors
    local ok = try {
        function ()
            gitpack.run(sleep, {"10"}, {context = _context({
                signal = signal,
                ontick = function ()
                    -- the terminal is alive while it waits, and this is what
                    -- reads the escape key in the real one
                    ticks = ticks + 1
                    signal.aborted = true
                end})})
            return true
        end,
        catch {function (errs) errors = tostring(errs) end}
    }
    local spent = os.mclock() - starttime
    assert(not ok, "it did not run to the end")
    assert(errors and errors:find("interrupted", 1, true), tostring(errors))
    assert(ticks > 0, "the tick ran while it waited")
    assert(spent < 3000, string.format("it stopped at once, not in %dms", spent))
end

function test_it_cannot_outlast_its_timeout()
    if os.host() == "windows" then
        return
    end
    local sleep = find_tool("sleep")
    if not sleep then
        return
    end
    local starttime = os.mclock()
    local ok, errors = gitpack.run(sleep, {"10"}, {context = _context(), timeout = 400})
    local spent = os.mclock() - starttime
    assert(not ok, "it was stopped")
    assert(errors and errors:find("longer than", 1, true), tostring(errors))
    assert(spent < 3000, string.format("and stopped near the timeout, not in %dms", spent))
end

function test_backgrounding_it_stops_it_instead_of_leaking_it()
    -- ctrl+b detaches a slow tool call and lets it finish on its own; a clone
    -- cannot, because whoever asked for it is waiting to use what it fetches
    if os.host() == "windows" then
        return
    end
    local sleep = find_tool("sleep")
    if not sleep then
        return
    end
    local signal = {aborted = false, background = false}
    local starttime = os.mclock()
    local ok, errors = gitpack.run(sleep, {"10"}, {context = _context({
        signal = signal,
        ontick = function () signal.background = true end})})
    assert(not ok, "it did not run to the end")
    assert(errors and errors:find("stopped", 1, true), tostring(errors))
    assert(os.mclock() - starttime < 3000, "and it stopped at once")
end

---------------------------------------------------------------------------------
-- and one which nobody waits for
---------------------------------------------------------------------------------

-- a git repository on this machine, so that this is not a test about the network
function _origin()
    local git = find_tool("git")
    if not git then
        return nil
    end
    local dir = os.tmpfile() .. ".origin"
    os.mkdir(dir)
    local ok = try {
        function ()
            os.iorunv(git.program, {"init", "-q", dir})
            io.writefile(path.join(dir, "README.md"), "hello\n")
            os.iorunv(git.program, {"-C", dir, "add", "."})
            os.iorunv(git.program, {"-C", dir, "-c", "user.email=a@b", "-c", "user.name=a",
                                    "commit", "-qm", "one"})
            return true
        end
    }
    return ok and dir or nil
end

function test_a_fetch_can_be_left_to_run()
    -- a clone is minutes of network and none of it is anybody's turn to speak:
    -- the harness hands it to the job store and goes on
    local jobs = import("harness.shell.jobs", {anonymous = true})
    local origin = _origin()
    if not origin then
        return
    end
    local target = os.tmpfile() .. ".copy"
    local store = jobs.new()

    local landed, reported
    local starttime = os.mclock()
    local job, errors = gitpack.start({
        url = origin,
        dir = target,
        jobs = store,
        context = _context(),
        label = "the test repository",
        onfinish = function (ok, errs, thejob)
            landed = ok
            reported = errs
            thejob.summary = ok and "the test repository is ready" or tostring(errs)
        end})
    assert(job, tostring(errors))
    assert(os.mclock() - starttime < 1000, "it came back at once")
    assert(job.status == "running", job.status)
    assert(jobs.running(store) == 1, tostring(jobs.running(store)))

    -- and the harness is free to do something else while it runs
    local turns = 0
    while jobs.running(store) > 0 and turns < 500 do
        turns = turns + 1
        os.sleep(20)
    end
    assert(landed, tostring(reported))
    assert(os.isfile(path.join(target, "README.md")), "what it fetched is there")

    -- whoever is watching the screen is told once, and with what it was for
    local finished = jobs.finished(store)
    assert(#finished == 1, tostring(#finished))
    assert(finished[1].summary == "the test repository is ready", tostring(finished[1].summary))
    assert(#jobs.finished(store) == 0, "and only once")
end

function test_a_fetch_which_fails_says_so_when_it_lands()
    local jobs = import("harness.shell.jobs", {anonymous = true})
    if not find_tool("git") then
        return
    end
    local store = jobs.new()
    local errors
    local job = gitpack.start({
        url = os.tmpfile() .. ".nothing-is-here",
        dir = os.tmpfile() .. ".copy",
        jobs = store,
        context = _context(),
        onfinish = function (ok, errs) errors = ok and "" or (errs or "?") end})
    assert(job, "it starts")
    local turns = 0
    while jobs.running(store) > 0 and turns < 500 do
        turns = turns + 1
        os.sleep(20)
    end
    assert(errors and errors ~= "", "it says what git said")
end

function test_the_job_shows_the_command_it_is_running()
    local jobs = import("harness.shell.jobs", {anonymous = true})
    local origin = _origin()
    if not origin then
        return
    end
    local store = jobs.new()
    local job = gitpack.start({url = origin, dir = os.tmpfile() .. ".copy",
                               jobs = store, context = _context()})
    assert(job and job.command and job.command:startswith("git clone"), tostring(job and job.command))
    jobs.kill(store, job.id, "the test is over")
end
