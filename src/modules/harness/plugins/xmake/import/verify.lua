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
-- @file        verify.lua
--

--
-- did the conversion produce the same project?
--
-- "it builds" is the weakest thing a conversion can be checked against and the
-- first thing to check: a draft which does not configure is a draft with a
-- typo in it, and finding that out costs a second.
--
-- what matters more is the comparison, and it is cheap: the original build
-- system knows what targets it has and so does xmake, and a conversion which
-- built four of the five is a conversion which quietly dropped one. the answer
-- is a list of differences and not a verdict, because some of them are right —
-- a `Utility` project with no output is not a target xmake needs.
--

-- imports
import("harness.shell.exec")
import("harness.util.sanitize")
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.import", {alias = "projectimport"})
import("harness.plugins.xmake.import.compiledb")

-- check the conversion
--
-- @param rootdir   the project directory
-- @param opt       {context = <the process context>, build = true, reader = ".."}
-- @return          {configured = .., built = .., missing = {..}, extra = {..},
--                   targets = {..}, output = ".."}
--
function check(rootdir, opt)
    opt = opt or {}
    local result = {missing = {}, extra = {}, targets = {}, steps = {}}

    if not os.isfile(path.join(rootdir, "xmake.lua")) then
        return nil, "there is no xmake.lua here to check"
    end

    -- what the original said it builds, if it is still here to ask
    local original, readerrors = projectimport.read(rootdir, {reader = opt.reader})
    if original then
        result.from = original.from
        for _, one in ipairs(original.targets) do
            table.insert(result.targets, {name = one.name, kind = one.kind})
        end
    else
        result.readerrors = readerrors
    end

    -- does it configure? that is the cheapest question and the first
    local configured = _xmake(rootdir, {"f", "-c"}, opt)
    result.configured = configured.exitcode == 0
    table.insert(result.steps, {name = "configure", ok = result.configured,
                                output = configured.output})
    if not result.configured then
        result.output = configured.output
        return result
    end

    -- what did it end up with?
    -- `xmake show -l targets` writes them on one line separated by spaces, and
    -- writes the colour reset after each one whatever the terminal is, so the
    -- escapes come off before anything is split
    local listed = _xmake(rootdir, {"show", "-l", "targets"}, opt)
    local built = {}
    if listed.exitcode == 0 then
        for name in sanitize.clean(listed.output or ""):gmatch("[^%s]+") do
            if name ~= "" then
                built[name] = true
            end
        end
    end
    result.xmaketargets = {}
    for name in pairs(built) do
        table.insert(result.xmaketargets, name)
    end
    table.sort(result.xmaketargets)

    -- the two lists, compared
    if original then
        local wanted = {}
        for _, one in ipairs(original.targets) do
            wanted[one.name] = one.kind
            if not built[one.name] then
                table.insert(result.missing, {name = one.name, kind = one.kind})
            end
        end
        for name in pairs(built) do
            if not wanted[name] then
                table.insert(result.extra, name)
            end
        end
        table.sort(result.missing, function (a, b) return a.name < b.name end)
        table.sort(result.extra)
    end

    -- and what the compiler was actually told, when the project kept a record
    --
    -- the target list is the coarse check and this is the fine one: a
    -- conversion which built the right targets with the wrong `-I` compiles,
    -- passes every check above, and behaves differently
    if opt.flags ~= false and original then
        local filepath = compiledb.find(rootdir)
        if filepath then
            local items = compiledb.entries(filepath, rootdir)
            if items then
                result.database = path.relative(filepath, rootdir)
                result.differences = compiledb.differences(original, items)
                result.compared = #items
            end
        end
    end

    -- and does it build? this is the slow one, so it is asked last and only
    -- when it was asked for
    if opt.build ~= false then
        local build = _xmake(rootdir, {"build"}, opt)
        result.built = build.exitcode == 0
        result.output = build.output
        table.insert(result.steps, {name = "build", ok = result.built, output = build.output})
    end
    return result
end

