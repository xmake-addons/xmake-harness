<div align="center">
  <a href="https://xmake.io">
    <img width="160" height="160" src="https://xmake.io/assets/img/logo.png">
  </a>

  <h1>xmake-harness</h1>

  <div>
    <a href="https://github.com/xmake-io/xmake-harness/blob/main/LICENSE.md">
      <img src="https://img.shields.io/github/license/xmake-io/xmake-harness.svg?colorB=f48041&style=flat-square" alt="license" />
    </a>
    <a href="https://xmake.io/about/sponsor.html">
      <img src="https://img.shields.io/badge/donate-us-orange.svg?style=flat-square" alt="Donate" />
    </a>
  </div>

  <b>纯 xmake lua 实现的通用 AI Agent Harness 框架</b><br/>
  <i>`xmake ai` 提供 claude code 风格的终端 agent，并对 xmake 构建开发做深度增强</i><br/>
</div>

## 简介 ([English](/README.md))

`xmake-harness` 包含两部分：

1. **一套通用的 agent harness 框架**，完全用 xmake lua 编写，零三方依赖：会话日志、agent 循环、
   工具管线、权限策略、沙盒、skills、子 agent、slash 命令，以及终端 UI。
2. **一个 xmake addon**，把框架暴露成 `xmake ai` —— 一个交互体验对齐 claude code 的终端编程助手。

框架本身完全不感知 xmake。所有和构建系统相关的东西 —— `xmake_*` 工具、
[xmake skills](https://github.com/xmake-io/xmake-skills)、文档检索、`xmake-builder` 子 agent
—— 都放在插件里。所以同一套 harness 也可以服务 cmake 项目（仓库里带了一个 cmake 插件做示例）、
普通仓库，或者你自己的工具链。

```
$ xmake ai
 ✻ xmake ai  ·  deepseek · deepseek-chat
   my-project

   /help 查看命令 · @ 引用文件 · esc 中断

› windows 上链接为什么失败？

● Update(src/xmake.lua)
  └ Added 1 line, removed 1 line
    12   add_files("src/*.c")
    13 - add_links("ws2_32")
    13 + add_syslinks("ws2_32")

● 链接失败是因为 `add_links` 只在项目的链接目录里找库。`ws2_32` 是系统库，
  必须用 `add_syslinks` 添加。

  8.4k tokens (↑ 8.2k · ↓ 210 · cache 82%) · 6.1s · 2 steps
────────────────────────────────────────────────────────────────────
› ▏
────────────────────────────────────────────────────────────────────
  ⏵ default mode (shift+tab to cycle) · / for commands · @ for files
```

## 特性

| | |
| --- | --- |
| **终端 UI** | 流式 markdown、彩色 diff、工具卡片、权限确认框、`/` 命令补全、`@` 文件补全、输入历史，中日韩宽字符正确排版 |
| **多模型** | deepseek、anthropic、openai、moonshot(kimi)、通义千问、智谱 GLM、硅基流动、openrouter、ollama，或你自己的接口。API key 存在用户侧，不进项目 |
| **大小模型分级** | main 模型负责主任务，small 模型负责标题、摘要压缩和轻量子 agent |
| **工具** | 文件读写编辑、glob、内容检索、shell、任务清单、子 agent、skill 加载、网页抓取，以及插件注册的工具 |
| **后台任务** | 长构建、watch、常驻服务在对话旁边跑：agent 启动它、继续干活、随时收取新输出 |
| **Skills** | 按需加载，几十个 skill 也几乎不占上下文。识别现有的各种布局：claude 的 `SKILL.md` 目录、claude plugin 与 marketplace、dsh 的单文件 skill，以及 `.zip` 包 |
| **子 Agent** | markdown 定义，独立的 prompt / 工具集 / 模型 / 上下文窗口 |
| **Agent 图编排** | 一次提交整个计划：互不相干的探索并发跑，需要它们结果的节点等齐再启动，只有叶子节点回报主上下文 |
| **权限** | `default` / `acceptedits` / `plan` / `bypass` 四种模式 + allow/deny 规则，shift+tab 循环切换 |
| **沙盒** | macOS seatbelt、Linux bubblewrap 限制命令执行 |
| **上下文管理** | 接近窗口上限时自动压缩成摘要，`/context`、`/cost` 随时查看 |
| **会话** | 追加式事件日志落盘，可恢复、可回放、可导出 |
| **周期任务** | `/loop 30m <任务>` 在会话内按周期重复执行，状态栏常驻显示距下次触发还有多久 |
| **插件化** | context 之上一切皆插件：工具、skills、agents、命令、prompt 段落、大模型 provider |

## 安装

```bash
xmake addon --install xmake-harness
xmake ai --setup
```

或者直接从源码运行，不需要安装：

```bash
git clone https://github.com/xmake-io/xmake-harness.git
cd xmake-harness
source scripts/srcenv.profile
xmake ai
```

setup 向导会询问 provider 和 API key，保存到 `~/.xmake/harness/config.json`。
也可以直接命令行配置：

```bash
xmake ai --config=providers.deepseek.apikey=sk-xxxxxx
xmake ai --provider=deepseek --model=deepseek-chat
```

## 使用

```bash
xmake ai                             # 交互式 tui
xmake ai "给 foo 加个单元测试"        # 带初始问题启动
xmake ai --print "这个项目构建什么？"  # 非交互模式，适合脚本和 CI
xmake ai -c                          # 继续当前目录的上一次会话
xmake ai --mode=plan                 # 只读，先出方案
xmake ai --sandbox                   # 沙盒里执行命令

xmake ai --doctor                    # 环境自检
xmake ai --list=skills               # 查看加载了哪些 skill
xmake ai --command=xmake-skills      # 安装/更新 xmake skills
```

其余能力全部是 slash 命令：`/help`、`/model`、`/provider`、
`/config`、`/context`、`/compact`、`/cost`、`/permissions`、`/skills`、`/agents`、`/tools`、
`/sessions`、`/resume`、`/export`、`/init`、`/clear`、`/doctor`。同一套命令也能在 TUI 外执行：

```bash
xmake ai --command="model deepseek-reasoner"
xmake ai --command=xmake-skills
```

## 文档

- [架构](docs/architecture.md) —— 分层、能力缝（seam）与事件流
- [配置](docs/configuration.md) —— 配置分层、provider、模型分级
- [终端 UI](docs/tui.md) —— 渲染模型、快捷键、slash 命令
- [工具](docs/tools.md) —— 内置工具与如何新增
- [Skills](docs/skills.md) —— `SKILL.md` 格式与发现路径
- [Agents](docs/agents.md) —— 子 agent 定义
- [插件](docs/plugins.md) —— 插件 API，含 xmake / cmake 两个示例
- [xmake 增强](docs/xmake.md) —— xmake 插件具体提供了什么
- [开发](docs/development.md) —— 源码调试、测试、调试日志

## 依赖

- xmake >= 3.0.9（提供本仓库依赖的 addon 机制）
- `curl`（大模型请求传输）
- `git`（可选，仅用于同步 skill 仓库）

## 许可证

[Apache-2.0](LICENSE.md)
