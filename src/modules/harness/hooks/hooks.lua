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
import("harness.shell.exec")

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

    if not context.harness then
        return "the hook has no execution context"
    end
    local result = try {
        function ()
            return exec.run(context.harness and {
                harness = context.harness,
                config = context.config or context.harness:config(),
                cwd = context.cwd or context.harness:rootdir(),
                signal = context.signal,
                ontick = context.ontick
            } or context, {command = command, cwd = context.cwd, timeout = hook.timeout})
        end,
        catch {
            function (errors)
                return {exitcode = -1, output = tostring(errors)}
            end
        }
    }
    if result and result.exitcode == 2 then
        return (result.output or ""):trim() ~= "" and result.output:trim()
            or "the tool call is blocked by the pretooluse hook"
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
