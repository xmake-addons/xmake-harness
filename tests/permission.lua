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
-- @file        permission.lua
--

-- imports
import("harness.permission.policy")

local READTOOL = {name = "read_file", permission = "read"}
local EXECTOOL = {name = "run_command", permission = "exec"}
local EDITTOOL = {name = "edit_file", permission = "write"}

function test_readonly_is_allowed()
    assert(policy.check({}, READTOOL, {}, {mode = "default"}) == "allow")
    assert(policy.check({}, READTOOL, {}, {mode = "plan"}) == "allow")
end

function test_default_asks()
    assert(policy.check({}, EXECTOOL, {command = "ls"}, {mode = "default"}) == "ask")
    assert(policy.check({}, EDITTOOL, {path = "a.c"}, {mode = "default"}) == "ask")
end

function test_acceptedits()
    assert(policy.check({}, EDITTOOL, {path = "a.c"}, {mode = "acceptedits"}) == "allow")
    assert(policy.check({}, EXECTOOL, {command = "ls"}, {mode = "acceptedits"}) == "ask")
end

function test_plan_denies()
    assert(policy.check({}, EDITTOOL, {path = "a.c"}, {mode = "plan"}) == "deny")
    assert(policy.check({}, EXECTOOL, {command = "ls"}, {mode = "plan"}) == "deny")
end

function test_bypass()
    assert(policy.check({}, EXECTOOL, {command = "rm -rf /"}, {mode = "bypass"}) == "allow")
end

function test_rules()
    local config = {permission = {allow = {"run_command(git *)"}, deny = {"run_command(rm *)"}}}
    assert(policy.check(config, EXECTOOL, {command = "git status"}, {mode = "default"}) == "allow")
    assert(policy.check(config, EXECTOOL, {command = "rm -rf /"}, {mode = "bypass"}) == "deny")
    assert(policy.check(config, EXECTOOL, {command = "make"}, {mode = "default"}) == "ask")
end

function test_signature()
    assert(policy.signature(EXECTOOL, {command = "git status"}) == "run_command(git status)")
    assert(policy.signature(READTOOL, {}) == "read_file()")
end

function test_nextmode()
    assert(policy.nextmode("default") == "acceptedits")
    assert(policy.nextmode("acceptedits") == "plan")
    assert(policy.nextmode("plan") == "default")
end
