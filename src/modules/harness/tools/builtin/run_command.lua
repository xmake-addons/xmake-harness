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
-- @file        run_command.lua
--

-- imports
import("harness.util.text")
import("harness.util.util")
import("harness.shell.exec")
import("harness.fs.observe")
import("harness.shell.jobs")

-- define the tool
function define()
    return {
        name = "run_command",
        group = "shell",
        permission = "exec",
        description = [[Run a shell command in the working directory and return its output.

- It runs through the system shell, so the pipes and the redirections work.
- Prefer the dedicated tools (`read_file`, `search_text`, `glob_files`) for reading
  and searching, they are faster and safer.
- Never run the interactive commands, they will hang.
- Write the temporary scripts in lua and run them with `xmake lua <script.lua>`, so
  no extra runtime is needed and they work on every platform.

Set `background: true` for anything which does not finish promptly — a long build,
a watch, a server, a test suite you want to keep an eye on. It returns a job id at
once instead of waiting, and you carry on; read what it has printed so far with
`job_output`, and stop it with `job_kill`. A job which finishes while you are
elsewhere tells you so at your next step.]],
        parameters = {
            type = "object",
            properties = {
                command     = {type = "string",  description = "The shell command to run."},
                description = {type = "string",  description = "A short description of what this command does, 5-10 words."},
                cwd         = {type = "string",  description = "The working directory, the project root by default."},
                timeout     = {type = "integer", description = "The timeout in milliseconds, 300000 by default. It does not apply to a background job."},
                background  = {type = "boolean", description = "Start it and return a job id at once, instead of waiting for it."}
            },
            required = {"command"}
        },
        render = function (args)
            return args.description or args.command
        end
    }
end

-- which directory this command could change
--
-- the one it runs in, which is the project unless it was told otherwise. a
-- command which writes somewhere else entirely is not something we can watch
-- without watching the whole machine, and the changes view says as much
--
function _watchdir(context, args)
    if not context.session then
        return nil
    end
    local dirpath = args.cwd and path.absolute(args.cwd, context.cwd) or context.cwd
    return os.isdir(dirpath) and dirpath or nil
end

-- run the tool
function run(context, args)
    if args.background then
        return _background(context, args)
    end

    -- a command tells us nothing about the files it writes, so it is bracketed:
    -- what the tree held before, and what it holds after, @see harness.fs.observe
    local watched = _watchdir(context, args)
    local before = watched and observe.snapshot(watched) or nil
    local result = exec.run(context, {command = args.command, cwd = args.cwd, timeout = args.timeout})
    if before then
        observe.record(context.session, observe.changed(watched, before))
    end
    if result.detached then
        return _adopt(context, args, result)
    end
    local output = result.output
    if result.timedout then
        output = output .. string.format("\n\n[the command timed out after %s]", util.duration(args.timeout or 300000))
    end
    if output == "" then
        output = result.exitcode == 0 and "(no output)" or string.format("(no output, exited with %d)", result.exitcode)
    end
    if result.exitcode ~= 0 and not result.timedout then
        output = output .. string.format("\n\n[exit code: %d]", result.exitcode)
    end

    local lines = text.lines(output)
    return {
        output = output,
        iserror = result.exitcode ~= 0,
        display = {
            title = "Run",
            subject = args.description or args.command,
            summary = string.format("%d line%s%s", #lines, #lines == 1 and "" or "s",
                result.exitcode ~= 0 and string.format(", exit %d", result.exitcode) or ""),
            kind = "output",
            command = args.command,
            output = output
        }
    }
end

-- the user pressed ctrl+b while it ran
--
-- it becomes an ordinary background job, so the model reads the rest of the
-- output the same way it would have if it had started it that way. it is told
-- who moved it, because nothing it did caused this and it should not guess
--
function _adopt(context, args, result)
    local store = context.harness:service("jobs")
    if not store then
        raise("the command was detached but there is nowhere to keep it.")
    end
    local job = jobs.adopt(store, result, {command = args.command,
        label = args.description or args.command, cwd = args.cwd})
    return {
        output = string.format("the user moved this command to the background as job %s while it was running.\n"
            .. "it is still going: read what it prints with job_output(%s), stop it with job_kill(%s).",
            job.id, job.id, job.id),
        display = {
            title = "Run",
            subject = args.description or args.command,
            summary = string.format("moved to background job %s", job.id),
            kind = "output",
            command = args.command
        }
    }
end

-- start it and come back with the id
function _background(context, args)
    local store = context.harness:service("jobs")
    if not store then
        raise("the background jobs are not available here, run it in the foreground.")
    end
    local job, errors = jobs.start(store, context, {
        command = args.command, cwd = args.cwd, label = args.description or args.command})
    if not job then
        raise("failed to start: %s (%s)", args.command, tostring(errors))
    end
    return {
        output = string.format("started as background job %s.\n"
            .. "read what it prints with job_output(%s), stop it with job_kill(%s).", job.id, job.id, job.id),
        display = {
            title = "Run",
            subject = args.description or args.command,
            summary = string.format("background job %s", job.id),
            kind = "output",
            command = args.command
        }
    }
end
