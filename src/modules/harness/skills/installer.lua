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
-- @file        installer.lua
--

--
-- the skill installer
--
-- a skill pack is a git repository (or a local directory) which holds the
-- `SKILL.md` directories, and it is installed into the harness home:
--
--   ~/.xmake/harness/skills/<name>/
--
-- nothing is bundled with the harness: the packs are maintained on their own
-- and are fetched only when the user asks for it, so they always get the
-- current version and never a stale copy shipped inside the addon.
--
-- the plugins register the well known packs, e.g. the xmake plugin registers
-- `xmake` -> https://github.com/xmake-io/xmake-skills, so the user only types
-- `/skills install xmake`.
--

-- imports
import("lib.detect.find_tool")
import("harness.util.text")
import("harness.config.config")

-- get the directory which holds the installed packs
function dir()
    return path.join(config.homedir(), "skills")
end

-- get the registered pack sources
--
-- @param harness   the harness context
-- @return          {xmake = {name = "xmake", url = "..", description = ".."}}
--
function sources(harness)
    local results = harness:service("skillsources") or {}
    return results
end

-- register a pack source, the plugins call it from their `apply()`
function register(harness, source)
    assert(source and source.name and source.url, "harness: invalid skill source!")
    local results = harness:service("skillsources") or {}
    results[source.name] = source
    harness:service("skillsources", results)
    return source
end

-- resolve the given specification to a source
--
-- the accepted forms:
--
--   xmake                                     a registered pack name
--   github:xmake-io/xmake-skills              a github shorthand
--   https://github.com/user/repo.git          a git url
--   git@github.com:user/repo.git              a git url
--   /path/to/my-skills                        a local directory
--
function resolve(harness, spec)
    spec = (spec or ""):trim()
    if spec == "" then
        return nil, "the skill pack is required, e.g. `/skills install xmake`"
    end

    local source = sources(harness)[spec]
    if source then
        source = table.clone(source)
        -- an alias points at the real pack name, so it is installed only once
        source.name = source.packname or source.name
        return source
    end
    if spec:startswith("github:") then
        local repo = spec:sub(8)
        return {name = _packname(repo), url = "https://github.com/" .. repo .. ".git"}
    end
    if spec:startswith("http://") or spec:startswith("https://") or spec:startswith("git@") then
        return {name = _packname(spec), url = spec}
    end
    if os.isdir(spec) then
        return {name = path.filename(path.normalize(spec)), localdir = path.absolute(spec)}
    end
    return nil, string.format("cannot resolve the skill pack: %s\n"
        .. "use a registered name, `github:<user>/<repo>`, a git url or a local directory.", spec)
end

-- get the pack name of the given url
function _packname(url)
    local name = url:gsub("%.git$", ""):gsub("[#?].*$", "")
    name = name:match("([^/]+)$") or name
    return name
end

-- get the installed packs
--
-- @return  {{name = "xmake-skills", dir = "..", url = "..", skills = 54}}
--
function installed()
    local results = {}
    for _, packdir in ipairs(os.dirs(path.join(dir(), "*"))) do
        local name = path.filename(packdir)
        table.insert(results, {
            name = name,
            dir = packdir,
            url = _remoteurl(packdir),
            skills = #_skillfiles(packdir),
            isgit = os.isdir(path.join(packdir, ".git"))
        })
    end
    table.sort(results, function (a, b) return a.name < b.name end)
    return results
end

-- is the given pack installed?
function isinstalled(name)
    return os.isdir(path.join(dir(), name))
end

-- get the skills directory of an installed pack
--
-- a pack usually keeps its skills in a `skills` subdirectory, but a flat layout
-- works too
--
function skillsdir(packdir)
    local subdir = path.join(packdir, "skills")
    if os.isdir(subdir) then
        return subdir
    end
    return packdir
end

-- count the skill files of the given directory
function _skillfiles(packdir)
    local results = {}
    local root = skillsdir(packdir)
    for _, pattern in ipairs({"*/SKILL.md", "*/*/SKILL.md", "*/*/*/SKILL.md"}) do
        for _, filepath in ipairs(os.files(path.join(root, pattern))) do
            table.insert(results, filepath)
        end
    end
    return results
end

-- get the git remote url of the given pack
function _remoteurl(packdir)
    if not os.isdir(path.join(packdir, ".git")) then
        return nil
    end
    local git = find_tool("git")
    if not git then
        return nil
    end
    local url = try { function () return os.iorunv(git.program, {"-C", packdir, "remote", "get-url", "origin"}) end }
    return url and url:trim() or nil
end

-- install a pack
--
-- @param source    the resolved source, @see resolve()
-- @param opt       the options, e.g. {update = true, onprogress = function (message) end}
-- @return          the installed pack info, or nil and the errors
--
function install(source, opt)
    opt = opt or {}
    local targetdir = path.join(dir(), source.name)
    local notify = opt.onprogress or function () end

    -- a local directory is linked in place, so the user can develop a pack
    if source.localdir then
        if os.isdir(targetdir) then
            os.tryrm(targetdir)
        end
        os.mkdir(path.directory(targetdir))
        local ok = try { function () os.ln(source.localdir, targetdir) return true end }
        if not ok then
            os.cp(source.localdir, targetdir)
        end
        notify(string.format("the skill pack `%s` is linked from %s", source.name, source.localdir))
        return _packinfo(source.name, targetdir)
    end

    local git = find_tool("git")
    if not git then
        return nil, "git is not found, it is required to install a skill pack."
    end

    local errors
    if os.isdir(path.join(targetdir, ".git")) then
        notify(string.format("updating `%s` ..", source.name))
        local ok = try {
            function ()
                os.iorunv(git.program, {"-C", targetdir, "pull", "--ff-only"})
                return true
            end,
            catch { function (errs) errors = errs end }
        }
        if not ok then
            return nil, string.format("failed to update %s: %s", source.name, tostring(errors))
        end
    else
        notify(string.format("cloning %s ..", source.url))
        os.tryrm(targetdir)
        os.mkdir(path.directory(targetdir))
        local argv = {"clone", "--depth", "1"}
        if source.branch then
            table.insert(argv, "--branch")
            table.insert(argv, source.branch)
        end
        table.insert(argv, source.url)
        table.insert(argv, targetdir)
        local ok = try {
            function ()
                os.iorunv(git.program, argv)
                return true
            end,
            catch { function (errs) errors = errs end }
        }
        if not ok then
            return nil, string.format("failed to clone %s: %s", source.url, tostring(errors))
        end
    end
    return _packinfo(source.name, targetdir)
end

-- remove an installed pack
function remove(name)
    local targetdir = path.join(dir(), name)
    if not os.isdir(targetdir) then
        return nil, string.format("the skill pack `%s` is not installed.", name)
    end
    os.tryrm(targetdir)
    return true
end

-- get the info of an installed pack
function _packinfo(name, packdir)
    return {
        name = name,
        dir = packdir,
        skillsdir = skillsdir(packdir),
        skills = #_skillfiles(packdir),
        url = _remoteurl(packdir)
    }
end

-- load all the installed packs into the skill registry
function loadall(harness)
    local registry = harness:service("skills")
    local count = 0
    for _, pack in ipairs(installed()) do
        registry:adddir(skillsdir(pack.dir), "pack:" .. pack.name)
        count = count + 1
    end
    return count
end
