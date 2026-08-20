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
-- @file        main.lua
--

-- imports
import("core.base.option")
import("core.sandbox.module")

-- register the harness modules directory of this addon
--
-- it works both for the installed addon and for the source tree,
-- so we can debug the source directly without any installation,
-- @see scripts/srcenv.profile
--
function _register_moduledirs()
    local dirs = {}
    table.insert(dirs, path.normalize(path.join(os.scriptdir(), "..", "..", "modules")))
    local devdir = os.getenv("XMAKE_HARNESS_DEV")
    if devdir then
        table.insert(dirs, 1, path.join(devdir, "src", "modules"))
    end
    for _, dir in ipairs(dirs) do
        if os.isdir(path.join(dir, "harness")) then
            module.add_directories(dir)
            return dir
        end
    end
    raise("harness: cannot find the harness modules directory!")
end

-- the main entry of `xmake ai`
function main()
    _register_moduledirs()
    import("harness.cli.ai")(option.options())
end
