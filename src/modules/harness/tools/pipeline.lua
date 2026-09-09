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
-- every tool call goes through the same guarded steps:
--
--   decode -> tools/pre-execute -> pretooluse hooks -> permission
--          -> run -> truncate -> tools/post-execute -> posttooluse hooks
--
-- the plugins intercept the tool calls by listening on the `tools/*` events,
-- they never need to patch the tools themselves.
--

-- imports
import("harness.llm.llm")
import("harness.util.sanitize")
import("harness.hooks.hooks")
import("harness.permission.policy")
import("harness.util.text")

-- execute the given tool call
--
-- @param context   the tool context
--                  - harness, config, cwd, session, ui, signal, mode, depth
-- @param call      the tool call, e.g. {id = "..", name = "bash", arguments_text = ".."}
--
-- @return          {output = "..", iserror = false, display = {..}, duration = 12}
--
function execute(context, call)
    local starttime = os.mclock()
    local result, errors
    try {
        function ()
            result = _execute(context, call, starttime)
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    if result then
        return result
    end

    -- whatever went wrong handling this call is the call's problem and not the
    -- conversation's. the arguments came from the model, so they may be wrong
    -- in ways nothing downstream expects; the model can read a failed tool call
    -- and try again, and it cannot read a turn which ended
    return _error(call, starttime, "%s", tostring(errors or "the tool call failed"))
end

-- execute it, in the ordinary case where nothing is thrown
function _execute(context, call, starttime)
    local harness = context.harness
    local tool = harness:service("tools"):get(call.name)
    if not tool then
        return _error(call, starttime,
            "the tool(%s) does not exist, please only use the available tools.", call.name)
    end

    local args, errors = llm.decode_arguments(call)
    if not args then
        return _error(call, starttime, "%s", errors or "invalid arguments")
    end

    -- the listeners may rewrite the arguments or reject the call
    local request = harness:waterfall("tools/pre-execute",
        {tool = tool, args = args, call = call, context = context})
    if request.denied then
        return _error(call, starttime, "%s", request.denied)
    end
    args = request.args or args

    local missing = _missing(tool, args)
    if missing then
        return _error(call, starttime, "%s", missing)
    end

    local blocked = _check(context, tool, args)
    if blocked then
        return _error(call, starttime, "%s", blocked)
    end

    local result, runerrors = _run(context, tool, args)
    if not result then
        return _error(call, starttime, "%s", tostring(runerrors))
    end
    result.id = call.id
    result.name = call.name
    result.args = args
    result.duration = os.mclock() - starttime
    _sanitize(result)
    _truncate(context, result)

    result = harness:waterfall("tools/post-execute", result, {tool = tool, args = args, context = context})
    hooks.run(context.config, "posttooluse", _hookcontext(context, tool, args))
    return result
end

-- the arguments the tool said it cannot do without
--
-- a model which leaves one out has made a mistake it can see and fix, so it is
-- told which argument and the turn goes on. without this the tool is what
-- notices, somewhere further in, and what it says is about its own internals:
-- "the path is required!" names neither the tool nor the argument
--
-- only a missing one counts, never an empty one: `edit_file` requires
-- `new_string` and an empty `new_string` is how you delete the old text
--
-- @return  nil if they are all there, otherwise what to tell the model
--
function _missing(tool, args)
    local required = (tool.parameters or {}).required
    if type(required) ~= "table" then
        return nil
    end
    local missing = {}
    for _, name in ipairs(required) do
        if args[name] == nil then
            table.insert(missing, name)
        end
    end
    if #missing == 0 then
        return nil
    end
    return string.format("the tool(%s) is missing the required argument%s: %s",
        tool.name, #missing == 1 and "" or "s", table.concat(missing, ", "))
end

-- check whether this call may run
--
-- @return  nil if it may, otherwise the reason for the model
--
function _check(context, tool, args)
    local blocked = hooks.run(context.config, "pretooluse", _hookcontext(context, tool, args))
    if blocked then
        return blocked
    end

    local decision, reason = policy.check(context.config, tool, args,
        {mode = context.mode, cwd = context.cwd})
    if decision == "allow" then
        return nil
    elseif decision == "deny" then
        return reason or "the tool call is denied"
    end
    return _confirm(context, tool, args, reason)
end

-- ask the user to confirm this call
function _confirm(context, tool, args, reason)
    if not (context.ui and context.ui.confirm) then
        return "no interactive terminal to confirm this tool call"
    end
    local answer = context.ui.confirm({
        tool = tool,
        args = args,
        reason = reason,
        signature = policy.signature(tool, args),
        preview = _preview(context, tool, args)})

    -- the user allowed it for the rest of the session, remember the scope
    if type(answer) == "table" and answer.answer == "always" then
        _allowalways(context, tool, answer.rule)
        return nil
    elseif answer == "always" then
        policy.allow(context.config, tool.name)
        return nil
    elseif answer == "allow" or answer == true then
        return nil
    end
    return type(answer) == "string" and answer ~= "deny" and answer
        or "the user rejected this tool call, ask the user how to continue."
end

-- what the dialog shows about this call, if anything
--
-- a preview is a courtesy: it reads the file the call is about and works out
-- what would change. what it is reading are the model's arguments, so it may
-- well not survive them — and a dialog which cannot be decorated must still be
-- asked, or nobody is asked anything ever again
--
function _preview(context, tool, args)
    if not tool.preview then
        return nil
    end
    return try { function () return tool.preview(context, args) end }
end

-- remember what the user allowed for the rest of the session
function _allowalways(context, tool, rule)
    if rule ~= "@acceptedits" then
        policy.allow(context.config, rule or tool.name)
        return
    end
    context.config.permission = context.config.permission or {}
    context.config.permission.mode = "acceptedits"
    if context.ui.on_mode then
        context.ui.on_mode("acceptedits")
    end
end

-- run the tool
--
-- @return  the result, or nil and the errors
--
function _run(context, tool, args)
    local result, errors
    local ok = try {
        function ()
            result = tool.run(context, args)
            return true
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    if not ok then
        return nil, errors
    end
    if type(result) == "string" then
        result = {output = result}
    end
    return result or {output = ""}
end

-- scrub what the tool produced
--
-- the output is not ours: a compiler message, a file, the output of somebody
-- else's command. it goes straight back into the model, so the escape sequences
-- and the bidi overrides come off first, @see harness.util.sanitize
--
function _sanitize(result)
    result.output = sanitize.clean(result.output)
    local display = result.display
    if not display then
        return
    end
    display.output = sanitize.clean(display.output)
    display.summary = sanitize.clean(display.summary)
    display.subject = sanitize.clean(display.subject)
    display.title = sanitize.clean(display.title)
end

-- truncate the output which goes to the model
function _truncate(context, result)
    local maxoutput = (context.config.tools or {}).maxoutput or 60000
    if not result.output or #result.output <= maxoutput then
        return
    end
    result.truncated = #result.output
    result.output = text.cut(result.output, maxoutput) ..
        string.format("\n\n[the output is truncated, %d bytes in total]", result.truncated)
end

-- the context of the user hooks
function _hookcontext(context, tool, args)
    return {
        toolname = tool.name,
        args = args,
        cwd = context.cwd,
        filepath = args.path,
        sessionid = context.session and context.session:id()
    }
end

-- make an error result
function _error(call, starttime, format, ...)
    return {
        id = call.id,
        name = call.name,
        output = string.format(format, ...),
        iserror = true,
        duration = os.mclock() - starttime
    }
end
