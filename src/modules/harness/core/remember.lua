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
-- @file        remember.lua
--

--
-- deciding what was worth learning, once the turn is over
--
-- the store is a list of sentences, @see harness.core.memory. this is the part
-- which decides which sentences, and it runs after the turn rather than during
-- it: asking the model to notice a durable fact while it is also doing the work
-- gets neither done well, and the turn the person is waiting on should not be
-- paying for it.
--
-- what it looks for is narrow on purpose. the useful memory is the one which
-- would have changed how the turn went: a correction the person made, a command
-- which turned out to be the way this project does something, a constraint
-- nothing in the repository states. the useless one is a summary — "the user
-- asked about the parser" is not a fact about the project, it is a fact about
-- tuesday, and a list of those is a list which makes every later prompt worse.
--
-- it costs one call to the small model, and only when the turn looks like it
-- might have taught something: a turn which read three files and answered a
-- question has nothing in it, and asking anyway is a tax on every question
-- anybody asks.
--

-- imports
import("harness.llm.llm")
import("harness.util.text")
import("harness.core.memory")
import("harness.config.config")

-- how much of the turn is shown to the small model
local MAXCHARS = 12000

-- how many memories one turn may produce
--
-- a turn which taught four things taught one thing and the model padded it.
-- the cap is not a guess about the model, it is a statement about turns
local MAXNEW = 2

-- what it is asked
local PROMPT = [[
You read one exchange between a developer and a coding agent, and decide whether
anything in it is worth remembering for the *next* conversation about this
project.

Remember only a durable fact which would have changed how this turn went:

- how this project does something: the command which builds or tests it, the
  layout it expects, the tool it uses instead of the obvious one
- a rule it holds to: a style, a constraint, a dependency it will not take
- a correction the developer made to the agent, and what the right answer was
- a preference the developer stated about how they want to be worked with

Never remember:

- what happened in this turn ("the user asked about X", "we fixed the parser")
- anything already written in the repository: the code, the README, the
  configuration, the existing project instructions
- a fact about one file which the agent could simply read again
- anything uncertain, or anything you are inferring rather than being told

Most turns teach nothing. That is the normal answer and you should give it
often.

Reply with nothing at all when there is nothing, which is usually. Otherwise
reply with at most %d lines, one fact per line, each beginning with "- ", each a
single sentence in the imperative or the declarative, and each understandable a
month from now by somebody who was not here. Do not explain, do not preface, do
not apologise. Only the lines.
]]

-- is this turn worth asking about?
--
-- the cheapest filter is the first one: a turn which changed nothing and was
-- told nothing is a question and an answer, and there is no fact in it. this is
-- a heuristic and it is allowed to be wrong in the cheap direction — it lets
-- through turns which teach nothing, and the model then says so
--
-- @param opt   - messages   the turn, as it was sent
--              - changed    did it write anything
--
function worthasking(opt)
    opt = opt or {}
    if opt.changed then
        return true
    end

    -- somebody who says "no", "actually", "don't" is correcting it, and a
    -- correction is the single highest-signal thing a turn can contain
    for _, message in ipairs(opt.messages or {}) do
        if message.role == "user" and _iscorrection(message.content) then
            return true
        end
    end
    return false
end

-- does this read like somebody putting the agent right?
function _iscorrection(content)
    local said = tostring(content or ""):lower()
    if #said > 600 then
        return false
    end
    for _, marker in ipairs({"no,", "no ", "not ", "don't", "do not", "never",
                             "actually", "instead", "wrong", "stop ", "always ",
                             "不要", "不用", "别", "错了", "应该", "不是", "改成"}) do
        if said:find(marker, 1, true) then
            return true
        end
    end
    return false
end

-- is it turned on?
--
-- on by default, because a memory which has to be discovered is a memory nobody
-- has. `{"memory": {"auto": false}}` turns it off, and `/memory` is how you see
-- and undo whatever it decided
--
function enabled(harnessconfig)
    local settings = (harnessconfig or {}).memory or {}
    return settings.auto ~= false
