# 插件

[English](plugins.md) | 中文

context 之上的一切都是插件，xmake 支持本身也是。一个插件就是一个
`plugin.lua`，导出 `define()` 和 `apply(harness, definition)`。

## 发现路径

```
<addon>/modules/harness/plugins/<name>/plugin.lua    内置
~/.xmake/harness/plugins/<name>/plugin.lua           用户级
<project>/.xmake-harness/plugins/<name>/plugin.lua   工程级
配置里的 plugins.dirs                                 额外目录
```

同名插件先加载的胜出，`plugins.disabled` 可以整个跳过。

## API

```lua
function define()
    return {name = "mybuild", description = "the mybuild enhancement"}
end

function apply(harness, definition)

    -- 工具，见 docs/tools.zh.md
    harness:service("tools"):add({...})

    -- 插件自带的资产
    harness:service("skills"):adddir(path.join(definition.dir, "skills"), "plugin:mybuild")
    harness:service("agents"):adddir(path.join(definition.dir, "agents"), "plugin:mybuild")

    -- slash 命令
    harness:service("commands"):add({
        name = "mybuild",
        description = "..",
        run = function (app, args)
            return {kind = "message", text = ".."}   -- message | prompt | exit | clear | none
        end
    })

    -- system prompt
    harness:on("prompt/environment", function (lines)
        table.insert(lines, "mybuild project: yes")
        return lines
    end, {owner = "mybuild"})

    harness:on("prompt/sections", function (sections)
        table.insert(sections, {name = "mybuild", content = ".."})
        return sections
    end, {owner = "mybuild"})

    -- 拦截工具调用
    harness:on("tools/pre-execute", function (request)
        if request.tool.name == "run_command" and request.args.command:find("rm -rf /") then
            request.denied = "this command is not allowed by the mybuild plugin"
        end
        return request
    end, {owner = "mybuild"})
end
```

不适用时插件应当保持静默：cmake 插件在没有 `CMakeLists.txt` 时直接返回，
所以非 cmake 工程根本看不到它的工具。

## 组织方式

工具多了就一个文件一个工具，和内置工具同构 —— xmake 与 cmake 插件都是这么做的：

```
plugins/mybuild/
  plugin.lua          只负责装配：注册工具、资产、事件
  mybuildcmd.lua      共享的执行/结果封装
  prompt.lua          prompt 段落
  tools/
    mybuild_build.lua   define() + run()
    mybuild_test.lua
  agents/
    mybuild-fixer.md
```

`plugin.lua` 用 `import("tools." .. name, {rootdir = definition.dir})` 加载它们，
用户/工程目录下的插件同样适用。

## 新增大模型 provider

在 `harness/llm/providers/<kind>.lua` 放一个模块，导出 `buildrequest`、
`parsechunk`、`parseresponse`、`normalizeusage` 和 `parseerror`，然后让 provider 指向它：

```json
{"providers": {"myllm": {"kind": "myllm", "baseurl": "..", "models": {"main": ".."}}}}
```

`kind` 是动态解析的，不需要改动任何核心文件。

## 钩子

用户不写 lua 也能挂外部命令：

```json
{
    "hooks": {
        "pretooluse":  [{"matcher": "write_file|edit_file", "command": "xmake format $FILE"}],
        "posttooluse": [{"matcher": "run_command", "command": "echo done"}]
    }
}
```

`pretooluse` 钩子以退出码 `2` 结束就会阻断这次工具调用，它的 stderr 作为理由回给模型。
