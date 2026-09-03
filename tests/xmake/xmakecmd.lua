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
-- @file        xmakecmd.lua
--

-- imports
import("harness.plugins.xmake.xmakecmd")

function _line(argv)
    return table.concat(xmakecmd.confirmed(argv), " ")
end

---------------------------------------------------------------------------------
-- saying yes without breaking the command line
---------------------------------------------------------------------------------

function test_the_answer_goes_before_the_values()
    -- the last argument of most tasks is a value and not an option, so `-y` at
    -- the end is read as one more of them: `xmake build demo -y` says "'-y' is
    -- not a valid target name" and `xrepo info zlib -y` looks for a package
    -- called `-y`
    assert(_line({"build", "demo"}) == "build -y demo", _line({"build", "demo"}))
    assert(_line({"test", "test_xml"}) == "test -y test_xml", _line({"test", "test_xml"}))
    assert(_line({"lua", "private.xrepo", "info", "zlib"})
           == "lua -y private.xrepo info zlib", _line({"lua", "private.xrepo", "info", "zlib"}))
end

function test_the_options_of_the_task_stay_with_it()
    assert(_line({"build", "-r", "demo"}) == "build -y -r demo", _line({"build", "-r", "demo"}))
    assert(_line({"f", "-m", "debug"}) == "f -y -m debug", _line({"f", "-m", "debug"}))
end

function test_a_program_is_not_handed_an_argument_nobody_asked_for()
    -- `xmake run demo` runs the user's program: an argument appended here is an
    -- argument the program is started with
    local argv = xmakecmd.confirmed({"run", "demo", "--input", "a.txt"})
    assert(argv[#argv] ~= "-y", table.concat(argv, " "))
    assert(_line({"run", "demo", "--input", "a.txt"}) == "run -y demo --input a.txt",
           _line({"run", "demo", "--input", "a.txt"}))
end

function test_a_task_which_is_all_options()
    assert(_line({}) == "-y", _line({}))
    assert(_line({"--version"}) == "-y --version", _line({"--version"}))
end

function test_what_the_user_is_shown_is_what_they_would_type()
    -- the confirmation is machinery: the card says the command somebody would
    -- have run by hand
    assert(xmakecmd.commandline({"build", "demo"}) == "xmake build demo",
           xmakecmd.commandline({"build", "demo"}))
end

---------------------------------------------------------------------------------
-- what xmake itself makes of it
---------------------------------------------------------------------------------

function test_xmake_accepts_it()
    -- the placement is a fact about xmake's parser and not about our opinion of
    -- it, so it is checked against the real one
    local rootdir = os.tmpfile() .. ".project"
    os.mkdir(rootdir)
    io.writefile(path.join(rootdir, "xmake.lua"),
        "target(\"demo\")\n    set_kind(\"binary\")\n    add_files(\"main.c\")\n")
    io.writefile(path.join(rootdir, "main.c"), "int main() { return 0; }\n")

    local ok = try
    {
        function ()
            os.iorunv(os.programfile(), xmakecmd.confirmed({"build", "--dry-run", "demo"}),
                      {curdir = rootdir, envs = {XMAKE_COLORTERM = "nocolor"}})
            return true
        end
    }
    assert(ok, "xmake refused the command line we build")
end
