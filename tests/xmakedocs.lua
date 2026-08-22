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
-- @file        xmakedocs.lua
--

-- imports
import("harness.plugins.xmake.docs")

-- make a fake checkout, so the test never needs the network
function _checkout()
    local rootdir = path.join(os.tmpdir(), "harness-docs-test", "docs")
    os.tryrm(path.directory(rootdir))
    os.mkdir(path.join(rootdir, "api", "description"))
    io.writefile(path.join(rootdir, "api", "description", "project-target.md"), [[
# Target

## set_kind

### Set the target kind

`binary`, `static` or `shared`.

## add_files

### Add source files

It accepts the wildcards.

## add_defines

### Add the macro definitions
]])
    os.mkdir(path.join(rootdir, "zh", "api", "description"))
    io.writefile(path.join(rootdir, "zh", "api", "description", "project-target.md"), [[
## add_files

### 添加源文件

支持通配符。
]])
    return rootdir
end

function test_find_a_checkout()
    local rootdir = _checkout()
    assert(docs.find({plugins = {xmake = {docsdir = path.directory(rootdir)}}}) == rootdir)
    os.tryrm(path.directory(rootdir))
end

function test_api_section()
    local rootdir = _checkout()
    local section, filepath = docs.api("add_files", {rootdir = rootdir})
    assert(section ~= nil, "add_files was not found")
    assert(section:startswith("## add_files"), section:sub(1, 40))
    assert(section:find("wildcards", 1, true), section)

    -- it stops at the next api, it must not swallow the whole file
    assert(not section:find("add_defines", 1, true), section)
    assert(filepath:endswith("project-target.md"))
    os.tryrm(path.directory(rootdir))
end

function test_api_unknown()
    local rootdir = _checkout()
    assert(docs.api("no_such_api", {rootdir = rootdir}) == nil)
    os.tryrm(path.directory(rootdir))
end

function test_api_chinese()
    local rootdir = _checkout()
    local section = docs.api("add_files", {rootdir = rootdir, language = "zh"})
    assert(section:find("添加源文件", 1, true), section:sub(1, 60))
    os.tryrm(path.directory(rootdir))
end

function test_apis_list()
    local rootdir = _checkout()
    local apis = docs.apis({rootdir = rootdir})
    assert(table.contains(apis, "add_files"), table.concat(apis, ", "))
    assert(table.contains(apis, "set_kind"))
    os.tryrm(path.directory(rootdir))
end

function test_grep()
    local rootdir = _checkout()
    local result = docs.grep("wildcards", {rootdir = rootdir})
    assert(result ~= nil and result.total > 0, "nothing was found")
    os.tryrm(path.directory(rootdir))
end

function test_page_prefers_the_checkout()
    local rootdir = _checkout()
    local filepath = docs.page("api/description/project-target.md", {rootdir = rootdir})
    assert(filepath == path.join(rootdir, "api", "description", "project-target.md"), tostring(filepath))
    os.tryrm(path.directory(rootdir))
end

function test_no_checkout_no_network()
    -- offline and with nothing cached, it says so instead of hanging
    assert(docs.page("api/description/nothing-here.md", {rootdir = false, offline = true}) == nil)
end
