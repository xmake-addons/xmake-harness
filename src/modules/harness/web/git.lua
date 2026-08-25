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
-- @file        git.lua
--

--
-- what git knows about this project
--
-- only what the rest of the web ui actually needs of it: whether there is a
-- repository, and the files it is tracking — which is the fastest list of a
-- project anybody has, and the only one which already knows what is ignored,
-- @see harness.web.files
--
-- what the agent changed is *not* asked of git, @see harness.web.changes: a
-- working tree holds whatever was already in it, and that is not an answer to
-- "what did it change".
--
-- `git` is not a dependency we ship; it is the thing the user already has and
-- already trusts with this repository.
--

-- run git in the given directory
--
-- @return  the stdout, or nil and the reason
--
function _git(rootdir, argv)
    local outdata
    local errors
    try {
        function ()
            outdata = os.iorunv("git", argv, {curdir = rootdir})
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }
    if outdata == nil then
        return nil, errors or "git could not be run"
    end
    return outdata
end

-- where the repository starts, or nil when there is none
function root(rootdir)
    local out = _git(rootdir, {"rev-parse", "--show-toplevel"})
    if not out then
        return nil
    end
    out = out:trim()
    return out ~= "" and path.normalize(out) or nil
end

-- the files of the repository: tracked, plus the ones it does not know yet
--
-- not `-z`, tempting as it is: `os.iorunv` reads the output through
-- `io.readfile`, which guesses the encoding, and a stream full of nul bytes
-- guesses utf-16. the text comes back as mojibake and the parse finds nothing,
-- @see xmake/core/base/io.lua. `core.quotepath=false` keeps a utf-8 path
-- readable, and what is left to undo is the c-style quoting of a path with a
-- quote, a backslash or a control character in it
--
-- @return  the paths, relative to the repository, or nil when there is none
--
function lsfiles(rootdir, opt)
    opt = opt or {}
    if not root(rootdir) then
        return nil
    end
    local out = _git(rootdir, {"-c", "core.quotepath=false", "ls-files", "--cached",
                               "--others", "--exclude-standard"})
    if not out then
        return nil
    end
    local files = {}
    for _, line in ipairs(out:split("\n", {plain = true})) do
        local filepath = unquote(line:trim())
        if filepath ~= "" then
            table.insert(files, filepath)
            if opt.limit and #files >= opt.limit then
                break
            end
        end
    end
    return files
end

-- undo git's c-style quoting, when it used it
function unquote(str)
    if not str:startswith("\"") then
        return str
    end
    local body = str:sub(2, #str - 1)
    local out = {}
    local idx = 1
    while idx <= #body do
        local ch = body:sub(idx, idx)
        if ch == "\\" then
            local next = body:sub(idx + 1, idx + 1)
            local escapes = {n = "\n", t = "\t", r = "\r", ["\""] = "\"", ["\\"] = "\\"}
            local octal = body:match("^(%d%d%d)", idx + 1)
            if octal then
                table.insert(out, string.char(tonumber(octal, 8)))
                idx = idx + 4
            else
                table.insert(out, escapes[next] or next)
                idx = idx + 2
            end
        else
            table.insert(out, ch)
            idx = idx + 1
        end
    end
    return table.concat(out)
end
