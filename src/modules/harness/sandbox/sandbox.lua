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
-- @file        sandbox.lua
--

--
-- the sandbox seam
--
-- the tools which spawn the processes ask this module to wrap their argv, so
-- the confinement backend is swappable and the tools never know about it.
--
-- the backends:
--
--   none      run the commands directly (the default)
--   seatbelt  macos, `sandbox-exec` with a generated profile
--   bwrap     linux, `bwrap` with the read-only bind mounts
--
-- on windows there is no builtin lightweight confinement, so the `none` backend
-- is used and the permission policy is the only guard.
--

-- imports
import("lib.detect.find_program")

-- find the given program, we cannot use find_tool here because the confinement
-- programs have no `--version` to probe
function _find(name)
    local program = _g[name]
    if program == nil then
        for _, dir in ipairs({"/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"}) do
            local filepath = path.join(dir, name)
            if os.isexec(filepath) then
                program = filepath
                break
            end
        end
        if not program then
            program = find_program(name, {check = function (program) return true end}) or false
        end
        _g[name] = program
    end
    return program or nil
end

-- get the available backends of the current host
function backends()
    local results = {"none"}
    if os.host() == "macosx" and _find("sandbox-exec") then
        table.insert(results, "seatbelt")
    elseif os.host() == "linux" and _find("bwrap") then
        table.insert(results, "bwrap")
    end
    return results
end

-- get the backend which is used by the given configuration
function backend(config)
    local settings = config.sandbox or {}
    if not settings.enabled then
        return "none"
    end
    local name = settings.backend or "auto"
    if name == "auto" then
        local available = backends()
        return available[#available]
    end
    if not table.contains(backends(), name) then
        return "none"
    end
    return name
end

-- wrap the given command with the sandbox
--
-- @return  the program and the arguments to spawn
--
function wrap(context, program, argv)
    local config = context.config or {}
    local name = backend(config)
    if name == "seatbelt" then
        return _wrap_seatbelt(context, program, argv)
    elseif name == "bwrap" then
        return _wrap_bwrap(context, program, argv)
    end
    return program, argv
end

-- get the writable directories
function _writabledirs(context)
    local dirs = {context.cwd or os.curdir()}
    for _, dir in ipairs((context.config.sandbox or {}).writabledirs or {}) do
        table.insert(dirs, dir)
    end
    table.insert(dirs, os.tmpdir())
    return dirs
end

-- wrap the command with the macos seatbelt
function _wrap_seatbelt(context, program, argv)
    local settings = context.config.sandbox or {}
    local rules = {
        "(version 1)",
        "(allow default)",
        "(deny file-write*)",
        "(allow file-write* (subpath \"/dev\"))"
    }
    for _, dir in ipairs(_writabledirs(context)) do
        table.insert(rules, string.format("(allow file-write* (subpath %q))", path.normalize(dir)))
    end
    if not settings.network then
        table.insert(rules, "(deny network*)")
        table.insert(rules, "(allow network* (local unix))")
    end
    local profile = table.concat(rules, "\n")
    local newargv = {"-p", profile, program}
    for _, arg in ipairs(argv) do
        table.insert(newargv, arg)
    end
    return _find("sandbox-exec"), newargv
end

-- wrap the command with the linux bubblewrap
function _wrap_bwrap(context, program, argv)
    local settings = context.config.sandbox or {}
    local newargv = {"--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"}
    for _, dir in ipairs(_writabledirs(context)) do
        dir = path.normalize(dir)
        if os.isdir(dir) then
            table.insert(newargv, "--bind")
            table.insert(newargv, dir)
            table.insert(newargv, dir)
        end
    end
    if not settings.network then
        table.insert(newargv, "--unshare-net")
    end
    table.insert(newargv, "--chdir")
    table.insert(newargv, context.cwd or os.curdir())
    table.insert(newargv, program)
    for _, arg in ipairs(argv) do
        table.insert(newargv, arg)
    end
    return _find("bwrap"), newargv
end

-- get the description of the current sandbox status
function status(config)
    local name = backend(config)
    if name == "none" then
        return "off"
    end
    local settings = config.sandbox or {}
    return string.format("%s%s", name, settings.network and " (network on)" or "")
end
