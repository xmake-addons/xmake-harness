# 配置

[English](configuration.md) | 中文

## 分层

配置由五层合并而成，后面的覆盖前面的：

1. 内置默认值，`config/config.lua`
2. 用户配置，`~/.xmake/harness/config.json`
3. 工程配置，`<project>/.xmake-harness/config.json`
4. 环境变量，`XMAKE_HARNESS_*`
5. `xmake ai` 的命令行选项

只有用户层会被 harness 写入，所以 **api key 永远不会落到工程仓库里**。

```bash
xmake ai --config=providers.deepseek.apikey=sk-xxxxxx   # 设置并退出
xmake ai --showconfig                                   # 查看合并后的配置
xmake ai --command="config provider"                    # 读单个键
```

TUI 内：`/config`、`/config ui.theme light`、`/model`、`/provider`，
以及设 key：

```
/config providers.deepseek.apikey sk-xxxxxx
```

`/config` 永远不会完整打印 key，只显示前几位。

## 完整结构

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
    "context": {"mode": "auto", "threshold": 0.82, "prunethreshold": 0.55, "keeprecent": 6, "keepresults": 8},
    "tools": {"disabled": [], "timeout": 300000, "maxoutput": 60000},
    "skills": {"dirs": [], "enabled": [], "disabled": []},
    "agents": {"dirs": [], "disabled": []},
    "plugins": {"dirs": [], "disabled": [], "xmake": {"skillsdir": null, "docsdir": null}},
    "ui": {"theme": "default", "showreasoning": true, "showtokens": true, "spinner": "star", "colors": {}},
    "session": {"save": true},
    "hooks": {"pretooluse": [], "posttooluse": []}
}
```

## Provider

内置预设只带 endpoint 和默认模型，key 永远是你自己的：
deepseek、anthropic、openai、moonshot、dashscope(通义千问)、zhipu(GLM)、
siliconflow、openrouter、ollama。

```bash
xmake ai --list=providers
xmake ai --provider=anthropic --apikey=sk-ant-xxx
```

预设之外的 provider 只是一条配置，写上 `kind`（`openai` 或 `anthropic`，
或你自己放在 `harness/llm/providers/` 下的模块）即可。

每个 provider 可配：`baseurl`、`chaturl`、`apikey`、`apikeyenv`、`headers`、
`contextsize`、`models`、`timeout`（连接超时，秒）、`proxy`、`insecure`、
`retries`（默认 2，断流或 429/5xx 会重试）。

## 大小模型分级

每个 provider 声明两个模型：

- `main` —— 顶层 agent
- `small` —— 会话标题、上下文摘要、轻量子 agent

```bash
xmake ai --model=deepseek-reasoner --smallmodel=deepseek-chat
```

TUI 内：`/model <name>` 和 `/model small <name>`。

agent 定义里可以按档位取名（`model: small`），也可以直接写模型 id。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `XMAKE_HARNESS_HOME` | harness 主目录，默认 `~/.xmake/harness` |
| `XMAKE_HARNESS_PROVIDER` | provider 名 |
| `XMAKE_HARNESS_MODEL` | 主模型 |
| `XMAKE_HARNESS_SMALL_MODEL` | 小模型 |
| `XMAKE_HARNESS_APIKEY` | 当前 provider 的 key |
| `XMAKE_HARNESS_DEBUG` | `1` 或路径：记录每次大模型请求与响应 |
| `XMAKE_HARNESS_INPUT` | `stdio` 强制不使用输入中继 |
| `XMAKE_HARNESS_DEV` | `scripts/srcenv.profile` 用的源码目录 |
| `DEEPSEEK_API_KEY`、`ANTHROPIC_API_KEY` ... | 各 provider 的 key 兜底 |

## 权限模式

| 模式 | 含义 |
| --- | --- |
| `default` | 只读工具直接放行，改文件和执行命令要问 |
| `acceptedits` | 文件编辑自动接受 |
| `plan` | 只读，必须先给方案 |
| `bypass` | 全部放行，不再询问 |

TUI 内 `shift+tab` 在 `default`、`acceptedits`、`plan` 之间循环。

规则按工具名或调用签名匹配，支持 `*` 通配：

```json
{"permission": {"allow": ["read_file", "run_command(git *)"], "deny": ["run_command(rm *)"]}}
```
