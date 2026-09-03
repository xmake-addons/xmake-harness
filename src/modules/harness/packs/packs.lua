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
-- @file        packs.lua
--

--
-- a pack of markdown files, fetched from somewhere
--
-- skills and subagents are the same thing twice: a directory of markdown with
-- frontmatter, kept in the user's home, fetched on demand from a git repository
-- or a local directory, never bundled with the harness. only what is inside a
-- pack differs, and that is one function.
--
-- so the fetching, the naming, the resolving and the removing live here once,
-- and a kind is a small description of what it is a pack *of*:
--
--   {name = "agents", label = "subagent", sources = "agentsources",
--    roots = function (packdir) .. end, files = function (packdir) .. end}
--
-- adding a third kind — prompt templates, rules, whatever comes next — is that
-- table and nothing else.
--

-- imports
import("harness.util.gitpack")
import("harness.config.config")

-- where the packs of this kind are kept
function dir(kind)
    return path.join(config.homedir(), kind.name)
end

-- the registered sources, which the plugins add to from their `apply()`
function sources(kind, harness)
    return harness:service(kind.sources) or {}
end

-- register one
function register(kind, harness, source)
    assert(source and source.name and source.url,
           string.format("harness: invalid %s source!", kind.label))
    local results = harness:service(kind.sources) or {}
    results[source.name] = source
    harness:service(kind.sources, results)
    return source
end

-- resolve a specification to a source
--
-- the accepted forms, the same for every kind:
--
--   xmake                                     a registered pack name
--   github:xmake-io/xmake-agents              a github shorthand
--   https://github.com/user/repo.git          a git url
--   git@github.com:user/repo.git              a git url
--   /path/to/my-agents                        a local directory
--   /path/to/pack.zip                         a bundle
--
function resolve(kind, harness, spec)
    spec = (spec or ""):trim()
    if spec == "" then
        return nil, string.format("the %s pack is required, e.g. `/%s install xmake`",
                                  kind.label, kind.name)
    end

    local source = sources(kind, harness)[spec]
    if source then
        source = table.clone(source)
        -- an alias points at the real pack name, so it is installed only once
        source.name = source.packname or source.name
        return source
    end
    if spec:startswith("github:") then
        local repo = spec:sub(8)
        return {name = packname(repo), url = "https://github.com/" .. repo .. ".git"}
    end
    if spec:startswith("http://") or spec:startswith("https://") or spec:startswith("git@") then
        return {name = packname(spec), url = spec}
    end
    if os.isdir(spec) then
        return {name = dirname(spec), localdir = path.absolute(spec)}
    end
    if isarchive(spec) and os.isfile(spec) then
        return {name = archivename(spec), archive = path.absolute(spec)}
    end
    return nil, string.format("cannot resolve the %s pack: %s\n"
        .. "use a registered name, `github:<user>/<repo>`, a git url, a local directory "
        .. "or a `.zip`/`.tar.gz` bundle.", kind.label, spec)
end

-- the pack name of a local directory
--
-- the leading dot goes: `~/.claude` and `~/.dsh` are exactly the directories
-- one points this at, and `pack:.claude` reads like a mistake
--
function dirname(spec)
    local name = path.filename(path.normalize(path.absolute(spec)))
    return (name:gsub("^%.+", ""))
end

-- is this an archive we can unpack?
function isarchive(spec)
    spec = spec:lower()
    for _, extension in ipairs({".zip", ".tar.gz", ".tgz", ".tar.bz2", ".tar.xz"}) do
        if spec:endswith(extension) then
            return true
        end
    end
    return false
end

-- the pack name of an archive
function archivename(spec)
    local name = path.filename(spec)
    for _, extension in ipairs({".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".zip"}) do
        if name:lower():endswith(extension) then
            return name:sub(1, #name - #extension)
        end
    end
    return path.basename(name)
end

-- the pack name of a url
function packname(url)
    local name = url:gsub("%.git$", ""):gsub("[#?].*$", "")
    name = name:match("([^/]+)$") or name
    return name
end

-- the installed packs of this kind
--
-- @return  {{name = "xmake-agents", dir = "..", url = "..", count = 4, layout = ".."}}
--
function installed(kind)
    local results = {}
    for _, packdir in ipairs(os.dirs(path.join(dir(kind), "*"))) do
        local title, layout = kind.describe(packdir)
        table.insert(results, {
            name = path.filename(packdir),
            dir = packdir,
            url = gitpack.remoteurl(packdir),
            count = #kind.files(packdir),
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
-- they sit inside the user directory of this kind, so a plain scan of it would
-- find them twice over
--
function packdirs(kind)
    local results = {}
    for _, pack in ipairs(installed(kind)) do
        table.insert(results, pack.dir)
    end
    return results
end

-- is it installed?
function isinstalled(kind, name)
    return os.isdir(path.join(dir(kind), name))
end

-- install one, waiting for it
--
-- @param opt   {onprogress = function (message) end, context = <process context>}
-- @return      the pack info, or nil and the reason
--
function install(kind, source, opt)
    opt = opt or {}
    local targetdir = path.join(dir(kind), source.name)
    local ok, errors = gitpack.install({
        url = source.url,
        dir = targetdir,
        branch = source.branch,
        localdir = source.localdir,
        archive = source.archive,
        context = opt.context,
        onprogress = function (message)
            if opt.onprogress then
                opt.onprogress(string.format("the %s pack `%s`: %s", kind.label,
                                             source.name, message))
            end
        end})
    if not ok then
        return nil, errors
    end
    return info(kind, source.name, targetdir)
end

-- fetch one in the background and go on with something else
--
-- @param opt   {jobs = <the store>, context = .., onfinish = function (pack, errors) end}
-- @return      the job, or nil and the reason
--
function fetch(kind, source, opt)
    opt = opt or {}
    local targetdir = path.join(dir(kind), source.name)

    -- an archive or a directory on this machine is not a fetch: there is
    -- nothing to wait for, so it is done here and the callback told at once
    if source.archive or source.localdir then
        local pack, errors = install(kind, source, opt)
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
        label = string.format("the %s pack `%s`", kind.label, source.name),
        onfinish = function (ok, errors, job)
            local pack = ok and info(kind, source.name, targetdir) or nil
            if pack then
                job.summary = string.format("the %s pack `%s` is installed: %d %s",
                                            kind.label, pack.name, pack.count, kind.name)
            else
                job.summary = string.format("the %s pack `%s` could not be fetched: %s",
                                            kind.label, source.name, tostring(errors))
            end
            if opt.onfinish then
                opt.onfinish(pack, errors)
            end
        end})
end

-- take one away again
function remove(kind, name)
    local targetdir = path.join(dir(kind), name)
    if not os.isdir(targetdir) then
        return nil, string.format("the %s pack `%s` is not installed.", kind.label, name)
    end
    os.tryrm(targetdir)
    return true
end

-- what is in one, as everything else reads it
function info(kind, name, packdir)
    local title, layout = kind.describe(packdir)
    return {
        name = name,
        dir = packdir,
        roots = kind.roots(packdir),
        count = #kind.files(packdir),
        layout = layout,
        title = title,
        url = gitpack.remoteurl(packdir)
    }
end
