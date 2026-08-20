# Getting started

English | [中文](getting-started.zh.md)

English | [中文](getting-started.zh.md)

## Install

```bash
xmake addon --install xmake-harness
```

Or run it from a source checkout, no installation needed:

```bash
git clone https://github.com/xmake-io/xmake-harness.git
cd xmake-harness
source scripts/srcenv.profile
```

Requirements: xmake >= 3.0.9, `curl`, and `git` if you want the skill packs.

## Configure a model

```bash
xmake ai --setup
```

The wizard asks for a provider and its api key and writes them to
`~/.xmake/harness/config.json`. Nothing is ever written into your project.

Non-interactive:

```bash
xmake ai --config=providers.deepseek.apikey=sk-xxxxxx
xmake ai --provider=deepseek --model=deepseek-chat
```

Check it:

```bash
xmake ai --doctor
```

## The first session

```bash
cd /path/to/your/project
xmake ai
```

```
 ╭──────────────────────────────────────────────────────────╮
 │   __  ___ __  __  __ _| | ______                          │
 │   \ \/ / |  \/  |/ _  | |/ / __ \                         │
 │    >  <  | \__/ | /_| |   <  ___/                         │
 │   /_/\_\_|_|  |_|\__ \|_|\_\____|                         │
 │                                                           │
 │ xmake ai  ·  the ai coding agent of xmake                 │
 │                                                           │
 │ model:   deepseek-chat  (deepseek · small: deepseek-chat) │
 │ cwd:     /path/to/your/project                            │
 │ loaded:  54 skills · 19 tools · xmake project             │
 ╰──────────────────────────────────────────────────────────╯
   /help for the commands · @ to attach a file · ! to run a shell command
   esc interrupts · shift+tab cycles the permission mode
```

Type a question and press enter. The agent reads the files it needs, and asks
before it changes anything or runs a command.

## The everyday commands

```bash
xmake ai "add a unit test for the parser"   # start with a prompt
xmake ai -c                                  # continue the last session here
xmake ai --print "what does this build?"     # non-interactive, for the scripts
xmake ai --mode=plan                         # read-only, plan first
xmake ai --sandbox                           # confine the commands it runs
xmake ai --command=doctor                    # run a slash command and exit
```

## Install the skills

The skill packs are not bundled: they live in their own repositories and are
fetched when you ask for them, so you always get the current version.

```
/skills                      what is loaded and what is available
/skills install xmake        the xmake build skills
/skills update               update everything installed
```

It asks before it downloads anything.

## Where things live

| path | what |
| --- | --- |
| `~/.xmake/harness/config.json` | your configuration and the api keys |
| `~/.xmake/harness/skills/` | the installed skill packs |
| `~/.xmake/harness/projects/<project>/` | the session history of that project |
| `~/.xmake/harness/agents`, `commands`, `plugins` | your own extensions |
| `<project>/.xmake-harness/` | the same, scoped to one project |
| `<project>/XMAKE.md` | the project instructions every session reads |
