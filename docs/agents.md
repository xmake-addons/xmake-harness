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
