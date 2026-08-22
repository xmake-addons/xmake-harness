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
-- @file        context.lua
--

--
-- the context commands: /context, /compact, /cost, /permissions, /sandbox
--

-- imports
import("harness.util.util")
import("harness.util.text")
import("harness.config.config")
import("harness.context.window")
import("harness.context.compact")
import("harness.sandbox.sandbox")
import("harness.permission.policy")

-- the commands of this group
function commands()
    return {
        {name = "context",     description = "Show the context breakdown, /context full to keep everything", run = _context},
        {name = "compact",     description = "Compact the conversation into a summary",       run = _compact},
        {name = "cost",        description = "Show the token usage and the cache hit rate",   run = _cost},
        {name = "permissions", description = "Show or switch the permission mode, e.g. /permissions plan", run = _permissions},
        {name = "sandbox",     description = "Show or toggle the command sandbox",            run = _sandbox}
    }
end

-- /context [full|auto]
function _context(app, args)
    local action = (args or ""):trim():lower()
    if action == "full" or action == "auto" then
        util.tset(app.harness:config(), "context.mode", action)
        config.set("context.mode", action)
        return {kind = "message", text = action == "full"
            and "the context mode is `full`: the whole history is sent, nothing is pruned or compacted"
            or "the context mode is `auto`: the old tool results are pruned and the history is compacted when needed"}
    end

    local result = window.breakdown(app.harness, app.session, {mode = app.mode})
    local lines = window.render(result, {width = 80})
    table.insert(lines, "")
    table.insert(lines, "  /compact to summarize now · /context full to disable the optimization")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /compact [focus]
function _compact(app, args)
    app:notify("compacting the conversation ..")
    local summary, errors = compact.run(app.harness, app.session, {focus = args, manual = true})
    if not summary then
        return {kind = "message", text = "cannot compact: " .. tostring(errors), iserror = true}
    end
    return {kind = "compacted", text = "the conversation is compacted into a summary"}
end

-- /cost
function _cost(app)
    local usage = app.session:usage()
    local lines = {
        string.format("requests:    %d", usage.requests or 0),
        string.format("input:       %s tokens", util.count(usage.input or 0)),
        string.format("output:      %s tokens", util.count(usage.output or 0))
    }
    local rate = app.session:cacherate()
    table.insert(lines, rate
        and string.format("cache:       %.0f%% hit (%s hit / %s miss)", rate * 100,
            util.count(usage.cachehit or 0), util.count(usage.cachemiss or 0))
        or "cache:       no data")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /permissions [mode]
function _permissions(app, args)
    local mode = (args or ""):trim()
    if mode == "" then
        local lines = {string.format("the current mode: %s (%s)", app.mode, policy.modedesc(app.mode)), ""}
        for _, name in ipairs(policy.modes()) do
            table.insert(lines, string.format("  %s %s", text.pad(name, 14), policy.modedesc(name)))
        end
        table.insert(lines, "")
        table.insert(lines, "switch it with `/permissions <mode>` or shift+tab")
        return {kind = "message", text = table.concat(lines, "\n")}
    end
    if not table.contains(policy.modes(), mode) then
        return {kind = "message", text = string.format("unknown mode: %s", mode), iserror = true}
    end
    app:setmode(mode)
    return {kind = "message", text = string.format("the permission mode is switched to %s", mode)}
end

-- /sandbox [on|off|backend]
function _sandbox(app, args)
    local harnessconfig = app.harness:config()
    harnessconfig.sandbox = harnessconfig.sandbox or {}
    args = (args or ""):trim()
    if args == "" then
        return {kind = "message", text = string.format(
            "the sandbox is %s, the available backends: %s\ntoggle it with `/sandbox on|off`",
            sandbox.status(harnessconfig), table.concat(sandbox.backends(), ", "))}
    end

    local enabled = util.tobool(args, nil)
    if enabled == nil then
        harnessconfig.sandbox.backend = args
        config.set("sandbox.backend", args)
        return {kind = "message", text = string.format("the sandbox backend is set to %s", args)}
    end
    harnessconfig.sandbox.enabled = enabled
    config.set("sandbox.enabled", enabled)
    return {kind = "message", text = string.format("the sandbox is %s (%s)",
        enabled and "enabled" or "disabled", sandbox.status(harnessconfig))}
end
