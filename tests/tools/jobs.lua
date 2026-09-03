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
-- @file        jobs.lua
--

-- imports
import("harness.harness")
import("harness.shell.jobs")

-- a context which can spawn
function _context()
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    return {harness = instance, config = instance:config(), cwd = os.tmpdir()}
end

-- start a shell command in the background
function _start(store, command)
    local job, errors = jobs.start(store, _context(), {command = command, label = "a test job"})
    assert(job ~= nil, tostring(errors))
    return job
end

-- wait until the job settles, or give up
function _settle(store, job)
    for _ = 1, 200 do
        jobs.poll(store)
        if job.status ~= "running" then
            return job
        end
        os.sleep(50)
    end
    return job
end

function test_a_job_starts_and_gets_an_id()
    local store = jobs.new()
    local job = _start(store, "echo hello")
    assert(job.id == "1")
    assert(job.status == "running" or job.status == "exited")
    jobs.shutdown(store)
end

function test_the_ids_keep_counting()
    local store = jobs.new()
    _start(store, "echo one")
    local second = _start(store, "echo two")
    assert(second.id == "2")
    assert(#jobs.list(store) == 2)
    jobs.shutdown(store)
end

function test_polling_never_blocks()
    -- xmake waits forever on a zero timeout, so a poll must not use one
    local store = jobs.new()
    local job = _start(store, "sleep 5")
    local start = os.mclock()
    jobs.poll(store)
    local elapsed = os.mclock() - start
    assert(elapsed < 1000, string.format("the poll took %dms, it must not wait", elapsed))
    assert(job.status == "running")
    jobs.shutdown(store)
end

function test_the_exit_code_is_kept()
    local store = jobs.new()
    local job = _settle(store, _start(store, "exit 3"))
    assert(job.status == "exited", job.status)
    assert(job.exitcode == 3, tostring(job.exitcode))
    jobs.shutdown(store)
end

function test_a_read_only_returns_what_is_new()
    local store = jobs.new()
    local job = _start(store, "echo first; sleep 1; echo second")
    -- the first line is there long before the second one
    for _ = 1, 40 do
        os.sleep(50)
        if (jobs.read(job).text or ""):find("first", 1, true) then
            break
        end
    end
    _settle(store, job)
    local rest = jobs.read(job).text
    assert(rest:find("second", 1, true), "the second read must bring what arrived since")
    assert(not rest:find("first", 1, true), "the second read must not repeat what was already read")
    jobs.shutdown(store)
end

function test_a_finished_job_is_announced_once()
    local store = jobs.new()
    local job = _settle(store, _start(store, "echo done"))
    local pending = jobs.pending(store)
    assert(#pending == 1 and pending[1].id == job.id)
    jobs.reported(job)
    assert(#jobs.pending(store) == 0, "it must not be announced twice")
    jobs.shutdown(store)
end

function test_a_running_job_is_not_announced()
    local store = jobs.new()
    _start(store, "sleep 5")
    assert(#jobs.pending(store) == 0)
    jobs.shutdown(store)
end

function test_a_job_can_be_killed()
    local store = jobs.new()
    local job = _start(store, "sleep 30")
    local killed = jobs.kill(store, job.id, "the test is over")
    assert(killed.status == "killed", killed.status)
    assert(jobs.status(killed):find("killed", 1, true))
    jobs.shutdown(store)
end

function test_killing_an_unknown_job_says_so()
    local store = jobs.new()
    local job, errors = jobs.kill(store, "42")
    assert(job == nil and errors:find("no job", 1, true), tostring(errors))
end

function test_the_running_count()
    local store = jobs.new()
    _start(store, "sleep 5")
    _settle(store, _start(store, "echo quick"))
    assert(jobs.running(store) == 1, tostring(jobs.running(store)))
    jobs.shutdown(store)
end

function test_shutdown_stops_everything()
    -- a job left behind would be a process the user never started and cannot see
    local store = jobs.new()
    local job = _start(store, "sleep 30")
    jobs.shutdown(store)
    assert(job.status ~= "running", job.status)
    assert(not os.isfile(job.outfile), "the output file must be cleaned up")
end

---------------------------------------------------------------------------------
-- the tools which drive them
---------------------------------------------------------------------------------

-- a tool context with a job store on it
function _toolcontext()
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    instance:service("jobs", jobs.new())
    return {harness = instance, config = instance:config(), cwd = os.tmpdir(),
            signal = {aborted = false}, mode = "bypass"}
end

-- load one builtin tool
function _tool(name)
    return import("harness.tools.builtin." .. name, {anonymous = true})
end

-- run a tool, catching what it raises
function _run(tool, context, args)
    local result, errors
    try {
        function () result = tool.run(context, args) end,
        catch {function (errs) errors = tostring(errs) end}
    }
    return result, errors
end

function test_tool_run_command_starts_a_job()
    local context = _toolcontext()
    local result = _run(_tool("run_command"), context,
        {command = "echo hello", description = "a test", background = true})
    assert(result.output:find("background job 1", 1, true), result.output)
    -- the id is in the message, so the model can read it back
    assert(result.output:find("job_output(1)", 1, true), result.output)
    assert(jobs.running(context.harness:service("jobs")) >= 0)
    jobs.shutdown(context.harness:service("jobs"))
end

function test_tool_job_output_reads_it_back()
    local context = _toolcontext()
    _run(_tool("run_command"), context, {command = "echo marker", background = true})
    local output = _tool("job_output")
    local result
    for _ = 1, 60 do
        result = _run(output, context, {job_id = "1"})
        if result.output:find("marker", 1, true) then
            break
        end
        os.sleep(50)
    end
    assert(result.output:find("marker", 1, true), result.output)
    assert(result.output:find("[status:", 1, true), "the status must always be there")
    jobs.shutdown(context.harness:service("jobs"))
end

function test_tool_job_output_says_when_there_is_nothing_new()
    local context = _toolcontext()
    _run(_tool("run_command"), context, {command = "sleep 5", background = true})
    local result = _run(_tool("job_output"), context, {job_id = "1"})
    assert(result.output:find("nothing new", 1, true), result.output)
    jobs.shutdown(context.harness:service("jobs"))
end

function test_tool_an_unknown_job_id_is_an_error_the_model_can_act_on()
    local context = _toolcontext()
    local result, errors = _run(_tool("job_output"), context, {job_id = "42"})
    assert(result == nil and errors ~= nil)
    assert(errors:find("no job", 1, true) and errors:find("job_list", 1, true), errors)
end

function test_tool_job_list_reports_every_job()
    local context = _toolcontext()
    _run(_tool("run_command"), context, {command = "sleep 5", description = "the first", background = true})
    _run(_tool("run_command"), context, {command = "sleep 5", description = "the second", background = true})
    local result = _run(_tool("job_list"), context, {})
    assert(result.output:find("the first", 1, true) and result.output:find("the second", 1, true), result.output)
    jobs.shutdown(context.harness:service("jobs"))
end

function test_tool_job_list_on_an_empty_session()
    local context = _toolcontext()
    local result = _run(_tool("job_list"), context, {})
    assert(result.output:find("no background job", 1, true), result.output)
end

function test_tool_job_kill_stops_it()
    local context = _toolcontext()
    _run(_tool("run_command"), context, {command = "sleep 30", background = true})
    local result = _run(_tool("job_kill"), context, {job_id = "1", reason = "the test is over"})
    assert(result.output:find("killed", 1, true), result.output)
    assert(jobs.running(context.harness:service("jobs")) == 0)
end

function test_tool_killing_an_unknown_job_is_an_error()
    local context = _toolcontext()
    local result, errors = _run(_tool("job_kill"), context, {job_id = "42"})
    assert(result == nil and errors ~= nil and errors:find("no job", 1, true), tostring(errors))
end
