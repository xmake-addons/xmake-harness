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
-- @file        xmake_docs.lua
--

-- imports
import("harness.config.config")

-- find the xmake documentation directory
function _docsdir(harnessconfig)
    local settings = (harnessconfig.plugins or {}).xmake or {}
    local candidates = {settings.docsdir, path.join(config.homedir(), "docs", "xmake-docs")}
    for _, dir in ipairs(candidates) do
        if dir and os.isdir(dir) then
            return dir
        end
    end
end

-- define the tool
function define()
    return {
        name = "xmake_docs",
        group = "xmake",
        permission = "read",
        description = [[Search the xmake documentation.

It searches the local clone of https://github.com/xmake-io/xmake-docs if it is
available, so the answers come from the real documentation instead of the memory.]],
        parameters = {
            type = "object",
            properties = {
                keyword = {type = "string",  description = "The keyword to search, e.g. `add_requires`."},
                limit   = {type = "integer", description = "The maximum number of matches, 20 by default."}
            },
            required = {"keyword"}
        }
    }
end

-- run the tool
function run(context, args)
    local docsdir = _docsdir(context.config)
    if not docsdir then
        return {
            output = "the local xmake documentation is not available.\n"
                .. "clone it with `git clone --depth 1 https://github.com/xmake-io/xmake-docs "
                .. path.join(config.homedir(), "docs", "xmake-docs") .. "`,\n"
                .. "or use fetch_url with https://xmake.io/api/description/ instead.",
            iserror = true
        }
    end

    -- the documentation is markdown, the content search tool already does this
    local searchtool = context.harness:service("tools"):get("search_text")
    return searchtool.run(context, {
        pattern = args.keyword,
        path = docsdir,
        include = "*.md",
        limit = args.limit or 20})
end
