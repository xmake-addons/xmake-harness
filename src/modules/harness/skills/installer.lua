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
-- a skill pack is a git repository, a local directory or a `.zip`/`.tar.gz`
-- bundle. whatever layout the tool which produced it used — a plain skills
-- directory, a claude plugin, a claude marketplace, a dsh skills folder — is
-- recognised on arrival, @see harness.skills.bundle
--
-- it is installed into the harness home:
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
import("harness.util.gitpack")
import("harness.skills.bundle")
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
        return {name = _dirname(spec), localdir = path.absolute(spec)}
    end
    if _isarchive(spec) and os.isfile(spec) then
        return {name = _archivename(spec), archive = path.absolute(spec)}
    end
    return nil, string.format("cannot resolve the skill pack: %s\n"
        .. "use a registered name, `github:<user>/<repo>`, a git url, a local directory "
        .. "or a `.zip`/`.tar.gz` bundle.", spec)
end

-- get the pack name of a local directory
--
-- the leading dot goes: `~/.claude` and `~/.dsh` are exactly the directories
-- one points this at, and `pack:.claude` reads like a mistake
--
function _dirname(spec)
    local name = path.filename(path.normalize(path.absolute(spec)))
    return (name:gsub("^%.+", ""))
end

-- is this a packed bundle?
function _isarchive(spec)
    for _, extension in ipairs({".zip", ".tar.gz", ".tgz", ".tar.bz2", ".tar.xz", ".7z"}) do
        if spec:lower():endswith(extension) then
            return true
        end
    end
    return false
end

-- get the pack name of an archive, e.g. `my-skills-1.2.zip` -> `my-skills-1.2`
function _archivename(spec)
    local name = path.filename(spec)
    return (name:gsub("%.tar%.%w+$", ""):gsub("%.%w+$", ""))
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
        local title, layout = bundle.describe(packdir)
        table.insert(results, {
            name = name,
            dir = packdir,
            url = _remoteurl(packdir),
            skills = #_skillfiles(packdir),
            layout = layout,
            title = title,
            isgit = os.isdir(path.join(packdir, ".git"))
        })
    end
    table.sort(results, function (a, b) return a.name < b.name end)
    return results
end

-- the directories of the installed packs
--
-- they sit inside the user skills directory, so a plain scan of it would find
-- them too, @see harness.skills.registry.adddir
--
function packdirs()
    local results = {}
    for _, pack in ipairs(installed()) do
        table.insert(results, pack.dir)
    end
    return results
end

-- is the given pack installed?
function isinstalled(name)
    return os.isdir(path.join(dir(), name))
end

-- get the skills directory of an installed pack
--
-- a pack keeps its skills wherever its own tool put them, @see harness.skills.bundle
--
function skillsdir(packdir)
    return skillsdirs(packdir)[1] or packdir
end

-- get every skills directory of an installed pack
--
-- a claude marketplace is a directory of plugins and each of them may carry
-- its own skills, so one pack can have many
--
function skillsdirs(packdir)
    return bundle.roots(packdir)
end

-- count the skill files of the given pack
function _skillfiles(packdir)
    return bundle.skillfiles(packdir)
end

-- get the git remote url of the given pack
function _remoteurl(packdir)
    return gitpack.remoteurl(packdir)
end

-- install a pack
--
-- @param source    the resolved source, @see resolve()
-- @param opt       the options, e.g. {update = true, onprogress = function (message) end,
--                  context = <the process context, so that a slow clone can be interrupted>}
-- @return          the installed pack info, or nil and the errors
--
function install(source, opt)
    opt = opt or {}
    local targetdir = path.join(dir(), source.name)
    local ok, errors = gitpack.install({
        url = source.url,
        dir = targetdir,
        branch = source.branch,
        localdir = source.localdir,
        archive = source.archive,
        context = opt.context,
        onprogress = function (message)
            local notify = opt.onprogress
            if notify then
                notify(string.format("the skill pack `%s`: %s", source.name, message))
            end
        end})
    if not ok then
        return nil, errors
    end
    return _packinfo(source.name, targetdir)
end

-- fetch a pack in the background and go on with something else
--
-- @param source    the resolved source, @see resolve()
-- @param opt       {jobs = <the store>, context = .., onfinish = function (pack, errors) end}
-- @return          the job, or nil and the reason
--
function fetch(source, opt)
    opt = opt or {}
    local targetdir = path.join(dir(), source.name)

    -- an archive or a directory on this machine is not a fetch: there is nothing
    -- to wait for, so it is done here and the callback is told at once
    if source.archive or source.localdir then
        local pack, errors = install(source, opt)
        if opt.onfinish then
            opt.onfinish(pack, errors)
        end
        return pack and {id = "-", label = source.name, immediate = true} or nil, errors
    end

    return gitpack.start({
        url = source.url,
        dir = targetdir,
        branch = source.branch,
        jobs = opt.jobs,
        context = opt.context,
        label = string.format("the skill pack `%s`", source.name),
        onfinish = function (ok, errors, job)
            local pack = ok and _packinfo(source.name, targetdir) or nil
            if pack then
                job.summary = string.format("the skill pack `%s` is installed: %d skills",
                                            pack.name, pack.skills)
            else
                job.summary = string.format("the skill pack `%s` could not be fetched: %s",
                                            source.name, tostring(errors))
            end
            if opt.onfinish then
                opt.onfinish(pack, errors)
            end
        end})
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
    local title, layout = bundle.describe(packdir)
    return {
        name = name,
        dir = packdir,
        skillsdir = skillsdir(packdir),
        skillsdirs = skillsdirs(packdir),
        skills = #_skillfiles(packdir),
        layout = layout,
        title = title,
        url = _remoteurl(packdir)
    }
end

-- load all the installed packs into the skill registry
function loadall(harness)
    local registry = harness:service("skills")
    local count = 0
    for _, pack in ipairs(installed()) do
        for _, root in ipairs(skillsdirs(pack.dir)) do
            registry:adddir(root, "pack:" .. pack.name)
        end
        count = count + 1
    end
    return count
end
