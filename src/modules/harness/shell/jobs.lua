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

--
-- the background jobs
--
-- a tool call which blocks holds the whole turn: nothing else runs, the model
-- waits, and the user watches a spinner. that is the right trade for a command
-- which takes a second, and the wrong one for everything a build system does —
-- a link step of twenty minutes, `xmake watch`, a server which is supposed to
-- stay up, a test suite somebody wants to keep an eye on.
--
-- so a command can be started instead of run: it keeps going in its own
-- process, the turn continues, and its output is collected later. the model
-- reads it with `job_output`, which returns only what has arrived since it last
-- looked, so following a build costs one page at a time instead of the whole
-- log again.
--
-- a job which finishes while the model was doing something else announces
-- itself once, at the top of the next step, because a result nobody is told
-- about is a result nobody uses.
--

-- imports
import("core.base.scheduler")
import("harness.shell.exec")

-- how much of the output one read may return
--
-- a build log is unbounded and the context is not. the tail is what matters —
-- the error is at the end — so a read which overflows keeps the end and says
-- how much it dropped
--
local MAXREAD = 20000

-- create the store
function new()
    return {jobs = {}, order = {}, count = 0}
end

-- start a command in the background
--
-- @param opt   - command   the shell command
--              - label     what to call it in the ui
--              - cwd       the working directory
--              - onfinish  called with the job when it ends, in the job's own
--                          coroutine: it is where whatever was waiting for the
--                          command gets to happen, e.g. reading what it fetched
--
-- @return      the job, or nil and the errors
--
function start(store, context, opt)
    local handle, errors = exec.start(context, opt)
    if not handle then
        return nil, errors
    end
    local job = _newjob(store, opt)
    job.proc = handle.proc
    job.outfile = handle.outfile
    _register(store, job)

    return job
end

-- take over a command which is already running
--
-- it is the same job as any other from here on, only its first seconds were
-- spent in the foreground, @see harness.shell.exec.run
--
-- @param handle    {proc = .., outfile = ..}, the caller gives up ownership
--
function adopt(store, handle, opt)
    local job = _newjob(store, opt)
    job.proc = handle.proc
    job.outfile = handle.outfile
    job.errfile = handle.errfile
    -- what it printed before it was detached has already been shown
    job.offset = os.isfile(handle.outfile) and #(io.readfile(handle.outfile) or "") or 0
    _register(store, job)
    return job
end

-- the record of one job, before it has a process
function _newjob(store, opt)
    store.count = store.count + 1
    return {
        id = tostring(store.count),
        command = opt.command,
        label = opt.label or opt.command,
        cwd = opt.cwd,
        onfinish = opt.onfinish,
        status = "running",
        starttime = opt.starttime or os.time(),
        offset = 0,
        reported = false
    }
end

-- put it in the store and start the coroutine which waits for it
--
-- one coroutine per job, and all it does is wait. polling looked simpler and
-- was wrong: a `wait(1)` which times out leaves nobody suspended on the poller,
-- so when the process finally exits there is no coroutine for the scheduler to
-- wake. a coroutine blocked on `wait(-1)` is properly suspended, is resumed the
-- instant the process exits, and the status is already right by the time
-- anybody looks. it is what `async.runjobs` does with its workers
function _register(store, job)
    store.jobs[job.id] = job
    table.insert(store.order, job.id)
    scheduler.co_start(function ()
        local ok, status = job.proc:wait(-1)
        if ok > 0 then
            _settle(job, job.killed and "killed" or "exited", status or 0)
        else
            _settle(job, job.killed and "killed" or "failed", -1)
        end
    end)
    return job
end

-- get a job by id
function get(store, id)
    return store.jobs[tostring(id or "")]
end

-- all the jobs, oldest first
function list(store)
    local results = {}
    for _, id in ipairs(store.order) do
        table.insert(results, store.jobs[id])
    end
    return results
end

-- how many are still running
function running(store)
    local count = 0
    for _, job in ipairs(list(store)) do
        if job.status == "running" then
            count = count + 1
        end
    end
    return count
