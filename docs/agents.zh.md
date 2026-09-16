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
| `xmake-porter` | 把 cmake/msbuild/meson/scons 工程转成 xmake —— 一个 bundle，自带技能和 `agent.lua` |
| `xmake-builder` | 修复 xmake 构建，反复 build → 读错误 → 修 → build（xmake 插件） |

## 发现路径

`<addon>/modules/harness/assets/agents`、`~/.xmake/harness/agents`、
`<project>/.xmake-harness/agents`、配置里的 `agents.dirs`，
以及插件注册的目录。

第一个同名的胜出，所以你自己的永远盖过包里的。

`/agents` 会列出它们，**还会列出两类以前完全看不见的东西**：看起来像 agent 但用不了的文件
（每条带原因），以及被别人顶掉了名字的。一个被静默跳过的文件仍然在磁盘上占着那个名字，
而界面上什么都没有 —— 没东西可修，也没东西可删。

## agent 也可以是一个目录

需要的不止是提示词时，就写成目录 —— 这样它可以自带它要读的技能和它要用的 lua：

```
xmake-porter/
    AGENT.md            提示词和 frontmatter
    agent.lua           可选，见下
    skills/
        xmake-import/SKILL.md
        xmake-import-cmake/SKILL.md
```

bundle 里的技能会跟着一起加载，来源标为 `agent:<名字>` —— **装这个 agent 就等于装了它读的东西**。
再加一个内置 agent，就是再加一个目录，别的都不用改。


## `agent.lua`

大多数 agent 应该老老实实是个 markdown：一段提示词、一个工具列表，没有会出错的地方。
但有些不行 —— 第一步永远是同一条命令的 agent，应该**带着答案出场**；工具列表取决于目录里
有什么的 agent，没法把它写进 frontmatter。

这种 agent 在 `AGENT.md` 旁边放一个 `agent.lua`，导出下面任意几个：

```lua
-- 改定义：工具、模型、步数上限
function define(context)
    return {tools = {"read_file", "xmake_build"}, maxsteps = 12}
end

-- 只管工具列表，参数是它本来会拿到的那一份
function tools(context, current)
    return table.join(current, os.isfile("xmake.lua") and {"xmake_build"} or {})
end

-- 追加到它的 system prompt
function prompt(context)
    return "This project uses xmake 3.x."
end

-- 追加到任务：它已经查清楚的东西
function before(context)
    progress.stage(context.progress, "reading the project")
    return "I read it for you: 3 targets, 2 of them libraries."
end

-- 报告过得去就返回 nil，过不去就说为什么
function validate(context, result)
    if not result.text:match("%d+ targets") then
        return "it does not say how many targets there are"
    end
end

-- 对最终报告补一句
function after(context, result)
    return string.format("that took %d steps.", result.steps)
end

-- 把 `before` 建起来的东西拆掉
function cleanup(context)
    os.tryrm(context.tmpdir)
end
```

它们就按这个顺序跑（`harness/agents/lifecycle.lua`）。那里是**一张阶段表**，
不是一串分支 —— 所以加一个钩子就是加一行。

`context` 带 `{harness, agent, prompt, description, cwd, progress, depth}`。
每个钩子都是可选的，每个都包在 `try` 里，**脚本报错会被上报然后忽略** ——
一个「改不动」的 agent，比一个「跑不起来」的 harness 好。`cleanup` 无论 agent 是
跑完、失败还是被中断都会执行，所以 `before` 里建的临时目录可以放心交给它。

`validate` 是唯一能把 agent 打回重做的钩子，而且**只打回一次** —— 第二份答案它还不
认，那就是 agent 在跟自己吵架，还是全价。打回的理由会进到任务里，所以它知道要改什么。
适合用在答案有形状、脚本认得出来的场合：必须能解析的 json、必须是数字的数字、
必须带出处的结论。模型判断不了自己有没有答上，而只要问题有个认得出的答案，脚本就能。

`xmake-porter` 就用了这个：探测构建系统、读取工程，每次答案都一样，
所以在第一次请求之前就做完，而不是花两步去问模型。


## 单独试一个

子 agent 通常是模型自己决定要不要用的，而这是验证「你刚写的那个到底行不行」
最糟糕的方式：你提一个但愿能让它去委派的需求，它委派给了另一个，你什么也没学到。
所以可以直接跑：

```bash
xmake ai agent list                                       # 这个工程能用哪些
xmake ai agent show hello-world                           # 它的工具、模型、钩子
xmake ai agent run hello-world 'greet this project'       # 直接跑，打印它的报告
```

**能写名字的地方就能写路径**，所以你正在写的那个**不装也能试** ——
否则这个循环里本该一条命令的地方要敲三条：

```bash
xmake ai agent run ./examples/agents/hello-world 'greet this project'
xmake ai agent show ./my-agent/AGENT.md
```

它会被登记进一个**临时的**注册表，所以这次运行不会改变下次能看到什么。

`show` 会说明它的 `agent.lua` **实际导出了哪些钩子** —— 刚写完脚本时你想知道的就是这个。
`run` 打印的是调用方本来会收到的东西：报告，仅此而已，背后那二十步仍待在它们该待的地方。

## hello-world 示例包

在 `examples/agents/hello-world`。它是**拿来读的**：七个钩子全在那个脚本里，
每个都只做一件明显属于该钩子职责的最小的事 —— 骨架一眼可见，不会被业务逻辑淹掉。

```bash
cd /某个工程
xmake ai agent run /path/to/xmake-harness/examples/agents/hello-world 'greet this project'
```

想在任何地方都能按名字叫它，就装一下：

```bash
xmake ai --command="agents install /path/to/xmake-harness/examples/agents/hello-world"
```

它会跟你指给它的工程打个招呼。`before` 先把源文件数好，让 agent **一出场就知道**；
`validate` 会打回一个从头到尾没提工程名字的招呼；`cleanup` 删掉 `before` 写的临时文件。
把这个目录复制走，删掉你不需要的，剩下的就是一个真 agent。

它**默认不安装**，这是故意的：每个 agent 的 description 都会进**每一轮**的
system prompt，一个演示用的 agent 会让所有人一直为它付 token，还可能被挑去干真活。

## 包

一个包就是一个从别处取来的 markdown 目录，跟技能包完全一样 —— 底层是同一套安装器
（`harness/packs/packs.lua`）：

```
/agents install github:someone/their-agents
/agents install https://github.com/someone/their-agents.git
/agents install ~/my-agents
/agents install ~/downloads/agents.zip
```

**认的布局是实际存在的那些**，所以别人的工程目录直接就能当包用：

| 布局 | agent 在哪 |
| --- | --- |
| `agents` | `<root>/agents/<name>.md` |
| `claude` | `<root>/.claude/agents/<name>.md` |
| `dsh` | `<root>/.agents/<name>.md` |
| `flat` | `<root>/<name>.md` |
| `claude-plugin` / `claude-market` | `.claude-plugin/` 以及它列出的插件 |

包装在 `~/.xmake/harness/agents/<包名>/`，harness 本身不打包任何一个。
插件可以在自己的 `apply()` 里注册一个，这样 `/agents install <名字>` 就认得这个名字。


## 进度

**任何跑很久的东西都往同一个通道上报**，所有前端读同一个（`harness/core/progress.lua`）：

```
● map the project · step 7 · reading src/main.c · 2m14s
```

耗时是**画这一行的时候**算的，不是最后一个事件到达时算的 —— 两个事件之间数字冻住不动，
读起来就是「harness 挂了」。`agent.lua` 里用
`progress.stage(context.progress, "…")` 往同一个通道报。

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
