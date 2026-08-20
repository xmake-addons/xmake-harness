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
-- @file        openai.lua
--

--
-- the openai compatible provider
--
-- it covers most of the llm services: deepseek, openai, moonshot(kimi), qwen,
-- zhipu(glm), siliconflow, openrouter, ollama, vllm, ...
--

-- imports
import("core.base.json")

-- the provider kind
function kind()
    return "openai"
end

-- build the http request
--
-- @param provider  the provider settings, e.g. {baseurl = "..", apikey = ".."}
-- @param req       the normalized request
--
function buildrequest(provider, req)
    local baseurl = (provider.baseurl or ""):gsub("/+$", "")
    local url = provider.chaturl or (baseurl .. "/v1/chat/completions")
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = req.stream and "text/event-stream" or "application/json"
    }
    if provider.apikey and provider.apikey ~= "" then
        headers["Authorization"] = "Bearer " .. provider.apikey
    end
    for name, value in pairs(provider.headers or {}) do
        headers[name] = value
    end

    local messages = {}
    if req.system and req.system ~= "" then
        table.insert(messages, {role = "system", content = req.system})
    end
    for _, message in ipairs(req.messages or {}) do
        table.insert(messages, _tomessage(message))
    end

    local body = {
        model = req.model,
        messages = json.mark_as_array(messages),
        stream = req.stream and true or false
    }
    if req.temperature then
        body.temperature = req.temperature
    end
    if req.maxtokens then
        body.max_tokens = req.maxtokens
    end
    if req.stream then
        body.stream_options = {include_usage = true}
    end
    if req.tools and #req.tools > 0 then
        local tools = {}
        for _, tool in ipairs(req.tools) do
            table.insert(tools, {
                type = "function",
                ["function"] = {
                    name = tool.name,
                    description = tool.description,
                    parameters = tool.parameters or {type = "object", properties = {}}
                }
            })
        end
        body.tools = json.mark_as_array(tools)
        body.tool_choice = req.toolchoice or "auto"
    end
    return {url = url, headers = headers, body = body}
end

-- convert the internal message to the openai message
function _tomessage(message)
    local role = message.role
    if role == "tool" then
        return {
            role = "tool",
            tool_call_id = message.toolcallid,
            content = message.content or ""
        }
    end
    local result = {role = role, content = message.content or ""}
    if message.toolcalls and #message.toolcalls > 0 then
        local toolcalls = {}
        for _, toolcall in ipairs(message.toolcalls) do
            table.insert(toolcalls, {
                id = toolcall.id,
                type = "function",
                ["function"] = {
                    name = toolcall.name,
                    arguments = toolcall.arguments_text or json.encode(toolcall.arguments or {})
                }
            })
        end
        result.tool_calls = json.mark_as_array(toolcalls)
        if result.content == "" then
            result.content = json.null
        end
    end
    return result
end

-- parse one streaming chunk object, it returns the normalized events
function parsechunk(state, obj)
    local events = {}
    if obj.usage and type(obj.usage) == "table" then
        table.insert(events, {kind = "usage", usage = normalizeusage(obj.usage)})
    end
    local choice = obj.choices and obj.choices[1]
    if not choice then
        return events
    end
    local delta = choice.delta or {}
    if delta.reasoning_content and delta.reasoning_content ~= "" then
        table.insert(events, {kind = "reasoning", text = delta.reasoning_content})
    end
    if delta.reasoning and type(delta.reasoning) == "string" and delta.reasoning ~= "" then
        table.insert(events, {kind = "reasoning", text = delta.reasoning})
    end
    if delta.content and delta.content ~= "" and type(delta.content) == "string" then
        table.insert(events, {kind = "text", text = delta.content})
    end
    for _, toolcall in ipairs(delta.tool_calls or {}) do
        local index = (toolcall.index or 0) + 1
        state.toolcalls = state.toolcalls or {}
        local item = state.toolcalls[index]
        if not item then
            item = {index = index, id = toolcall.id, name = "", arguments_text = ""}
            state.toolcalls[index] = item
            table.insert(events, {kind = "toolcall.start", index = index, id = toolcall.id})
        end
        if toolcall.id then
            item.id = toolcall.id
        end
        local func = toolcall["function"]
        if func then
            if func.name and func.name ~= "" then
                item.name = item.name .. func.name
                table.insert(events, {kind = "toolcall.name", index = index, name = item.name})
            end
            if func.arguments and func.arguments ~= "" then
                item.arguments_text = item.arguments_text .. func.arguments
                table.insert(events, {kind = "toolcall.delta", index = index, text = func.arguments})
            end
        end
    end
    if choice.finish_reason and choice.finish_reason ~= json.null then
        table.insert(events, {kind = "finish", reason = choice.finish_reason})
    end
    return events
end

-- parse the non-streaming response object
function parseresponse(obj)
    local result = {content = "", reasoning = "", toolcalls = {}}
    local choice = obj.choices and obj.choices[1]
    if choice and choice.message then
        local message = choice.message
        if type(message.content) == "string" then
            result.content = message.content
        end
        if type(message.reasoning_content) == "string" then
            result.reasoning = message.reasoning_content
        end
        for idx, toolcall in ipairs(message.tool_calls or {}) do
            local func = toolcall["function"] or {}
            table.insert(result.toolcalls, {
                index = idx,
                id = toolcall.id,
                name = func.name,
                arguments_text = func.arguments
            })
        end
        result.finishreason = choice.finish_reason
    end
    if obj.usage then
        result.usage = normalizeusage(obj.usage)
    end
    return result
end

-- normalize the usage information
--
-- deepseek reports the context cache statistics, which we show in the ui
--
function normalizeusage(usage)
    local input = usage.prompt_tokens or 0
    local output = usage.completion_tokens or 0
    local cachehit = usage.prompt_cache_hit_tokens
    local cachemiss = usage.prompt_cache_miss_tokens
    if not cachehit and usage.prompt_tokens_details then
        cachehit = usage.prompt_tokens_details.cached_tokens
        if cachehit then
            cachemiss = input - cachehit
        end
    end
    local reasoning = 0
    if usage.completion_tokens_details then
        reasoning = usage.completion_tokens_details.reasoning_tokens or 0
    end
    return {
        input = input,
        output = output,
        cachehit = cachehit or 0,
        cachemiss = cachemiss or (cachehit and (input - cachehit) or 0),
        cachewrite = 0,
        reasoning = reasoning,
        total = usage.total_tokens or (input + output)
    }
end

-- get the error message from the response object
function parseerror(obj)
    if type(obj) ~= "table" then
        return nil
    end
    if type(obj.error) == "table" then
        return obj.error.message or obj.error.type
    elseif type(obj.error) == "string" then
        return obj.error
    end
    if obj.message and obj.code then
        return tostring(obj.message)
    end
end
