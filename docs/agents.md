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

## Where they are discovered

`<addon>/modules/harness/assets/agents`, `~/.xmake/harness/agents`,
`<project>/.xmake-harness/agents`, `agents.dirs` in the config, plus whatever the
plugins register.

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
