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
-- @file        paths.lua
--

--
-- the protected paths
--
-- editing the sources of the project is the everyday work of the agent, it
-- should not ask for it. a few paths inside the project are another matter:
-- the git internals hold the history, the dotfiles hold the secrets, and both
-- are hard to recover from a wrong write.
--

-- the paths which always deserve a confirmation
--
-- they are matched against the path relative to the project, so a `.env` of the
-- project is protected while a `src/env.c` is not
--
local PROTECTED = {
    {pattern = "^%.git/",           reason = "it writes into the git internals"},
    {pattern = "^%.git$",           reason = "it writes into the git internals"},
    {pattern = "^%.ssh/",           reason = "it writes into the ssh directory"},
    {pattern = "^%.env",            reason = "it writes into an environment file, it usually holds the secrets"},
    {pattern = "/%.env",            reason = "it writes into an environment file, it usually holds the secrets"},
    {pattern = "%.pem$",            reason = "it writes a certificate"},
    {pattern = "%.key$",            reason = "it writes a key file"},
    {pattern = "id_rsa",            reason = "it writes an ssh key"},
    {pattern = "id_ed25519",        reason = "it writes an ssh key"},
    {pattern = "%.netrc$",          reason = "it writes the network credentials"},
    {pattern = "%.npmrc$",          reason = "it writes the npm credentials"},
    {pattern = "%.pypirc$",         reason = "it writes the pypi credentials"},
    {pattern = "credentials",       reason = "it writes a credentials file"},
    {pattern = "%.xmake%-harness/", reason = "it writes into the harness configuration"},

    -- the build-tool configuration which grants code execution: writing one of
    -- them makes the next `npm install` or `git commit` run whatever it says
    {pattern = "%.npmrc$",           reason = "it writes a build-tool config which can run code"},
    {pattern = "%.yarnrc",           reason = "it writes a build-tool config which can run code"},
    {pattern = "bunfig%.toml$",      reason = "it writes a build-tool config which can run code"},
    {pattern = "%.bazelrc$",         reason = "it writes a build-tool config which can run code"},
    {pattern = "%.pre%-commit%-config", reason = "it writes a hook config which can run code"},
    {pattern = "^%.husky/",          reason = "it writes a git hook"},
    {pattern = "^%.devcontainer/",   reason = "it writes the devcontainer config which can run code"},
    {pattern = "^%.github/workflows/", reason = "it writes a ci workflow which can run code"},
    {pattern = "^%.vscode/tasks%.json", reason = "it writes an editor task which can run code"}
}

-- is the given path inside the project?
function inworkspace(cwd, filepath)
    if not cwd or not filepath then
        return false
    end
    local rootdir = path.normalize(path.absolute(cwd))
    filepath = path.normalize(path.absolute(filepath, rootdir))
    return filepath == rootdir or filepath:startswith(rootdir .. path.sep())
end

-- is the given path protected?
--
-- @param filepath  the path, absolute or relative to the project
-- @param opt       the options, e.g. {cwd = "..", extra = {"secrets/*"}}
--
-- @return          the reason, or nil when it is an ordinary file
--
function isprotected(filepath, opt)
    opt = opt or {}
    if not filepath then
        return nil
    end
    local relative = filepath
    if opt.cwd then
        relative = path.relative(path.absolute(filepath, opt.cwd), opt.cwd) or filepath
    end
    relative = path.unix(relative)

    for _, item in ipairs(PROTECTED) do
        if relative:find(item.pattern) then
            return item.reason
        end
    end
    for _, pattern in ipairs(opt.extra or {}) do
        if _matchglob(relative, pattern) then
            return string.format("it matches the protected path `%s`", pattern)
        end
    end
end

-- match a glob against the path
function _matchglob(str, pattern)
    local luapattern = "^" .. path.unix(pattern):gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1"):gsub("%*%*", "\1")
        :gsub("%*", "[^/]*"):gsub("\1", ".*") .. "$"
    return str:match(luapattern) ~= nil
end

-- get the protected patterns, they are shown by `/permissions`
function protected()
    local results = {}
    for _, item in ipairs(PROTECTED) do
        table.insert(results, item.pattern)
    end
    return results
end
