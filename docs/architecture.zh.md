# 架构

[English](architecture.md) | 中文

动 `src/modules/harness` 之前先读这篇。

## 分层

```
  xmake ai                          唯一的 cli 入口（src/plugins/ai）
 ─────────────────────────────────────────────────────────────────
  ui/app                            终端应用
  cli/headless                      非交互运行器
 ─────────────────────────────────────────────────────────────────
  core/agent                        turn/step 循环
  core/graph                        agent 图，子 agent 的有向无环图
  core/subagent                     单次委派：深度、中断信号、ui 嵌套
  core/progress                     正在做什么，一条通道
  core/reload                       重新读取配置、技能、子 agent、命令
  core/session                      追加式事件日志，按工程存储
  prompt/system                     system prompt 组装
  tools/pipeline                    受控的工具执行
  context/window                    投影及其优化
  context/compact                   上下文压缩
 ─────────────────────────────────────────────────────────────────
  core/context                      服务容器与事件总线
 ─────────────────────────────────────────────────────────────────
  packs/packs                       安装一个 markdown 包，不分种类
  llm/*  fs/*  shell/*  sandbox/*  permission/*  hooks/*   能力缝
  util/parallel                     一切并发扇出的唯一出口
```

`core/context` 之上的一切都由 `harness.harness.bootstrap()` 在启动时组装，
所有与具体构建系统相关的东西都是插件。

## context（上下文对象）

`core/context` 是一次 harness 实例的共享运行时，只有两样东西：

**services（服务）** —— 各类注册表，按名字取用：

| 服务 | 内容 |
| --- | --- |
| `tools` | 工具注册表，`tools/registry.lua` |
| `skills` | skill 注册表，`skills/registry.lua` |
| `agents` | 子 agent 定义，`agents/registry.lua` |
| `jobs` | 后台任务，见 [工具](tools.zh.md) |
| `commands` | slash 命令，`commands/registry.lua` |
| `skillsources` | 插件注册的可安装 skill 包 |
| `agentsources` | 可安装的子 agent 包，同样的形状 |
| `plugins` | 已加载的插件描述 |
| `notices` | 启动提示，显示在欢迎面板下方 |
| `todos` | 当前任务清单 |

```lua
harness:service("tools"):add(definition)
local skills = harness:service("skills"):all()
```

**events（事件）** —— 扩展点，三种形态：

```lua
harness:emit(name, ...)             -- 通知所有人，忽略返回值
harness:bail(name, ...)             -- 在第一个非 nil 返回处停下
harness:waterfall(name, value, ..)  -- 每个监听者都可以改写这个值
```

| 事件 | 形态 | 用途 |
| --- | --- | --- |
| `harness/ready` | emit | 启动完成 |
| `prompt/sections` | waterfall | 增删改 system prompt 的段落 |
| `prompt/environment` | waterfall | 追加环境事实 |
| `agent/request` | waterfall | 发送前改写大模型请求 |
| `tools/pre-execute` | waterfall | 改写参数，或拒绝这次调用 |
| `tools/post-execute` | waterfall | 改写工具结果 |
| `turn/start`、`turn/end` | emit | 一轮的边界 |
| `todos/changed` | emit | 任务清单变化 |
| `skill/loaded` | emit | 模型加载了某个 skill |

## 一轮对话

一次 `agent.run()` 是一轮（turn），一轮包含一到多步（step）：

```
turn/start
  step
    core/guards               卡在原地打转或全部失败时终止这一轮
    context/window.optimize   裁剪投影，并强制不超过硬上限
    context/compact           窗口快满时把历史总结成摘要
    prompt/system.build       各段落 + 工具 schema
    agent/request             （waterfall）
    llm.complete              流式请求
    assistant 事件写入会话日志
    对每个工具调用：
        tools/pre-execute -> hooks -> 权限 -> 沙盒 -> 执行
        tools/post-execute
        tool 事件写入会话日志
  step（只要模型还在调工具就继续）
turn/end
```

UI 从不直接和模型打交道：它把一张 handler 表（`on_text`、`on_tool_start`、
`on_tool_result`、`confirm`、`ontick` ...）传进循环，
所以同一个循环同时驱动 TUI、非交互运行器和子 agent。

