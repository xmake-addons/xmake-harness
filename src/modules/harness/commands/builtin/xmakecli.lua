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
-- @file        xmakecli.lua
--

--
-- the xmake command: /xmake
--
-- it runs xmake itself, in your terminal, exactly as you would type it. the
-- point is what it does *not* do: the output goes to the screen and nowhere
-- else, so a build you run to see for yourself costs nothing.
--
-- that is the difference from `!xmake build`, which hands the output to the
-- model afterwards, and from the `xmake_build` tool, which the model drives on
-- its own. this one is yours: no tokens, no round trip, no second terminal.
--
-- the arguments are passed through untouched, so everything you know about the
-- xmake command line is still true here — `/xmake f -m debug`, `/xmake run -d
-- myapp --arg`, `/xmake build -vD`.
--

-- imports
import("harness.util.util")

-- the subcommands offered by the completion
--
-- it is a shortlist of what one reaches for while working, not the full task
-- list: the point is to save the typing of the common ones, and anything else
-- still runs, it is just not suggested
--
local SUBCOMMANDS = {
    {"build",     "build the project"},
    {"run",       "run the target"},
    {"config",    "configure the project, e.g. -m debug"},
    {"f",         "configure the project (the short form)"},
    {"clean",     "clean the build files"},
    {"test",      "run the tests"},
    {"install",   "install the targets"},
    {"uninstall", "uninstall the targets"},
    {"package",   "package the targets"},
    {"require",   "install the dependencies"},
    {"show",      "show the project and the target information"},
    {"project",   "generate the ide project files, e.g. -k compile_commands"},
    {"format",    "format the source files"},
    {"check",     "run the static analysis"},
    {"update",    "update xmake itself"},
    {"repo",      "manage the package repositories"},
    {"lua",       "run a lua script"},
    {"doctor",    "check the xmake environment"},
    {"version",   "show the xmake version"}
}

-- describe the command
function command()
    return {
        name = "xmake",
        description = "Run xmake here without spending tokens, e.g. /xmake build, /xmake run -d",
        run = _run,
        complete = _complete
    }
end

-- the argument list of `/xmake <args>`
--
-- a bare `/xmake` builds, which is what a bare `xmake` does in a terminal
--
function argv(args)
    local line = (args or ""):trim()
    if line == "" then
        return {"build"}
    end
    return os.argv(line)
end

-- /xmake [subcommand] [arguments]
function _run(app, args)
    if not app.runterminal then
        return {kind = "message", text = "cannot run xmake here.", iserror = true}
    end
    local arguments = argv(args)
    local program = os.programfile() or "xmake"
    local rootdir = app.harness:rootdir()

    local starttime = os.mclock()
    local code = app:runterminal(function ()
        return os.execv(program, arguments, {curdir = rootdir, try = true})
    end)
    return {kind = "message", text = _summary(arguments, code, os.mclock() - starttime),
            iserror = code ~= 0}
end

-- what is printed once it is over
--
-- the failure says who did not see it, because the obvious next thought after a
-- broken build is to ask the model about it, and it was not watching
--
function _summary(arguments, code, elapsed)
    local line = string.format("xmake %s · %s · %s", table.concat(arguments, " "),
        code == 0 and "ok" or string.format("exit %s", tostring(code)), util.duration(elapsed))
    if code == 0 then
        return line
    end
    return line .. "\nthis ran in your terminal only, the agent did not see the output. "
        .. "ask it to build if you want it to look."
end

-- complete `/xmake <prefix>`
function _complete(harness, args)
    -- only the subcommand, the flags are xmake's own business and they change
    if (args or ""):find("%s") then
        return nil
    end
    local prefix = (args or ""):lower()
    local items = {}
    for _, subcommand in ipairs(SUBCOMMANDS) do
        if prefix == "" or subcommand[1]:startswith(prefix) then
            table.insert(items, {text = subcommand[1], description = subcommand[2]})
        end
    end
    return items
end