end

-- let the waiting coroutines have a turn
--
-- nothing is polled: each job settles itself, @see start(). this only yields, so
-- that a caller which just started something sees a status which is up to date
-- rather than one from before the scheduler last ran
--
function poll(store)
    scheduler.co_yield()
    return store
end

-- record how a job ended
function _settle(job, status, exitcode)
    job.status = status
    job.exitcode = exitcode
    job.finishtime = os.time()
    job.proc:close()

    -- whoever started it may have something to do now that it is over, and it
    -- happens here rather than wherever somebody next looks: a fetch which has
    -- landed is of no use until the thing it fetched has been read.
    --
    -- it may not take the job down with it, so it is wrapped: the store has to
    -- go on holding a job which finished, whatever a callback made of it
    if job.onfinish then
        try {
            function ()
                job.onfinish(job)
            end,
            catch {
                function (errors)
                    job.summary = string.format("%s: %s", job.label, tostring(errors))
                    job.status = "failed"
                end
            }
        }
    end
    return job
end

-- read what a job has written since the last read
--
-- @return  {text = "..", dropped = 0}
--
function read(job)
    local data = os.isfile(job.outfile) and io.readfile(job.outfile) or ""
    local text = data:sub(job.offset + 1)
    job.offset = #data
    if #text <= MAXREAD then
        return {text = text, dropped = 0}
    end
    -- the end is where the error is
    return {text = text:sub(#text - MAXREAD + 1), dropped = #text - MAXREAD}
end

-- kill a job
function kill(store, id, reason)
    local job = get(store, id)
    if not job then
        return nil, string.format("there is no job(%s).", tostring(id))
    end
    if job.status ~= "running" then
        return job
    end
    job.killed = true
    job.reason = reason
    job.proc:kill()
    -- the job's own coroutine reaps it and records how it went, we only wait
    -- for that to have happened so the caller can report the result
    _await(job, 2000)
    return job
end

-- wait until a job has settled, but not forever
function _await(job, timeout)
    local deadline = os.mclock() + timeout
    while job.status == "running" and os.mclock() < deadline do
        os.sleep(20)
    end
    return job
end

-- the jobs which finished without anybody being told
function pending(store)
    local results = {}
    for _, job in ipairs(list(store)) do
        if job.status ~= "running" and not job.reported then
            table.insert(results, job)
        end
    end
    return results
end

-- the jobs which settled without the user being shown
--
-- nothing is polled here either: the job's own coroutine has already recorded
-- how it went, this only reports what has not been said yet. the user and the
-- model learn about it at different moments, so each has its own mark
--
function finished(store)
    local results = {}
    for _, job in ipairs(list(store)) do
        if job.status ~= "running" and not job.shown then
            job.shown = true
            table.insert(results, job)
        end
    end
    return results
end

-- mark a job as announced
function reported(job)
    job.reported = true
    return job
end

-- how a job stands, e.g. "running", "exited 0", "killed"
function status(job)
    if job.status == "running" then
        return string.format("running for %s", duration(job))
    elseif job.status == "exited" then
        return string.format("exited %d after %s", job.exitcode or 0, duration(job))
    elseif job.status == "killed" then
        return string.format("killed after %s", duration(job))
    end
    return string.format("failed after %s", duration(job))
end

-- how long a job has been going
function duration(job)
    local seconds = (job.finishtime or os.time()) - job.starttime
    if seconds < 60 then
        return string.format("%ds", seconds)
    end
    return string.format("%dm%02ds", math.floor(seconds / 60), seconds % 60)
end

-- kill everything and clean up
--
-- the jobs belong to the session, so leaving them behind would hand the user a
-- background process they never started and cannot see
--
function shutdown(store)
    for _, job in ipairs(list(store)) do
        if job.status == "running" then
            job.killed = true
            job.proc:kill()
        end
    end
    for _, job in ipairs(list(store)) do
        _await(job, 1000)
        os.tryrm(job.outfile)
        if job.errfile then
            os.tryrm(job.errfile)
        end
    end
    return store
end
