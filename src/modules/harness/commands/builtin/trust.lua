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
-- @file        trust.lua
--

--
-- the trust command: /trust
--
-- the question is asked once, before anything in the directory is read, and the
-- answer is kept. this is how to see it and how to change it — including the
-- common case of having said no in a hurry, @see harness.config.trust
--

-- imports
import("harness.config.trust")
import("harness.core.reload", {alias = "reloader"})

-- the commands of this group
function commands()
    return {
        {name = "trust", description = "Show or change what this directory is allowed to tell the agent",
         run = _trust}
    }
end

-- /trust [yes|no|forget]
function _trust(app, args)
    local rootdir = app.harness:rootdir()
    local what = (args or ""):trim():lower()

    if what == "yes" or what == "on" then
        return _set(app, rootdir, true)
    elseif what == "no" or what == "off" then
        return _set(app, rootdir, false)
    elseif what == "forget" then
        trust.forget(rootdir)
        return {kind = "message", text = string.format(
            "forgotten: %s will be asked about the next time it is opened.", rootdir)}
    elseif what ~= "" then
        return {kind = "message", text = "/trust [yes|no|forget]", iserror = true}
    end
    return _status(app, rootdir)
end

-- /trust
function _status(app, rootdir)
    local kinds, found = trust.requires(rootdir)
    if #kinds == 0 then
        return {kind = "message", text = string.format(
            "%s\nnothing here asks to be trusted: no instructions, no skills, no plugins.", rootdir)}
    end

    local trusted = app.harness:config()._trusted
    local lines = {rootdir, ""}
    table.insert(lines, string.format("it carries %s:", table.concat(kinds, ", ")))
    for _, name in ipairs(found) do
        table.insert(lines, "  " .. name)
    end
    table.insert(lines, "")
    if trusted == false then
        table.insert(lines, "none of it is being read. /trust yes to read it.")
    else
        table.insert(lines, "all of it is being read. /trust no to stop.")
    end
    local remembered = trust.remembered(rootdir)
    if remembered ~= nil then
        table.insert(lines, string.format("the answer is remembered as %s, /trust forget to be asked again.",
                                          remembered and "yes" or "no"))
    end
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /trust yes | /trust no
--
-- the answer is written down and everything is read again, so that saying yes
-- is not one more thing which needs a restart to mean anything
--
function _set(app, rootdir, trusted)
    trust.remember(rootdir, trusted)
    app.harness:config()._trusted = trusted
    local counted = reloader.everything(app.harness)
    return {kind = "message", text = string.format(
        "%s: %d skill%s, %d subagent%s, %d command%s.%s",
        trusted and "trusted" or "not trusted",
        counted.skills, counted.skills == 1 and "" or "s",
        counted.agents, counted.agents == 1 and "" or "s",
        counted.commands, counted.commands == 1 and "" or "s",
        trusted and "" or "\nwhat this project already said in this conversation is still in it, "
                       .. "/clear to start without it.")}
end
