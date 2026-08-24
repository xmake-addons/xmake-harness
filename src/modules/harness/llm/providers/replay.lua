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
-- @file        replay.lua
--

--
-- the replay provider
--
-- it answers from a file instead of from a server. that is the whole point: the
-- turn loop, the tool pipeline, the permission checks, the compaction, the
-- guards and the rendering can all be driven end to end without a network, a
-- key, or a model which answers differently every time.
--
-- everything above the llm seam is where the bugs have actually been, and until
-- now it was the part no test could reach: driving a turn meant paying for a
-- real completion and accepting whatever it decided to do. a recorded session
-- makes that whole layer testable, which is why this adapter exists at all.
--
-- the cassette is what a real provider produced, recorded by `providers.<name>.record`:
--
--   {"turns": [
--     {"content": "let me look",
--      "toolcalls": [{"name": "read_file", "arguments": "{\"path\": \"xmake.lua\"}"}]},
--     {"content": "it builds one target."}
--   ]}
--
-- a turn is replayed through the same streaming handlers a server would drive,
-- in small pieces, so the incremental renderer and the token accounting are
-- exercised the way they are in a real session and not bypassed
--

-- imports
import("core.base.json")

-- how much text one delta carries
--
-- a real server sends a few tokens at a time. one big string would leave the
-- streaming path untested, which is most of what we are here to test
--
local CHUNK = 24

-- the provider kind
function kind()
    return "replay"
end

-- answer without a server
--
-- the presence of this function is what tells `harness.llm.llm` that the
-- adapter speaks for itself: no request is built, no key is needed, and nothing
-- is posted anywhere
--
-- @param provider  {cassette = "/path/to/file.json"}
-- @param req       the request, @see harness.llm.llm.complete
-- @param handlers  the streaming handlers
--
function complete(provider, req, handlers)
    handlers = handlers or {}
    local turns, errors = _load(provider)
    if not turns then
        return {errors = errors}
    end

    local turn, index = _next(provider, turns, req)
    if not turn then
        return {errors = string.format("the cassette(%s) has no turn left to play, "
            .. "%d were recorded: the run asked for more than it was given",
            provider.cassette, #turns)}
    end
    -- a recorded failure carries its kind too, so what the caller does about it
    -- can be replayed as well, @see harness.llm.llm.isretryable
    if turn.errors then
        return {errors = turn.errors, errorcode = turn.errorcode or "unknown", replayed = index}
    end
    return _emit(turn, handlers, index)
end

-- read the cassette
function _load(provider)
    local filepath = provider.cassette
    if not filepath or filepath == "" then
        return nil, "the replay provider needs a `cassette` to play, set `providers.<name>.cassette`"
    end
    if not os.isfile(filepath) then
        return nil, string.format("the cassette(%s) does not exist", filepath)
    end
    local data = try { function () return json.loadfile(filepath) end }
    local turns = type(data) == "table" and (data.turns or data) or nil
    if type(turns) ~= "table" then
        return nil, string.format("the cassette(%s) is not readable", filepath)
    end
    return turns
end

-- which turn answers this request?
--
-- a cassette is played in order, because that is the order it was recorded in
-- and the order the loop asks in. the position is kept per file rather than per
-- provider table, so a test may hand the same table to two runs and still get
-- the recording from the start
--
function _next(provider, turns, req)
    local positions = _g.positions or {}
    local key = provider.cassette
    local index = (positions[key] or 0) + 1
    positions[key] = index
    _g.positions = positions
    return turns[index], index
end

-- start this cassette from the beginning again
function rewind(cassette)
    local positions = _g.positions or {}
    positions[cassette] = nil
    _g.positions = positions
end

-- play one turn through the handlers a server would drive
function _emit(turn, handlers, index)
    local result = {content = "", reasoning = "", toolcalls = {}, replayed = index}

    for _, piece in ipairs(_pieces(turn.reasoning)) do
        result.reasoning = result.reasoning .. piece
        if handlers.onreasoning then
            handlers.onreasoning(piece)
        end
    end
    for _, piece in ipairs(_pieces(turn.content)) do
        result.content = result.content .. piece
        if handlers.ontext then
            handlers.ontext(piece)
        end
        if handlers.ontick and handlers.ontick() == false then
            result.aborted = true
            return result
        end
    end

    result.toolcalls = _toolcalls(turn, handlers)
    result.usage = _usage(turn, result)
    if handlers.onusage then
        handlers.onusage(result.usage)
    end
    result.finishreason = turn.finishreason or (#result.toolcalls > 0 and "tool_calls" or "stop")
    return result
end

-- cut a string into the deltas a server would have sent
function _pieces(str)
    local results = {}
    local idx = 1
    while str and idx <= #str do
        table.insert(results, str:sub(idx, idx + CHUNK - 1))
        idx = idx + CHUNK
    end
    return results
end

-- replay the tool calls, announcing them the way the streaming parser does
function _toolcalls(turn, handlers)
    local results = {}
    for index, call in ipairs(turn.toolcalls or {}) do
        local id = call.id or string.format("call_%d", index)
        local arguments = call.arguments or call.arguments_text or "{}"
        if type(arguments) == "table" then
            arguments = json.encode(arguments)
        end
        if handlers.ontoolcall then
            handlers.ontoolcall({kind = "toolcall.start", index = index, id = id})
            handlers.ontoolcall({kind = "toolcall.name", index = index, name = call.name})
            for _, piece in ipairs(_pieces(arguments)) do
                handlers.ontoolcall({kind = "toolcall.delta", index = index, text = piece})
            end
        end
        table.insert(results, {index = index, id = id, name = call.name, arguments_text = arguments})
    end
    return results
end

-- the token usage of a replayed turn
--
-- a recording carries the real numbers when it has them. without them we make
-- something up from the sizes, because the estimator calibrates against this
-- and a zero would teach it that everything is free
--
function _usage(turn, result)
    if type(turn.usage) == "table" then
        return turn.usage
    end
    local output = math.max(1, math.ceil((#result.content + #(result.reasoning or "")) / 4))
    return {input = turn.input or 100, output = output, cachehit = 0, cachemiss = turn.input or 100}
end
