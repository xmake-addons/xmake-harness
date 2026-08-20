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
  no extra runtime is needed and they work on every platform.]],
        parameters = {
            type = "object",
            properties = {
                command     = {type = "string",  description = "The shell command to run."},
                description = {type = "string",  description = "A short description of what this command does, 5-10 words."},
                cwd         = {type = "string",  description = "The working directory, the project root by default."},
                timeout     = {type = "integer", description = "The timeout in milliseconds, 300000 by default."}
            },
            required = {"command"}
        },
        render = function (args)
            return args.description or args.command
        end
    }
end

-- run the tool
function run(context, args)
    local result = exec.run(context, {command = args.command, cwd = args.cwd, timeout = args.timeout})
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
