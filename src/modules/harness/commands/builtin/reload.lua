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
-- @file        reload.lua
--

--
-- the reload command: /reload
--
-- the session is the expensive thing in a running harness — it is the one with
-- the context in it — and everything else is read once at startup. so writing a
-- skill, editing the configuration or adding a command used to mean throwing the
-- session away to pick it up.
--

-- imports
import("harness.core.reload", {alias = "reloader"})

-- the commands of this group
function commands()
    return {
        {name = "reload", description = "Read the configuration, the skills, the subagents and the commands again",
         run = _reload}
    }
end

-- /reload
function _reload(app, args)
    local counted = reloader.everything(app.harness)
    return {kind = "message", text = string.format(
        "reloaded: %d skill%s, %d subagent%s, %d command%s, and the configuration.",
        counted.skills, counted.skills == 1 and "" or "s",
        counted.agents, counted.agents == 1 and "" or "s",
        counted.commands, counted.commands == 1 and "" or "s")}
end
