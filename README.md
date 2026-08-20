<div align="center">
  <a href="https://xmake.io">
    <img width="160" height="160" src="https://xmake.io/assets/img/logo.png">
  </a>

  <h1>xmake-harness</h1>

  <div>
    <a href="https://github.com/xmake-io/xmake-harness/blob/main/LICENSE.md">
      <img src="https://img.shields.io/github/license/xmake-io/xmake-harness.svg?colorB=f48041&style=flat-square" alt="license" />
    </a>
    <a href="https://xmake.io/about/sponsor.html">
      <img src="https://img.shields.io/badge/donate-us-orange.svg?style=flat-square" alt="Donate" />
    </a>
  </div>

  <b>A generic AI agent harness written in pure xmake lua</b><br/>
  <i>`xmake ai` gives you a claude-code style terminal agent, with first-class xmake build support</i><br/>
</div>

## Introduction ([中文](/README_zh.md))

`xmake-harness` is two things:

1. **A generic agent harness framework** written entirely in xmake lua, with no third-party
   dependency: the session log, the agent loop, the tool pipeline, the permission policy, the
   sandbox, the skills, the subagents, the slash commands and the terminal ui.
2. **An xmake addon** which exposes it as `xmake ai`, a terminal coding agent whose interaction
   follows claude code closely.

The framework knows nothing about xmake. Everything build-system specific — the `xmake_*` tools,
the [xmake skills](https://github.com/xmake-io/xmake-skills), the documentation search and the
`xmake-builder` agent — lives in a plugin, so the same harness serves a cmake project (a plugin
is shipped as an example), a plain repository, or your own toolchain.

```
$ xmake ai
 ✻ xmake ai  ·  deepseek · deepseek-chat
   my-project

   /help for the commands · @ to attach a file · esc to interrupt

› why does the link step fail on windows?

● Update(src/xmake.lua)
  └ Added 1 line, removed 1 line
    12   add_files("src/*.c")
    13 - add_links("ws2_32")
    13 + add_syslinks("ws2_32")

● The link failed because `add_links` looks for a library in the project link
  directories. `ws2_32` is a system library, so it must be added with `add_syslinks`.

  8.4k tokens (↑ 8.2k · ↓ 210 · cache 82%) · 6.1s · 2 steps
────────────────────────────────────────────────────────────────────
› ▏
────────────────────────────────────────────────────────────────────
  ⏵ default mode (shift+tab to cycle) · / for commands · @ for files
```

## Features

| | |
| --- | --- |
| **Terminal UI** | streaming markdown, colored diffs, tool cards, permission dialogs, `/` command completion, `@` file completion, input history, cjk aware layout |
| **Any model** | deepseek, anthropic, openai, moonshot(kimi), qwen, zhipu(glm), siliconflow, openrouter, ollama, or your own endpoint. The api keys live on the user side, never in the project |
| **Model tiers** | a main model and a small model, the small one does the titles, the summaries and the light subagents |
| **Tools** | read/write/edit files, glob, content search, shell, todo list, subagents, skills, url fetch — plus whatever the plugins add |
| **Skills** | claude-code compatible `SKILL.md` directories, loaded on demand so a large library costs no context |
| **Subagents** | markdown agent definitions with their own prompt, tools and model, running in their own context window |
| **Permissions** | `default` / `acceptedits` / `plan` / `bypass`, plus the allow/deny rules, shift+tab to cycle |
| **Sandbox** | macos seatbelt and linux bubblewrap confinement for the spawned commands |
| **Context** | automatic compaction with a summary when the window fills up, `/context` and `/cost` to watch it |
| **Sessions** | every turn is an append-only event log on disk: resume, replay, export |
| **Plugins** | everything above the context is a plugin: tools, skills, agents, commands, prompt sections, llm providers |

## Install

```bash
xmake addon --install xmake-harness
xmake ai --setup
```

Or run it from a source checkout without installing anything:

```bash
git clone https://github.com/xmake-io/xmake-harness.git
cd xmake-harness
source scripts/srcenv.profile
xmake ai
```

The setup wizard asks for the provider and its api key, and saves them to
`~/.xmake/harness/config.json`. You can also set them non-interactively:

```bash
xmake ai --config=providers.deepseek.apikey=sk-xxxxxx
xmake ai --provider=deepseek --model=deepseek-chat
```

## Usage

```bash
xmake ai                             # the interactive tui
xmake ai "add a unit test for foo"   # start with a prompt
xmake ai --print "what does this build?"   # non-interactive, for the scripts and the ci
xmake ai -c                          # continue the last session of this directory
xmake ai --mode=plan                 # read-only, plan before doing anything
xmake ai --sandbox                   # confine the commands it runs

xmake ai --doctor                    # check the environment
xmake ai --list=skills               # what is loaded
xmake ai --command=xmake-skills      # install/update the xmake skills
```

Everything else is a slash command, exactly like claude code: `/help`, `/model`,
`/provider`, `/config`, `/context`, `/compact`, `/cost`, `/permissions`,
`/skills`, `/agents`, `/tools`, `/sessions`, `/resume`, `/export`, `/init`, `/clear`,
`/doctor`. The same commands run outside the tui with `--command`:

```bash
xmake ai --command="model deepseek-reasoner"
xmake ai --command=xmake-skills
```

## Documentation

- [Architecture](docs/architecture.md) — the layers, the seams and the event flow
- [Configuration](docs/configuration.md) — the config layers, the providers, the model tiers
- [The terminal ui](docs/tui.md) — the rendering model, the keys, the slash commands
- [Tools](docs/tools.md) — the builtin tools and how to add one
- [Skills](docs/skills.md) — the `SKILL.md` format and where they are discovered
- [Agents](docs/agents.md) — the subagent definitions
- [Plugins](docs/plugins.md) — the plugin api, with the xmake and cmake plugins as examples
- [The xmake enhancement](docs/xmake.md) — what the xmake plugin adds
- [Development](docs/development.md) — running from source, the tests, the debug log

## Requirements

- xmake >= 3.0.9 (it provides the addon system this repository builds on)
- `curl` (the llm transport)
- `git` (optional, only to sync the skill repositories)

## License

[Apache-2.0](LICENSE.md)
