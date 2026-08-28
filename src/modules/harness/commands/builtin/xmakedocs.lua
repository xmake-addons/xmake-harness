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

--
-- the xmake documentation command: /xmake-docs
--
-- it is registered by the xmake plugin, @see harness.plugins.xmake.plugin
--

-- imports
import("harness.ui.theme")
import("harness.plugins.xmake.docs")

-- the command definition
function command()
    return {
        name = "xmake-docs",
        description = "Fetch or update the xmake documentation, so the agent can look the apis up",
        run = _run
    }
end

-- /xmake-docs [status]
function _run(app, args)
    local harnessconfig = app.harness:config()
    if (args or ""):trim() == "status" then
        local rootdir = docs.find(harnessconfig)
        return {kind = "message", text = rootdir
            and string.format("the documentation is at %s (%d apis)", rootdir, #docs.apis({rootdir = rootdir}))
            or "the documentation is not installed, run `/xmake-docs` to fetch it."}
    end

    if not _ask(app) then
        return {kind = "message", text = "cancelled."}
    end
    -- it goes into the background, because nothing here waits on it: it is a
    -- copy of the documentation, and until it lands the agent simply does not
    -- have it. the terminal stays yours, and the job says so when it is done
    local store = app.harness:service("jobs")
    if store then
        local job, errors = docs.fetch({
            jobs = store,
            context = {harness = app.harness, config = app.harness:config(),
                       cwd = app.harness:rootdir()}})
        if not job then
            return {kind = "message", text = tostring(errors), iserror = true}
        end
        return {kind = "message", text = string.format(
            "fetching the xmake documentation in the background (job %s).\n"
            .. "carry on, it will say when it is ready. /jobs to look, /jobs kill %s to stop it.",
            job.id, job.id)}
    end

    -- no job store, e.g. `--command`: then it is worth waiting for
    local rootdir, errors = docs.install({
        context = app.processcontext and app:processcontext("Cloning the documentation") or nil,
        onprogress = function (message) app:notify(message) end})
    if app.processdone then
        app:processdone()
    end
    if not rootdir then
        return {kind = "message", text = tostring(errors), iserror = true}
    end
    return {kind = "message", text = string.format(
        "the xmake documentation is ready: %d apis from %s\nthe agent looks them up with `xmake_docs`",
        #docs.apis({rootdir = rootdir}), rootdir)}
end

-- it downloads a repository into the user home, so we ask first
function _ask(app)
    if not app.ask then
        return true
    end
    return app:ask({
        lines = {
            theme.styled("tool.name", "xmake-docs"),
            theme.styled("md.code", "https://github.com/xmake-io/xmake-docs.git"),
            theme.styled("dim", "it is cloned into " .. docs.dir())
        },
        question = docs.isavailable(app.harness:config())
            and "Do you want to update it from the network?"
            or "Do you want to fetch it from the network?",
        options = {{text = "Yes", value = true}, {text = "No", value = false}}})
end
