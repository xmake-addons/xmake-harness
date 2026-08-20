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
-- @file        todo_write.lua
--

-- define the tool
function define()
    return {
        name = "todo_write",
        group = "core",
        permission = "none",
        description = [[Maintain the task list of the current work.

Use it for the multi-step tasks: create the list first, then mark exactly one
item as `in_progress` while you work on it, and mark it `completed` immediately
when it is done. Skip it for the trivial single-step requests.]],
        parameters = {
            type = "object",
            properties = {
                todos = {
                    type = "array",
                    description = "The whole task list, it replaces the previous one.",
                    items = {
                        type = "object",
                        properties = {
                            content = {type = "string", description = "The task, in the imperative form, e.g. `Fix the link errors`."},
                            status  = {type = "string", description = "One of `pending`, `in_progress`, `completed`."}
                        },
                        required = {"content", "status"}
                    }
                }
            },
            required = {"todos"}
        }
    }
end

-- run the tool
function run(context, args)
    local todos = {}
    local counts = {pending = 0, in_progress = 0, completed = 0}
    for _, todo in ipairs(args.todos or {}) do
        local status = todo.status or "pending"
        if counts[status] == nil then
            status = "pending"
        end
        counts[status] = counts[status] + 1
        table.insert(todos, {content = todo.content, status = status})
    end
    context.harness:service("todos", todos)
    context.harness:emit("todos/changed", todos)

    local lines = {}
    for _, todo in ipairs(todos) do
        local marker = todo.status == "completed" and "[x]" or (todo.status == "in_progress" and "[~]" or "[ ]")
        table.insert(lines, string.format("%s %s", marker, todo.content))
    end
    return {
        output = string.format("The task list is updated (%d completed, %d in progress, %d pending):\n%s",
            counts.completed, counts.in_progress, counts.pending, table.concat(lines, "\n")),
        display = {
            title = "Todos",
            subject = string.format("%d/%d", counts.completed, #todos),
            summary = string.format("%d completed, %d in progress, %d pending", counts.completed, counts.in_progress, counts.pending),
            kind = "todos",
            todos = todos
        }
    }
end
