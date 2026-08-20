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
-- @file        anthropic.lua
--

--
-- the anthropic messages api provider
--

-- imports
import("core.base.json")

-- the provider kind
function kind()
    return "anthropic"
end

-- build the http request
function buildrequest(provider, req)
    local baseurl = (provider.baseurl or ""):gsub("/+$", "")
    local url = provider.chaturl or (baseurl .. "/v1/messages")
    local headers = {
        ["Content-Type"] = "application/json",
        ["anthropic-version"] = provider.apiversion or "2023-06-01"
    }
    if provider.apikey and provider.apikey ~= "" then
        headers["x-api-key"] = provider.apikey
    end
    for name, value in pairs(provider.headers or {}) do
        headers[name] = value
    end

    -- the anthropic api splits the system prompt out of the messages,
    -- and we mark it as the cache breakpoint to enable the prompt caching
    local system = nil
    if req.system and req.system ~= "" then
        system = json.mark_as_array({{type = "text", text = req.system, cache_control = {type = "ephemeral"}}})
    end

    local messages = {}
    for _, message in ipairs(req.messages or {}) do
        local converted = _tomessage(message)
        if converted then
            table.insert(messages, converted)
        end
    end

    local body = {
        model = req.model,
        messages = json.mark_as_array(messages),
        max_tokens = req.maxtokens or 8192,
        stream = req.stream and true or false
    }
    if system then
        body.system = system
    end
    if req.temperature then
        body.temperature = req.temperature
    end
    if req.tools and #req.tools > 0 then
        local tools = {}
        for _, tool in ipairs(req.tools) do
            table.insert(tools, {
                name = tool.name,
                description = tool.description,
                input_schema = tool.parameters or {type = "object", properties = {}}
            })
        end
        body.tools = json.mark_as_array(tools)
    end
    return {url = url, headers = headers, body = body}
end

-- convert the internal message to the anthropic message
function _tomessage(message)
    if message.role == "tool" then
        return {
            role = "user",
            content = json.mark_as_array({{
                type = "tool_result",
                tool_use_id = message.toolcallid,
                content = message.content or "",
                is_error = message.iserror or nil
            }})
        }
    end
    local blocks = {}
    if message.content and message.content ~= "" then
        table.insert(blocks, {type = "text", text = message.content})
    end
    for _, toolcall in ipairs(message.toolcalls or {}) do
        local arguments = toolcall.arguments
        if not arguments and toolcall.arguments_text then
            arguments = json.decode(toolcall.arguments_text)
        end
        table.insert(blocks, {
            type = "tool_use",
            id = toolcall.id,
            name = toolcall.name,
            input = arguments or {}
        })
    end
    if #blocks == 0 then
        return nil
    end
    return {role = message.role, content = json.mark_as_array(blocks)}
end

-- parse one streaming chunk object
function parsechunk(state, obj)
    local events = {}
    local etype = obj.type
    if etype == "content_block_start" then
        local block = obj.content_block or {}
        local index = (obj.index or 0) + 1
        state.blocks = state.blocks or {}
        state.blocks[index] = {type = block.type}
        if block.type == "tool_use" then
            state.toolcalls = state.toolcalls or {}
            local item = {index = index, id = block.id, name = block.name or "", arguments_text = ""}
            state.toolcalls[index] = item
            state.blocks[index].toolcall = item
            table.insert(events, {kind = "toolcall.start", index = index, id = block.id})
            table.insert(events, {kind = "toolcall.name", index = index, name = item.name})
        end
    elseif etype == "content_block_delta" then
        local delta = obj.delta or {}
        local index = (obj.index or 0) + 1
        if delta.type == "text_delta" then
            table.insert(events, {kind = "text", text = delta.text or ""})
        elseif delta.type == "thinking_delta" then
            table.insert(events, {kind = "reasoning", text = delta.thinking or ""})
        elseif delta.type == "input_json_delta" then
            local item = state.toolcalls and state.toolcalls[index]
            if item then
                item.arguments_text = item.arguments_text .. (delta.partial_json or "")
            end
            table.insert(events, {kind = "toolcall.delta", index = index, text = delta.partial_json or ""})
        end
    elseif etype == "message_start" then
        local usage = obj.message and obj.message.usage
        if usage then
            table.insert(events, {kind = "usage", usage = normalizeusage(usage)})
        end
    elseif etype == "message_delta" then
        if obj.usage then
            table.insert(events, {kind = "usage", usage = normalizeusage(obj.usage), partial = true})
        end
        if obj.delta and obj.delta.stop_reason then
            table.insert(events, {kind = "finish", reason = obj.delta.stop_reason})
        end
    elseif etype == "error" then
        table.insert(events, {kind = "error", message = (obj.error or {}).message or "unknown error"})
    end
    return events
end

-- parse the non-streaming response object
function parseresponse(obj)
    local result = {content = "", reasoning = "", toolcalls = {}}
    for idx, block in ipairs(obj.content or {}) do
        if block.type == "text" then
            result.content = result.content .. (block.text or "")
        elseif block.type == "thinking" then
            result.reasoning = result.reasoning .. (block.thinking or "")
        elseif block.type == "tool_use" then
            table.insert(result.toolcalls, {
                index = idx,
                id = block.id,
                name = block.name,
                arguments = block.input
            })
        end
    end
    result.finishreason = obj.stop_reason
    if obj.usage then
        result.usage = normalizeusage(obj.usage)
    end
    return result
end

-- normalize the usage information
function normalizeusage(usage)
    local input = usage.input_tokens or 0
    local output = usage.output_tokens or 0
    local cachehit = usage.cache_read_input_tokens or 0
    local cachewrite = usage.cache_creation_input_tokens or 0
    return {
        input = input + cachehit + cachewrite,
        output = output,
        cachehit = cachehit,
        cachemiss = input + cachewrite,
        cachewrite = cachewrite,
        reasoning = 0,
        total = input + output + cachehit + cachewrite
    }
end

-- get the error message from the response object
function parseerror(obj)
    if type(obj) == "table" and type(obj.error) == "table" then
        return obj.error.message or obj.error.type
    end
end
