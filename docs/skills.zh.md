# Skills

[English](skills.md) | 中文

一个 skill 就是一个带 `SKILL.md` 的目录，格式与 claude code 一致，
现成的 skill 仓库可以直接用。

```
xmake-packages/
  SKILL.md
  reference.md        可选的附加文件，agent 需要时会去读
```

```markdown
---
name: xmake-packages
description: Use when adding third-party C/C++ dependencies to an xmake project — via add_requires / add_packages, configuring package options or pinning versions.
---

# Adding packages

..agent 需要遵循的具体说明..
```

## description 为什么关键

进入 system prompt 的只有每个 skill 的**名字和 description**，而且 description
也不是全文：列出来的是**触发词** —— 第一个子句，去掉开头的 *"Use when"*，
并截断到 120 字符。正文由 `use_skill` 工具按需加载。

这个截断不是为了好看。一个 53 个 skill 的包，会往**每一次请求**里写 15.7 KB 的
description，占整个 system prompt 的四分之三；只留触发词是 5 KB。被砍掉的那半
（*"Covers x、y、z"*）对"要不要打开这个 skill"毫无帮助，而对"打开之后怎么做"
很有帮助 —— 而它本来就还在那儿。

所以 description 要先写触发条件，再写内容摘要：

```
description: Use when <触发条件，一个子句> — <它覆盖的全部内容>
```

破折号之前（或第一句话）是模型用来路由的部分，之后的部分照样会被读到，
只是晚一点。

装一个包就是一次 clone，而 clone 是几分钟的网络等待，对话里没有任何东西在等它。
所以它走后台：命令立刻返回，`/jobs` 能看到，`/jobs kill <id>` 能停，装完自己会说。
落地的那一刻技能就读进来了，不用 `/reload`。

## 它不选的时候

列表里写了每个 skill 是干什么的，但**开不开由模型自己决定，而它并不总会开** ——
一个装好了、启用了、描述也没写错的 skill，照样可能被无视。`/skill:<名字>` 把这个
选择权收回来：

```
/skill:xmake-templates 在这里建一个 c++ 工程
```

每个启用的 skill 都是一条命令，所以在输入框里打 `/skill:` 就能补全。

harness 运行期间新写或改过的 skill，用 `/reload` 就能生效 —— 它同时会重新读取配置、
子 agent 和命令。装包会自动 reload。

## 安装 skill 包

harness 不内置任何 skill 包。它们各自独立维护，只在你要求时才拉取，
因此拿到的永远是上游最新版本：

```
/skills                              已加载 / 已安装 / 可安装的列表
/skills install xmake                已注册的包
/skills install github:user/repo     github 仓库
/skills install https://.../x.git    任意 git url
/skills install /path/to/my-skills   本地目录（软链接，方便开发）
/skills install ./bundle.zip         打包好的 bundle（.zip、.tar.gz、.tgz ..）
/skills update [pack]                git pull 更新
/skills remove <pack>                删除
```

下载前一定会先征求确认：

```
  ╭─ Install skill pack ────────────────────────────────────╮
  │ xmake-skills                                            │
  │ https://github.com/xmake-io/xmake-skills.git            │
  │ The xmake build skills: the packages, the rules, ..     │
  │                                                         │
  │ it is cloned into ~/.xmake/harness/skills/xmake-skills  │
  │                                                         │
  │ Do you want to fetch it from the network?               │
  │ ❯ 1. Yes                                                │
  │   2. No (esc)                                           │
  ╰─────────────────────────────────────────────────────────╯
```

在 TUI 之外：

```bash
xmake ai --command="skills install xmake" -y
```

指向一个你已经在用的工具，也是同一条命令 —— 目录是**软链接**而不是拷贝，
所以那个工具往里写什么，这边就跟着变：

```
/skills install ~/.claude            你已经有的 claude skills
/skills install ~/.dsh/skills        dsh 的那些
```

包名会去掉开头的点，于是它们叫 `claude` 和 `skills`。不会往这些目录里写任何东西。

## 支持的目录布局

