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
-- @file        fetch_url.lua
--

-- imports
import("lib.detect.find_tool")
import("harness.util.text")

-- define the tool
function define()
    return {
        name = "fetch_url",
        group = "net",
        permission = "network",
        description = [[Fetch a web page or a raw file and return its text content.

The html tags are stripped, so it is best used for the documentation pages, the
raw files of a repository and the json apis.]],
        parameters = {
            type = "object",
            properties = {
                url    = {type = "string",  description = "The url to fetch."},
                limit  = {type = "integer", description = "The maximum number of characters to return, 40000 by default."}
            },
            required = {"url"}
        }
    }
end

-- run the tool
function run(context, args)
    local url = args.url
    if not url:startswith("http://") and not url:startswith("https://") then
        raise("only the http(s) urls are supported: %s", url)
    end
    local curl = find_tool("curl")
    if not curl then
        raise("curl is not found, it is required by fetch_url.")
    end
    local outfile = os.tmpfile()
    local ok = try {
        function ()
            os.execv(curl.program, {"-sSL", "--max-time", "60", "-A", "xmake-harness", "-o", outfile, url},
                {stdout = os.nuldev(), stderr = os.nuldev()})
            return true
        end
    }
    if not ok or not os.isfile(outfile) then
        os.tryrm(outfile)
        raise("failed to fetch %s", url)
    end
    local content = io.readfile(outfile) or ""
    os.tryrm(outfile)

    local limit = math.min(tonumber(args.limit) or 40000, 200000)
    local istext = not content:find("\0", 1, true)
    if not istext then
        raise("%s is not a text resource.", url)
    end
    if content:lower():find("<html", 1, true) or content:lower():find("<!doctype html", 1, true) then
        content = _html2text(content)
    end
    local truncated = false
    if #content > limit then
        content = text.cut(content, limit)
        truncated = true
    end
    return {
        output = content .. (truncated and "\n\n[the content is truncated]" or ""),
        display = {
            title = "Fetch",
            subject = url,
            summary = string.format("%d characters", #content)
        }
    }
end

-- convert the html to the plain text
function _html2text(html)
    html = html:gsub("<script.-</script>", " ")
    html = html:gsub("<style.-</style>", " ")
    html = html:gsub("<!%-%-.-%-%->", " ")
    html = html:gsub("<br%s*/?>", "\n")
    html = html:gsub("</p>", "\n\n")
    html = html:gsub("</h%d>", "\n\n")
    html = html:gsub("</li>", "\n")
    html = html:gsub("<[^>]->", "")
    html = html:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"):gsub("&quot;", "\"")
    local lines = {}
    for _, line in ipairs(text.lines(html)) do
        line = line:trim()
        if line ~= "" then
            table.insert(lines, line)
        end
    end
    return table.concat(lines, "\n")
end
