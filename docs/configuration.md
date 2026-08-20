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
    "permission": {"mode": "default", "allow": ["run_command(git status*)"], "deny": [], "ask": []},
    "sandbox": {"enabled": false, "backend": "auto", "network": false, "writabledirs": []},
    "context": {"autocompact": true, "threshold": 0.82, "keeprecent": 6, "maxfilesize": 262144},
    "tools": {"disabled": [], "timeout": 300000, "maxoutput": 60000},
    "skills": {"dirs": [], "enabled": [], "disabled": []},
    "agents": {"dirs": [], "disabled": []},
    "plugins": {"dirs": [], "disabled": [], "xmake": {"skillsdir": null, "docsdir": null}},
    "ui": {"theme": "default", "showreasoning": true, "showtokens": true, "spinner": "star", "colors": {}},
    "session": {"save": true},
    "hooks": {"pretooluse": [], "posttooluse": []}
}
```

## The providers

The builtin presets only carry the endpoint and the default models, the key is always
yours: deepseek, anthropic, openai, moonshot, dashscope(qwen), zhipu, siliconflow,
openrouter, ollama.

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

| mode | what it allows |
| --- | --- |
| `default` | the read-only tools run freely, the edits and the commands are asked |
| `acceptedits` | the file edits are accepted automatically |
| `plan` | read-only, the agent must present a plan first |
| `bypass` | everything runs without asking |

Shift+tab cycles between `default`, `acceptedits` and `plan` in the tui.

The rules are matched against the tool name or the call signature, with `*` wildcards:

```json
{"permission": {"allow": ["read_file", "run_command(git *)"], "deny": ["run_command(rm *)"]}}
```
