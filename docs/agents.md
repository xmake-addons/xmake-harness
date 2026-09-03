# Agents

English | [中文](agents.zh.md)

A subagent runs in its own context window, with its own system prompt, its own tool
set and its own model. Only its final message returns to the caller, which is why it
is the right tool for the wide searches and the long explorations.

```markdown
---
name: explorer
description: Search the codebase and report the findings. Use it when answering means sweeping many files.
tools: read_file, list_dir, glob_files, search_text, use_skill
model: small
maxsteps: 30
---

You are a codebase explorer. ..
```

| field | meaning |
| --- | --- |
| `name` | how the model refers to it in `run_agent` |
| `description` | when to use it, it goes into the system prompt |
| `tools` | the allowed tools, all of them if omitted, `*` for all |
| `model` | a tier (`main`, `small`, `reasoner`) or an explicit model id |
| `maxsteps` | the step budget, 60 by default |
| the body | the system prompt, it replaces the default identity |

## The builtin agents

| agent | purpose |
| --- | --- |
| `explorer` | search the codebase and report the findings (small model) |
| `planner` | design an implementation plan before the code is written |
| `reviewer` | review a change for the correctness bugs and the cleanups |
| `xmake-builder` | fix an xmake build, iterating build → fix → build (xmake plugin) |
| `xmake-porter` | convert a cmake/msbuild/meson/scons project to xmake — a bundle, with its own skills and its own `agent.lua` |

## Where they are discovered

`<addon>/modules/harness/assets/agents`, `~/.xmake/harness/agents`,
`<project>/.xmake-harness/agents` (once the project is trusted), `agents.dirs` in
the config, whatever the plugins register, and the installed packs. The first of a
name wins, so your own always beats a pack's.

`/agents` lists them, and lists two things which used to be invisible: the files
which look like agents and cannot be used, each with the reason, and the ones
which lost their name to another. A file skipped in silence still holds its name
on disk while every surface shows nothing to fix and nothing to delete.

## An agent which is a directory

One that brings more than a prompt is written as a directory instead, and then
it can carry the skills it reads and the lua it needs:

```
xmake-porter/
    AGENT.md            the prompt and the frontmatter
    agent.lua           optional, see below
    skills/
        xmake-import/SKILL.md
        xmake-import-cmake/SKILL.md
```

The skills of a bundle are loaded with it and marked `agent:<name>`, so
installing the agent installs what it reads. Adding another built-in agent is
another directory and nothing else.


## `agent.lua`

Most agents should stay a markdown file: a prompt, a list of tools, and nothing
to go wrong. Some cannot. An agent whose first act is always the same command
should arrive knowing the answer, and one whose tools depend on what is in the
directory cannot list them in frontmatter.

Such an agent puts an `agent.lua` beside its `AGENT.md` and exports any of:

```lua
-- change the definition: the tools, the model, the step budget
function define(context)
    return {tools = {"read_file", "xmake_build"}, maxsteps = 12}
end

-- text appended to its system prompt
function prompt(context)
    return "This project uses xmake 3.x."
end

-- text appended to the task: what it has already found out
function before(context)
    progress.stage(context.progress, "reading the project")
    return "I read it for you: 3 targets, 2 of them libraries."
end

-- the last word on the report
function after(context, result)
    return string.format("that took %d steps.", result.steps)
end
```

`context` carries `{harness, agent, prompt, description, cwd, progress, depth}`.
Every hook is optional, every one runs inside a `try`, and a script which raises
is reported and then ignored — an agent which cannot be improved is better than
a harness which cannot run one.

The `xmake-porter` uses this: detecting the build system and reading it are the
same answer every time, so it does them before the first request instead of
spending two steps on them.


## Packs

A pack is a directory of markdown fetched from somewhere, exactly as a skill
pack is — the same installer underneath, @see `harness/packs/packs.lua`:

```
/agents install github:someone/their-agents
/agents install https://github.com/someone/their-agents.git
/agents install ~/my-agents
/agents install ~/downloads/agents.zip
```

The layouts it recognises are the ones which exist, so somebody else's project
works as a pack:

| layout | where the agents are |
| --- | --- |
| `agents` | `<root>/agents/<name>.md` |
| `claude` | `<root>/.claude/agents/<name>.md` |
| `dsh` | `<root>/.agents/<name>.md` |
| `flat` | `<root>/<name>.md` |
| `claude-plugin` / `claude-market` | `.claude-plugin/` and the plugins it lists |

