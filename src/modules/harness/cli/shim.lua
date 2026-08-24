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
-- @file        shim.lua
--

--
-- the application shim of the command line
--
-- the slash commands are written against the tui application, and they only use
-- a small part of it: the harness, the session, the mode, a notice and a
-- question. this shim gives them the same surface outside the tui, so one
-- command implementation serves both.
--

-- imports
import("core.base.option")
import("harness.ui.theme")
import("harness.util.util")
import("harness.core.session", {alias = "sessions"})

-- create a shim for the given context
function new(context, options)
    options = options or {}
    return {
        harness = context,
        session = options.session or sessions.new({cwd = context:rootdir()}),
        mode = options.mode or (context:config().permission or {}).mode or "default",
        notify = _notify,
        ask = _ask,
        setmode = _setmode,
        runterminal = _runterminal,
        newsession = _newsession,
        setsession = _setsession
    }
end

-- write one line of somebody else's text
--
-- never `print` and never `cprint`: both hand the string to `vformat`, which
-- reads `$(..)` as an xmake variable and replaces it with nothing. a command
-- like `rm -rf $(cat targets)` would be shown as `rm -rf ` — the user would be
-- approving something milder than what is about to run. the style is applied
-- around the text instead of through a format string
--
function _writeline(str, style)
    io.write(style and theme.styled(style, tostring(str)) or tostring(str), "\n")
end

-- print a progress notice
function _notify(self, message)
    _writeline(message, "dim")
end

-- ask a question on the plain terminal
function _ask(self, request)
    for _, line in ipairs(request.lines or {}) do
        _writeline(line)
    end
    local options = request.options or {{text = "Yes", value = true}, {text = "No", value = false}}
    if option.get("yes") then
        return options[1].value
    end
    if not io.isatty() then
        return options[#options].value
    end

    _writeline(request.question or "Do you want to proceed?", "title")
    for idx, item in ipairs(options) do
        _writeline(string.format("  %d. ", idx) .. tostring(item.text))
    end
    io.write("choose [1]: ")
    io.flush()
    return _answer((io.read("l") or ""):trim(), options)
end

-- resolve the typed answer to an option value
function _answer(answer, options)
    local index = tonumber(answer)
    if answer == "" then
        index = 1
    elseif answer:lower() == "y" or answer:lower() == "yes" then
        index = 1
    elseif answer:lower() == "n" or answer:lower() == "no" then
        index = #options
    end
    local option = options[index or #options] or options[#options]
    return option.value
end

-- set the permission mode
function _setmode(self, mode)
    self.mode = mode
    util.tset(self.harness:config(), "permission.mode", mode)
end

-- run a command which owns the terminal
--
-- there is no live region and no raw mode out here, so there is nothing to take
-- down first: the command already has the terminal
--
function _runterminal(self, run)
    return run()
end

-- start a new session
function _newsession(self)
    self.session = sessions.new({cwd = self.harness:rootdir()})
    return self.session
end

-- set the current session
function _setsession(self, session)
    self.session = session
end
