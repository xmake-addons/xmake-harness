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
-- @file        job_list.lua
--

--
-- the job_list tool
--

-- imports
import("harness.shell.jobs")

-- define the tool
function define()
    return {
        name = "job_list",
        group = "shell",
        permission = "read",
        concurrent = true,
        description = [[List the background jobs of this session and how each one stands.

Use it when you have lost track of the ids, e.g. after the conversation was
compacted.]],
        parameters = {type = "object", properties = {}},
        render = function ()
            return "the background jobs"
        end
    }
end

-- run the tool
function run(context, args)
    local store = context.harness:service("jobs")
    local all = store and jobs.list(jobs.poll(store)) or {}
    if #all == 0 then
        return {output = "no background job was started in this session."}
    end
    local lines = {}
    for _, job in ipairs(all) do
        table.insert(lines, string.format("%s  %s  %s", job.id, jobs.status(job), job.label))
    end
    return {
        output = table.concat(lines, "\n"),
        display = {title = "Jobs", subject = string.format("%d job%s", #all, #all == 1 and "" or "s"),
                   summary = string.format("%d running", jobs.running(store))}
    }
end
