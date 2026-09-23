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
-- @file        transport.lua
--

-- imports
import("core.base.pipe")
import("harness.llm.transport")

-- a pipe which answers from a script of turns
--
-- each turn is what one round of the loop is told: `{read = "data"}` hands that
-- over, `{read = 0, wait = 0}` is "nothing now, and nothing is coming", and
-- `{read = 0, wait = pipe.EV_READ}` is the readable-but-empty which is how a
-- posix pipe says its writer has gone
function _pipe(turns, opt)
    opt = opt or {}
    local at = 0
    return {
        turns = 0,
        read = function (self, buff)
            self.turns = self.turns + 1

            -- past the end of the script it behaves like the platform under
            -- test forever, which is the whole point of the broken one
            at = at + 1
            local turn = turns[at] or opt.forever
            if not turn then
                return -1
            end
            if type(turn.read) == "string" then
                return #turn.read, {str = function () return turn.read end}
            end
            self.pending = turn
            return 0
        end,
        wait = function (self, events, timeout)
            local turn = self.pending or opt.forever or {}
            return turn.wait or 0
        end
    }
end

-- a process which is running, or which has exited with the given code
function _proc(exitcode)
    return {
        asked = 0,
        wait = function (self, timeout)
            self.asked = self.asked + 1
            if exitcode == nil then
                return 0
            end
            return 1, exitcode
        end
    }
end

-- run one stream and collect what came out of it
function _run(rpipe, proc, handlers)
    local state = {status = 0, parts = {}, left = ""}
    local aborted, errors, exitcode = transport.stream(rpipe, proc, state, handlers or {})
    -- `_handleline` puts back the newline it split on, so the body always ends
    -- with one: the assertions here are about what was carried, not about that
    return {aborted = aborted, errors = errors, exitcode = exitcode,
            body = table.concat(state.parts):trim(), status = state.status}
end

---------------------------------------------------------------------------------
-- how it ends
---------------------------------------------------------------------------------

function test_a_pipe_which_closes_ends_the_stream()
    local result = _run(_pipe({{read = "hello "}, {read = "world"}}), _proc(0))
    assert(result.body == "hello world", result.body)
    assert(not result.aborted)
end

function test_a_readable_pipe_with_nothing_in_it_ends_the_stream()
    -- how a posix pipe says the writer has gone: readable, and empty
    local result = _run(_pipe({{read = "data"}},
        {forever = {read = 0, wait = pipe.EV_READ}}), _proc(0))
    assert(result.body == "data", result.body)
    assert(not result.aborted)
end

function test_a_pipe_which_never_admits_its_writer_is_gone()
    -- the reported bug: on some platforms a pipe whose writer has exited reads
    -- as empty and polls as "nothing yet", every time. the loop waited for two
    -- *consecutive* readable-and-empty turns, and a timeout in between put the
    -- count back to zero — so the two never arrived and the stream never ended
    local started = os.mclock()
    local result = _run(_pipe({{read = "the answer"}},
        {forever = {read = 0, wait = 0}}), _proc(0))

    assert(result.body == "the answer", result.body)
    assert(not result.aborted)

    -- it ends by asking the other question instead, and quickly
    assert(os.mclock() - started < 5000, "it must not spin")
end

function test_and_it_brings_back_the_exit_code()
    -- whoever works out that the process is over is the one who reaped it, so
    -- it is the one which has the status: waiting again would answer with an
    -- error rather than with the code
    local result = _run(_pipe({}, {forever = {read = 0, wait = 0}}), _proc(23))
    assert(result.exitcode == 23, tostring(result.exitcode))
end

function test_a_process_which_is_still_running_is_waited_for()
    -- the model thinking is not the stream ending: nothing arrives for a while
    -- and that is the normal shape of a slow answer
    local turns = {}
    for _ = 1, 6 do
        table.insert(turns, {read = 0, wait = 0})
    end
    table.insert(turns, {read = "at last"})
    local result = _run(_pipe(turns), _proc(nil))
    assert(result.body == "at last", result.body)
    assert(result.exitcode == nil, "it never exited, so there is no code")
end

