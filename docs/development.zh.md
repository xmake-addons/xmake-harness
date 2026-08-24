# 开发

[English](development.md) | 中文

## 从源码运行

```bash
git clone https://github.com/xmake-io/xmake-harness.git
cd xmake-harness
source scripts/srcenv.profile     # 软链到 ~/.xmake，不需要安装
xmake ai
```

profile 建两个软链，改完源码立刻生效：

```
~/.xmake/plugins/ai       -> src/plugins/ai
~/.xmake/modules/harness  -> src/modules/harness
```

`source scripts/srcenv.profile --unlink` 移除。

## 目录结构

```
addon.lua                     addon 清单
src/plugins/ai                `xmake ai` 任务
src/modules/harness           框架本体
  cli/                        入口：tui、非交互、配置、报告、命令 shim
  core/                       context、session、agent 循环
  llm/                        传输层与 provider
  tools/                      注册表、管线、runner、内置工具
  mcp/                        jsonrpc、client、注册
  skills/ agents/ commands/   markdown 资产的注册表
  prompt/ context/            system prompt、投影优化与压缩
  permission/ sandbox/ hooks/ 策略缝
  fs/ shell/                  文件系统与进程缝
  ui/                         终端、主题、编辑器、渲染器、应用
  assets/                     内置 agent、命令、skill
  plugins/                    内置插件：xmake、cmake
tests/                        单元测试
docs/                         文档
```

## 测试

```bash
xmake l tests/run.lua                # 全部
xmake l tests/run.lua text           # 单个文件
xmake l tests/run.lua replay loop    # 多个
```

大部分测试覆盖纯逻辑：文本排版、diff、frontmatter、正则翻译、配置合并、
会话投影、权限规则。

其余的会驱动**完整的一轮对话** —— step 循环、工具管线、熔断、流式渲染 ——
对着一份**录好的模型**而不是真模型跑。所有测试都不碰网络。

MCP 测试用 `tests/mcpserver.lua` —— 一个 93 行的 xmake lua 实现的 MCP server。

### 录制一个模型

`replay` adapter 从文件里应答。**上层能被测试全靠它** ——
在这之前，驱动一轮对话意味着付一次真实请求的钱，并接受它那一次碰巧决定做的事。

录一次真实会话：

```bash
xmake ai --config=providers.deepseek.record=/tmp/cassette.json
xmake ai "read xmake.lua and say what it builds"
xmake ai --config=providers.deepseek.record=      # 停止录制
```

回放它，不需要 key、不需要网络：

```json
{"provider": "replay",
 "providers": {"replay": {"kind": "replay", "cassette": "/tmp/cassette.json",
                          "models": {"main": "recorded", "small": "recorded"}}}}
```

cassette 就是一串轮次，**手写往往比录制更清楚** ——
测试要让模型做真实模型很少做的事（比如一模一样的请求连发十二次），只能靠手写：

```json
{"turns": [
  {"content": "let me look",
   "toolcalls": [{"name": "read_file", "arguments": "{\"path\": \"xmake.lua\"}"}]},
  {"content": "it builds one target."}
]}
```

`tests/replay.lua` 是完整范例：工具调用、多轮、步数上限、每一种熔断都在里面。

## 调试

```bash
XMAKE_HARNESS_DEBUG=1 xmake ai --print "hi"     # 记录每次请求/响应
tail -f ~/.xmake/harness/debug.log
```

`xmake ai --doctor`（或 TUI 内 `/doctor`）检查 curl、git、api key、
已加载资产、沙盒后端、终端和输入后端。

会话是 `~/.xmake/harness/projects/<工程>/` 下的普通 json，
`xmake ai --list=sessions` 列出，`xmake ai -r <id>` 恢复。

## runtime 约束

harness 跑在 xmake 的 lua 沙盒里，以下**不可用**：`pcall`/`xpcall`、`error`、
`setmetatable`/`getmetatable`、`rawget`、`select`、`next`、`require`、
`io.popen`、带 TLS 的 socket。

对应替代：

| 不要用 | 改用 |
| --- | --- |
| `pcall(f, a)` | `try {function () .. end, catch {..}}` |
| `error("..")` | `raise("..")` |
| `setmetatable` | `import("core.base.object")` 和 `object {_init = {..}}` |
| `next(t)` | `for _, _ in pairs(t) do return t end` |
| http 客户端 | `harness.llm.transport`（curl + 管道） |
| 起进程 | `harness.shell.exec` |
| `print` 输出界面 | app 的渲染器，保证活动区一致 |

模块状态是按 import 实例隔离的；模块级缓存用 `_g`。

## 风格

跟随 xmake 源码：每个文件带 apache 头，函数名小写，模块私有函数用 `_` 前缀，
每个函数上方一句说明「做什么、为什么」，顶部 `-- imports` 块。

函数保持短小：目前 632 个函数，中位数 13 行，超过 60 行的只有 3 个纯数据表
（语言定义、provider 预设、主题样式名）。新增代码请保持这个水位。
