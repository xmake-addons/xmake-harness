# 终端界面

[English](tui.md) | 中文

## 渲染模型

屏幕分成两部分：

- **transcript（历史区）** —— 打到 stdout 之后就不再改动，所以终端的滚动缓冲里
  保留着完整对话，鼠标选中复制也正常
- **live region（活动区）** —— 最后几行：流式输出的尾巴、状态行、输入框、
  补全弹窗、提示行，每次变化就擦掉重画

不进 alternate screen，也不整屏重绘，所以它既像一个应用，又是个规规矩矩的 cli 程序。

模型输出是**边流边渲染**的：每写完一行就按 markdown 渲染并永久打印，
未完成的那一行留在活动区。

markdown 渲染覆盖标题、列表（含任务列表）、引用块、分隔线、表格（对齐 + 框线），
以及围栏代码块（按语言语法高亮）。行内的粗体、斜体、删除线、行内代码和链接也会上色。

## 输入

终端被设置成非规范模式（`-icanon -echo -isig -ixon`），每次按键直接进入 harness，
同时保留输出后处理（不会出现逐行右移的错位）。

POSIX 上按键通过一个小的中继进程读取，因为 C 库的 stdin 会整块缓冲，
`select()` 看不到已经缓冲的字节 —— 那会吞掉转义序列和快速连打。
中继起不来时会自动回退到直接读 stdin，并自己把缓冲抽干。
`XMAKE_HARNESS_INPUT=stdio` 可强制回退，`/doctor` 会报告当前用的是哪种。

## 快捷键

| 按键 | 作用 |
| --- | --- |
| `enter` | 发送消息（或确认补全） |
| `alt+enter`、`ctrl+j`、行尾 `\` | 插入换行 |
| `shift+tab` | 循环切换权限模式 |
| `tab` | 补到候选的公共前缀，没得补了就在候选间循环 |
| `esc` | 中断当前工作 / 关闭弹窗 / 清空输入 |
| `ctrl+c` | 清空输入，连按两次退出 |
| `ctrl+d` | 输入为空时退出 |
| `ctrl+l` | 清屏 |
| `up`/`down` | 在输入内移动，到边界时翻输入历史 |
| `ctrl+a`/`ctrl+e` | 行首 / 行尾 |
| `ctrl+w`、`alt+backspace` | 删除光标前一个词 |
| `ctrl+u`/`ctrl+k` | 删到行首 / 行尾 |
| `ctrl+y` | 粘回删掉的内容 |
| `/` | slash 命令补全 |
| `@` | 文件补全，文件内容会附到消息里 |
| `!<command>` | 直接执行 shell 命令，并把输出并入对话 |

模型工作时打的字会排进输入框，等这一轮结束后接着发。

## 答案的出处

关于代码的回答总是落在代码的某个地方，所以会要求 agent 说清是哪儿：
`src/main.cpp:42`。多数终端会把它变成可点击的东西，这本身就有价值。

**不是装饰的那部分是校验。** 一个引用了自己从没读过的行的模型，比什么都不说的
更有说服力，而且一样是错的 —— 两者在屏幕上长得一模一样。但文件就在那儿，所以我们去看：

- 文件存在、行号在范围内 → 渲染成链接
- 文件不存在，或者文件根本没那么多行 → 渲染成错误色

**只改颜色，不加字符**：引用是在**折行之后**标记的，多一个字符就会让那一行宽出一列。

带端口的 url（`http://host:8080`）和版本号（`1.2:3`）读起来和「文件:行号」一模一样，
但都不是。文件行数会被记住直到文件发生变化，所以一段满是引用的长回答，每个文件只读一次。

## Slash 命令

| 命令 | 作用 |
| --- | --- |
| `/help` | 命令与快捷键 |
| `/clear` | 开新会话 |
| `/model [name]`、`/model small <name>` | 查看或切换模型 |
| `/provider [name]` | 查看或切换 provider |
| `/config [key] [value]` | 查看或设置用户配置（含 api key） |
| `/status` | provider、模型、会话、各项数量 |
| `/cost` | token 消耗与缓存命中率 |
| `/context [full\|auto]` | 上下文占用明细与优化模式 |
| `/compact [focus]` | 立即压缩成摘要 |
| `/xmake [参数]` | 就地跑 xmake，不消耗 token（xmake 插件提供）|
| `/loop <间隔> <任务>`、`/loop stop` | 按周期重复一个任务 |
| `/rewind [n]` | 把文件恢复到某次请求之前的样子 |
| `/jobs`、`/jobs kill <id>` | 后台任务 |
| `/permissions [mode]` | 查看或切换权限模式 |
| `/sandbox [on\|off\|backend]` | 查看或开关命令沙盒 |
| `/theme [name]` | 切换主题 |
| `/skills [install\|update\|remove]` | skill 包，见 [skills](skills.zh.md) |
| `/agents`、`/tools`、`/plugins` | 已加载了什么 |
| `/sessions [all\|remove <id>]`、`/resume [id]` | 会话历史，见 [上下文](context.zh.md) |
| `/export [path]` | 导出对话为 markdown |
| `/init` | 生成工程说明文件 |
| `/cwd [dir]` | 查看或切换工作目录 |
| `/doctor` | 环境自检 |

在 `~/.xmake/harness/commands/` 或 `<project>/.xmake-harness/commands/` 放一个
markdown 文件，就多一条命令，正文作为 prompt 发送，`$ARGUMENTS` 会被替换。

同一套命令在 TUI 外也能跑：

```bash
xmake ai --command="model deepseek-reasoner"
xmake ai --command="skills install xmake" -y
```

## 主题

