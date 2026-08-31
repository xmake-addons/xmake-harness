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
-- @file        import.lua
--

--
-- bringing a project built with something else into xmake
--
-- the work splits in two, and the split is the point:
--
--   what can be read     the targets, their sources, their includes, their
--                        defines, their dependencies. a reader states these or
--                        says nothing, and it is the same answer every time.
--   what has to be judged  the conditions, the platform branches, which package
--                        a `find_package(Foo)` really is, whether a flag has a
--                        rule in xmake which says it better.
--
-- a model asked to convert a project from the raw text does both at once, and
-- gets the first kind wrong in ways nobody notices until the build runs. so the
-- first kind is done here, deterministically, and handed over with its gaps
-- marked — and the second kind is what the model is actually for.
--
-- a reader is a module with `read(dir) -> model` and an entry in READERS. that
-- is the whole extension point: another build system is another file.
--

-- imports
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.emit")

-- the readers, by name
--
-- `detect` is what says whether a directory holds one of these, `match` is the
-- files it is looking for, and `weight` breaks the tie when a project carries
-- more than one — which is common, and usually means one of them is the real
-- build and the rest are somebody's experiment
--
local READERS = {
    {
        name = "cmake",
        title = "CMake",
        module = "harness.plugins.xmake.import.cmake",
        match = {"CMakeLists.txt"},
        weight = 40
    },
    {
        name = "vcxproj",
        title = "Visual Studio",
        module = "harness.plugins.xmake.import.vcxproj",
        match = {"*.sln", "*.vcxproj"},
        weight = 30,
        -- msbuild is read from a file and not from a directory
        byfile = true
    },
    {
        name = "meson",
        title = "Meson",
        module = "harness.plugins.xmake.import.meson",
        match = {"meson.build"},
        weight = 20
    },
    {
        name = "scons",
        title = "SCons",
        module = "harness.plugins.xmake.import.scons",
        match = {"SConstruct", "SConstruct.py"},
        weight = 10
    }
}

-- every reader there is
function readers()
    return READERS
end

-- the reader of the given name
function reader(name)
    for _, one in ipairs(READERS) do
        if one.name == name then
            return one
        end
    end
end

-- what this directory is built with
--
-- @param rootdir   the directory to look in
-- @return          {{name = "cmake", title = "CMake", files = {"CMakeLists.txt"}, weight = 40}, ..}
--                  in the order they are worth trying
--
function detect(rootdir)
    rootdir = rootdir or os.curdir()
    local found = {}
    for _, one in ipairs(READERS) do
        local files = {}
        for _, pattern in ipairs(one.match) do
            if pattern:find("*", 1, true) then
                for _, filepath in ipairs(os.files(path.join(rootdir, pattern))) do
                    table.insert(files, path.relative(filepath, rootdir))
                end
            elseif os.isfile(path.join(rootdir, pattern)) then
                table.insert(files, pattern)
            end
        end
        if #files > 0 then
            -- a solution says more about a set of projects than any one of them
            table.sort(files, function (a, b)
                local asln = a:lower():endswith(".sln") and 1 or 0
                local bsln = b:lower():endswith(".sln") and 1 or 0
                if asln ~= bsln then
                    return asln > bsln
                end
                return a < b
            end)
            table.insert(found, {name = one.name, title = one.title, files = files,
                                 weight = one.weight, byfile = one.byfile})
        end
    end
    table.sort(found, function (a, b) return a.weight > b.weight end)

    -- an xmake.lua already here is worth saying, because converting over one is
    -- a different thing from converting into an empty directory
    if os.isfile(path.join(rootdir, "xmake.lua")) then
        for _, one in ipairs(found) do
            one.hasxmake = true
        end
    end
    return found
end

-- read a project into the model
--
-- @param rootdir   the project directory
-- @param opt       {reader = "cmake", file = "all.sln"}
-- @return          the model, or nil and the reason
--
function read(rootdir, opt)
    opt = opt or {}
    local name = opt.reader
    if not name then
        local found = detect(rootdir)
        if #found == 0 then
            return nil, string.format("nothing in %s looks like a project this can read: "
                                      .. "it knows %s", rootdir, _known())
        end
        name = found[1].name
        opt.file = opt.file or found[1].files[1]
    end

    local one = reader(name)
    if not one then
        return nil, string.format("`%s` is not a reader, they are %s", name, _known())
    end

    local module = import(one.module, {anonymous = true})
    local project, errors
    if one.byfile then
        local filepath = opt.file and path.absolute(opt.file, rootdir) or nil
        if not filepath then
            local found = detect(rootdir)
            for _, item in ipairs(found) do
                if item.name == name then
                    filepath = path.join(rootdir, item.files[1])
                end
            end
        end
        if not filepath then
            return nil, string.format("`%s` reads a file and none was given", name)
        end
        project, errors = module.read(filepath, {rootdir = rootdir})
    else
        project, errors = module.read(rootdir, opt)
    end
    if not project then
        return nil, errors
    end
    project.reader = name
    return project
end

-- read a project and write the xmake.lua for it
--
-- @param rootdir   the project directory
-- @param opt       {reader = .., file = .., dry = false, todofile = "XMAKE-TODO.md"}
-- @return          {path = .., todopath = .., project = <model>, problems = {..}}, or nil and why
--
function convert(rootdir, opt)
    opt = opt or {}
    local project, errors = read(rootdir, opt)
    if not project then
        return nil, errors
    end

    local problems = model.problems(project)
    local text = emit.render(project, opt)
    local result = {project = project, problems = problems, text = text,
                    summary = model.summary(project)}

    -- a dry run is how something looks at what it would write before it writes
    -- it, which is what a conversion wants: the file it would replace is
    -- somebody's build
    if opt.dry then
        return result
    end

    local target = path.join(rootdir, "xmake.lua")
    if os.isfile(target) and not opt.force then
        return nil, string.format("%s already exists, pass force to replace it", target)
    end
    io.writefile(target, text)
    result.path = target

    if #project.unresolved > 0 and opt.todofile ~= false then
        local todopath = path.join(rootdir, opt.todofile or "XMAKE-TODO.md")
        io.writefile(todopath, emit.todos(project))
        result.todopath = todopath
    end
    return result
end

-- the readers, named
function _known()
    local names = {}
    for _, one in ipairs(READERS) do
        table.insert(names, one.name)
    end
    return table.concat(names, ", ")
end
