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
-- @file        providers.lua
--

--
-- the builtin provider presets
--
-- we only ship the endpoints and the default model tiers here,
-- the api keys always come from the user side configuration.
--
-- the model tiers:
--   - main:      the main model, used by the top-level agent
--   - small:     the small/cheap model, used by the title generation, the summary, the light subagents
--   - reasoner:  the thinking model, used by the plan/deep-think mode (optional)
--

function presets()
    return {
        deepseek = {
            kind        = "openai",
            title       = "DeepSeek",
            baseurl     = "https://api.deepseek.com",
            apikeyenv   = "DEEPSEEK_API_KEY",
            apikeyurl   = "https://platform.deepseek.com/api_keys",
            contextsize = 131072,
            models      = {main = "deepseek-chat", small = "deepseek-chat", reasoner = "deepseek-reasoner"},
            modellist   = {"deepseek-chat", "deepseek-reasoner"}
        },
        anthropic = {
            kind        = "anthropic",
            title       = "Anthropic Claude",
            baseurl     = "https://api.anthropic.com",
            apikeyenv   = "ANTHROPIC_API_KEY",
            apikeyurl   = "https://console.anthropic.com/settings/keys",
            contextsize = 200000,
            models      = {main = "claude-sonnet-4-5", small = "claude-haiku-4-5", reasoner = "claude-opus-4-5"},
            modellist   = {"claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5"}
        },
        openai = {
            kind        = "openai",
            title       = "OpenAI",
            baseurl     = "https://api.openai.com",
            apikeyenv   = "OPENAI_API_KEY",
            apikeyurl   = "https://platform.openai.com/api-keys",
            contextsize = 128000,
            models      = {main = "gpt-4.1", small = "gpt-4.1-mini"},
            modellist   = {"gpt-4.1", "gpt-4.1-mini", "o4-mini"}
        },
        moonshot = {
            kind        = "openai",
            title       = "Moonshot Kimi",
            baseurl     = "https://api.moonshot.cn",
            apikeyenv   = "MOONSHOT_API_KEY",
            contextsize = 131072,
            models      = {main = "kimi-k2-turbo-preview", small = "moonshot-v1-8k"},
            modellist   = {"kimi-k2-turbo-preview", "moonshot-v1-32k", "moonshot-v1-8k"}
        },
        dashscope = {
            kind        = "openai",
            title       = "Aliyun Qwen",
            baseurl     = "https://dashscope.aliyuncs.com/compatible-mode",
            apikeyenv   = "DASHSCOPE_API_KEY",
            contextsize = 131072,
            models      = {main = "qwen3-coder-plus", small = "qwen-turbo"},
            modellist   = {"qwen3-coder-plus", "qwen-max", "qwen-plus", "qwen-turbo"}
        },
        siliconflow = {
            kind        = "openai",
            title       = "SiliconFlow",
            baseurl     = "https://api.siliconflow.cn",
            apikeyenv   = "SILICONFLOW_API_KEY",
            contextsize = 131072,
            models      = {main = "deepseek-ai/DeepSeek-V3", small = "Qwen/Qwen2.5-7B-Instruct"}
        },
        openrouter = {
            kind        = "openai",
            title       = "OpenRouter",
            baseurl     = "https://openrouter.ai/api",
            apikeyenv   = "OPENROUTER_API_KEY",
            contextsize = 131072,
            models      = {main = "anthropic/claude-sonnet-4.5", small = "anthropic/claude-haiku-4.5"}
        },
        zhipu = {
            kind        = "openai",
            title       = "Zhipu GLM",
            baseurl     = "https://open.bigmodel.cn/api/paas/v4",
            apikeyenv   = "ZHIPU_API_KEY",
            contextsize = 131072,
            models      = {main = "glm-4.6", small = "glm-4-flash"}
        },
        ollama = {
            kind        = "openai",
            title       = "Ollama (local)",
            baseurl     = "http://127.0.0.1:11434",
            apikey      = "ollama",
            contextsize = 32768,
            models      = {main = "qwen2.5-coder:14b", small = "qwen2.5-coder:7b"}
        }
    }
end

-- get the preset of the given provider name
function preset(name)
    return presets()[name]
end
