# Configuration

English | [中文](configuration.zh.md)

## The layers

The configuration is merged from five layers, the later ones win:

1. the builtin defaults, `config/config.lua`
2. the user config, `~/.xmake/harness/config.json`
3. the project config, `<project>/.xmake-harness/config.json`
4. the environment variables, `XMAKE_HARNESS_*`
5. the command line options of `xmake ai`

Only the user layer is written by the harness, so **an api key never lands in a
project repository**.

```bash
xmake ai --config=providers.deepseek.apikey=sk-xxxxxx   # set and exit
xmake ai --showconfig                                   # show the resolved config
xmake ai --command="config provider"           # inside or outside the tui
```

Inside the tui: `/config`, `/config ui.theme light`, `/model`, `/provider`, and

```
/config providers.deepseek.apikey sk-xxxxxx
```

`/config` never prints a key in full, it shows the first characters only.

## The full shape

```json
{
    "provider": "deepseek",
    "model": null,
    "smallmodel": null,
    "stream": true,
    "maxtokens": 8192,
    "temperature": 0.0,
    "providers": {
        "deepseek": {"apikey": "sk-xxx"},
        "mycompany": {
            "kind": "openai",
            "baseurl": "https://llm.mycompany.com",
            "apikey": "sk-yyy",
            "contextsize": 131072,
            "models": {"main": "big-model", "small": "small-model"}
        }
    },
    "permission": {"mode": "default", "confirm": "dangerous",
                   "allow": ["run_command(git status*)"], "deny": [], "ask": [],
                   "dangerous": [], "protected": []},
    "sandbox": {"enabled": false, "backend": "auto", "network": false, "writabledirs": []},
    "context": {"mode": "auto", "threshold": 0.82, "hardthreshold": 0.92,
                "prunethreshold": 0.55, "keeprecent": 6, "keepresults": 8},
    "agent": {"maxsteps": 60, "maxrepeats": 3, "maxerrors": 3, "maxfruitless": 4, "maxparallel": 3},
    "tools": {"disabled": [], "timeout": 300000, "maxoutput": 60000, "maxconcurrency": 4},
    "skills": {"dirs": [], "enabled": [], "disabled": []},
    "agents": {"dirs": [], "disabled": []},
    "plugins": {"dirs": [], "disabled": [], "xmake": {"skillsdir": null, "docsdir": null}},
    "ui": {"theme": "default", "showreasoning": true, "showtokens": true, "spinner": "star", "colors": {}},
    "session": {"save": true},
    "code": {"comments": "English", "braces": "sameline"},
    "hooks": {"pretooluse": [], "posttooluse": []}
}
```

## Trusting a project

A project can carry instructions for the agent and code for the harness:
`AGENTS.md` goes into the system prompt, `.xmake-harness/skills` are loaded on
demand, `.xmake-harness/plugins` is lua which runs in this process, and
`.xmake-harness/config.json` can set the permission mode. All of it is useful,
and all of it belongs to whoever wrote the repository — so cloning something and
running `xmake ai` inside it would otherwise hand a stranger the system prompt.

The first time a directory which carries any of these is opened, the harness asks
once. A directory with none of them is never mentioned:

```
Trust the files in this directory?
  /home/u/src/someone-elses-repo

  it carries instructions, plugins, which this harness would read:
    AGENTS.md
    .xmake-harness/plugins

    1) yes, and remember this directory
    2) yes, just this once
    3) no
    4) no, and do not ask again here
```

The answer is kept in `~/.xmake/harness/trust.json`, per directory. `/trust`
shows it, `/trust yes` / `/trust no` change it without a restart, and
`/trust forget` asks again next time.

Where nobody can answer — a pipe, `--print`, the ci — the answer is no. Pass
`--trust` to say yes for one run, or `--no-trust` to be explicit about it.

## The code it writes

`code` is the house style, and it is only consulted when there is nothing to
match — the first file of a new project. Everywhere else the file being edited
decides, because a harness which reformatted your project to its own taste would
be worse than one with no opinion at all.

```json
{"code": {"comments": "English", "braces": "newline"}}
```

- `comments` — the language the comments are written in. It is deliberately not
  the language of the conversation: you read the answer, everybody reads the
  file. A project which comments in another language is still followed, judged
  from the files which were there before the conversation started.
- `braces` — `sameline` or `newline`, for the opening brace of a new file.

## The providers

The builtin presets only carry the endpoint and the default models, the key is always
yours: deepseek, anthropic, openai, moonshot, dashscope(qwen), zhipu, siliconflow,
openrouter, ollama.

There is one more which talks to nothing: `kind = "replay"` answers from a
recorded file instead of a server, and `providers.<name>.record = "<file>"`
writes one. It is how the turn loop is tested without a network,
@see [development](development.md).

