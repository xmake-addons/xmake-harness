# 工具

[English](tools.md) | 中文

## 内置工具

| 工具 | 权限 | 作用 |
| --- | --- | --- |
| `read_file` | read | 带行号读文件，支持 `offset`/`limit` |
| `write_file` | write | 整文件写入，展示 diff |
| `edit_file` | write | 精确字符串替换，展示 diff |
| `list_dir` | read | 列目录 |
| `glob_files` | read | 按 glob 找文件，最近修改的在前 |
| `search_text` | read | 内容检索：`content` / `files` / `count` 三种模式，支持上下文行 |
| `run_command` | exec | 执行 shell 命令（带超时），或放到后台启动 |
| `job_output` | read | 读后台任务自上次以来的新输出 |
| `job_list` | read | 有哪些后台任务、各自什么状态 |
| `job_kill` | exec | 停掉一个后台任务 |
| `todo_write` | none | 维护任务清单 |
| `use_skill` | read | 按名加载 skill |
| `run_agent` | read | 委派任务给子 agent |
| `run_agents` | read | 一次委派一整张子 agent 图 |
| `fetch_url` | network | 抓网页并剥离 html |

`search_text` 优先用系统的 `ripgrep`，没有就用内部的 lua 遍历，两者结果一致 ——
所以大工程可以靠检索定位，而不必把文件整个读进上下文。

xmake 插件追加 `xmake_create`、`xmake_config`、`xmake_build`、`xmake_run`、
`xmake_test`、`xmake_show`、`xmake_lua`、`xrepo`、`xmake_docs`，以及三个转换工具
`xmake_import`、`xmake_import_write`、`xmake_import_verify`（见
[xmake 增强](xmake.zh.md)）；cmake 插件追加
`cmake_configure`、`cmake_build`、`ctest`；MCP server 带来的工具见
[MCP](mcp.zh.md)。

## 后台任务

阻塞的工具调用会占住整整一轮：别的什么都跑不了，模型干等，你看着转圈。
对一条一秒钟的命令这没问题，但对构建系统干的大多数事都是错的 ——
二十分钟的链接、`xmake watch`、一个本来就该一直开着的服务。

所以命令可以**启动**而不是执行：

```
run_command(command: "xmake build -r", background: true)   -> background job 1
job_output(job_id: "1")    自上次查看以来它打印了什么
job_list()                 有哪些任务、各自什么状态
job_kill(job_id: "1")      停掉一个
```

`job_output` 只返回**增量** —— 上次读之后新到的部分 ——
所以跟进一个长构建是一页一页地花 token，而不是每次把整个日志重来一遍。
它从不等待：还在跑的任务就返回目前有的内容，每次结果末尾都带
`[status: running for 2m03s]` 或 `[status: exited 0 after 5s]`。
一次读超量时保留的是**末尾**（错误在那儿），并说明丢了多少。

任务在模型忙别的事时结束的话，会在下一步开头自己报到：

```
[harness] background job 1 finished: exited 0 after 5s
```

这条通知既进对话也上屏幕，模型才知道该去收结果 ——
没人被告知的结果等于没有结果。

你这边也看得见：状态栏会显示 `2 jobs running`，`/jobs` 列出全部，
`/jobs kill <id>` 停掉一个。任务属于当前会话，会话结束时全部杀掉，
所以绝不会给你留下一个你没启动、也看不见的后台进程。

前台命令的 `timeout` 对后台任务不生效 —— watch 本来就该一直跑到有人停它。

## 执行管线

每次调用都走 `tools/pipeline.lua` 的同一条路径：

```
解析参数
  -> tools/pre-execute      （waterfall，可改写参数或设 request.denied 拒绝）
  -> pretooluse 钩子        （钩子以退出码 2 阻断调用）
  -> 权限策略               （放行 / 询问用户 / 拒绝）
  -> 沙盒包装               （对会起进程的工具）
  -> 执行
  -> 截断输出               （tools.maxoutput）
  -> tools/post-execute     （waterfall）
  -> posttooluse 钩子
```

被拒绝不是错误：拒绝的理由会作为工具结果返回给模型，让它换个做法，
而不是盲目重试。

工具打印的一切在进入模型和屏幕之前都会被清洗：转义序列、控制字符、
零宽字符、双向覆写符全部剥掉。这些输出多半不是我们自己的 —— 编译器信息、
刚读的文件、别人写的命令 —— 否则就是一条夹带指令的通道，
或者让屏幕显示的内容和模型看到的不一致。

## 并行执行

模型常常一次要好几样东西。所有**不会改变世界**的调用都在 xmake 协程里并发执行：
只读工具、子 agent（定义里 `concurrent = true`），以及权限策略已经放行的调用。
结果仍按原顺序回报，会话日志保持确定性。

默认判断不合适时，工具可以自己声明：

```lua
{name = "my_tool", permission = "read", concurrent = false, ..}
```

只读工具（`read`/`none` 权限且无需确认）由 `tools/runner.lua` 放进
xmake 协程组并发执行 —— 模型常常一次要好几个文件，串行等待纯属浪费。
结果仍按原顺序写回日志，保证确定性。

## 新增一个工具

```lua
harness:service("tools"):add({
    name = "mybuild_build",
    group = "mybuild",
    permission = "exec",              -- none | read | write | exec | network
    description = [[Build the project ..]],
    parameters = {                    -- 发给模型的 json schema
        type = "object",
        properties = {target = {type = "string", description = ".."}},
        required = {}
    },
    commandline = function (args)     -- 可选：它真正执行的命令行
        return "mybuild build " .. (args.target or "")
    end,
    preview = function (context, args) -- 可选：确认框里展示什么
        return {kind = "diff", filepath = "..", diff = ..}
    end,
    run = function (context, args)
        local exec = import("harness.shell.exec", {anonymous = true})
        local result = exec.run(context, {program = "mybuild", argv = {"build"}})
        return {
            output = result.output,               -- 模型看到的
            iserror = result.exitcode ~= 0,
            display = {                           -- TUI 展示的
                title = "mybuild build",
                summary = "ok",
                kind = "output",                  -- output | diff | todos
                output = result.output
            }
        }
    end
})
```

`display.kind` 决定 TUI 怎么渲染：`output` 打印前几行，`diff` 渲染彩色 diff
（`display.diff` 来自 `harness.ui.diff`），`todos` 渲染任务清单。

`commandline(args)` 很重要：确认框和结果卡片都用它显示**真实命令**，
而不是内部工具名。

`run` 里抛错是可以的：错误信息会成为工具结果，模型能看到。参数问题就这么处理
（`raise("%s does not exist", path)`）。

内置工具是 `harness/tools/builtin/<name>.lua`，导出 `define()` 和
`run(context, args)`，注册表自动发现。插件的工具同理，放在插件目录的
`tools/` 下。

## 工具必须遵守的约定

- 路径经 `harness.fs.fs` 解析，绝不写出工作区（`fs.checkwritable`）
- 起进程走 `harness.shell.exec`，不要直接 spawn —— 沙盒、超时、中断都在那里
- 输出对模型要有用：截断时必须说明截掉了什么
