---
name: xmake-import-msvc
description: Use when converting a Visual Studio solution or project to xmake — .sln and .vcxproj, the configuration/platform matrix, the runtime library, the property sheets, the precompiled headers and the MSVC settings that are a rule in xmake rather than a flag.
---

# Visual Studio to xmake, the parts that need deciding

`xmake_import` has already read the `.sln`, the projects in it, their sources,
includes, defines, dependencies and the `.lib`s they link. This is the rest.

## The configuration matrix is not four targets

`Debug|Win32`, `Debug|x64`, `Release|Win32`, `Release|x64` describe **one**
target four times. In xmake the axes are separate:

- Debug against Release is `add_rules("mode.debug", "mode.release")`
- Win32 against x64 is `xmake f -a x86` or `-a x64`, and nothing in the file

So a value which the reader marked as belonging to one configuration goes in a
mode, not in a copy of the target:

```lua
target("demo")
    add_defines("NDEBUG", {mode = "release"})
    -- or, better, because mode.release already defines it:
    -- nothing at all
```

`mode.debug` and `mode.release` already set the optimisation, the symbols,
`NDEBUG` and the runtime. Most of what differs between the two configurations of
a normal project is exactly that, and converts to nothing.

## The runtime library

This is the one which produces link errors weeks later, so do it deliberately:

| `RuntimeLibrary` | xmake |
| --- | --- |
| `MultiThreaded` | `set_runtimes("MT")` |
| `MultiThreadedDebug` | `set_runtimes("MTd")` |
| `MultiThreadedDLL` | `set_runtimes("MD")` (the default) |
| `MultiThreadedDebugDLL` | `set_runtimes("MDd")` |

Two rules about it:

**Set it once, at the top of the file, not per target.** Every target in a build
has to agree, and a mismatch is a link error about `_ITERATOR_DEBUG_LEVEL`. The
conversion already hoists it there when every target agreed in the original.

**Do not add a platform filter.** `set_runtimes("MT", {plat = "windows"})` reads
as though it were doing something and is not: the runtime is an msvc idea and
xmake ignores it on every other toolchain already. The filter is noise.

**And do not set it because you can.** If the original did not say `/MT`, do not
decide it here — `MD` is xmake's default and it is the right one for most
projects. Locking a project to the static runtime changes what its consumers
have to do, and that is the user's call and not a conversion.

## The settings which are rules

| the project says | xmake |
| --- | --- |
| `SubSystem: Windows` | `add_rules("win.sdk.application")` |
| `CharacterSet: Unicode` | `add_defines("UNICODE", "_UNICODE")` |
| `PrecompiledHeader: Use` | `set_pcxxheader("stdafx.h")` |
| `TreatWarningAsError` | `set_warnings("error")` |
| `WarningLevel: Level4` | `set_warnings("all", "extra")` |
| `OpenMPSupport` | `add_rules("c++.openmp")` |
| `.rc` in the sources | nothing, xmake compiles it |
| `.def` file | `add_files("x.def")` |
| a `Utility` project | usually no target at all |

## Property sheets

A `.props` referenced by `<Import Project="..">` holds settings the reader did
not follow — it reads the project file it was given. If several projects share
one, that is a policy for the whole build:

```lua
-- at the top of the xmake.lua, before the targets
set_runtimes("MT")
add_defines("_CRT_SECURE_NO_WARNINGS")
```

Open the `.props` and check for exactly that kind of thing before deciding a
target is simple.

## Paths

- `\` becomes `/`. The reader does this; anything left with a `\` in it came
  from a place it did not read.
- `$(SolutionDir)`, `$(ProjectDir)`, `$(OutDir)` are marked unresolved. The
  first two are usually "here", relative to the `xmake.lua`.
- `$(IntDir)` and `$(OutDir)` have no equivalent and want none: xmake decides
  where objects go.

## The libraries

`AdditionalDependencies` lists `.lib` files and the reader strips the suffix.
Which of `add_syslinks` and `add_packages` they become is the decision:

- a windows sdk library — `ws2_32`, `user32`, `advapi32`, `shlwapi` — is
  `add_syslinks`
- a third-party library is a package: `xrepo search` it first
- a `.lib` built by another project in the solution is already `add_deps`

## After it builds

Compare more than the build succeeding:

- does every project in the `.sln` have a target? `xmake_import_verify` says.
- does the binary still link the same libraries? `dumpbin /dependents` on both.
- was there a post-build step? `<PostBuildEvent>` is not read, and a project
  which copies a dll next to the exe will not run without it.