### When a provider cannot answer

`fallback` names the providers to try instead — per provider, or once for all of
them:

```json
{"providers": {"deepseek": {"fallback": ["anthropic", "openai"]}}}
```

The retries inside one request already cover a cut stream or a moment of
throttling on the same service. `fallback` is for the service itself being
unreachable, out of quota, or holding a key which no longer works: the turn
moves to the next provider mid-conversation, the tier is resolved again against
it — `deepseek-chat` means nothing to anthropic — and the rest of the turn
belongs to whoever answered.

Only failures another provider could plausibly do better on are worth moving
for. A request the service rejected as malformed is our own mistake and would be
rejected identically everywhere, so it is reported rather than repeated. The
providers are named by you and never guessed: a key you configured for one
service is not permission to spend it on another.

```bash
xmake ai --list=providers
xmake ai --provider=anthropic --apikey=sk-ant-xxx
```

A provider which is not in the presets is just a config entry with a `kind`
(`openai` or `anthropic`, or your own module in `harness/llm/providers/`).

Per-provider knobs: `baseurl`, `chaturl`, `apikey`, `apikeyenv`, `headers`,
`contextsize`, `models`, `timeout` (the connect timeout in seconds), `proxy`,
`insecure`, `retries` (2 by default — a cut stream or a 429/5xx is retried).

## The model tiers

Every provider declares two models:

- `main` — the top level agent
- `small` — the session titles, the context summaries and the light subagents

```bash
xmake ai --model=deepseek-reasoner --smallmodel=deepseek-chat
```

In the tui: `/model <name>` and `/model small <name>`.

An agent definition may pick a tier by name (`model: small`) or an explicit model id.

## The environment variables

| variable | effect |
| --- | --- |
| `XMAKE_HARNESS_HOME` | the harness home, `~/.xmake/harness` by default |
| `XMAKE_HARNESS_PROVIDER` | the provider name |
| `XMAKE_HARNESS_MODEL` | the main model |
| `XMAKE_HARNESS_SMALL_MODEL` | the small model |
| `XMAKE_HARNESS_APIKEY` | the api key of the current provider |
| `XMAKE_HARNESS_DEBUG` | `1` or a path: log every llm request/response |
| `XMAKE_HARNESS_DEV` | the source checkout used by `scripts/srcenv.profile` |
| `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, ... | the per-provider key fallback |

## The permission modes

Editing the sources of your project and running the ordinary commands is the
everyday work of an agent: asking for every one of them is noise nobody reads.
So the harness allows what it can see and judge safe, and asks for what is hard
to undo, reaches outside the project, or that it cannot read at all.

| mode | files | commands |
| --- | --- | --- |
| `default` | free inside the project, asks for the protected ones | asks only when dangerous |
| `acceptedits` | always free | asks only when dangerous |
| `plan` | denied | denied |
| `bypass` | free | free |

**What counts as dangerous**: `sudo`, `rm -rf`, `dd`, `mkfs`, `shutdown`,
`chown`, `chmod -R`, `git push`, `git reset`, `git clean`, `git rebase`, the
package installs (`brew`, `apt`, `npm i -g`, `pip install`, ..), a download
piped into a shell, a write into `/etc` or anywhere outside the project, and any
tool whose command line the harness cannot read (an MCP tool, for instance).
A chain is judged by its most dangerous part, the substitutions inside it count
too, and the wrappers never hide anything: `LANG=C rm -rf /`, `timeout 5 rm -rf`
and `find . -exec rm {} +` are the deletions they really are.

**What counts as protected**: `.git/`, `.ssh/`, `.env*`, `*.pem`, `*.key`,
`id_rsa`, `.netrc`, `.npmrc`, `.pypirc`, anything named `credentials`, and the
harness configuration.

The dialog always says *why* it is asking:

```
 rm -rf build
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to run it?
 ❯ 1. Yes
   2. Yes, and do not ask again for `rm -rf`
   3. No, and tell the model what to do differently

 it deletes a directory tree without asking · runs on your machine (/sandbox on)
```

Tune it with `permission.confirm`:

| value | meaning |
| --- | --- |
| `dangerous` | the default described above |
| `edits` | also ask before every file change |
| `all` | ask before every change and every command |

And extend the two lists:

```json
{"permission": {
    "dangerous": ["make deploy*", "kubectl *"],
    "protected": ["config/*.yml", "deploy/**"]
}}
```

Shift+tab cycles between `default`, `acceptedits` and `plan` in the tui.

The rules are matched against the tool name or the call signature, with `*` wildcards:

```json
{"permission": {"allow": ["read_file", "run_command(git *)"], "deny": ["run_command(rm *)"]}}
```
