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
-- the eval runner
--
--   $ xmake l evals/run.lua                  run every eval three times
--   $ xmake l evals/run.lua comments         run one file
--   $ xmake l evals/run.lua comments 10      run it ten times
--
-- an eval is not a test. a test asks whether this code returns what it should,
-- and `xmake l tests/run.lua` answers that in a second without touching the
-- network. an eval asks whether the *model* does what the prompt asks of it,
-- which cannot be answered without running one: it calls a real provider, it
-- costs money, it is slow, and the same eval can pass four times out of five.
--
-- so it lives here and not in tests/, and what it reports is a rate and not a
-- verdict. a rate which drops after a prompt change is the finding; a single
-- red run is weather.
--

-- imports
import("core.base.option")
import("core.sandbox.module")
import("harness.config.config")

-- how many times each eval runs, unless told otherwise
local RUNS = 3

-- run one eval the given number of times
--
-- @return  the number which passed, and the reasons the others gave
--
function _runeval(evals, name, runs)
    local passed = 0
    local reasons = {}
    for _ = 1, runs do
        local errors
        local ok = try {
            function ()
                evals[name]()
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
            io.write(".")
        else
            table.insert(reasons, tostring(errors))
            io.write("x")
        end
        io.flush()
    end
    return passed, reasons
end

-- run one eval file
function _runfile(filepath, runs)
    local name = path.basename(filepath)
    local evals = import(name, {rootdir = path.directory(filepath), anonymous = true})
    local names = {}
    for key, value in pairs(evals) do
        if type(key) == "string" and key:startswith("eval_") and type(value) == "function" then
            table.insert(names, key)
        end
    end
    table.sort(names)

    local scores = {}
    for _, casename in ipairs(names) do
        io.write(string.format("  %s.%s ", name, casename:sub(6)))
        local passed, reasons = _runeval(evals, casename, runs)
        local rate = passed / runs
        cprint(" %s%d/%d${clear}", rate == 1 and "${green}" or (rate >= 0.5 and "${yellow}" or "${red}"),
               passed, runs)
        -- one reason is enough to say what went wrong, and the others are
        -- usually the same thing said again
        if #reasons > 0 then
            cprint("      ${dim}%s${clear}", reasons[1])
        end
        table.insert(scores, {name = string.format("%s.%s", name, casename:sub(6)),
                              passed = passed, runs = runs})
    end
    return scores
end

-- the main entry
function main(filter, runs)
    module.add_directories(path.join(os.scriptdir(), "..", "src", "modules"))
    runs = tonumber(runs) or RUNS

    -- an eval without a provider is an eval which cannot run, and saying so is
    -- better than a page of connection errors
    local provider = config.provider(config.load())
    if not provider.apikey or provider.apikey == "" then
        cprint("${yellow}no api key for the `%s` provider${clear}", provider.name)
        cprint("the evals call a real model. set a key with `xmake ai --apikey=<key>` first.")
        os.exit(1)
    end
    cprint("${dim}provider %s, model %s, %d run%s each${clear}", provider.name,
           provider.models.main or "?", runs, runs == 1 and "" or "s")

    local scores = {}
    for _, filepath in ipairs(os.files(path.join(os.scriptdir(), "*.lua"))) do
        local name = path.basename(filepath)
        if name ~= "run" and name ~= "support" and (not filter or name:find(filter, 1, true)) then
            table.join2(scores, _runfile(filepath, runs))
        end
    end

    local passed, total = 0, 0
    for _, score in ipairs(scores) do
        passed = passed + score.passed
        total = total + score.runs
    end
    print("")
    if total == 0 then
        cprint("${yellow}no evals ran${clear}")
        return
    end
    cprint("${bright}%d of %d runs passed${clear} (%d%%)", passed, total,
           math.floor(passed * 100 / total))
end
