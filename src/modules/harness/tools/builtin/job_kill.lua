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
-- @file        job_kill.lua
--

--
-- the job_kill tool
--

-- imports
import("harness.shell.jobs")

-- define the tool
function define()
    return {
        name = "job_kill",
        group = "shell",
        permission = "exec",
        description = [[Stop a background job.

Stop what you started once you have what you need from it: a watch or a server
runs until something stops it.]],
        parameters = {
            type = "object",
            properties = {
                job_id = {type = "string", description = "The job id."},
                reason = {type = "string", description = "Why it is being stopped, one short line."}
            },
            required = {"job_id"}
        },
        render = function (args)
            return string.format("stop job %s", (args or {}).job_id or "?")
        end
    }
end

-- run the tool
function run(context, args)
    local store = context.harness:service("jobs")
    if not store then
        raise("the background jobs are not available here.")
    end
    local job, errors = jobs.kill(store, args.job_id, args.reason)
    if not job then
        raise(errors)
    end
    return {
        output = string.format("job %s: %s", job.id, jobs.status(job)),
        display = {title = "Job", subject = job.label, summary = jobs.status(job)}
    }
end
