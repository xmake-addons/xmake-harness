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
-- @file        codestyle.lua
--

--
-- does the model write the code the way the prompt asks it to
--
-- `tests/prompt.lua` already asserts that the prompt says these things. it
-- says them and passes whether or not anybody listens — which is exactly what
-- happened: the tests were green while the model was still writing chinese
-- comments into a chinese conversation. this file asks the other question.
--

-- imports
import("support")

-- the comments go into the file in english, whatever language the user writes
function eval_comments_are_english_in_a_chinese_conversation()
    local run = support.ask({
        prompt = "给 main.c 加一个 add 函数，两个整数相加，带上注释说明它做什么",
        files = {["main.c"] = "int main(void) {\n    return 0;\n}\n"}
    })

    local files = support.written(run)
    if #files == 0 then
        support.fail("nothing was written at all")
    end
    for _, file in ipairs(files) do
        for _, line in ipairs(support.comments(file.content)) do
            if support.hascjk(line) then
                support.fail("%s comments in chinese: %s", file.path, line)
            end
        end
    end
end

-- the first file of a new project follows the house style and not the model's
function eval_a_new_file_takes_the_house_brace_placement()
    local run = support.ask({
        prompt = "write src/hello.c with a main which prints hello world",
        files = {["README.md"] = "an empty project\n"}
    })

    local files = support.written(run)
    if #files == 0 then
        support.fail("nothing was written at all")
    end
    for _, file in ipairs(files) do
        -- a brace alone on its line is the placement the default argues against
        for _, line in ipairs(file.content:split("\n", {strict = true})) do
            if line:trim() == "{" then
                support.fail("%s opens a brace on a line of its own", file.path)
            end
        end
    end
end

-- and the file which is already there still wins over the house style
function eval_the_file_being_edited_wins()
    local run = support.ask({
        prompt = "add a subtract function to calc.c, same as the add one",
        files = {["calc.c"] = [[
int add(int a, int b)
{
    return a + b;
}
]]}
    })

    local files = support.written(run)
    if #files == 0 then
        support.fail("nothing was written at all")
    end
    for _, file in ipairs(files) do
        if file.path:find("calc.c", 1, true) then
            if not file.content:find("subtract", 1, true) then
                support.fail("%s has no subtract in it", file.path)
            end
            -- the file it joined puts the brace on its own line, so it does too
            -- (`%s` would match the newline as well, and then following the file
            -- and ignoring it would look the same from here)
            if file.content:find("subtract%b()[ \t]*{") then
                support.fail("%s did not follow the brace placement of the file it edited",
                             file.path)
            end
        end
    end
end
