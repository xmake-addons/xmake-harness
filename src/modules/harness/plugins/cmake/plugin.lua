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
-- @file        plugin.lua
--

--
-- the cmake enhancement plugin
--
-- it is intentionally small: it shows that the harness is not tied to xmake,
-- the same seams give a cmake project its own tools and prompt facts.
--
-- it stays inert outside a cmake project, so a repository which has no
-- `CMakeLists.txt` never sees these tools.
--

-- the tools of this plugin, one module each
local TOOLS = {"cmake_configure", "cmake_build", "ctest"}

-- describe the plugin
function define()
    return {
        name = "cmake",
        description = "The cmake support: configure, build and test a cmake project."
    }
end

-- apply the plugin to the harness
function apply(harness, definition)
    local settings = (harness:config().plugins or {}).cmake or {}
    if settings.enabled == false then
        return
    end
    if not os.isfile(path.join(harness:rootdir(), "CMakeLists.txt")) then
        return
    end

    local tools = harness:service("tools")
    for _, name in ipairs(TOOLS) do
        local module = import("tools." .. name, {rootdir = definition.dir, anonymous = true})
        local tool = module.define()
        tool.run = tool.run or module.run
        tools:add(tool)
    end

    harness:on("prompt/environment", function (lines)
        table.insert(lines, "cmake project: yes (CMakeLists.txt)")
        return lines
    end, {owner = "cmake"})
end