## 会话日志

会话是唯一的事实来源，每一条事实都是一个事件：

```
user       {text}
assistant  {text, reasoning, toolcalls, model}
tool       {id, name, arguments, output, iserror, duration, display}
notice     {text, level}      -- 仅本地，不发给模型
compact    {summary}          -- 压缩边界
```

`session:messages()` 从日志投影出模型历史（从最后一个 `compact` 开始），
`context/window.optimize()` 在不动日志的前提下把这份投影缩小。
终端回显、恢复、导出、token 统计都源自同一份日志，因此不可能互相对不上。

会话按工程目录存储（`~/.xmake/harness/projects/<slug>/<id>.json`），
详见[会话与上下文](context.zh.md)。

## 能力缝（seam）

一条缝 = 一个稳定接口 + 可替换实现：

| 缝 | 接口 | 实现 |
| --- | --- | --- |
| `llm/llm` | `buildrequest`/`parsechunk`/`parseresponse` | `providers/openai`、`providers/anthropic`，或你自己的 |
| `llm/transport` | `post(opt, handlers)` | curl 子进程流式传输 |
| `fs/fs` | 路径解析/读写/遍历 + 工作区边界 | 本地文件系统 |
| `shell/exec` | `run(context, opt)` | 本地子进程，带超时与中断 |
| `sandbox/sandbox` | `wrap(context, program, argv)` | `none`、`seatbelt`(macOS)、`bwrap`(Linux) |
| `permission/policy` | `check(config, tool, args, opt)` | 四种模式 + allow/deny 规则 |
| `hooks/hooks` | `run(config, event, context)` | 用户命令钩子 |
| `ui/terminal` | 原始模式、按键解码 | 管道中继 + stdio 回退 |
| `packs/packs` | 按种类 `resolve`/`install`/`fetch`/`remove` | skills、子 agent |
| `agents/script` | `define`/`prompt`/`before`/`after` | agent 自带的 `agent.lua` |
| `core/progress` | `stage`/`step`/`describe` | 终端状态行、web 状态 |

换掉一个实现就能改变整个产品：把 `shell/exec` 和 `fs/fs` 指向容器，
所有工具就都跟着进容器了。

最后三条是另一种缝：不是「一种能力多种实现」，而是**一套机制多个使用者**。
`packs/packs` 负责安装一个 markdown 包，而「种类」就是一张小表，说明这是**什么**的包 ——
skills 和子 agent 就是同一套机制做了两遍，加第三种是加这张表，不是复制一份。
`core/progress` 是「此刻在做什么」的唯一通道，所有前端读同一个，而不是各写各的。

## 为什么零三方依赖

整个 harness 跑在 xmake 的 lua 沙盒里，那里没有 `pcall`、没有 `setmetatable`、
也没有带 TLS 的 socket。代码里能看到的这些取舍都是刻意的：

- 类用 `core.base.object`，不用 metatable
- 错误处理用 `try{}`，不用 `pcall`
- 大模型传输把 `curl` 当子进程驱动，通过管道读它的 stdout
- POSIX 上终端输入经由一个管道中继读取，因为 stdio 缓冲会让 `select()` 看不到已缓冲的字节
- token 计数是启发式估算，不是 BPE 分词器
- 语法高亮和 markdown 渲染都是手写的小 tokenizer，且都按行工作，
  所以流式输出可以边到边渲染

## 并发扇出

所有「同时跑好几件事」的地方 —— 一步里的多个工具调用、一张 agent 图里的多个
节点 —— 都走 `util/parallel`，跑在 xmake 的协程调度器上。它只要三样东西：
一组 job、并发上限、中断信号。

它开的协程组以**开组的那个协程**命名，绝不用常量。子 agent 在父级等待期间会跑
自己的工具，所以这段代码会自己套自己两三层；用同一个组名的话，内层的
`co_group_begin` 会失败并返回 *already exists* —— 沙箱会把它变成 raise，
于是只要两个子 agent 同时去调工具，整轮就直接挂了。
而一个协程在等自己的组时是阻塞的，也就不可能同时开两个组，
所以拿它的身份当组名就足够唯一。
