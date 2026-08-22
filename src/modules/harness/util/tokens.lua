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
-- @file        tokens.lua
--

--
-- a lightweight token estimator
--
-- we do not ship any real bpe tokenizer here (no third-party dependency),
-- instead we use a heuristic estimation which is accurate enough for the
-- context budget management and the ui statistics:
--
--   - ascii text: about 1 token per 4 characters
--   - cjk text:   about 1 token per 1 character
--


-- the per-model correction factors of the estimator
--
-- the heuristic below is only worth about ±20%, which is fine for a progress
-- bar and not fine for a limit we must never cross. the providers report the
-- real prompt-token count of every request, so we fold each observation into a
-- per-model factor and multiply the estimate by it. after a couple of turns the
-- error is down to a few percent, which is what makes the hard backstop
-- trustworthy.
--
function factor(model)
    local factors = _g.factors or {}
    return factors[model or ""] or 1
end

-- fold one real observation into the factor of a model
--
-- @param estimated the tokens we thought we were sending
-- @param actual    the prompt tokens the provider counted
--
function observe(model, estimated, actual)
    if not model or model == "" or (estimated or 0) <= 0 or (actual or 0) <= 0 then
        return
    end

    -- an outlier is usually a cache boundary or a provider quirk, not a drift
    local ratio = math.max(0.5, math.min(2.5, actual / estimated))
    local factors = _g.factors or {}
    local previous = factors[model]
    factors[model] = previous and (previous * 0.7 + ratio * 0.3) or ratio
    _g.factors = factors
end

-- the calibrated token count of the given messages
function calibrated(messages, model)
    return math.ceil(estimate_messages(messages) * factor(model))
end

-- estimate the token count of the given text
function estimate(str)
    if str == nil or str == "" then
        return 0
    end
    if type(str) ~= "string" then
        str = tostring(str)
    end
    local asciicount = 0
    local widecount = 0
    local ok = try {
        function ()
            for _, code in utf8.codes(str) do
                if code < 128 then
                    asciicount = asciicount + 1
                else
                    widecount = widecount + 1
                end
            end
            return true
        end
    }
    if not ok then
        asciicount = #str
    end
    return math.floor(asciicount / 4 + widecount + 0.5)
end

-- estimate the token count of the given message
function estimate_message(message)
    local total = 4 -- the message envelope overhead
    if message.content then
        if type(message.content) == "string" then
            total = total + estimate(message.content)
        elseif type(message.content) == "table" then
            for _, block in ipairs(message.content) do
                total = total + estimate(block.text or block.content or "")
            end
        end
    end
    if message.reasoning then
        total = total + estimate(message.reasoning)
    end
    for _, toolcall in ipairs(message.toolcalls or {}) do
        total = total + estimate(toolcall.name) + estimate(toolcall.arguments_text or "")
        total = total + 8
    end
    return total
end

-- estimate the token count of the given messages
function estimate_messages(messages)
    local total = 0
    for _, message in ipairs(messages or {}) do
        total = total + estimate_message(message)
    end
    return total
end

-- estimate the token count of the given tool schemas
function estimate_tools(tools)
    local total = 0
    for _, tool in ipairs(tools or {}) do
        total = total + estimate(tool.name) + estimate(tool.description)
        total = total + estimate(_schematext(tool.parameters))
    end
    return total
end

-- get the plain text of the given json schema
function _schematext(schema, depth)
    depth = depth or 0
    if type(schema) ~= "table" or depth > 8 then
        return tostring(schema or "")
    end
    local parts = {}
    for k, v in pairs(schema) do
        table.insert(parts, tostring(k))
        table.insert(parts, _schematext(v, depth + 1))
    end
    return table.concat(parts, " ")
end
