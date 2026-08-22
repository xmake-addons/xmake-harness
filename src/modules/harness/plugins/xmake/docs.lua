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
-- @file        docs.lua
--

--
-- the xmake documentation
--
-- "how do i do X in xmake.lua" is the most common question an agent has, and
-- the answer it invents from memory is often a plausible api which does not
-- exist. the documentation is the cure, but only if it is cheap to consult:
--
--   api("add_files")   returns exactly one section, prototype and parameters
--   search("qt")       returns the matching lines across the documentation
--
-- looking up one api costs a fraction of what a grep dump costs, so it is the
-- first thing the tool tries.
--

-- imports
import("harness.fs.search")
import("harness.util.text")
import("harness.util.gitpack")
import("harness.config.config")

-- the upstream of the documentation
local URL = "https://github.com/xmake-io/xmake-docs.git"

-- where the single pages come from when there is no checkout
local RAWURL = "https://raw.githubusercontent.com/xmake-io/xmake-docs/master/docs"

-- the files which describe the api, they are fetched one by one when needed
--
-- the api of xmake lives in a handful of pages, and one of them answers most
-- questions: fetching the right page costs a second and a few kilobytes, while
-- cloning the whole documentation costs tens of megabytes nobody asked for
--
local PAGES = {
    "api/description/project-target.md",
    "api/description/global-interfaces.md",
    "api/description/builtin-modules.md",
    "api/description/configuration-option.md",
    "api/description/package-dependencies.md",
    "api/description/builtin-rules.md",
    "api/description/builtin-policies.md",
    "api/description/builtin-variables.md",
    "api/description/custom-rule.md",
    "api/description/custom-toolchain.md",
    "api/description/helper-interfaces.md",
    "api/description/conditions.md",
    "api/scripts/builtin-modules.md",
    "api/scripts/extension-modules.md"
}

-- where we keep our own clone
function dir()
    return path.join(config.homedir(), "docs", "xmake-docs")
end

-- find a local checkout of the documentation
--
-- only two places count: the one the user configured, and the one `/xmake-docs`
-- cloned for them. we never go looking around the home directory for something
-- which might be an unrelated fork or a checkout from two years ago — a wrong
-- answer from a stale copy is worse than fetching the page we need.
--
-- @return  the root of the markdown files, or nil when there is none
--
function find(harnessconfig)
    local settings = ((harnessconfig or {}).plugins or {}).xmake or {}

    -- @note a nil in the middle of a table constructor truncates its array
    -- part, the candidates are collected one by one
    local candidates = {}
    table.insert(candidates, settings.docsdir)
    table.insert(candidates, dir())

    for _, candidate in ipairs(candidates) do
        local root = _root(candidate)
        if root then
            return root
        end
    end
    return nil
end

-- get the markdown root of a checkout, e.g. `<repo>/docs`
function _root(dirpath)
    for _, subdir in ipairs({path.join(dirpath, "docs"), dirpath}) do
        if os.isdir(path.join(subdir, "api")) then
            return subdir
        end
    end
    return nil
end

-- is a local checkout available?
function isavailable(harnessconfig)
    return find(harnessconfig) ~= nil
end

-- where the fetched pages are cached
function cachedir()
    return path.join(config.homedir(), "docs", "cache")
end

-- get one documentation page
--
-- a checkout is used when there is one, otherwise the page is fetched once and
-- cached: the agent answers from the real documentation without anybody having
-- to install anything first
--
-- @return  the local file which holds the page, or nil
--
function page(name, opt)
    opt = opt or {}
    local rootdir = opt.rootdir or find(opt.config)
    if rootdir then
        local filepath = path.join(rootdir, name)
        if os.isfile(filepath) then
            return filepath
        end
    end
    return _fetch(name, opt)
end

-- fetch one page from the upstream
function _fetch(name, opt)
    local filepath = path.join(cachedir(), name)
    local maxage = (opt.maxage or 7 * 24 * 3600)
    if os.isfile(filepath) and os.time() - (os.mtime(filepath) or 0) < maxage then
        return filepath
    end
    if opt.offline then
        return os.isfile(filepath) and filepath or nil
    end

    local curl = _curl()
    if not curl then
        return os.isfile(filepath) and filepath or nil
    end
    os.mkdir(path.directory(filepath))
    local tmpfile = os.tmpfile()
    local ok = try {
        function ()
            os.execv(curl, {"-fsSL", "--max-time", "20", "-o", tmpfile,
                            RAWURL .. "/" .. name}, {stdout = os.nuldev(), stderr = os.nuldev()})
            return true
        end
    }
    if ok and os.isfile(tmpfile) and (os.filesize(tmpfile) or 0) > 0 then
        os.mv(tmpfile, filepath)
        return filepath
    end
    os.tryrm(tmpfile)
    return os.isfile(filepath) and filepath or nil
