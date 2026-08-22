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
-- @file        headless.lua
--

--
-- the non-interactive runner
--
-- it is used by `xmake ai -P "..."` and by the pipes, so the harness can be
-- scripted in the ci or chained with the other tools.
--

-- imports
import("core.base.option")
import("harness.util.util")
import("harness.core.agent")
import("harness.core.session", {alias = "sessions"})

-- run one prompt and print the result
--
-- @param harness   the harness context
-- @param opt       the options, e.g. {prompt = "..", session = .., mode = "..", quiet = false}
--
function run(harness, opt)
    opt = opt or {}
    local session = opt.session or sessions.new({cwd = harness:rootdir()})
    local result = agent.run(harness, {
        session = session,
        prompt = opt.prompt,
        ui = _handlers(opt),
        signal = {aborted = false},
        mode = opt.mode
    })
    io.write("\n")
    if result.errors then
        raise(result.errors)
    end
    if not opt.quiet then
        _printusage(result)
    end
    session:save()
    return result
end

-- the ui handlers of a non-interactive run
--
-- everything goes to the stdout as plain text, so the output can be piped into
-- another tool
--
function _handlers(opt)
    local quiet = opt.quiet
    local function _trace(format, ...)
        if not quiet then
            io.write(string.format(format, ...))
            io.flush()
        end
    end
    return {
        on_text = function (delta)
            io.write(delta)
            io.flush()
        end,
        on_tool_start = function (call)
            _trace("\n[tool] %s\n", call.name)
        end,
        on_tool_result = function (result, call)
            _trace("[tool] %s: %s\n", call.name,
                (result.display or {}).summary or (result.iserror and "failed" or "ok"))
        end,
        on_notice = function (message)
            _trace("[harness] %s\n", message)
        end,
        on_error = function (errors)
            io.write(string.format("\n[error] %s\n", tostring(errors)))
        end,
        confirm = _confirm
    }
end

-- confirm a tool call
--
-- there is no interactive terminal here: `-y` accepts everything, otherwise the
-- call is rejected and the model is told why
--
function _confirm(request)
    if option.get("yes") then
        return "allow"
    end
    return "the tool call needs a confirmation, but this is a non-interactive run.\n"
        .. "tell the user what you would do instead, or ask them to rerun with `-y` or `--mode=bypass`."
end

-- print the token usage of the run
function _printusage(result)
    local usage = result.usage
    if not usage then
        return
    end
    local rate = nil
    if (usage.cachehit or 0) + (usage.cachemiss or 0) > 0 then
        rate = usage.cachehit / (usage.cachehit + usage.cachemiss)
    end
    io.write(string.format("[usage] %s tokens (in %s, out %s%s), %d steps\n",
        util.count(usage.input + usage.output), util.count(usage.input), util.count(usage.output),
        rate and string.format(", cache %.0f%%", rate * 100) or "", result.steps))
end