-- run one xmake command in the project
function _xmake(rootdir, argv, opt)
    local context = opt.context or {config = {}, cwd = rootdir}
    local result, errors
    try {
        function ()
            result = exec.run(context, {
                program = exec.xmakeprogram(),
                -- `-y` after the task name and before the values, for the same
                -- reason as everywhere else, @see harness.plugins.xmake.xmakecmd
                argv = table.join({argv[1], "-y"}, table.slice(argv, 2)),
                cwd = rootdir,
                nosandbox = true,
                timeout = opt.timeout or 900000,
                envs = {XMAKE_COLORTERM = "nocolor"}})
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    if type(result) ~= "table" then
        return {exitcode = -1, output = tostring(errors or "xmake could not be run")}
    end
    return result
end

-- what the check found, as a report
function report(result)
    local lines = {}
    if not result.configured then
        table.insert(lines, "it does not configure.")
        table.insert(lines, "")
        table.insert(lines, "```")
        table.insert(lines, _tail(result.output, 40))
        table.insert(lines, "```")
        table.insert(lines, "")
        table.insert(lines, "fix that first: everything else is downstream of it.")
        return table.concat(lines, "\n")
    end

    if #result.missing > 0 then
        table.insert(lines, string.format("%d target%s of the original %s not here:",
            #result.missing, #result.missing == 1 and "" or "s",
            #result.missing == 1 and "is" or "are"))
        for _, one in ipairs(result.missing) do
            table.insert(lines, string.format("- `%s` (%s)", one.name, one.kind))
        end
        table.insert(lines, "")
        table.insert(lines, "some of those are right — a utility project which builds nothing "
                            .. "has no target in xmake. the rest were dropped and should not have been.")
        table.insert(lines, "")
    end
    if #result.extra > 0 then
        table.insert(lines, string.format("and %d which the original does not have: %s",
            #result.extra, table.concat(result.extra, ", ")))
        table.insert(lines, "")
    end
    if #result.missing == 0 and #result.extra == 0 and result.from then
        table.insert(lines, string.format("the same %d target%s as the %s project.",
            #result.targets, #result.targets == 1 and "" or "s", result.from))
        table.insert(lines, "")
    end

    -- what the compiler was told, where there is a record of it
    if result.database then
        local differences = result.differences or {}
        if #differences == 0 then
            table.insert(lines, string.format(
                "and every file it shares with `%s` is compiled with the same includes "
                .. "and defines (%d files).", result.database, result.compared))
        else
            table.insert(lines, string.format(
                "%d file%s compiled differently from what `%s` records:",
                #differences, #differences == 1 and " is" or "s are", result.database))
            for index, one in ipairs(differences) do
                if index > 12 then
                    table.insert(lines, string.format("- and %d more", #differences - 12))
                    break
                end
                local parts = {}
                if #one.missing > 0 then
                    table.insert(parts, "missing " .. table.concat(one.missing, ", "))
                end
                if #one.extra > 0 then
                    table.insert(parts, "extra " .. table.concat(one.extra, ", "))
                end
                table.insert(lines, string.format("- `%s` (%s): %s", one.file, one.target,
                                                  table.concat(parts, "; ")))
            end
            table.insert(lines, "")
            table.insert(lines, "some of those are right — an include the original passed to "
                                .. "every file may belong on one target here. the rest are "
                                .. "the conversion having lost something.")
        end
        table.insert(lines, "")
    end

    if result.built == nil then
        table.insert(lines, "it configures. it was not built.")
    elseif result.built then
        table.insert(lines, "it configures and it builds.")
    else
        table.insert(lines, "it configures, and the build fails:")
        table.insert(lines, "")
        table.insert(lines, "```")
        table.insert(lines, _tail(result.output, 40))
        table.insert(lines, "```")
    end
    return table.concat(lines, "\n")
end

-- the end of the output, which is where the error is
function _tail(output, count)
    local lines = tostring(output or ""):split("\n", {strict = true})
    if #lines <= count then
        return table.concat(lines, "\n")
    end
    return table.concat(table.slice(lines, #lines - count + 1), "\n")
end