Packs live in `~/.xmake/harness/agents/<pack>/` and are never bundled with the
harness. A plugin registers one from its `apply()` so `/agents install <name>`
knows what the name means.


## Progress

Anything which runs for minutes says what it is doing on one channel, and every
front end reads the same one — @see `harness/core/progress.lua`:

```
● map the project · step 7 · reading src/main.c · 2m14s
```

The elapsed time is worked out when the line is *drawn* and not when the last
event arrived, because a number which stops moving between two events reads as a
harness which has stopped. An `agent.lua` reports into the same channel with
`progress.stage(context.progress, "…")`.

## The nesting

A subagent may itself delegate, up to a depth of 3. Its token usage is reported back
in the tool result, and it shares the abort signal of the parent, so `esc` stops the
whole tree.

## The graph

One `run_agent` call is a single task. Real work usually has a shape: three
explorations which know nothing about each other, then a plan which needs all
three, then a review of that plan. Driving that by hand costs one round trip per
level, and every intermediate report passes through the main context on its way.

`run_agents` takes the whole shape at once. Every node is one subagent, and
`needs` names the nodes whose reports it must have first:

```json
{"nodes": [
  {"id": "parser",  "agent": "explorer", "prompt": "map the parser"},
  {"id": "codegen", "agent": "explorer", "prompt": "map the code generator"},
  {"id": "plan",    "agent": "planner",  "prompt": "plan the new syntax",
   "needs": ["parser", "codegen"]}
]}
```

`parser` and `codegen` run at the same time; `plan` starts when both are done and
is given their reports, each wrapped in a named `<report from="...">` block so it
can tell them apart and so nothing inside a report reads as an instruction.

Only the leaves — the nodes nobody depends on — report back to the caller. The
rest already told the nodes which needed them, and repeating their text would put
the whole graph back into the context the graph exists to keep it out of. A short
status line still names every node, so a failure is never silent.

The graph is checked before anything runs: a cycle, a missing dependency, a
duplicate id or a node which needs itself comes back as a message the model can
act on, not as a half-executed graph. If a node fails, whatever needed it is
skipped rather than run on nothing. `agent.maxparallel` (3) caps how many nodes
run at a time — a node is a whole agent loop, so the useful number is smaller
than for tool calls.

Use `run_agent` instead when there is only one task, or when what you do next
depends on what you just read.

## When a turn goes nowhere

The step budget is the last line of defence, not the first. Two cheaper guards run
on every step, because a model gets stuck in two recognisable ways:

- it repeats the very same round of tool calls, waiting for a different answer to
  the same question — three identical rounds in a row and the turn stops
- everything it tries fails, and it keeps trying variations of a broken idea —
  three consecutive rounds where *every* tool failed and the turn stops

A round counts as identical only if the tool names and their arguments match, so
`edit → build → edit → build` is not a loop: those rounds differ, and reading a
second file is progress even though the tool is the same. A partial failure is
progress too; only an all-failed round moves the counter.

When a guard fires the reason is told to the model as well as the user, so a
session which continues afterwards knows what not to do again. `agent.maxrepeats`
and `agent.maxerrors` tune them, both 3 by default.

## Why a turn ended

Every ending carries a code as well as a sentence. The sentence is for whoever
reads the screen; the code is for whatever decides what to do next.

| code | what happened |
| --- | --- |
| `done` | the model asked for nothing more, the ordinary ending |
| `step-budget` | it ran out of steps with work still in hand |
| `repeated-tool-calls` | it asked for the same thing until a guard stopped it |
| `all-tools-failed` | nothing it tried worked, three rounds running |
| `aborted` | the user interrupted it |
| `error` | the request itself failed |

It is on the turn result as `stop = {code, text}` and in the session log on the
notice which recorded it, so a repeating task, a report or a test can act on the
reason without matching prose. `/loop` is the first consumer: it keeps going
after a step budget and gives up after three stuck iterations, which are not the
same thing at all.

## The parallel calls

A model may ask for several tools in one step. The ones which only read — searching,
listing, reading a file — run concurrently on the coroutine scheduler, `tools.maxconcurrency`
(4) at a time; anything which writes or executes runs alone and in order. So reading
five files costs one round trip instead of five, while two edits never race.