function test_what_arrived_after_it_exited_is_still_delivered()
    -- curl has gone and the last thing it wrote is still in flight, so the
    -- stream does not end the instant the process does
    local turns = {{read = 0, wait = 0}, {read = 0, wait = 0}, {read = "the tail"}}
    local result = _run(_pipe(turns, {forever = {read = 0, wait = 0}}), _proc(0))
    assert(result.body == "the tail", result.body)
end

function test_a_pipe_which_errors_ends_the_stream()
    local result = _run(_pipe({{read = "half"}}), _proc(0))
    assert(result.body == "half", result.body)
end

---------------------------------------------------------------------------------
-- and what it does on the way
---------------------------------------------------------------------------------

function test_the_user_can_interrupt_it()
    local turns = {}
    for index = 1, 50 do
        table.insert(turns, {read = string.format("chunk %d ", index)})
    end
    local result = _run(_pipe(turns), _proc(nil), {ontick = function () return false end})
    assert(result.aborted, "it stopped")
    assert(#result.body < 200, "and not after all fifty")
end

function test_it_is_not_asked_about_the_process_on_every_idle_turn()
    -- the answer only changes once and asking is a system call
    local proc = _proc(nil)
    local turns = {}
    for _ = 1, 40 do
        table.insert(turns, {read = 0, wait = 0})
    end
    table.insert(turns, {read = "done"})
    _run(_pipe(turns), proc)
    assert(proc.asked <= 12, tostring(proc.asked))
end

---------------------------------------------------------------------------------
-- what curl's exit code means
---------------------------------------------------------------------------------

function test_an_exit_code_is_not_left_as_a_number()
    -- `curl exited with 23` is a number somebody has to go and look up
    local response = transport.response({status = 0, parts = {}},
        {exitcode = 23, stderr = nil})
    assert(response.errors:find("could not write", 1, true), response.errors)
    assert(response.errors:find("23", 1, true), response.errors)
end

function test_the_ones_which_actually_happen()
    for code, said in pairs({[6] = "resolved", [7] = "listening",
                             [28] = "timed out", [60] = "certificate"}) do
        local response = transport.response({status = 0, parts = {}}, {exitcode = code})
        assert(response.errors:find(said, 1, true), tostring(code) .. ": " .. response.errors)
    end
end

function test_an_exit_code_nobody_has_a_sentence_for()
    local response = transport.response({status = 0, parts = {}}, {exitcode = 91})
    assert(response.errors:find("curl --help", 1, true), response.errors)
end

function test_a_request_which_worked_says_nothing_about_curl()
    local response = transport.response({status = 200, parts = {"{}"}}, {exitcode = 0})
    assert(response.errors == nil, tostring(response.errors))
end

---------------------------------------------------------------------------------
-- and why a process would not start at all
---------------------------------------------------------------------------------

import("harness.shell.exec")

function test_a_program_which_is_not_there()
    local said = exec.spawnfailed("/nope/nosuchtool", {"x"}, os.curdir(), "openv failed!")
    assert(said:find("is not there", 1, true), said)
    assert(said:find("nosuchtool", 1, true), said)
end

function test_a_program_which_is_not_executable()
    local file = os.tmpfile() .. ".txt"
    io.writefile(file, "not a program")
    local said = exec.spawnfailed(file, {}, os.curdir(), "openv failed!")
    assert(said:find("not executable", 1, true), said)
end

function test_a_working_directory_which_is_not_there()
    local said = exec.spawnfailed("/bin/sh", {}, "/nope/nodir", "openv failed!")
    assert(said:find("does not exist", 1, true), said)
    assert(said:find("/nope/nodir", 1, true), said)
end

function test_a_command_line_windows_will_not_take()
    local argv = {}
    for index = 1, 4000 do
        argv[index] = string.format("--file=%s", string.rep("x", 8))
    end
    local said = exec.spawnfailed("/bin/sh", argv, os.curdir(), "openv failed!")
    assert(said:find("past what windows will take", 1, true), said)
end

function test_when_everything_we_can_check_is_fine()
    -- it says so, rather than repeating `failed!` and leaving it there: the
    -- next report is then about the thing we could not check
    local said = exec.spawnfailed("/bin/sh", {"-c", "true"}, os.curdir(),
                                  "openv process(/bin/sh, -c true) failed!")
    assert(said:find("openv process", 1, true), said)
    assert(said:find("refused to start it", 1, true), said)
end