end

-- find curl
function _curl()
    local cached = _g.curl
    if cached == nil then
        local tool = import("lib.detect.find_tool", {anonymous = true})("curl")
        cached = tool and tool.program or false
        _g.curl = cached
    end
    return cached or nil
end

-- fetch or update the documentation
function install(opt)
    opt = opt or {}
    local ok, errors = gitpack.install({url = URL, dir = dir(), onprogress = opt.onprogress})
    if not ok then
        return nil, errors
    end
    return _root(dir())
end

-- look one api up
--
-- @param name  the api name, e.g. "add_files", "set_kind"
-- @param opt   the options, e.g. {rootdir = "..", language = "zh"}
--
-- @return      the section text and the file it came from, or nil
--
function api(name, opt)
    opt = opt or {}
    if not name or name == "" then
        return nil
    end

    -- a checkout answers from any of its files, and it has the translations
    local rootdir = opt.rootdir or find(opt.config)
    if rootdir then
        local roots = {}
        if opt.language == "zh" and os.isdir(path.join(rootdir, "zh", "api")) then
            table.insert(roots, path.join(rootdir, "zh"))
        end
        table.insert(roots, rootdir)
        for _, root in ipairs(roots) do
            for _, filepath in ipairs(_apifiles(root)) do
                local section = _section(filepath, name)
                if section then
                    return section, filepath
                end
            end
        end
        return nil
    end

    -- without one we fetch the pages which describe the api, most questions are
    -- answered by the first or the second of them
    for _, pagename in ipairs(_pages(opt.language)) do
        local filepath = page(pagename, opt)
        if filepath then
            local section = _section(filepath, name)
            if section then
                return section, filepath
            end
        end
    end
    return nil
end

-- the pages to look through, in the language of the user
function _pages(lang)
    if lang ~= "zh" then
        return PAGES
    end
    local results = {}
    for _, name in ipairs(PAGES) do
        table.insert(results, "zh/" .. name)
    end
    for _, name in ipairs(PAGES) do
        table.insert(results, name)
    end
    return results
end

-- get the files which describe the api
function _apifiles(rootdir)
    local results = {}
    for _, pattern in ipairs({"api/**/*.md", "api/*.md"}) do
        for _, filepath in ipairs(os.files(path.join(rootdir, pattern))) do
            table.insert(results, filepath)
        end
    end
    return results
end

-- extract the section of the given api from one file
--
-- the documentation writes one api per `## name` heading, and everything until
-- the next one belongs to it
--
function _section(filepath, name)
    local lines = {}
    local inside = false
    for line in io.lines(filepath) do
        local heading = line:match("^##%s+([%w_%.:%-]+)")
        if heading then
            if inside then
                break
            end
            inside = (heading == name)
        end
        if inside then
            table.insert(lines, line)
        end
    end
    if #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n"):trim()
end

-- list the api names of the documentation
function apis(opt)
    opt = opt or {}
    local rootdir = opt.rootdir or find(opt.config)
    local files = {}
    if rootdir then
        files = _apifiles(rootdir)
    else
        for _, name in ipairs(PAGES) do
            local filepath = page(name, table.join(opt, {offline = true}))
            if filepath then
                table.insert(files, filepath)
            end
        end
    end

    local results = {}
    for _, filepath in ipairs(files) do
        for line in io.lines(filepath) do
            local heading = line:match("^##%s+([%w_%.:%-]+)")
            if heading and heading:find("_", 1, true) then
                table.insert(results, heading)
            end
        end
    end
    table.sort(results)
    return results
end

-- search the documentation
--
-- @return  the search result, @see harness.fs.search
--
function grep(keyword, opt)
    opt = opt or {}
    local rootdir = opt.rootdir or find(opt.config)
    if not rootdir then
        -- without a checkout we search what we fetched so far
        for _, name in ipairs(_pages(opt.language)) do
            page(name, opt)
        end
        rootdir = cachedir()
        if not os.isdir(rootdir) then
            return nil
        end
    end
    return search.run({
        pattern = keyword,
        rootdir = (opt.language == "zh" and os.isdir(path.join(rootdir, "zh"))) and path.join(rootdir, "zh") or rootdir,
        include = "*.md",
        mode = opt.mode or "content",
        context = opt.context or 0,
        ignorecase = true,
        limit = opt.limit or 20
    })
end
