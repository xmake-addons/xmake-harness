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
-- @file        builtin.lua
--

--
-- the builtin slash commands
--
-- they are modelled after the claude code commands, so the muscle memory works.
-- every group lives in its own module under `commands/builtin`, and each of
-- them exports `commands()`.
--

-- the command groups
local GROUPS = {"session", "model", "context", "loop", "rewind", "jobs", "skills", "mcp", "info"}

-- get all the builtin commands
function commands()
    local results = {}
    for _, group in ipairs(GROUPS) do
        local module = import("harness.commands.builtin." .. group, {anonymous = true})
        for _, command in ipairs(module.commands()) do
            table.insert(results, command)
        end
    end
    return results
end
