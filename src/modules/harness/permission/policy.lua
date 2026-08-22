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
-- @file        policy.lua
--

--
-- the permission policy
--
-- every tool declares the permission it needs: "read", "write", "exec",
-- "network" or "none", and the policy decides whether it can run:
--
--   allow -> run it directly
--   ask   -> ask the user, the ui answers
--   deny  -> reject it and tell the model why
--
-- editing the sources of the project and running the ordinary commands is the
-- everyday work of an agent: asking for every one of them is noise nobody
-- reads. so we allow what we can see and judge safe, and we ask for what is
-- hard to undo, reaches outside the project, or that we cannot read at all.
--
-- the modes:
--
--   default      the dangerous commands and the protected files ask
--   acceptedits  the file edits never ask, the commands still do
--   plan         nothing may change the world, the agent only plans
--   bypass       everything runs without asking (dangerous)
--

-- imports
import("harness.permission.paths")
import("harness.permission.danger")

-- the permission modes
function modes()
    return {"default", "acceptedits", "plan", "bypass"}
end

-- get the description of the given mode
function modedesc(mode)
    local descs = {
        default     = "ask before the dangerous commands and the protected files",
        acceptedits = "accept every file edit, still ask before the dangerous commands",
        plan        = "read-only, plan before doing anything",
        bypass      = "run everything without asking (dangerous)"
    }
    return descs[mode] or ""
end

-- get the next mode, it is used by the shift+tab cycling
function nextmode(mode)
    local all = {"default", "acceptedits", "plan"}
    for idx, name in ipairs(all) do
        if name == mode then
            return all[idx % #all + 1]
        end
    end
    return "default"
end

-- check the given tool call
--
-- @param config    the harness configuration
-- @param tool      the tool definition
-- @param args      the tool arguments
-- @param opt       the options, e.g. {mode = "default", cwd = "/path/to/project"}
--
-- @return          "allow"/"ask"/"deny", and the reason
--
function check(config, tool, args, opt)
    opt = opt or {}
    local permission = config.permission or {}
    local mode = opt.mode or permission.mode or "default"
    local kind = tool.permission or "none"

    -- the explicit rules always win
    local decision, reason = _rules(permission, tool, args)
    if decision then
        return decision, reason
    end

    -- the read-only tools are always safe
    if kind == "none" or kind == "read" then
        return "allow"
    end
    if mode == "bypass" then
        return "allow"
    elseif mode == "plan" then
        return "deny", "the plan mode is active, present the plan to the user first"
    end

    if kind == "write" then
        return _checkwrite(permission, args, {mode = mode, cwd = opt.cwd})
    elseif kind == "exec" then
        return _checkexec(permission, tool, args, {cwd = opt.cwd})
    end
    return "ask"
end

-- check the explicit user rules
function _rules(permission, tool, args)
    local sig = signature(tool, args)
    if _match(permission.deny, tool.name, sig) then
        return "deny", "it is denied by the user rules"
    end
    if _match(permission.allow, tool.name, sig) then
        return "allow"
    end
    if _match(permission.ask, tool.name, sig) then
        return "ask", "it is listed in the ask rules"
    end
end

-- check a file change
--
-- the workspace boundary is enforced by the filesystem layer already, so a
-- write which gets here is inside the project: the sources are the work, we
-- only stop at the files which are hard to recover
--
function _checkwrite(permission, args, opt)
    local filepath = type(args) == "table" and (args.path or args.filepath) or nil
    if permission.confirm == "edits" or permission.confirm == "all" then
        return "ask", "every file change is confirmed by your configuration"
    end
    if opt.mode == "acceptedits" then
        return "allow"
    end
    if not filepath then
        return "ask", "the file of this change is unknown"
    end

    local reason = paths.isprotected(filepath, {cwd = opt.cwd, extra = permission.protected})
    if reason then
        return "ask", reason
    end
    if opt.cwd and not paths.inworkspace(opt.cwd, filepath) then
        return "ask", "it writes outside the project"
    end
    return "allow"
end

-- check a command
--
-- we can only judge a command we can read: a tool which spawns something
-- without telling us what is asked, @see harness.permission.danger
--
function _checkexec(permission, tool, args, opt)
    if permission.confirm == "all" then
        return "ask", "every command is confirmed by your configuration"
    end

    local commandline = _commandline(tool, args)
    if not commandline then
        return "ask", "we cannot tell what this tool runs"
    end
    local reason = danger.check(commandline, {cwd = opt.cwd, extra = permission.dangerous})
    if reason then
        return "ask", reason
    end
    return "allow"
end

-- get the command line which the given call runs
function _commandline(tool, args)
    if type(args) ~= "table" then
        return nil
    end
    if tool.commandline then
        local commandline = tool.commandline(args)
        if commandline and commandline ~= "" then
            return commandline
        end
    end
    return args.command
end

-- get the signature of the given tool call, e.g. "bash(git status)"
function signature(tool, args)
    local brief = nil
    if type(args) == "table" then
        brief = args.command or args.path or args.filepath or args.pattern or args.url or args.name
    end
    if brief == nil then
        return tool.name .. "()"
    end
    return string.format("%s(%s)", tool.name, tostring(brief))
end

-- match the given rules
--
-- the rule formats:
--
--   "*"                    match everything
--   "bash"                 match the whole tool
--   "bash(git status*)"    match the tool call signature with the wildcards
--
function _match(rules, toolname, signature)
    for _, rule in ipairs(rules or {}) do
        if rule == "*" or rule == toolname then
            return true
        end
        if _matchpattern(signature, rule) then
            return true
        end
    end
    return false
end

-- match the wildcard pattern
function _matchpattern(str, pattern)
    if not str or not pattern then
        return false
    end
    local luapattern = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1"):gsub("%*", ".*") .. "$"
    return str:match(luapattern) ~= nil
end

-- add an allow rule to the given configuration in memory
function allow(config, rule)
    config.permission = config.permission or {}
    config.permission.allow = config.permission.allow or {}
    table.insert(config.permission.allow, rule)
    return config
end
