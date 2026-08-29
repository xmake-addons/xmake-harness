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
import("harness.util.util")
import("harness.util.text")
import("harness.util.language")
import("harness.plugins.xmake.docs")

-- define the tool
function define()
    return {
        name = "xmake_docs",
        group = "xmake",
        permission = "read",
        description = [[Look an xmake api or topic up in the official documentation.

Use it before writing an `xmake.lua` api you are not sure about: it returns the
real prototype and the real parameters, which is cheaper and safer than guessing.
It works out of the box: the pages are fetched from the upstream documentation
and cached, and a local checkout is used instead when the user has one.

- `api` looks one interface up, e.g. `add_files`, `set_kind`, `add_requires`.
  This is the precise mode, prefer it.
- `keyword` searches the whole documentation when you do not know the api name
  yet, e.g. `qt.widgetapp`, `cross compilation`.]],
        parameters = {
            type = "object",
            properties = {
                api     = {type = "string",  description = "The api name to look up, e.g. `add_files`."},
                keyword = {type = "string",  description = "What to search when the api name is unknown."},
                limit   = {type = "integer", description = "The maximum number of search matches, 20 by default."}
            }
        }
    }
end

-- run the tool
--
-- a local checkout is used when the user has one, otherwise the pages are
-- fetched once and cached, so this works with nothing installed
--
function run(context, args)
    local rootdir = docs.find(context.config)
    local lang = language.ofsession(context.session)
    if args.api and args.api ~= "" then
        return _api(args.api, rootdir, lang, context.config)
    end
    if args.keyword and args.keyword ~= "" then
        return _search(args.keyword, rootdir, lang, args.limit, context.config)
    end
    return {output = "give me an `api` name or a `keyword` to look up.", iserror = true}
end

-- look one api up
function _api(name, rootdir, lang, harnessconfig)
    local section, filepath = docs.api(name, {rootdir = rootdir, language = lang, config = harnessconfig})
    if not section then
        return _notfound(name, rootdir, harnessconfig)
    end
    return {
        output = section,
        display = {
            title = "xmake docs",
            subject = name,
            summary = string.format("%d lines from %s", #text.lines(section), path.filename(filepath))
        }
    }
end

-- the api is unknown, the closest names help more than an empty answer
function _notfound(name, rootdir, harnessconfig)
    local suggestions = {}
    local prefix = name:match("^([%a]+)_") or name:sub(1, 4)
    for _, api in ipairs(docs.apis({rootdir = rootdir, config = harnessconfig})) do
        if api:startswith(prefix) or api:find(name, 1, true) then
            table.insert(suggestions, api)
        end
        if #suggestions >= 12 then
            break
        end
    end
    local output = string.format("`%s` is not in the documentation.", name)
    if #suggestions > 0 then
        output = output .. "\n\ndid you mean one of these?\n  " .. table.concat(suggestions, ", ")
    end
    return {output = output, display = {title = "xmake docs", subject = name, summary = "not found"}}
end

-- search the documentation
function _search(keyword, rootdir, lang, limit, harnessconfig)
    local result = docs.grep(keyword, {rootdir = rootdir, language = lang, config = harnessconfig,
        limit = math.min(tonumber(limit) or 20, 100)})
    if not result or result.total == 0 then
        return {output = string.format("nothing about `%s` in the documentation.", keyword),
                display = {title = "xmake docs", subject = keyword, summary = "no matches"}}
    end

    local lines = {}
    for _, match in ipairs(result.matches) do
        table.insert(lines, string.format("%s:%d: %s", path.filename(match.path),
            match.line or 0, text.cut((match.text or ""):trim(), 200)))
    end
    table.insert(lines, "")
    table.insert(lines, "look one of them up with `api=<name>` to get its prototype and parameters.")
    return {
        output = table.concat(lines, "\n"),
        display = {
            title = "xmake docs",
            subject = keyword,
            summary = string.format("%d match%s", result.total, result.total == 1 and "" or "es")
        }
    }
end