end

-- which scope the automatic ones go to
--
-- the project, because that is what the turn was about. the user scope is for
-- what somebody says about themselves, and nothing here is confident enough
-- about the difference to put a line in a file which follows them everywhere
--
function scope(harnessconfig)
    local settings = (harnessconfig or {}).memory or {}
    return memory.isscope(settings.scope) and settings.scope or "project"
end

-- look at the turn, and remember what it taught
--
-- it never raises and it never blocks anything: the turn is over, nothing is
-- waiting on this, and a memory which failed to be written is a memory nobody
-- was going to miss
--
-- @param opt   - messages   the turn, as it was sent
--              - changed    did it write anything
--              - ontick     keep the ui alive while the model thinks
--
-- @return      the entries which were written
--
function run(harness, session, opt)
    opt = opt or {}
    local harnessconfig = harness:config()
    if not enabled(harnessconfig) or not worthasking(opt) then
        return {}
    end

    local said = _transcript(opt.messages)
    if said == "" then
        return {}
    end

    local answer = _ask(harness, session, said, opt)
    local written = {}
    for _, entry in ipairs(_lines(answer)) do
        if #written >= MAXNEW then
            break
        end
        if memory.remember(harness, scope(harnessconfig), entry) then
            table.insert(written, entry)
        end
    end
    return written
end

-- ask the small model
--
-- everything it does is inside a `try`: it is an extra, it runs after the
-- answer the person wanted, and it does not get to end the turn it follows
--
function _ask(harness, session, said, opt)
    local content
    try {
        function ()
            local provider = config.provider(harness:config())
            local result = llm.complete(provider, {
                model = provider.models.small or provider.models.main,
                system = string.format(PROMPT, MAXNEW),
                messages = {{role = "user", content = said}},
                stream = false,
                maxtokens = 512,
                temperature = 0
            }, {ontick = opt.ontick})
            if result.errors then
                return
            end
            if result.usage and session then
                session:usage_update(result.usage)
            end
            content = result.content
        end
    }
    return content or ""
end

-- the turn, as much of it as is worth showing
--
-- the tail and not the head: what the person said last and what the agent did
-- about it is where a correction lives, and the beginning of a long turn is the
-- part which has already been superseded
--
function _transcript(messages)
    local lines = {}
    for _, message in ipairs(messages or {}) do
        local role = message.role
        local content = tostring(message.content or ""):trim()
        if role == "user" and content ~= "" then
            table.insert(lines, "developer: " .. content)
        elseif role == "assistant" then
            local names = {}
            for _, toolcall in ipairs(message.toolcalls or {}) do
                table.insert(names, toolcall.name)
            end
            if content ~= "" then
                table.insert(lines, "agent: " .. content)
            end
            if #names > 0 then
                table.insert(lines, "agent used: " .. table.concat(names, ", "))
            end
        end
    end

    local said = table.concat(lines, "\n\n")
    if #said > MAXCHARS then
        said = "[the beginning is left out]\n\n" .. said:sub(#said - MAXCHARS)
    end
    return said:trim()
end

-- the lines of what came back
--
-- a model told to reply with nothing replies with "nothing", "none", "no
-- durable facts" and a dozen other ways of saying it. they are all the same
-- answer and none of them is a memory
--
function _lines(answer)
    local found = {}
    for line in (tostring(answer) .. "\n"):gmatch("([^\n]*)\n") do
        local entry = line:trim():match("^[%-%*]%s+(.+)$")
        if entry and not _isnothing(entry) then
            table.insert(found, entry)
        end
    end
    return found
end

-- is that an empty answer wearing a bullet?
function _isnothing(entry)
    local said = entry:lower():trim():gsub("[%.!]+$", "")
    return said == "" or said == "none" or said == "nothing"
        or said == "n/a" or said:startswith("no durable")
        or said:startswith("nothing worth") or said:startswith("nothing to remember")
end
