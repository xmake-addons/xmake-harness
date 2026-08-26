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
-- @file        prompt.lua
--

--
-- the xmake sections of the system prompt
--
-- they only appear in a project which really is an xmake project, so the model
-- of a plain repository never pays for them.
--

-- imports
import("harness.util.util")
import("harness.shell.exec")

-- contribute the xmake facts and rules to the system prompt
function apply(harness, opt)
    opt = opt or {}
    harness:on("prompt/environment", function (lines)
        local rootdir = harness:rootdir()
        if os.isfile(path.join(rootdir, "xmake.lua")) then
            table.insert(lines, string.format("xmake project: yes (%s)", _version()))
            local targets = _targets(rootdir)
            if #targets > 0 then
                table.insert(lines, string.format("xmake targets: %s", table.concat(targets, ", ")))
            end
        end
        return lines
    end, {owner = "xmake"})

    harness:on("prompt/sections", function (sections)
        if os.isfile(path.join(harness:rootdir(), "xmake.lua")) then
            table.insert(sections, {name = "xmake", content = _section(opt.hasskills)})
        end
        return sections
    end, {owner = "xmake"})
end

-- the section which tells the model how to work in an xmake project
function _section(hasskills)
    local lines = {"# Building with xmake", "",
        "This project is built with xmake, use the `xmake_*` tools instead of the raw",
        "shell commands, they report the errors in a structured way:", "",
        "- `xmake_create` to start a new project, a new target or a new library: it",
        "  scaffolds from an xmake template, which is the layout the project is",
        "  supposed to have — do not hand-write the first `xmake.lua` and the first",
        "  source file instead",
        "- `xmake_config` to configure (the modes, the toolchains, the options)",
        "- `xmake_build` to build, it is the fastest way to check that your change compiles",
        "- `xmake_run` / `xmake_test` to run the targets and the tests",
        "- `xmake_show` to inspect the project: the targets, the options, the toolchains",
        "- `xmake_lua` to run a small lua script inside the xmake runtime, prefer it over",
        "  writing the shell/python scripts: it is cross-platform and has no dependency",
        "- `xrepo` to search and inspect the c/c++ packages", "",
        "Rules which matter in an `xmake.lua`:", "",
        "- the description scope (`target`, `add_files`, ..) is declarative, the script",
        "  scope (`on_load`, `on_build`, ..) is imperative, never mix them",
        "- add the dependencies with `add_requires`/`add_packages`, not with the manual",
        "  include and link flags",
        "- prefer the builtin rules (`mode.debug`, `mode.release`, ..) over the hand-written flags"}
    if hasskills then
        table.insert(lines, "")
        table.insert(lines, "The `xmake-*` skills hold the detailed recipes, load the matching one with")
        table.insert(lines, "`use_skill` before doing the work.")
    end
    return table.concat(lines, "\n")
end

-- get the xmake version
function _version()
    local version = _g.version
    if version == nil then
        local result = try { function () return os.iorunv(exec.xmakeprogram(), {"--version"}) end }
        version = result and (result:match("xmake v([%d%.%+]+)") or "unknown") or "unknown"
        _g.version = version
    end
    return "v" .. version
end

-- get the target names of the project
--
-- we parse them from the `xmake.lua` files directly, so we never trigger a
-- configure just to fill in a prompt section
--
function _targets(rootdir)
    local targets = {}
    local files = table.join({path.join(rootdir, "xmake.lua")}, os.files(path.join(rootdir, "*", "xmake.lua")))
    for _, filepath in ipairs(files) do
        if os.isfile(filepath) then
            for name in (io.readfile(filepath) or ""):gmatch("target%s*%(%s*[\"']([%w%._%-]+)[\"']") do
                table.insert(targets, name)
            end
        end
    end
    return util.unique(targets)
end
