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
-- @file        compiledb.lua
--

--
-- read a `compile_commands.json`
--
-- this is not a build system and that is exactly why it is here. every other
-- reader works out what the build system *means*; this one is the command line
-- the compiler was actually given, for every file, with nothing inferred.
--
-- it is two things:
--
--   a reader     when there is nothing else to read — a generator nobody kept
--                the input of, a build system this does not know — the files
--                group by the flags they share, and each group is a target.
--                the target names are made up and say so.
--
--   a check      when there *is* something else to read, this is the ground
--                truth to check it against: the includes, the defines and the
--                standard of every file, as the compiler saw them. a conversion
--                which built the right targets with the wrong `-I` is a
--                conversion which compiles and behaves differently, and nothing
--                else here can catch that.
--
-- the second use is the valuable one. `xmake_import_verify` compares target
-- lists; with this it compares flags.
--

-- imports
import("core.base.json")
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.reader")

-- the flags which say nothing about how the code is compiled
--
-- an output path, an input path and the dependency-file machinery differ
-- between any two builds of the same project and comparing them says nothing
local NOISE = {
    ["-c"] = true, ["-o"] = 1, ["-MD"] = true, ["-MMD"] = true, ["-MP"] = true,
    ["-MF"] = 1, ["-MT"] = 1, ["-MQ"] = 1, ["--driver-mode"] = true,
    ["-fdiagnostics-color"] = true, ["-fcolor-diagnostics"] = true,
    ["-pipe"] = true, ["/nologo"] = true, ["/showIncludes"] = true
}

-- where the database is, if it is anywhere
--
-- the build directory is where every generator puts it, and the root is where
-- people symlink it so their editor finds it
--
function find(rootdir)
    for _, name in ipairs({"compile_commands.json",
                           "build/compile_commands.json",
                           ".xmake/compile_commands.json",
                           "out/compile_commands.json",
                           "builddir/compile_commands.json"}) do
        local filepath = path.join(rootdir, name)
        if os.isfile(filepath) then
            return filepath
        end
    end
end

-- the entries of a database, as facts about files
--
-- @return  {{file = "src/main.c", dir = "..", argv = {..}, language = "c++"}, ..}
--
function entries(filepath, rootdir)
    local loaded = try { function () return json.loadfile(filepath) end }
    if type(loaded) ~= "table" then
        return nil, string.format("%s could not be read as json", filepath)
    end

    local out = {}
    for _, item in ipairs(loaded) do
        if type(item) == "table" and item.file then
            local argv = item.arguments
            if type(argv) ~= "table" then
                argv = reader.argv(item.command)
            end
            local file = item.file
            if not path.is_absolute(file) and item.directory then
                file = path.join(item.directory, file)
            end
            table.insert(out, {
                file = _relative(file, rootdir),
                dir = item.directory,
                argv = argv,
                language = _language(file)
            })
        end
    end
    return out
end

