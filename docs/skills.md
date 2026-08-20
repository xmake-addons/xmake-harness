# Skills

English | [中文](skills.zh.md)

A skill is a directory with a `SKILL.md` file. The format is the claude code
one, so an existing skill repository works unchanged.

```
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

Only the **name and the description** of every skill go into the system prompt.
The body is loaded on demand by the `use_skill` tool. So 50 skills cost a few
hundred tokens, and the model pays for the body only when it needs it.

Write the description as a trigger, not as a summary: *"Use when ..."*.

## Installing a pack

Nothing is bundled with the harness. The packs live in their own repositories,
are fetched only when you ask, and always come from the current upstream:

```
/skills                              what is loaded, installed and available
/skills install xmake                a registered pack
/skills install github:user/repo     a github repository
/skills install https://.../x.git    any git url
/skills install /path/to/my-skills   a local directory (it is linked, for development)
/skills update [pack]                git pull
/skills remove <pack>                delete it
```

It always asks before it downloads anything:

```
  ╭─ Install skill pack ────────────────────────────────────╮
  │ xmake-skills                                            │
  │ https://github.com/xmake-io/xmake-skills.git            │
  │ The xmake build skills: the packages, the rules, ..     │
  │                                                         │
  │ it is cloned into ~/.xmake/harness/skills/xmake-skills  │
  │                                                         │
  │ Do you want to fetch it from the network?               │
  │ ❯ 1. Yes                                                │
  │   2. No (esc)                                           │
  ╰─────────────────────────────────────────────────────────╯
```

Outside the tui:

```bash
xmake ai --command="skills install xmake" -y
```

## Where they are discovered

| directory | source |
| --- | --- |
| `~/.xmake/harness/skills/<pack>/` | the installed packs |
| `~/.xmake/harness/skills/` | your own loose skills |
| `<project>/.xmake-harness/skills/` | the project ones |
| `<addon>/modules/harness/assets/skills` | the few builtin ones |
| `skills.dirs` in the config | the extra directories |

Nested layouts are supported (`skills/<category>/<name>/SKILL.md`), which is how
the [xmake-skills](https://github.com/xmake-io/xmake-skills) repository is
organized. An existing `~/.claude/xmake-skills` checkout is picked up as is, so
one copy serves both tools.

## Registering a pack from a plugin

```lua
import("harness.skills.installer")

function apply(harness, definition)
    installer.register(harness, {
        name = "mybuild",
        url = "https://github.com/me/mybuild-skills.git",
        description = "The mybuild recipes"
    })
end
```

Then `/skills install mybuild` works, and the pack shows up in the available
list. The plugin should never clone anything by itself.

## Enabling and disabling

```json
{"skills": {"enabled": ["xmake-packages", "xmake-rules"], "disabled": ["xmake-nim"]}}
```

An empty `enabled` list means "all of them".
