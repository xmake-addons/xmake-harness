---
name: xmake-import
description: Use when converting a project from another build system to xmake — CMake, Visual Studio (.sln/.vcxproj), Meson or SCons. Covers the read-decide-write-verify loop, what the readers can and cannot work out, and how to check the conversion against the original.
---

# Converting a project to xmake

There is a tool for the half of this which has one right answer, and it is not
you. `xmake_import` reads the original build system and hands you the facts —
targets, kinds, sources, includes, defines, dependencies — and, separately, the
list of places it could not work out. **That list is your work.**

Do not read the `CMakeLists.txt` first and convert from it. You will get the
mechanical half subtly wrong — a source list expanded from a variable, a
dependency declared in a subdirectory, a `.lib` suffix — in ways nobody notices
until the build runs somewhere else.

## The loop

```
1. xmake_import        action=detect   what is this built with
2. xmake_import        action=read     the facts, and what could not be decided
3. read the original    only at the lines the tool named
4. xmake_import_write                  the draft xmake.lua
5. edit it              answer the TODOs
6. xmake_import_verify                 configures? builds? same targets?
7. back to 5 until it is clean
```

Never skip 6. A conversion which builds can still be wrong: a target which was
quietly dropped builds perfectly. `xmake_import_verify` compares the target list
against the original build system, which is the check that catches it.

## What the readers cannot do, and what you do about it

**Conditions are recorded, not evaluated.** `if(WIN32)` and `if(BUILD_TESTING)`
are the same shape and mean different things. The reader takes the values inside
and marks them. You decide:

- a platform branch becomes `if is_plat("windows") then ... end`
- a feature branch becomes an `option()` and `has_config()`
- a compiler branch is usually a builtin rule or `add_cxflags` with `{tools = ..}`

**A package name is a name in the other build system.** `find_package(ZLIB)`
tells you the project wants zlib, not what it is called in xmake-repo. Run
`xrepo search` before writing `add_requires`, every time. Some have no package
and want `add_syslinks` instead — `pthread`, `dl`, `m`, `ws2_32`.

**A Visual Studio configuration is not a target.** `Debug|Win32` and
`Release|x64` describe one target twice. What differs between them belongs in
`mode.debug` / `mode.release`, which is a rule and not a copy — the reader marks
those values with the configuration they came from.

**Flags are the last resort.** A `-O2` or a `/MT` in the original is usually a
mode or a runtime setting in xmake and not a flag to copy across:

| the original | xmake |
| --- | --- |
| `-O2 -DNDEBUG` in Release | `add_rules("mode.release")` |
| `-g` in Debug | `add_rules("mode.debug")` |
| `/MT`, `/MTd` | `set_runtimes("MT")` |
| `-std=c++17` | `set_languages("c++17")` |
| `-Wall -Wextra` | `set_warnings("all", "extra")` |
| `-fPIC` on a shared library | nothing, xmake does it |

Copying the flag works and reads as a conversion nobody finished.

## What the readers do work out

Do not redo any of this by hand — if it looks wrong, it is a bug worth
reporting, not something to work around:

- CMake: `set`/`list(APPEND)` variables, `file(GLOB)` as a pattern,
  `add_subdirectory`, the `target_*` family, `find_package`, `option`,
  `CMAKE_CURRENT_SOURCE_DIR` and friends, and dependencies between targets
  declared in any order
- Visual Studio: `.sln` to its projects, `ConfigurationType`, `ClCompile` and
  `ClInclude` items, excluded sources, `PreprocessorDefinitions`,
  `AdditionalIncludeDirectories`, `AdditionalDependencies` (with the `.lib` off),
  `ProjectReference` as a dependency, `LanguageStandard`
- Meson: `project`, `files`/list variables, `executable`/`*_library`,
  `dependency`, `subdir`, and the keyword arguments
- SCons: the `Program`/`*Library` calls and the obvious lists. An `SConstruct`
  is python and most of it is unread — expect to do more here.

## Where to look when it does not build

- **a header is not found** — the original had an `include_directories` at
  directory scope, which applies to everything below it. The reader records it
  on the project and not on the targets; put it where it belongs.
- **a symbol is not found** — a dependency between targets was a link in the
  original. `add_deps` and not `add_links` for anything built here.
- **the target is missing** — it was declared inside a condition. The verify
  step names it.
- **a package fails to resolve** — the name is the other build system's. Search
  xmake-repo.

## Related

- `xmake-templates` for starting a project rather than converting one
- `xmake-packages` for `add_requires` and what the options mean
- `xmake-targets` for what a target can say