一个 skill 就是一个 markdown 文件，frontmatter 里有 name 和 description。
不同工具把这些文件放在不同地方，所以 harness 不强求自己的布局，
而是识别现实中存在的这几种：

| 布局 | 形状 |
| --- | --- |
| skill 包 | `<root>/skills/<name>/SKILL.md` |
| skill 包（裸） | `<root>/<name>/SKILL.md` |
| claude plugin | `.claude-plugin/plugin.json` + `skills/<name>/SKILL.md` |
| claude marketplace | `.claude-plugin/marketplace.json` + 它列出的每个 plugin |
| dsh | `<root>/<name>.md` —— 一个文件就是一个 skill |

claude marketplace 是一堆 plugin 的目录，每个 plugin 都可能带自己的 skills，
所以一个包可以贡献多个根目录。它的清单里也可能指向**别的仓库**里的 plugin；
只加载磁盘上真实存在的，其余是别人的 clone。
`source` 为 `./` 的 plugin 指的就是仓库自己 —— `xmake-skills` 正是这样，
一个只有一个 plugin 的 marketplace。

deepseek harness（dsh）把一个 skill 放在单个 markdown 文件里，
同时还会读工程的 `.dsh/skills` 和 `.agents/skills`，这两者都支持。
单个 markdown 文件只有在 frontmatter **同时**有 name 和 description 时才算 skill ——
这是 dsh 的要求，也正好让 `README.md` 不会变成一个 skill。

安装时和 `/skills` 里都会报告识别到的布局：

```
the installed packs:
  xmake-skills     53 skills  claude marketplace `xmake-skills`  https://github.com/..
  my-notes          4 skills  dsh skills                         ~/.xmake/harness/skills/my-notes
```

压缩包是解压而不是 clone，并且会把里面**唯一的顶层目录**提上来 ——
`mypack.zip` 基本都装着一个 `mypack/`，留着这一层会让 skills 比布局所说的深一级。

### 两个 skill 抢同一个名字时

一个把许多 plugin 的 skills 汇集起来的包，迟早会出现两个都叫 `configure` 的 ——
claude 官方 marketplace 里就有三个，分别来自 discord、imessage、telegram 三个 plugin。
**第一个占住名字，其余的不加载。**

「第一个」由**排序后的路径**决定，而不是文件系统碰巧返回的顺序，
所以每台机器上赢的都是同一个 —— 一个 skill 在这个开发者机器上有、在另一个机器上没有，
是最难查的那类 bug。

落选的绝不会被静默丢弃：`/skills` 会逐个列出它和它输给的那个文件，
安装时的消息也会说明有几个。

```
4 skills could not be loaded, the name was already taken:
  access       claude-plugins-official/external_plugins/imessage/skills/access/SKILL.md
               kept: claude-plugins-official/external_plugins/discord/skills/access/SKILL.md
```

## 发现路径

| 目录 | 来源 |
| --- | --- |
| `~/.xmake/harness/skills/<pack>/` | 已安装的包 |
| `~/.xmake/harness/skills/` | 你自己零散的 skill |
| `<project>/.xmake-harness/skills/` | 工程级 |
| `<addon>/modules/harness/assets/skills` | 少量内置 |
| 配置里的 `skills.dirs` | 额外目录 |

支持嵌套布局（`skills/<category>/<name>/SKILL.md`），
[xmake-skills](https://github.com/xmake-io/xmake-skills) 仓库就是这么组织的。
已有的 `~/.claude/xmake-skills` 检出会被直接复用，一份拷贝两边共用。

## 在插件里注册 skill 包

```lua
import("harness.skills.installer")

function apply(harness, definition)
    installer.register(harness, {
        name = "mybuild",
        url = "https://github.com/me/mybuild-skills.git",
        description = "The mybuild recipes"
    })
end
```

之后 `/skills install mybuild` 即可用，包也会出现在可安装列表里。
插件本身不应该主动去 clone 任何东西。

## 启用与禁用

```json
{"skills": {"enabled": ["xmake-packages", "xmake-rules"], "disabled": ["xmake-nim"]}}
```

`enabled` 为空表示全部启用。
