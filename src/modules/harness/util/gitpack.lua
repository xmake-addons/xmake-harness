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
-- @file        gitpack.lua
--

--
-- the git packs
--
-- the harness fetches a few things which are maintained elsewhere: the skill
-- packs and the xmake documentation. they are never bundled, they are cloned
-- into the harness home when the user asks for them, and updated with a pull.
--

-- imports
import("lib.detect.find_tool")

-- install or update a pack
--
-- @param opt   the options
--              - url       the git url
--              - dir       where it goes
--              - branch    the branch, optional
--              - localdir  a local directory to link instead of cloning
--              - onprogress a function which reports what is happening
--
-- @return      true, or false and the errors
--
function install(opt)
    opt = opt or {}
    local notify = opt.onprogress or function () end
    if opt.localdir then
        return _link(opt, notify)
    end
    return _clone(opt, notify)
end

-- link a local directory in place, so the user can develop it
function _link(opt, notify)
    if os.isdir(opt.dir) then
        os.tryrm(opt.dir)
    end
    os.mkdir(path.directory(opt.dir))

    -- a link keeps the edits visible at once, a copy is the fallback for the
    -- filesystems which have none
    if not try { function () os.ln(opt.localdir, opt.dir) return true end } then
        os.cp(opt.localdir, opt.dir)
    end
    notify(string.format("linked from %s", opt.localdir))
    return true
end

-- clone or update a git repository
function _clone(opt, notify)
    local git = find_tool("git")
    if not git then
        return false, "git is not found, it is required to fetch this."
    end

    if os.isdir(path.join(opt.dir, ".git")) then
        notify(string.format("updating %s ..", path.filename(opt.dir)))
        local ok, errors = run(git, {"-C", opt.dir, "pull", "--ff-only"})
        if not ok then
            return false, string.format("failed to update %s: %s", path.filename(opt.dir), tostring(errors))
        end
        return true
    end

    notify(string.format("cloning %s ..", opt.url))
    os.tryrm(opt.dir)
    os.mkdir(path.directory(opt.dir))
    local argv = {"clone", "--depth", "1"}
    if opt.branch then
        table.insert(argv, "--branch")
        table.insert(argv, opt.branch)
    end
    local ok, errors = run(git, table.join(argv, {opt.url, opt.dir}))
    if not ok then
        return false, string.format("failed to clone %s: %s", opt.url, tostring(errors))
    end
    return true
end

-- run one git command
function run(git, argv)
    local errors
    local ok = try {
        function ()
            os.iorunv(git.program, argv)
            return true
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    return ok or false, errors
end

-- get the remote url of a checkout
function remoteurl(dir)
    if not os.isdir(path.join(dir, ".git")) then
        return nil
    end
    local git = find_tool("git")
    if not git then
        return nil
    end
    local url = try { function () return os.iorunv(git.program, {"-C", dir, "remote", "get-url", "origin"}) end }
    return url and url:trim() or nil
end
