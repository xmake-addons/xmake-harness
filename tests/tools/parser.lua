--!A generic AI agent harness framework based on xmake lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
--
-- @file parser.lua
--

-- imports
import("harness.shell.parser")

function test_posix_quotes_and_operators()
    local result = parser.parse([[echo "a && b" && cat input | grep 'x y' > out.txt]])
    assert(#result.commands == 3, tostring(#result.commands))
    assert(result.commands[1].words[2] == "a && b", result.commands[1].words[2])
    assert(result.commands[2].words[1] == "cat", result.commands[2].words[1])
    assert(result.commands[3].redirects[1].target == "out.txt", result.commands[3].redirects[1].target)
end

function test_posix_substitution_stays_one_word()
    local words = parser.words("echo $(printf '%s' hello)")
    assert(#words == 2, tostring(#words))
    assert(words[2] == "$(printf '%s' hello)", words[2])
end

function test_cmd_caret_escape_and_redirect()
    local result = parser.parse([[echo a ^& b && del /q C:\temp\x.txt > out.txt]], {dialect = "cmd"})
    assert(#result.commands == 2, tostring(#result.commands))
    assert(result.commands[1].words[2] == "a", result.commands[1].words[2])
    assert(result.commands[1].words[3] == "&", result.commands[1].words[3])
    assert(result.commands[2].words[1] == "del", result.commands[2].words[1])
    assert(result.commands[2].redirects[1].target == "out.txt", result.commands[2].redirects[1].target)
end

function test_unclosed_quote_is_opaque()
    local result = parser.parse([[echo "unfinished]])
    assert(result.opaque, "an unclosed quote must require confirmation")
end
