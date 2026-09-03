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
-- @file        run.lua
--

--
-- the unit test runner
--
--   $ xmake l tests/run.lua              run all the tests
--   $ xmake l tests/run.lua text         run the files whose name matches
--   $ xmake l tests/run.lua import/      run one group
--
-- the tests are grouped by what they are about — `core/`, `tools/`, `ui/`,
-- `web/`, `skills/`, `agents/`, `import/`, `xmake/`, `llm/` — because fifty
-- files in one directory is a list nobody reads. the group is part of the name
-- a failure is reported under, so a red line says where to look.
--
-- the tests only cover the pure logic, they never call a model. what asks
-- whether the *model* does the right thing is `xmake l evals/run.lua`.
--

-- imports
import("core.base.option")
import("core.sandbox.module")

-- run one test file
--
-- @param name  what to call it, e.g. `import/cmake`
--
function _runfile(filepath, name)
    local tests = import(path.basename(filepath),
                         {rootdir = path.directory(filepath), anonymous = true})
    local passed, failed = 0, 0
    local names = {}
    for key, value in pairs(tests) do
        if type(key) == "string" and key:startswith("test_") and type(value) == "function" then
            table.insert(names, key)
        end
    end
    table.sort(names)
    for _, casename in ipairs(names) do
        local errors
        local ok = try {
            function ()
                tests[casename]()
                return true
            end,
            catch {
                function (errs)
                    errors = errs
                end
            }
        }
        if ok then
            passed = passed + 1
            cprint("  ${green}✔${clear} %s.%s", name, casename:sub(6))
        else
            failed = failed + 1
            cprint("  ${red}✘${clear} %s.%s\n      ${dim}%s${clear}", name, casename:sub(6), tostring(errors))
        end
    end

    -- a file may have something to put away afterwards, e.g. a server it kept
    -- up across its tests. it runs whatever happened above, because a listener
    -- left behind holds the whole process open, @see tests/webroutes.lua
    if type(tests.teardown) == "function" then
        local errors
        local ok = try {
            function ()
                tests.teardown()
                return true
            end,
            catch {
                function (errs)
                    errors = errs
                end
            }
        }
        if not ok then
            failed = failed + 1
            cprint("  ${red}✘${clear} %s.teardown\n      ${dim}%s${clear}", name, tostring(errors))
        end
    end
    return passed, failed
end

-- every test file, the groups included
--
-- the runner itself is not one of them, and neither is anything under
-- `fixtures/`: those are projects to convert and build, not lua to run
--
function _files()
    local out = {}
    for _, filepath in ipairs(os.files(path.join(os.scriptdir(), "*.lua"))) do
        if path.basename(filepath) ~= "run" then
            table.insert(out, filepath)
        end
    end
    for _, dir in ipairs(os.dirs(path.join(os.scriptdir(), "*"))) do
        if path.filename(dir) ~= "fixtures" then
            for _, filepath in ipairs(os.files(path.join(dir, "*.lua"))) do
                table.insert(out, filepath)
            end
        end
    end
    table.sort(out)
    return out
end

-- what a file is called in a report: `import/cmake`, or `text` at the top
function _nameof(filepath)
    local name = path.basename(filepath)
    local group = path.filename(path.directory(filepath))
    if group == "tests" then
        return name
    end
    return string.format("%s/%s", group, name)
end

-- the main entry
function main(filter)
    module.add_directories(path.join(os.scriptdir(), "..", "src", "modules"))
    local passed, failed = 0, 0
    for _, filepath in ipairs(_files()) do
        local name = _nameof(filepath)
        if not filter or name:find(filter, 1, true) then
            local p, f = _runfile(filepath, name)
            passed = passed + p
            failed = failed + f
        end
    end
    print("")
    if failed > 0 then
        cprint("${red}%d failed${clear}, %d passed", failed, passed)
        os.exit(1)
    end
    cprint("${bright green}all %d tests passed${clear}", passed)
end