所有颜色都是命名样式，视图里不写死转义序列：

```json
{"ui": {"theme": "default", "colors": {"code.keyword": "${bright magenta}", "diff.addline": "${on#22}"}}}
```

颜色标签就是 xmake 的那套：`${red}`、`${bright green}`、`${dim}`、`${#33}`（256 色）、
`${on#22}`（256 色背景）、`${on;30;60;30}`（真彩背景）、`${color.success}`（xmake 主题色）。

内置主题：`default`、`dark`、`light`、`plain`（完全无色）。

配色参考 claude code：关键字粉洋红、字符串绿色、函数与数字蓝色、类型黄色、
注释灰暗，diff 行用深绿/深红背景。调色板分 256 色和基础色两套，
按终端能力自动选。

## 权限确认框

需要确认的工具会在活动区弹出对话框，把「将要发生什么」放在框里：

```
  ╭─ Edit file ────────────────────────────────────────────────╮
  │ src/main.c                                                 │
  │    12   int main(void) {                                   │
  │    13 - printf("hello");                                   │
  │    13 + printf("hello world");                             │
  │                                                            │
  │ Do you want to make this edit to main.c?                   │
  │ ❯ 1. Yes                                                   │
  │   2. Yes, and accept all the file edits of this session    │
  │   3. No, and tell the model what to do differently (esc)   │
  ╰────────────────────────────────────────────────────────────╯
```

`up`/`down` + `enter`，或直接按数字，或 `y`/`n`。

措辞随工具而变：编辑类展示 diff，并提供「本次会话内全部接受」（等价于 `shift+tab`）；
命令类展示命令行，并提供「以后该程序都不再问」；网络类展示 url。

命令类的底部始终说明它将在哪里执行：

```
  │ the command runs directly on your machine (the sandbox is  │
  │ off, /sandbox on)                                          │
```

下载任何东西之前（比如安装 skill 包）也是同一个对话框。

## 周期任务

有些活儿不是一个问题，而是同一个问题按周期问：每半小时看一眼 ci，
每十分钟重跑一次构建直到它绿了。

```
/loop 30m 看看 ci 绿了没有，没绿的话告诉我是什么挂了
```

第一次迭代**立即**执行 —— 你刚下的指令，先干等半小时只会显得像坏了 ——
之后每一次都从上一次**结束**的时刻开始计时，所以一次跑得比间隔还慢的迭代
不会在自己后面越堆越多。

间隔支持 `s`、`m`、`h` 及其组合：`90s`、`30m`、`2h`、`1h30m`。
纯数字会被拒绝 —— `30` 到底是秒还是分，没有共识，猜错要么变成忙等要么干等很久；
最短间隔是 10s。

每次迭代都是同一个会话里的一轮正常对话，所以循环记得前几次发现了什么，
而且 prompt 缓存让重复的部分很便宜。

一个挂着的循环会在你没看着的时候花钱，所以它一直明说：状态栏上常驻
`loop every 30m · next in 12m · 3 runs` 并逐秒倒计时。
它在下面几种情况停下：你输入 `/loop stop`；迭代进行中你按 `esc` ——
那意味着「停」，不是「跳过这次」；以及连续三次迭代失败后它自己停。
单独输入 `/loop` 查看当前挂着什么。它只活在挂它的那个会话里，
不落盘，退出即消失。

### 循环什么时候算完成

周期任务通常没有终点：「每半小时看一眼 ci」本来就该一直跑到你喊停。
但有些有终点 —— 「一直构建到绿为止」—— 而**只有 agent 知道它到了**。

循环挂着期间，agent 多一个工具 `loop_stop(reason)`，它一调用，循环就结束：

```
● Loop(the build is green again)
  └ done
  the loop is done after 4 runs: the build is green again
```

**这个工具只在循环存在时才存在**。一个几乎永远用不上的工具，
每次请求都要付它的 schema，还诱惑模型去够它 —— 所以循环开始时装上，结束时摘掉。

以**卡住**结束的那一轮（反复同一组调用，或连续三轮全失败）会计入循环的失败次数：
半小时后重跑同一个提示，大概率卡在同一个地方。**步数用完不算** ——
那通常说明它正在推进。结束码的完整列表见 [agents](agents.zh.md)。

## 撤销它做过的修改

一个改了十二个文件、第十一个改错了的 agent，会让你除了 git 无路可退 ——
而**会话开始前就躺在工作区里的那些活儿，恰恰是 git 没有的**。

所以每次写入都会留下被覆盖的内容。`/rewind` 列出可以回到的点，
每个改动过文件的请求一个：

```
the files can be put back to how they were before:

  1. fix the linker error
     xmake.lua, main.cpp
  2. also rename the target
     xmake.lua

  /rewind <n> to go back · /rewind last for the most recent one
  it undoes the edits, not the commands the agent ran
```

`/rewind 1` 把那之后动过的每个文件恢复到当时的内容 ——
包括**删掉那些原本不存在的新文件**。执行前会先确认，因为那之后你手工改的东西也会被覆盖。

**它只撤销编辑，别的一概不管。** agent 跑过的命令、通过 shell 删掉的文件、
工程之外的任何改动 —— 都没有记录，`/rewind` 也不会假装能收拾。

回滚之后，对话里**仍然记着**那些已经不存在的编辑，模型会基于一棵对不上的树继续干活。
所以要么告诉它你做了什么，要么 `/clear` 重来。

副本存在会话**旁边**而不是里面 —— 一份携带完整文件内容的日志会按工程大小膨胀、
并且每次保存都要整份重读 —— 大到不值得复制的文件会被跳过并明确告知。
