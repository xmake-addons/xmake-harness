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
-- the jobs command: /jobs
--

-- imports
import("harness.util.text")
import("harness.shell.jobs")

-- the commands of this group
function commands()
    return {
        {name = "jobs", description = "Show the background jobs, /jobs kill <id> to stop one", run = _jobs}
    }
end

-- /jobs [kill <id>|clear]
function _jobs(app, args)
    local action, id = (args or ""):match("^(%S+)%s*(.*)$")
    local store = app.harness:service("jobs")
    if not store then
        return {kind = "message", text = "the background jobs are not available here."}
    end
    if action == "kill" or action == "stop" then
        return _kill(store, id)
    end
    if action ~= nil and action ~= "list" then
        return {kind = "message", iserror = true,
                text = string.format("unknown action: %s\nusage: /jobs [kill <id>]", action)}
    end
    return _list(store)
end

-- /jobs
function _list(store)
    local all = jobs.list(jobs.poll(store))
    if #all == 0 then
        return {kind = "message", text = "no background job was started in this session.\n"
            .. "the agent starts one with `run_command(background: true)`, e.g. for a long build."}
    end
    local lines = {}
    for _, job in ipairs(all) do
        table.insert(lines, string.format("  %s  %s  %s", text.pad(job.id, 4),
            text.pad(jobs.status(job), 24), text.truncate(job.label, 44)))
    end
    table.insert(lines, "")
    table.insert(lines, "  /jobs kill <id> to stop one · they all stop when you exit")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /jobs kill <id>
function _kill(store, id)
    if (id or ""):trim() == "" then
        return {kind = "message", text = "which one? e.g. /jobs kill 1", iserror = true}
    end
    local job, errors = jobs.kill(store, id:trim())
    if not job then
        return {kind = "message", text = errors, iserror = true}
    end
    return {kind = "message", text = string.format("job %s: %s", job.id, jobs.status(job))}
end
