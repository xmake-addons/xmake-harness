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
-- @file        hooks.lua
--

--
-- the hooks
--
-- the users can attach the external commands to the harness lifecycle from
-- their configuration, e.g.
--
--   "hooks": {
--       "pretooluse":  [{"matcher": "write_file|edit_file", "command": "xmake format $FILE"}],
--       "posttooluse": [{"matcher": "bash", "command": "echo done"}],
--       "sessionstart": [{"command": "git status --short"}]
--   }
--
-- a `pretooluse` hook may block the tool call by exiting with the code 2, its
-- stderr is then sent back to the model as the reason.
--

-- get the hooks of the given event
function get(config, event)
    local hooks = (config.hooks or {})[event]
    return hooks or {}
end

-- run the hooks of the given event
--
-- @param config    the configuration
-- @param event     the event name, e.g. "pretooluse"
-- @param context   the context, e.g. {toolname = "bash", args = {..}, cwd = ".."}
--
-- @return          nil if it is allowed, otherwise the block reason
--
function run(config, event, context)
    context = context or {}
    for _, hook in ipairs(get(config, event)) do
        local matcher = hook.matcher
        if not matcher or matcher == "*" or (context.toolname and context.toolname:match(matcher)) then
            local reason = _runone(hook, context)
            if reason then
                return reason
            end
        end
    end
end

-- run one hook command
function _runone(hook, context)
    local command = hook.command
    if not command or command == "" then
        return
    end

    -- expand the variables of the command
    command = command:gsub("%$(%w+)", function (name)
        local values = {
            FILE = context.filepath or (context.args or {}).path or "",
            TOOL = context.toolname or "",
            CWD = context.cwd or os.curdir(),
            SESSION = context.sessionid or ""
        }
        return values[name] or ("$" .. name)
    end)

    local outfile = os.tmpfile()
    local errfile = os.tmpfile()
    local exitcode = try {
        function ()
            return os.execv(_shell(), {_shellflag(), command},
                {stdout = outfile, stderr = errfile, curdir = context.cwd, try = true})
        end
    } or -1
    local stderrdata = os.isfile(errfile) and io.readfile(errfile) or ""
    os.tryrm(outfile)
    os.tryrm(errfile)
    if type(exitcode) == "number" and exitcode == 2 then
        return stderrdata ~= "" and stderrdata:trim() or "the tool call is blocked by the pretooluse hook"
    end
end

-- get the shell program
function _shell()
    if os.host() == "windows" then
        return os.getenv("COMSPEC") or "cmd"
    end
    return os.getenv("SHELL") or "/bin/sh"
end

-- get the shell flag which runs a command string
function _shellflag()
    return os.host() == "windows" and "/c" or "-c"
end
