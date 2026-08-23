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
-- @file        job_output.lua
--

--
-- the job_output tool
--

-- imports
import("harness.util.text")
import("harness.shell.jobs")

-- define the tool
function define()
    return {
        name = "job_output",
        group = "shell",
        permission = "read",
        concurrent = true,
        description = [[Read what a background job has printed since you last read it.

It does not wait: a job which is still running returns whatever has arrived so
far, and you can read it again later to see the rest. The status is at the end of
the result, so you always know whether it is still going.]],
        parameters = {
            type = "object",
            properties = {
                job_id = {type = "string", description = "The job id, as reported when it started."}
            },
            required = {"job_id"}
        },
        render = function (args)
            return string.format("job %s", (args or {}).job_id or "?")
        end
    }
end

-- run the tool
function run(context, args)
    local store = context.harness:service("jobs")
    local job = store and jobs.get(store, args.job_id)
    if not job then
        raise("there is no job(%s), use job_list to see which ones there are.", tostring(args.job_id))
    end

    local result = jobs.read(job)
    local output = result.text
    if result.dropped > 0 then
        output = string.format("[%d earlier characters are omitted, this is the end of it]\n\n%s",
            result.dropped, output)
    end
    if output:trim() == "" then
        output = "(nothing new)"
    end
    output = output .. string.format("\n\n[status: %s]", jobs.status(job))
    return {
        output = output,
        iserror = job.status == "failed",
        display = {
            title = "Job",
            subject = job.label,
            summary = string.format("%d line%s · %s", #text.lines(result.text),
                #text.lines(result.text) == 1 and "" or "s", jobs.status(job)),
            kind = "output",
            command = job.command,
            output = result.text
        }
    }
end
