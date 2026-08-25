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
--   $ xmake l tests/run.lua           run all the tests
--   $ xmake l tests/run.lua text      run one test file
--
-- the tests only cover the pure logic, they never call a model.
--

-- imports
import("core.base.option")
import("core.sandbox.module")

-- run one test file
function _runfile(filepath)
    local name = path.basename(filepath)
    local tests = import(name, {rootdir = path.directory(filepath), anonymous = true})
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

-- the main entry
function main(filter)
    module.add_directories(path.join(os.scriptdir(), "..", "src", "modules"))
    local passed, failed = 0, 0
    for _, filepath in ipairs(os.files(path.join(os.scriptdir(), "*.lua"))) do
        local name = path.basename(filepath)
        if name ~= "run" and (not filter or name:find(filter, 1, true)) then
            local p, f = _runfile(filepath)
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
