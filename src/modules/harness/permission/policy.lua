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
-- the modes:
--
--   default      read-only tools run freely, the others are asked
--   acceptedits  the file edits are accepted automatically
--   plan         nothing may change the world, the agent only plans
--   bypass       everything runs without asking (dangerous)
--

-- the permission modes
function modes()
    return {"default", "acceptedits", "plan", "bypass"}
end

-- get the description of the given mode
function modedesc(mode)
    local descs = {
        default     = "ask before editing files or running commands",
        acceptedits = "accept file edits automatically",
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
-- @param opt       the options, e.g. {mode = "default"}
--
-- @return          "allow"/"ask"/"deny", the reason
--
function check(config, tool, args, opt)
    opt = opt or {}
    local permission = config.permission or {}
    local mode = opt.mode or permission.mode or "default"
    local kind = tool.permission or "none"

    -- the explicit rules always win
    local sig = signature(tool, args)
    if _match(permission.deny, tool.name, sig) then
        return "deny", "it is denied by the user rules"
    end
    if _match(permission.allow, tool.name, sig) then
        return "allow"
    end
    if _match(permission.ask, tool.name, sig) then
        return "ask"
    end

    -- the read-only tools are always safe
    if kind == "none" or kind == "read" then
        return "allow"
    end

    if mode == "bypass" then
        return "allow"
    elseif mode == "plan" then
        return "deny", "the plan mode is active, present the plan to the user first"
    elseif mode == "acceptedits" and kind == "write" then
        return "allow"
    end
    return "ask"
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
