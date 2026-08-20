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
-- @file        pipeline.lua
--

--
-- the tool execution pipeline
--
-- every tool call goes through the same guarded pipeline:
--
--   decode -> tools/pre-execute -> pretooluse hooks -> permission
--          -> sandbox -> run -> truncate -> tools/post-execute -> posttooluse hooks
--
-- the plugins intercept the tool calls by listening on the `tools/*` events,
-- they never need to patch the tools themselves.
--

-- imports
import("core.base.json")
import("harness.llm.llm")
import("harness.hooks.hooks")
import("harness.permission.policy")

-- execute the given tool call
--
-- @param context   the tool context
--                  - harness       the harness context
--                  - config        the configuration
--                  - cwd           the working directory
--                  - session       the session
--                  - ui            the ui callbacks, e.g. {confirm = function (request) end}
--                  - signal        the abort signal, e.g. {aborted = false}
-- @param call      the tool call, e.g. {id = "..", name = "bash", arguments_text = ".."}
--
-- @return          {output = "..", iserror = false, display = {..}, duration = 12}
--
function execute(context, call)
    local starttime = os.mclock()
    local harness = context.harness
    local registry = harness:service("tools")
    local tool = registry:get(call.name)
    if not tool then
        return _error(call, string.format("the tool(%s) does not exist, please only use the available tools.", call.name), starttime)
    end

    -- decode the arguments
    local args, errors = llm.decode_arguments(call)
    if not args then
        return _error(call, errors or "invalid arguments", starttime)
    end

    -- the pre-execute waterfall, a listener may rewrite the arguments or reject the call
    local request = harness:waterfall("tools/pre-execute", {tool = tool, args = args, call = call, context = context})
    if request.denied then
        return _error(call, request.denied, starttime)
    end
    args = request.args or args

    -- run the pretooluse hooks
    local blocked = hooks.run(context.config, "pretooluse", {
        toolname = tool.name, args = args, cwd = context.cwd, sessionid = context.session and context.session:id()})
    if blocked then
        return _error(call, blocked, starttime)
    end

    -- check the permission
    local decision, reason = policy.check(context.config, tool, args, {mode = context.mode})
    if decision == "ask" then
        if context.ui and context.ui.confirm then
            local answer = context.ui.confirm({
                tool = tool,
                args = args,
                signature = policy.signature(tool, args),
                preview = tool.preview and tool.preview(context, args) or nil})
            if answer == "always" then
                policy.allow(context.config, tool.name)
                decision = "allow"
            elseif answer == "allow" or answer == true then
                decision = "allow"
            else
                return _error(call, type(answer) == "string" and answer ~= "deny" and answer
                    or "the user rejected this tool call, ask the user how to continue.", starttime)
            end
        else
            decision = "deny"
            reason = "no interactive terminal to confirm this tool call"
        end
    end
    if decision == "deny" then
        return _error(call, reason or "the tool call is denied", starttime)
    end

    -- run the tool
    local result
    local runerrors
    local ok = try {
        function ()
            result = tool.run(context, args)
            return true
        end,
        catch {
            function (errs)
                runerrors = errs
            end
        }
    }
    if not ok then
        return _error(call, tostring(runerrors), starttime)
    end
    if type(result) == "string" then
        result = {output = result}
    end
    result = result or {output = ""}
    result.name = call.name
    result.id = call.id
    result.args = args
    result.duration = os.mclock() - starttime

    -- truncate the output for the model
    local maxoutput = (context.config.tools or {}).maxoutput or 60000
    if result.output and #result.output > maxoutput then
        result.truncated = #result.output
        result.output = result.output:sub(1, maxoutput) ..
            string.format("\n\n[the output is truncated, %d bytes in total]", result.truncated)
    end

    -- the post-execute waterfall
    result = harness:waterfall("tools/post-execute", result, {tool = tool, args = args, context = context})

    -- run the posttooluse hooks
    hooks.run(context.config, "posttooluse", {
        toolname = tool.name, args = args, cwd = context.cwd,
        filepath = args.path, sessionid = context.session and context.session:id()})
    return result
end

-- make an error result
function _error(call, message, starttime)
    return {
        id = call.id,
        name = call.name,
        output = message,
        iserror = true,
        duration = os.mclock() - starttime
    }
end
