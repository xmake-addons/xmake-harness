# xmake 增强

[English](xmake.md) | 中文

harness 本身与构建系统无关；xmake 支持是
`src/modules/harness/plugins/xmake` 这个插件。工作目录下有 `xmake.lua` 时它才激活。

## 工具

| 工具 | 实际执行 |
| --- | --- |
| `xmake_config` | `xmake f <args> -y` —— 模式、平台、工具链、选项 |
| `xmake_build` | `xmake build [-r] [-v] [target]` |
| `xmake_run` | `xmake run <target> <args>` |
| `xmake_test` | `xmake test [name]` |
| `xmake_show` | `xmake show` —— 目标、单个目标、选项、工具链 |
| `xmake_lua` | 在 xmake runtime 里执行一段 lua |
| `xrepo` | 搜索/查看/安装 c/c++ 包 |
| `xmake_docs` | 检索本地的 [xmake-docs](https://github.com/xmake-io/xmake-docs) |

每个工具都提供 `commandline(args)`，所以确认框和结果卡片显示的是
`xmake build -r` 这样的真实命令，而不是内部工具名。

所有 xmake 调用都自动带 `-y`：生成缺失的 `xmake.lua`、安装依赖包这类确认，
不该由 agent 来卡住。

`xmake_lua` 是 agent 不需要 python/bash 写临时脚本的原因：整套 xmake 脚本
API（`os`、`io`、`path`、`import`）都能用，且 Windows/macOS/Linux 行为一致。

## Skills

插件注册 [xmake-skills](https://github.com/xmake-io/xmake-skills) 这个包
（约 50 个 skill，覆盖包管理、规则、工具链、C++ modules、交叉编译、打包、
构建缓存、分布式编译和各语言配置），但**不内置**：

```
/skills install xmake     按需拉取，会先征求确认
/skills update            更新
```

查找顺序：`plugins.xmake.skillsdir`、
`~/.xmake/harness/skills/xmake-skills/skills`、`~/.claude/xmake-skills/skills`
（已有的 claude code 检出会被直接复用，一份拷贝两边共用）。

工程是 xmake 工程但 skills 没装时，欢迎面板会提示一次。

## Agent

`xmake-builder` —— 专门修构建的子 agent：build → 读错误 → 修 → 再 build，
带 xmake 工具和 xmake skills。主 agent 用 `run_agent` 委派给它。

## Prompt

工程有 `xmake.lua` 时，插件会补充：

- 环境事实：xmake 版本和目标名（直接从 `xmake.lua` 文本里解析，
  不会为了填个 prompt 就去触发 configure）
- 一段简短说明：优先用哪些工具，以及 `xmake.lua` 里真正要紧的规则
  （描述域 vs 脚本域、用 `add_requires` 而不是手写 flags、优先内置 rules）

## 配置

```json
{"plugins": {"xmake": {"enabled": true, "skillsdir": "/path/to/skills", "docsdir": "/path/to/xmake-docs"}}}
```

## 接入别的构建系统

照抄 `plugins/cmake/`：`plugin.lua` 64 行做装配，`cmakecmd.lua` 封装执行，
`tools/` 下三个工具各一文件。这就是全部约定。
