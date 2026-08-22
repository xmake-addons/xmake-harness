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
-- @file        parallel.lua
--

--
-- run the jobs together on the xmake scheduler
--
-- everything in the harness which fans out goes through here: the tool calls of
-- one step, the nodes of one agent graph. they all want the same three things —
-- run these together, no more than n at a time, and stop when the user aborts.
--
-- the group name is derived from the coroutine which fans out, and never a
-- constant. a subagent runs its own tools while the parent is waiting, so the
-- same code is inside itself two or three levels deep, and a shared name makes
-- the inner `co_group_begin` fail with "co_group(..): already exists!" — which
-- the sandbox turns into a raise, so the whole turn dies the moment two
-- subagents happen to reach for their tools at the same time.
--
-- a coroutine is blocked while it waits for its own group, so it can only have
-- one open at a time, which is what makes its identity a sufficient name.
--

-- imports
import("core.base.scheduler")

-- how many jobs may run at the same time
--
-- a model which asks for twenty files at once would otherwise open twenty
-- coroutines, twenty processes and twenty subagents: the machine slows down,
-- the api rate-limits us, and nothing finishes sooner
--
function defaultlimit()
    return 4
end

-- run the given jobs
--
-- @param jobs      the functions to run, each keeps its own result
-- @param opt       the options
--                  - limit     how many at a time, @see defaultlimit()
--                  - signal    the abort signal, the pending batches are dropped
--
-- @return          how many jobs ran
--
function run(jobs, opt)
    opt = opt or {}
    local limit = math.max(1, opt.limit or defaultlimit())
    local count = 0
    for _, batch in ipairs(batches(jobs, limit)) do
        if opt.signal and opt.signal.aborted then
            break
        end
        _runbatch(batch)
        count = count + #batch
    end
    return count
end

-- split the jobs into batches of the given size
function batches(jobs, size)
    local results = {}
    local batch = {}
    for _, job in ipairs(jobs) do
        table.insert(batch, job)
        if #batch >= size then
            table.insert(results, batch)
            batch = {}
        end
    end
    if #batch > 0 then
        table.insert(results, batch)
    end
    return results
end

-- run one batch and wait for it
function _runbatch(batch)
    if #batch == 1 then
        batch[1]()
        return
    end
    local group = _groupname()
    scheduler.co_group_begin(group, function (co_group)
        for _, job in ipairs(batch) do
            scheduler.co_start(job)
        end
    end)
    scheduler.co_group_wait(group)
end

-- the group name of the calling coroutine
function _groupname()
    local running = scheduler.co_running()
    return string.format("harness/parallel/%s", tostring(running))
end
