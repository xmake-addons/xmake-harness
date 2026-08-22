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
    "permission": {"mode": "default", "confirm": "dangerous",
                   "allow": ["run_command(git status*)"], "deny": [], "ask": [],
                   "dangerous": [], "protected": []},
    "sandbox": {"enabled": false, "backend": "auto", "network": false, "writabledirs": []},
    "context": {"mode": "auto", "threshold": 0.82, "hardthreshold": 0.92,
                "prunethreshold": 0.55, "keeprecent": 6, "keepresults": 8},
    "agent": {"maxsteps": 60, "maxrepeats": 3, "maxerrors": 3, "maxparallel": 3},
    "tools": {"disabled": [], "timeout": 300000, "maxoutput": 60000, "maxconcurrency": 4},
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

改自己工程里的代码、跑日常命令，本来就是 agent 的工作 —— 每一步都问一遍，
提示多到没人会看。所以 harness 的原则是：**看得清且判定安全的直接放行，
难以撤销的、伸出工程之外的、或者根本看不清的才问。**

| 模式 | 文件 | 命令 |
| --- | --- | --- |
| `default` | 工程内自由，受保护的才问 | 只有危险命令才问 |
| `acceptedits` | 全部自由 | 只有危险命令才问 |
| `plan` | 拒绝 | 拒绝 |
| `bypass` | 自由 | 自由 |

**什么算危险**：`sudo`、`rm -rf`、`dd`、`mkfs`、`shutdown`、`chown`、`chmod -R`、
`git push`、`git reset`、`git clean`、`git rebase`、各种包安装（`brew`、`apt`、
`npm i -g`、`pip install` ...）、把下载内容管道给 shell、写入 `/etc` 或工程之外的路径，
以及任何 harness 读不到命令行的工具（比如 MCP 工具）。
命令链按其中**最危险的一段**判定，`$(...)` 里的替换命令同样会被检查，
包装器也藏不住东西：`LANG=C rm -rf /`、`timeout 5 rm -rf`、`find . -exec rm {} +`
都会被识别成它们真正在做的事。

**什么算受保护**：`.git/`、`.ssh/`、`.env*`、`*.pem`、`*.key`、`id_rsa`、`.netrc`、
`.npmrc`、`.pypirc`、名字里带 `credentials` 的文件，以及 harness 自己的配置。

确认框一定会说明**为什么**要问：

```
 rm -rf build
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to run it?
 ❯ 1. Yes
   2. Yes, and do not ask again for `rm -rf`
   3. No, and tell the model what to do differently

 it deletes a directory tree without asking · runs on your machine (/sandbox on)
```

用 `permission.confirm` 调节严格程度：

| 值 | 含义 |
| --- | --- |
| `dangerous` | 默认，即上面描述的行为 |
| `edits` | 每次改文件也要确认 |
| `all` | 每次改文件和每条命令都要确认 |

两份名单也可以自己扩展：

```json
{"permission": {
    "dangerous": ["make deploy*", "kubectl *"],
    "protected": ["config/*.yml", "deploy/**"]
}}
```

TUI 内 `shift+tab` 在 `default`、`acceptedits`、`plan` 之间循环。

规则按工具名或调用签名匹配，支持 `*` 通配：

```json
{"permission": {"allow": ["read_file", "run_command(git *)"], "deny": ["run_command(rm *)"]}}
```
