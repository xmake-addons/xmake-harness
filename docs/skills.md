# Skills

A skill is a directory with a `SKILL.md` file. The format is the claude code one, so
an existing skill repository works unchanged.

```
skills/
  xmake-packages/
    SKILL.md
    reference.md        the optional extra files, the agent reads them if needed
```

```markdown
---
name: xmake-packages
description: Use when adding third-party C/C++ dependencies to an xmake project — via add_requires / add_packages, configuring package options or pinning versions.
---

# Adding packages

..the instructions the agent must follow..
```

## Why the description matters

Only the **name and the description** of every skill go into the system prompt. The
body is loaded on demand by the `use_skill` tool. So 50 skills cost a few hundred
tokens, and the model pays for the body only when it actually needs it.

Write the description as a trigger, not as a summary: *"Use when ..."*.

## Where they are discovered

| directory | source |
| --- | --- |
| `<addon>/modules/harness/assets/skills` | the builtin ones |
| `~/.xmake/harness/skills` | the user ones |
| `<project>/.xmake-harness/skills` | the project ones |
| `skills.dirs` in the config | the extra ones |
| whatever a plugin registers | e.g. the xmake plugin |

Nested layouts are supported (`skills/<category>/<name>/SKILL.md`), which is how the
[xmake-skills](https://github.com/xmake-io/xmake-skills) repository is organized.

```bash
xmake ai --command=xmake-skills   # clone/update xmake-skills into ~/.xmake/harness/skills
xmake ai --list=skills
```

The xmake plugin also picks up an existing `~/.claude/xmake-skills/skills` checkout,
so a claude code user shares one copy.

## Enabling and disabling

```json
{"skills": {"enabled": ["xmake-packages", "xmake-rules"], "disabled": ["xmake-nim"]}}
```

An empty `enabled` list means "all of them".
