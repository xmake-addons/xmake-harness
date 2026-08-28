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
-- @file        xmake.lua
--

task("ai")
    set_category("plugin")
    on_run("main")
    set_menu {
        usage = "xmake ai [options] [prompt]",
        description = "Chat with an AI coding agent in the terminal.",
        options = {
            {'p', "provider",   "kv", nil, "Use the given llm provider.",
                                           "e.g.",
                                           "    $ xmake ai -p deepseek",
                                           "    $ xmake ai -p anthropic"},
            {'m', "model",      "kv", nil, "Use the given main model."},
            {nil, "smallmodel", "kv", nil, "Use the given small model, it is used by the title/summary/light subagents."},
            {'a', "agent",      "kv", nil, "Run with the given agent."},
            {nil, "apikey",     "kv", nil, "Set the api key of the current provider and save it to the user config."},
            {nil, "config",     "kv", nil, "Set a user config value and exit.",
                                           "e.g.",
                                           "    $ xmake ai --config=providers.deepseek.apikey=sk-xxx",
                                           "    $ xmake ai --config=ui.theme=light"},
            {nil, "trust",      "k",  nil, "Trust this project without asking: read its instructions, skills and plugins."},
            {nil, "no-trust",   "k",  nil, "Do not read anything this project would have the agent read."},
            {nil, "setup",      "k",  nil, "Run the interactive setup wizard and exit."},
            {nil, "showconfig", "k",  nil, "Show the resolved configuration and exit."},
            {nil, "doctor",     "k",  nil, "Check the harness environment and exit."},
            {},
            {'c', "continue",   "k",  nil, "Continue the last session of this directory.",
                                           "e.g.",
                                           "    $ xmake ai -c",
                                           "    $ xmake ai -c 'and now add the tests'"},
            {'r', "resume",     "kv", nil, "Resume a session, it picks one interactively if no id is given.",
                                           "e.g.",
                                           "    $ xmake ai -r",
                                           "    $ xmake ai -r 6a86cfc5-bbda-14ce"},
            {nil, "new",        "k",  nil, "Start a new session even if `--continue` is set."},
            {nil, "print",      "k",  nil, "Run in the non-interactive mode, print the result and exit."},
            {nil, "command",    "kv", nil, "Run a slash command without entering the tui and exit.",
                                           "e.g.",
                                           "    $ xmake ai --command=doctor",
                                           "    $ xmake ai --command='xmake-skills'",
                                           "    $ xmake ai --command='model deepseek-reasoner'"},
            {nil, "list",       "kv", nil, "List the harness resources and exit.",
                                           values = {"skills", "agents", "tools", "commands", "plugins", "providers", "sessions"}},
            {},
            {nil, "mode",       "kv", "default", "Set the permission mode.",
                                           values = {"default", "acceptedits", "plan", "bypass"}},
            {nil, "web",        "k",  nil, "Open the web ui in a browser instead of the terminal.",
                                           "e.g.",
                                           "    $ xmake ai --web",
                                           "    $ xmake ai --web --port=9800",
                                           "    $ xmake ai --web --cwd=/path/to/project"},
            {nil, "port",       "kv", nil, "The port of the web ui, 9736 by default."},
            {nil, "host",       "kv", nil, "Where the web ui listens, the loopback by default.",
                                           "e.g.",
                                           "    $ xmake ai --web --host=0.0.0.0   # every interface",
                                           "    $ xmake ai --web --host=192.168.1.7",
                                           "It still demands the token: the url is the key."},
            {nil, "nobrowser",  "k",  nil, "Do not open the browser for --web."},
            {nil, "sandbox",    "k",  nil, "Run the tool commands in the sandbox."},
            {nil, "notools",    "k",  nil, "Disable all the tools, chat only."},
            {nil, "cwd",        "kv", nil, "Set the working directory."},
            {nil, "prompt",     "vs", nil, "The prompt to send, it enters the interactive tui if not given.",
                                           "e.g.",
                                           "    $ xmake ai",
                                           "    $ xmake ai how to add a package to xmake.lua?",
                                           "    $ xmake ai --print 'summarize the build errors'"}
        }
    }
