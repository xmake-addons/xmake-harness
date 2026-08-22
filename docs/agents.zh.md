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
