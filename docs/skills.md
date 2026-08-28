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

Only the **name and the description** of every skill go into the system prompt,
and not even all of the description: what is listed is the trigger — the first
clause, with the *"Use when"* taken off and a cap of 120 characters. The body is
loaded on demand by the `use_skill` tool.

That trimming is not cosmetic. A pack of 53 skills wrote 15.7 KB of description
into every single request, three quarters of the whole system prompt; the
triggers are 5 KB. The half which is cut — the *"Covers x, y and z"* half — is of
no use to somebody deciding whether to open the skill, and of every use once it
is open, which is exactly where it still is.

So write the description as a trigger first and a summary second:

```
description: Use when <the trigger, in one clause> — <everything it covers>
```

The clause before the dash (or the first sentence) is what the model routes on.
Everything after it is still read, just later.

Fetching a pack is a clone, and a clone is minutes of network that nothing in
the conversation waits on. So it goes to the background: the command returns at
once, `/jobs` lists it, `/jobs kill <id>` stops it, and it says when it has
landed. The skills are read the moment it does — no `/reload` needed.

## When it does not pick one

The listing says what each skill is for and the model decides whether to open it,
which it does not always do — a skill can be installed, enabled, correctly
described and still ignored. `/skill:<name>` takes the choice away from it:

```
/skill:xmake-templates start a c++ project here
```

Every enabled skill is a command, so `/skill:` in the editor completes them.

A skill written or edited while the harness is running is picked up by `/reload`,
which also re-reads the configuration, the subagents and the commands. Installing
a pack reloads on its own.

## Installing a pack

Nothing is bundled with the harness. The packs live in their own repositories,
are fetched only when you ask, and always come from the current upstream:

```
/skills                              what is loaded, installed and available
/skills install xmake                a registered pack
/skills install github:user/repo     a github repository
/skills install https://.../x.git    any git url
/skills install /path/to/my-skills   a local directory (it is linked, for development)
/skills install ./bundle.zip         a packed bundle (.zip, .tar.gz, .tgz, ..)
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

Pointing it at a tool you already use is the same command — the directory is
linked, not copied, so it stays in step with whatever that tool writes there:

```
/skills install ~/.claude            the claude skills you already have
/skills install ~/.dsh/skills        the dsh ones
```

The leading dot is dropped from the pack name, so those become `claude` and
`skills`. Nothing is written back into them.

## The layouts it accepts

A skill is a markdown file whose frontmatter carries a name and a description.
Where those files sit differs between the tools which produce them, so the
harness recognises the layouts which exist rather than demanding its own:

| layout | shape |
| --- | --- |
| skill pack | `<root>/skills/<name>/SKILL.md` |
| skill pack (bare) | `<root>/<name>/SKILL.md` |
| claude plugin | `.claude-plugin/plugin.json` + `skills/<name>/SKILL.md` |
| claude marketplace | `.claude-plugin/marketplace.json` + every plugin it names |
| dsh | `<root>/<name>.md` — one file is one skill |

A claude marketplace is a directory of plugins and each of them may carry its
own skills, so one pack can contribute many roots. Its manifest may also point
at plugins which live in another repository; only what is on disk is loaded, the
rest is somebody else's clone. A plugin whose `source` is `./` is the repository
itself — which is what `xmake-skills` is, a marketplace of one.

The deepseek harness (dsh) keeps a skill in a single markdown file, and reads a
project's `.dsh/skills` and `.agents/skills` as well; both are picked up. A lone
markdown file only counts as a skill when its frontmatter has **both** a name
and a description — that is what dsh requires, and it is what keeps a `README.md`
from becoming a skill.

The layout is reported when the pack is installed and in `/skills`:

```
the installed packs:
  xmake-skills     53 skills  claude marketplace `xmake-skills`  https://github.com/..
  my-notes          4 skills  dsh skills                         ~/.xmake/harness/skills/my-notes
```

An archive is unpacked instead of cloned, and a lone top level directory inside
it is lifted away — `mypack.zip` almost always contains `mypack/`, and keeping
that level would bury the skills one deeper than the layout says.

### When two skills want the same name

A pack which brings together the skills of many plugins will have two called
`configure` sooner or later — the official claude marketplace has three, from its
discord, imessage and telegram plugins. The first one keeps the name and the
others are not loaded.

"First" is decided by sorted path, not by whatever order the filesystem hands
back, so the winner is the same on every machine — a skill which appears on one
developer's setup and not another's is the worst kind of bug.

What lost is never dropped silently: `/skills` names each one and the file it
lost to, and the install message says how many there were.

```
4 skills could not be loaded, the name was already taken:
  access       claude-plugins-official/external_plugins/imessage/skills/access/SKILL.md
               kept: claude-plugins-official/external_plugins/discord/skills/access/SKILL.md
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
