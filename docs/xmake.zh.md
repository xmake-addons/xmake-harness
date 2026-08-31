# xmake 增强

[English](xmake.md) | 中文

harness 本身与构建系统无关；xmake 支持是
`src/modules/harness/plugins/xmake` 这个插件。工作目录下有 `xmake.lua` 时它才激活。

## 把工程导入进来

用别的构建系统的工程，分四步转过来，而这个切分本身就是重点：

```
/import                     这里有什么，然后交给 xmake-porter 子 agent
  xmake_import              目标（作为事实）—— 以及它推不出来的部分
  xmake_import_write        xmake.lua 初稿
  xmake_import_verify       能配置吗、能编译吗、目标跟原来一样吗
```

`xmake_import` 能读 CMake、Visual Studio（`.sln` / `.vcxproj`）、Meson、SCons，
统一读进一个中立模型，然后交出**两份清单**。第一份是事实 —— 目标、类型、源文件、
包含目录、宏定义、依赖 —— 这些只有一个正确答案，不值得每次去问模型。第二份是
**每一处它推不出来的地方**，都带着文件和行号：没求值的 `if(WIN32)`、展不开的变量、
一个属于 CMake 而不属于 xmake-repo 的 `find_package` 名字。

第二份清单才是转换本身。直接把 `CMakeLists.txt` 原文丢给模型，它会两件事一起做，
然后在机械的那一半上出微妙的错 —— 变量展开出来的源文件列表、在子目录里声明的依赖 ——
而这种错要等到在别人机器上构建时才会被发现。

### 编译选项是翻译，不是照搬

为某个编译器写的构建系统，是用那个编译器的 flag 来表达意图的。照搬过来，得到的
`xmake.lua` 只在转换那台机器上成立，而且没说清楚它到底想要什么。所以**凡是有对应
抽象接口的 flag 都换成接口，凡是 mode rule 已经提供的都直接丢掉**：

```cmake
target_compile_options(demo PRIVATE -fvisibility=hidden -Wall -Wextra -O2 -g -std=c++17 -fPIC)
target_link_libraries(demo PRIVATE m pthread z)
```
```lua
target("demo")
    set_kind("binary")
    set_languages("c++17")
    set_warnings("all", "extra")
    set_symbols("hidden")
    add_files("src/main.cpp")
    add_links("z")
    add_syslinks("m", "pthread")
```

`-O2` 和 `-g` 没了，因为 `mode.debug` / `mode.release` 已经设了，而且它们的答案在
每个编译器上都对。`-fPIC` 没了，因为 xmake 对动态库本来就加。`m` 和 `pthread` 是
系统库；`z` 不是，所以留着并**附一个问题** —— 按名字链接的库大多应该是
`add_requires`，而只有 `xrepo search` 能回答是哪个。

**没有一处是悄悄丢的**：每一条都记在读取结果的 notes 里，可以拿去跟原文对照、
也可以推翻。没有对应接口的 flag 会带上它所属的编译器 ——
`add_cxflags("/GR-", {tools = "cl"})` —— 因为把 `/GR-` 喂给 gcc 是个错误。

`xmake_import_verify` 不是可选步骤：它会把目标列表跟原构建系统对一遍，这才是抓
「悄悄少了一个目标」的手段。**能编译不等于转对了。**

再支持一种构建系统 = `import/` 下再加一个文件：一个带 `read(dir) -> model` 的模块，
加一行注册。

## 工具

