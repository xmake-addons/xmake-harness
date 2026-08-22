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
-- @file        ai.lua
--

--
-- the entry of `xmake ai`
--
-- it resolves what the user asked for and hands over: a one-off action (the
-- setup, a config value, a listing), a slash command, a non-interactive run, or
-- the interactive tui.
--

-- imports
import("core.base.option")
import("harness.harness")
import("harness.util.util")
import("harness.ui.app")
import("harness.cli.setup")
import("harness.cli.report")
import("harness.cli.headless")
import("harness.config.config")
import("harness.core.session", {alias = "sessions"})

-- the main entry
function main(options)
    options = options or {}

    -- the config actions do not need the whole harness
    if options.config then
        return setup.setconfig(options.config)
    end

    local rootdir = options.cwd and path.absolute(options.cwd) or os.curdir()
    local context = harness.bootstrap({rootdir = rootdir, options = _overrides(options)})
    local action = _action(context, options)
    if action then
        return action
    end

    local session = _session(context, options)
    local prompt = options.prompt and #options.prompt > 0 and table.concat(options.prompt, " ") or nil
    if not setup.ensurekey(context, {interactive = io.isatty() and not options["print"]}) then
        return
    end

    -- the non-interactive mode, e.g. a pipe or `--print`
    if options["print"] or not io.isatty() then
        return headless.run(context, {
            prompt = prompt or io.read("a"),
            session = session,
            quiet = options.quiet,
            mode = options.mode})
    end
    app.new(context, {session = session, mode = options.mode}):run({prompt = prompt, replay = session ~= nil})
end

-- run the one-off actions
--
-- @return  true when the action ran and we are done
--
function _action(context, options)
    if options.apikey then
        return setup.setapikey(context, options.apikey)
    elseif options.showconfig then
        return report.showconfig(context)
    elseif options.doctor then
        return report.printlines(doctor(context))
    elseif options.setup then
        return setup.wizard(context)
    elseif options.list then
        return report.list(context, options.list)
    elseif options.command then
        return runcommand(context, options.command, options)
    end
end

-- build the configuration overrides of the command line options
function _overrides(options)
    local overrides = {}
    if options.provider then
        overrides.provider = options.provider
    end
    if options.model then
        overrides.model = options.model
    end
    if options.smallmodel then
        overrides.smallmodel = options.smallmodel
    end
    if options.mode then
        overrides.permission = {mode = options.mode}
    end
    if options.sandbox then
        overrides.sandbox = {enabled = true}
    end
    if options.notools then
        overrides.notools = true
    end
    return overrides
end

-- resolve the session of this run
--
-- the behaviour follows claude code:
--
--   xmake ai              a new session
--   xmake ai -c           continue the last session of this directory
--   xmake ai -r <id>      resume that session
--   xmake ai -r           pick one of this directory interactively
--
function _session(context, options)
    if options["new"] then
        return nil
    end
    if options.resume ~= nil then
        local id = tostring(options.resume):trim()
        if id == "" then
            return _pick(context)
        end
        local session, errors = sessions.load(id, context:rootdir())
        if not session then
            raise(errors)
        end
        return session
    end
    if options["continue"] then
        local session = sessions.last(context:rootdir())
        if not session then
            cprint("${color.warning}no previous session in %s, starting a new one${clear}", context:rootdir())
        end
        return session
    end
end

-- pick a session of this project interactively
function _pick(context)
    local items = sessions.list({cwd = context:rootdir(), limit = 20})
    if #items == 0 then
        cprint("${color.warning}no session for %s yet.${clear}", context:rootdir())
        return nil
    end
    report.sessions_list(items, {title = string.format("the recent sessions of %s", context:rootdir()), numbered = true})
    io.write("resume which one? [1, or enter to cancel]: ")
    io.flush()

    local answer = (io.read("l") or ""):trim()
    if answer == "" then
        return nil
    end
    local meta = items[tonumber(answer) or 0]
    if not meta then
        for _, item in ipairs(items) do
            if item.id:startswith(answer) then
                meta = item
                break
            end
        end
    end
    if not meta then
        raise("no such session: %s", answer)
    end
    local session, errors = sessions.load(meta.id, context:rootdir())
    if not session then
        raise(errors)
    end
    return session
end

-- run one slash command without entering the tui
--
-- e.g. xmake ai --command=doctor
--      xmake ai --command="model deepseek-reasoner"
--
function runcommand(context, line, options)
    -- `-c` and `-r` apply here too: `/context` and `/compact` are about a
    -- conversation, running them against a fresh empty one says nothing
    local shim = import("harness.cli.shim", {anonymous = true}).new(context,
        {mode = options.mode, session = _session(context, options)})
    local result = context:service("commands"):run(shim, line)
    if result.kind == "prompt" then
        return headless.run(context, {prompt = result.text, session = shim.session,
            quiet = options.quiet, mode = options.mode})
    end
    if result.text then
        if result.iserror then
            cprint("${color.failure}%s", result.text)
            os.exit(1)
        end
        print(result.text)
    end
    return true
end

-- check the harness environment
--
-- it is shared by `xmake ai --doctor` and the `/doctor` command, so both report
-- exactly the same thing
--
function doctor(context)
    return report.doctor(context)
end