-- read the whole database as a project
--
-- the targets are invented, because a database has none: the files which share
-- a set of flags were compiled together and are almost always one target, and
-- naming them after the directory they sit in is the best guess there is. it
-- says so rather than pretending
--
function read(rootdir, opt)
    opt = opt or {}
    local filepath = opt.file and path.absolute(opt.file, rootdir) or find(rootdir)
    if not filepath then
        return nil, string.format("there is no compile_commands.json in %s", rootdir)
    end

    local items, errors = entries(filepath, rootdir)
    if not items then
        return nil, errors
    end
    if #items == 0 then
        return nil, string.format("%s is empty", path.relative(filepath, rootdir))
    end

    local state = reader.new({from = "compiledb", rootdir = rootdir,
                              name = path.filename(path.absolute(rootdir))})
    model.note(state.model, "this was read from %s, which has no targets in it: the "
               .. "files were grouped by the flags they share and the names are guesses",
               path.relative(filepath, rootdir))
    model.unresolved(state.model, {
        file = path.relative(filepath, rootdir),
        why = "the target names and kinds are not in a compile database: name them, and say "
              .. "which are libraries",
        text = string.format("%d files", #items)
    })

    -- one group per set of flags
    local groups = {}
    local order = {}
    for _, item in ipairs(items) do
        local key = _signature(item.argv)
        if not groups[key] then
            groups[key] = {argv = item.argv, files = {}, languages = {}}
            table.insert(order, key)
        end
        table.insert(groups[key].files, item.file)
        if item.language then
            groups[key].languages[item.language] = true
        end
    end

    local taken = {}
    for index, key in ipairs(order) do
        local group = groups[key]
        -- two groups from one directory are two sets of flags and two targets,
        -- and `model.target` hands back the first when the names collide
        local name = _name(group.files, index)
        if taken[name] then
            taken[name] = taken[name] + 1
            name = string.format("%s%d", name, taken[name])
        else
            taken[name] = 1
        end
        local one = model.target(state.model, name,
                                 {kind = "static", from = path.relative(filepath, rootdir)})
        for _, file in ipairs(group.files) do
            model.add(one.files, file)
        end
        local rest = reader.flags(state, one, _meaningful(group.argv), "")
        for _, flag in ipairs(rest) do
            _flag(one, flag)
        end
    end
    return state.model
end

-- a name for a group of files which has none
function _name(files, index)
    local dirs = {}
    for _, file in ipairs(files) do
        local dir = path.directory(file)
        dirs[dir] = (dirs[dir] or 0) + 1
    end
    local best, count = nil, 0
    for dir, seen in pairs(dirs) do
        if seen > count then
            best, count = dir, seen
        end
    end
    if not best or best == "." or best == "" then
        return string.format("group%d", index)
    end
    return (path.filename(best):gsub("[^%w_%-]", "_"))
end

-- the flags which take their value as the next word
--
-- dropping a bare word as "the source file" is right for `main.c` and wrong for
-- the `include` of `-I include`, and the two look identical without this
local TAKESVALUE = {
    ["-I"] = true, ["-D"] = true, ["-U"] = true, ["-l"] = true, ["-L"] = true,
    ["-isystem"] = true, ["-include"] = true, ["-iquote"] = true,
    ["-idirafter"] = true, ["-framework"] = true, ["-Xclang"] = true,
    ["--sysroot"] = true, ["-target"] = true, ["-arch"] = true
}

-- the flags which say something, in a stable order
function _meaningful(argv)
    local out = {}
    local skip = 0
    local keepnext = false
    for index, flag in ipairs(argv or {}) do
        if skip > 0 then
            skip = skip - 1
        elseif keepnext then
            keepnext = false
            table.insert(out, flag)
        elseif index == 1 then
            -- the compiler itself
        elseif NOISE[flag] then
            skip = NOISE[flag] == 1 and 1 or 0
        elseif TAKESVALUE[flag] then
            keepnext = true
            table.insert(out, flag)
        elseif flag:startswith("-o") and #flag > 2 then
            -- an output written as one word
        elseif flag:startswith("@") then
            -- a response file, which is not on disk any more
        elseif not flag:startswith("-") and not flag:startswith("/") then
            -- the source file itself
        else
            table.insert(out, flag)
        end
    end
    return out
end

-- what makes two files "compiled the same way"
--
-- the order does not matter and the pairing does, so it is not a plain sort:
-- `-I a -I b` and `-I b -I a` are the same set and sorting the words apart
-- would make `-I a` and `-I b` indistinguishable
function _signature(argv)
    local meaningful = _meaningful(argv)
    local pieces = {}
    local idx = 1
    while idx <= #meaningful do
        local flag = meaningful[idx]
        if TAKESVALUE[flag] and meaningful[idx + 1] then
            table.insert(pieces, flag .. " " .. meaningful[idx + 1])
            idx = idx + 2
        else
            table.insert(pieces, flag)
            idx = idx + 1
        end
    end
    table.sort(pieces)
    return table.concat(pieces, " ")
end

-- one flag which was not a value
function _flag(one, flag)
    local standard = flag:match("^%-std=(.+)$") or flag:match("^/std:(.+)$")
    if standard then
        model.add(one.languages, standard)
        return
    end
    model.add(one.cxflags, flag)
end

-- the language of a file, by its extension
function _language(file)
    local extension = path.extension(file):sub(2):lower()
    if extension == "c" then
        return "c"
    end
    if extension == "cc" or extension == "cpp" or extension == "cxx" or extension == "c++" then
        return "c++"
    end
    if extension == "m" then
        return "objc"
    end
    if extension == "mm" then
        return "objc++"
    end
end

function _relative(file, rootdir)
    if not rootdir then
        return file
    end
    local inside = path.relative(file, rootdir)
    if inside and not inside:startswith("..") then
        return path.normalize(inside)
    end
    return file
end

---------------------------------------------------------------------------------
-- and the other use: checking a conversion against it
---------------------------------------------------------------------------------

-- what the database says about one file
--
-- @return  {includedirs = {..}, defines = {..}, languages = {..}}
--
function factsof(items, file)
    for _, item in ipairs(items or {}) do
        if item.file == file then
            local one = {includedirs = {}, sysincludedirs = {}, defines = {},
                         links = {}, linkdirs = {}, frameworks = {}, cxflags = {},
                         languages = {}}
            local rest = reader.flags(nil, one, _meaningful(item.argv), nil)
            for _, flag in ipairs(rest) do
                _flag(one, flag)
            end
            return one
        end
    end
end

-- compare what a converted project says against what the compiler was told
--
-- it is per file, because that is the only level a database has: the target a
-- file ended up in is xmake's business, and what it was compiled with is not
--
-- @param project   the converted model
-- @param items     the database entries, @see entries()
-- @return          {{file = .., missing = {..}, extra = {..}}, ..}
--
function differences(project, items)
    local byfile = {}
    for _, item in ipairs(items or {}) do
        byfile[item.file] = item
    end

    local out = {}
    for _, one in ipairs(project.targets or {}) do
        for _, file in ipairs(one.files or {}) do
            -- a pattern covers files the database names individually, and
            -- comparing a pattern with a file says nothing
            if not file:find("*", 1, true) and byfile[file] then
                local said = factsof(items, file)
                local missing = {}
                local extra = {}
                for _, field in ipairs({"includedirs", "defines"}) do
                    _compare(missing, extra, field, one[field] or {}, said[field] or {})
                end
                if #missing > 0 or #extra > 0 then
                    table.insert(out, {file = file, target = one.name,
                                       missing = missing, extra = extra})
                end
            end
        end
    end
    return out
end

-- what one side has and the other does not
function _compare(missing, extra, field, ours, theirs)
    for _, value in ipairs(theirs) do
        if not table.contains(ours, value) then
            table.insert(missing, string.format("%s %s", field, value))
        end
    end
    for _, value in ipairs(ours) do
        if not table.contains(theirs, value) then
            table.insert(extra, string.format("%s %s", field, value))
        end
    end
end
