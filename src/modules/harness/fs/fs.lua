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
-- @file        fs.lua
--

--
-- the filesystem seam
--
-- all the file tools go through this module, so the workspace boundary, the
-- size limits and the text detection are enforced in exactly one place.
--

-- imports
import("harness.util.util")
import("harness.core.checkpoint")

-- the binary file extensions which we never read as the text
local BINARY_EXTENSIONS = {
    [".png"] = true, [".jpg"] = true, [".jpeg"] = true, [".gif"] = true, [".bmp"] = true,
    [".ico"] = true, [".webp"] = true, [".pdf"] = true, [".zip"] = true, [".gz"] = true,
    [".xz"] = true, [".bz2"] = true, [".7z"] = true, [".tar"] = true, [".exe"] = true,
    [".dll"] = true, [".so"] = true, [".dylib"] = true, [".a"] = true, [".lib"] = true,
    [".o"] = true, [".obj"] = true, [".class"] = true, [".jar"] = true, [".pyc"] = true,
    [".mp3"] = true, [".mp4"] = true, [".mov"] = true, [".wav"] = true, [".ttf"] = true
}

-- the directories which are skipped by the search tools
local IGNORE_DIRS = {
    [".git"] = true, [".svn"] = true, [".hg"] = true, ["node_modules"] = true,
    ["build"] = true, [".xmake"] = true, ["dist"] = true, ["target"] = true,
    [".venv"] = true, ["__pycache__"] = true, [".cache"] = true, [".idea"] = true
}

-- resolve the given path to an absolute path
function resolve(context, filepath)
    if not filepath or filepath == "" then
        raise("the path is required!")
    end
    filepath = tostring(filepath)
    if filepath:startswith("~") then
        local home = os.getenv("HOME") or os.getenv("USERPROFILE")
        if home then
            filepath = path.join(home, filepath:sub(2))
        end
    end
    if not path.is_absolute(filepath) then
        filepath = path.join(context.cwd or os.curdir(), filepath)
    end
    return path.normalize(filepath)
end

-- is the given path inside the workspace?
function inworkspace(context, filepath)
    local rootdir = path.normalize(context.cwd or os.curdir())
    if filepath == rootdir or filepath:startswith(rootdir .. path.sep()) then
        return true
    end
    for _, dir in ipairs((context.config.sandbox or {}).writabledirs or {}) do
        dir = path.normalize(dir)
        if filepath:startswith(dir) then
            return true
        end
    end
    return false
end

-- ensure the given path can be written
function checkwritable(context, filepath)
    if not inworkspace(context, filepath) then
        raise("%s is outside the working directory(%s), it cannot be written!", filepath, context.cwd)
    end
end

-- is the given file a binary file?
function isbinary(filepath)
    local extension = path.extension(filepath):lower()
    if BINARY_EXTENSIONS[extension] then
        return true
    end
    local file = io.open(filepath, "rb")
    if not file then
        return false
    end
    local data = file:read(1024)
    file:close()
    if type(data) ~= "string" then
        return false
    end
    return data:find("\0", 1, true) ~= nil
end

-- is the given directory ignored by the search tools?
function isignored(dirname)
    return IGNORE_DIRS[dirname] or false
end

-- read the text of the given file
--
-- @param opt   the options, e.g. {maxsize = 262144}
--
function readtext(filepath, opt)
    opt = opt or {}
    if not os.isfile(filepath) then
        raise("%s does not exist!", filepath)
    end
    local filesize = os.filesize(filepath)
    local maxsize = opt.maxsize or 262144
    if filesize > maxsize then
        raise("%s is too large(%d bytes), please read it with the offset/limit arguments.", filepath, filesize)
    end
    if isbinary(filepath) then
        raise("%s is a binary file, it cannot be read as the text.", filepath)
    end
    return io.readfile(filepath) or ""
end

-- read the lines of the given file
function readlines(filepath, opt)
    local text = readtext(filepath, opt)
    local lines = {}
    for line in text:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
    end
    -- the gmatch above appends one extra empty line
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

-- write the text to the given file
--
-- @param context   the tool context, so that what is being replaced can be kept
--                  first. every write goes through here, which is why the
--                  checkpoint hangs off it rather than off the two tools which
--                  happen to write today, @see harness.core.checkpoint
--
function writetext(filepath, content, context)
    _checkpoint(context, filepath)
    os.mkdir(path.directory(filepath))
    io.writefile(filepath, content)
    return true
end

-- keep what the file holds now, and note it in the session
function _checkpoint(context, filepath)
    local session = context and context.session
    if not session then
        return
    end
    local record = checkpoint.save(session, filepath)
    if record then
        session:append("edit", {record = record})
    end
end

-- list the entries of the given directory
--
-- @return  {{name = "src", kind = "dir"}, {name = "xmake.lua", kind = "file", size = 128}}
--
function listdir(dirpath, opt)
    opt = opt or {}
    local results = {}
    for _, filepath in ipairs(os.filedirs(path.join(dirpath, "*"))) do
        local name = path.filename(filepath)
        local isdir = os.isdir(filepath)
        if not (opt.skipignored and isdir and isignored(name)) and not name:startswith(".") or opt.all then
            table.insert(results, {
                name = name,
                kind = isdir and "dir" or "file",
                size = (not isdir) and os.filesize(filepath) or nil,
                path = filepath})
        end
    end
    table.sort(results, function (a, b)
        if a.kind ~= b.kind then
            return a.kind == "dir"
        end
        return a.name < b.name
    end)
    return results
end

-- walk the files of the given directory recursively
--
-- @param opt   the options, e.g. {maxcount = 5000, extensions = {".lua"}}
--
function walk(dirpath, opt)
    opt = opt or {}
    local results = {}
    local maxcount = opt.maxcount or 20000
    local function _walk(dir, depth)
        if #results >= maxcount or depth > (opt.maxdepth or 32) then
            return
        end
        for _, filepath in ipairs(os.filedirs(path.join(dir, "*"))) do
            local name = path.filename(filepath)
            if os.isdir(filepath) then
                if not isignored(name) and not name:startswith(".") then
                    _walk(filepath, depth + 1)
                end
            else
                if not opt.extensions or table.contains(opt.extensions, path.extension(name):lower()) then
                    table.insert(results, filepath)
                    if #results >= maxcount then
                        return
                    end
                end
            end
        end
    end
    _walk(dirpath, 1)
    return results
end