| 工具 | 实际执行 |
| --- | --- |
| `xmake_create` | `xmake create [-l 语言] [-t 模板] [-P 目录] [名字]` —— 按模板生成工程，或列出模板 |
| `xmake_config` | `xmake f <args>` —— 模式、平台、工具链、选项 |
| `xmake_build` | `xmake build [-r] [-v] [target]` |
| `xmake_run` | `xmake run <target> <args>` |
| `xmake_test` | `xmake test [name]` |
| `xmake_show` | `xmake show` —— 目标、单个目标、选项、工具链 |
| `xmake_lua` | 在 xmake runtime 里执行一段 lua |
| `xrepo` | 搜索/查看/安装 c/c++ 包 |
| `xmake_docs` | 在[官方文档](https://github.com/xmake-io/xmake-docs)里查 API |
| `xmake_import` | 把 cmake/msbuild/meson/scons 工程读成事实 |
| `xmake_import_write` | 生成 `xmake.lua` 初稿 |
| `xmake_import_verify` | 能配置吗、能编译吗、目标一样吗 |

每个工具都提供 `commandline(args)`，所以确认框和结果卡片显示的是
`xmake build -r` 这样的真实命令，而不是内部工具名。

新建工程、新建库、新加目标都走 `xmake_create`。xmake 自带七十来个模板，模板插件
还能再加，所以第一个 `xmake.lua` 和第一个源文件是取来的而不是编出来的 —— 新工程
的风格因此是你的，而不是模型的。模板怎么选看 `xmake-templates` 技能，工具只负责
把命令跑起来。

`xmake_config`、`xmake_build`、`xmake_run`、`xmake_test`、`xmake_show` 都接受一个
`dir`，对应 `-P <目录>`。否则所有工具都只在会话启动的那个目录里跑，刚建到子目录里
的工程会变成唯一一个 agent 编不了的工程。

所有 xmake 调用都自动带 `-y`：生成缺失的 `xmake.lua`、安装 `add_requires` 依赖包
这类确认，不该由 agent 来卡住。`-y` 紧跟在任务名后面，因为大多数任务的最后一个
参数是值不是选项：`xmake build demo -y` 会把 `-y` 当成第二个 target 而报错。

`xmake_lua` 是 agent 不需要 python/bash 写临时脚本的原因：整套 xmake 脚本
API（`os`、`io`、`path`、`import`）都能用，且 Windows/macOS/Linux 行为一致。

## 不花 token 的命令行

`/xmake` 就地跑 xmake 本身，和你在终端里敲的一模一样：

```
/xmake                     等价于裸 `xmake`：构建
/xmake f -m debug          配置
/xmake build -vD           详细输出构建
/xmake run -d myapp        调试器里跑
/xmake clean、test、show、project -k compile_commands ...
```

参数原样透传，所以你对 xmake 命令行的一切认知在这里仍然成立，
`tab` 可以补全子命令。

重点在于它**不做**什么：输出只到你的屏幕，不去别的地方。
它不消耗 token，模型也看不到。这就是它和 `!xmake build` 的区别 ——
后者会把输出交给模型；也是它和 `xmake_build` 工具的区别 —— 那个是模型自己跑的。
这一个是你的：想亲眼看一下的构建，不用另开一个终端。

命令执行期间终端会被交还出去：退出 raw 模式、收起活动区，
于是 xmake 有自己的颜色和进度条，`ctrl+c` 能打到它身上，它也能向你提问。
失败时的汇总行会说明「谁没看见这段输出」—— 因为构建挂了之后的下一个念头
通常是去问 agent，而它刚才并不在看。

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

## 文档查询

「xmake.lua 里这个怎么写」是 agent 最常问的问题，而它凭记忆编出来的答案，
经常是一个看着很合理、实际不存在的 API。

**不需要任何安装**：查某个 API 时按需从上游拉取对应的那一页，缓存在
`~/.xmake/harness/docs/cache`（总共几百 KB，每周刷新）。第一次查约 1 秒，之后都是毫秒级。

走网络之前只看两个地方，也只有这两个：你**显式配置**的 checkout，以及
`/xmake-docs` 克隆下来的那份。harness 不会去你的家目录里乱猜 —— 猜中的可能是
某个无关的 fork 或者两年前的旧拷贝，用陈旧文档答错比联网取一页更糟。

```json
{"plugins": {"xmake": {"docsdir": "/path/to/your/xmake-docs"}}}
```

想离线用就整份克隆：

```
/xmake-docs            克隆或更新完整文档（会先征求确认）
/xmake-docs status     文档在哪、索引了多少个 API
```

工具有两种模式，精确那种很省 token：

```lua
xmake_docs(api = "add_files")         -- 只返回那一节：原型 + 参数表
xmake_docs(keyword = "qt.widgetapp")  -- 不知道 API 名字时全文检索
```

查不到的 API 会返回最接近的几个名字，而不是空答案；用户用中文提问时自动用中文文档。
已有的检出（`~/projects/**/xmake-docs`、配置里的 `plugins.xmake.docsdir`）会直接复用，
不会重复占一份磁盘。

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
