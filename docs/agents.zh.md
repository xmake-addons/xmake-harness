# Agents

[English](agents.md) | 中文

子 agent 在自己的上下文窗口里运行，有独立的 system prompt、工具集和模型。
只有它的最终消息会回到调用方，所以它是做大范围搜索和长时间探索的正确方式 ——
中间过程不会污染主上下文。

```markdown
---
name: explorer
description: Search the codebase and report the findings. Use it when answering means sweeping many files.
tools: read_file, list_dir, glob_files, search_text, use_skill
model: small
maxsteps: 30
---

You are a codebase explorer. ..
```

| 字段 | 含义 |
| --- | --- |
| `name` | 模型在 `run_agent` 里引用的名字 |
| `description` | 什么时候该用它，会进入 system prompt |
| `tools` | 允许的工具，省略表示全部，`*` 也是全部 |
| `model` | 档位（`main`、`small`、`reasoner`）或具体模型 id |
| `maxsteps` | 步数上限，默认 60 |
| 正文 | 它的 system prompt，会替换默认身份 |

## 内置 agent

| agent | 用途 |
| --- | --- |
| `explorer` | 搜索代码库并汇报发现（小模型） |
| `planner` | 写代码前先出实现方案 |
| `reviewer` | 审查改动的正确性问题和可简化处 |
| `xmake-builder` | 修复 xmake 构建，反复 build → 读错误 → 修 → build（xmake 插件） |

## 发现路径

`<addon>/modules/harness/assets/agents`、`~/.xmake/harness/agents`、
`<project>/.xmake-harness/agents`、配置里的 `agents.dirs`，
以及插件注册的目录。

## 嵌套

子 agent 自己也可以再委派，最多 3 层。它的 token 消耗会在工具结果里报告，
并且和父级共享中断信号 —— 按 `esc` 会停掉整棵调用树。

## 图编排

一次 `run_agent` 只是一个任务。真实的活儿通常是有形状的：三路互不相干的探索，
然后一个需要这三份结果的方案，再然后是对方案的评审。手工驱动的话，每一层
都要一次主模型往返，而且每份中间报告都要从主上下文里过一遍。

`run_agents` 一次接收整个形状。每个节点是一个子 agent，`needs` 写明它必须先
拿到哪些节点的报告：

```json
{"nodes": [
  {"id": "parser",  "agent": "explorer", "prompt": "梳理 parser"},
  {"id": "codegen", "agent": "explorer", "prompt": "梳理 code generator"},
  {"id": "plan",    "agent": "planner",  "prompt": "设计新语法的实现方案",
   "needs": ["parser", "codegen"]}
]}
```

`parser` 和 `codegen` 同时跑；两个都完成后 `plan` 才启动，并拿到它们的报告 ——
每份都包在带名字的 `<report from="...">` 块里，这样它既能分辨来源，
报告里的内容也不会被当成调用方的指令。

只有**叶子节点**（没有人依赖它的那些）会把结果报告回调用方。其余节点的内容
早就交给需要它的节点了，再报一遍等于把整张图塞回我们本来要避开的上下文里。
但每个节点仍有一行状态，所以失败绝不会悄无声息。

图在跑之前先做校验：成环、依赖不存在、id 重复、自己依赖自己，
都会以模型能据此修正的消息返回，而不是留下一张执行了一半的图。
某个节点失败时，依赖它的节点会被跳过，而不是拿着空结果硬跑。
`agent.maxparallel`（默认 3）限制同时运行的节点数 —— 一个节点是一整个 agent
循环，所以这个数比工具调用的并发数要小。

只有一个任务，或者下一步做什么取决于刚读到的东西时，用 `run_agent`。

## 一轮卡住了怎么办

步数上限是最后一道防线，不是第一道。每一步还会跑两个更便宜的检查 ——
模型卡住的方式基本就两种：

- 反复发出**完全相同**的一组工具调用，指望同一个问题给出不同的答案 ——
  连续三轮相同就终止这一轮
- 试什么都失败，然后继续换着花样试同一个错误思路 ——
  连续三轮**每个**工具都失败就终止

只有工具名和参数都一致才算「相同」，所以 `改 → 编译 → 改 → 编译` 不是死循环：
这些轮次本来就不同；读另一个文件也是进展，哪怕用的是同一个工具。
部分失败同样算进展，只有整轮全挂才会累加计数。

触发时，终止的理由会同时告诉模型和用户，这样接着聊的时候模型知道什么事不该再做。
`agent.maxrepeats` 和 `agent.maxerrors` 可调，默认都是 3。

## 一轮为什么结束

每一种结束都带一个**码**，而不只是一句话。话给看屏幕的人，码给**决定下一步做什么**的东西。

| 码 | 含义 |
| --- | --- |
| `done` | 模型没再要任何东西，正常结束 |
| `step-budget` | 活儿没干完，步数先用光了 |
| `repeated-tool-calls` | 反复要同一样东西，被熔断拦下 |
| `all-tools-failed` | 试什么都失败，连续三轮 |
| `aborted` | 用户中断 |
| `error` | 请求本身失败 |

它在 turn 结果里是 `stop = {code, text}`，也写进会话日志对应的 notice 上 ——
周期任务、统计、测试都可以据此决策，不必去 match 散文。
`/loop` 是第一个消费者：步数用完它会继续，连续三轮卡住它就放弃 —— 这两件事完全不同。

## 并行调用

模型一步里可以要求调用多个工具。其中**只读**的那些 —— 搜索、列目录、读文件 ——
会在协程调度器上并发执行，一次最多 `tools.maxconcurrency`（默认 4）个；
写文件和执行命令的则单独按顺序跑。所以读五个文件只花一轮的时间，
而两个编辑永远不会互相踩踏。
