# 快速开始

[English](getting-started.md) | 中文

## 安装

```bash
xmake addon --install xmake-harness
```

或者直接从源码跑，不用安装：

```bash
git clone https://github.com/xmake-io/xmake-harness.git
cd xmake-harness
source scripts/srcenv.profile
```

依赖：xmake >= 3.0.9、`curl`，需要 skill 包的话还要 `git`。

## 配置模型

```bash
xmake ai --setup
```

向导会询问 provider 和它的 api key，写入 `~/.xmake/harness/config.json`，
绝不会写进你的工程目录。

非交互方式：

```bash
xmake ai --config=providers.deepseek.apikey=sk-xxxxxx
xmake ai --provider=deepseek --model=deepseek-chat
```

检查一下：

```bash
xmake ai --doctor
```

## 第一次会话

```bash
cd /path/to/your/project
xmake ai
```

```
 ╭─────────────────────────────────────────────────────────────╮
 │                          _                                  │
 │     __  ___ __  __  __ _| | ______                          │
 │     \ \/ / |  \/  |/ _  | |/ / __ \                         │
 │      >  <  | \__/ | /_| |   <  ___/                         │
 │     /_/\_\_|_|  |_|\__ \|_|\_\____|                         │
 │                          by ruki, xmake.io                  │
 │                                                             │
 │ xmake ai  ·  the ai coding agent of xmake                   │
 │                                                             │
 │ model:   deepseek-chat  (deepseek · small: deepseek-chat)   │
 │ cwd:     /path/to/your/project                              │
 │ loaded:  54 skills · 19 tools · xmake project               │
 │ session: 6a8712ae-1b33-7aa6 (new)                           │
 ╰─────────────────────────────────────────────────────────────╯
   /help for the commands · @ to attach a file · ! to run a shell command
   esc interrupts · shift+tab cycles the permission mode
```

直接输入问题回车即可。它会自己读需要的文件，
但改动任何东西、执行任何命令之前都会先问你。

## 常用命令

```bash
xmake ai "给 parser 加个单元测试"      # 带问题启动
xmake ai -c                            # 继续当前目录的上一次会话
xmake ai -r                            # 从当前工程的会话里挑一个恢复
xmake ai -r <id>                       # 恢复指定会话
xmake ai --print "这个工程构建什么？"    # 非交互，适合脚本
xmake ai --mode=plan                   # 只读，先出方案
xmake ai --sandbox                     # 沙盒里执行命令
xmake ai --command=doctor              # 执行一条 slash 命令后退出
```

## 安装 skills

skill 包不内置：它们各自独立维护，只在你要求时拉取，所以拿到的永远是最新版。

```
/skills                      已加载 / 可安装的列表
/skills install xmake        xmake 构建相关的 skills
/skills update               更新所有已安装的
```

下载前一定会先问你。

## 文件都在哪

| 路径 | 内容 |
| --- | --- |
| `~/.xmake/harness/config.json` | 你的配置和 api key |
| `~/.xmake/harness/skills/` | 已安装的 skill 包 |
| `~/.xmake/harness/projects/<工程>/` | 该工程的会话历史 |
| `~/.xmake/harness/agents`、`commands`、`plugins` | 你自己的扩展 |
| `<project>/.xmake-harness/` | 同上，但只作用于这个工程 |
| `<project>/XMAKE.md` | 工程说明，每次会话都会读 |
