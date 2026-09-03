---
name: xmake-import-cmake
description: Use when converting a CMake project to xmake and the straightforward part is done — the conditions, the generator expressions, the find_package names, the install rules, the custom commands and the things CMake does that xmake says differently.
---

# CMake to xmake, the parts that need deciding

`xmake_import` has already given you the targets and their sources. This is
about the rest of the `CMakeLists.txt`, in the order it usually bites.

## Conditions

The reader never evaluates one. Read it and decide which kind it is.

```cmake
if(WIN32)          → if is_plat("windows") then ... end
if(APPLE)          → if is_plat("macosx") then ... end
if(UNIX AND NOT APPLE) → if is_plat("linux") then ... end
if(MSVC)           → if is_plat("windows") and is_host("windows") then ... end
                     or, for a flag: add_cxflags("/W4", {tools = "cl"})
if(CMAKE_BUILD_TYPE STREQUAL "Debug") → add_rules("mode.debug"), not an if
if(BUILD_SHARED_LIBS) → set_kind("$(kind)") and let the user choose
if(BUILD_TESTING)  → option("tests") and if has_config("tests")
if(MY_FEATURE)     → option("my_feature") and has_config("my_feature")
```

A condition on a *value* is often better as a scoped call than an `if`:

```lua
target("demo")
    add_defines("ON_WINDOWS", {plat = "windows"})
    add_syslinks("pthread", {plat = "linux"})
```

## Generator expressions

`$<...>` is evaluated at build time and the reader drops it. The common ones:

| CMake | xmake |
| --- | --- |
| `$<BUILD_INTERFACE:${d}>` | `add_includedirs(d)` — it is the build one |
| `$<INSTALL_INTERFACE:include>` | `add_headerfiles` and `add_installfiles` |
| `$<CONFIG:Debug>` | `mode.debug` |
| `$<PLATFORM_ID:Windows>` | `{plat = "windows"}` |
| `$<COMPILE_LANGUAGE:CXX>` | `add_cxxflags` rather than `add_cxflags` |

## find_package

The name is CMake's. Look every one up before writing `add_requires`:

```
xrepo search zlib
```

Some are not packages at all:

| find_package | xmake |
| --- | --- |
| `Threads` | `add_syslinks("pthread")` on linux, nothing elsewhere |
| `OpenMP` | `add_rules("c++.openmp")` |
| `CUDAToolkit` | `add_rules("cuda")` |
| `PkgConfig` + `pkg_check_modules(X)` | `add_requires("x")`, check the name |
| a project's own `Find*.cmake` | read it: it is usually one library and a header |

`COMPONENTS` become the package's configs: `add_requires("boost", {configs = {filesystem = true}})`.

## PUBLIC, PRIVATE, INTERFACE

CMake's usage requirements have a direct equivalent and it is worth keeping:

```cmake
target_include_directories(mylib PUBLIC include PRIVATE src)
```
```lua
target("mylib")
    add_includedirs("include", {public = true})
    add_includedirs("src")
```

`INTERFACE` on a library with no sources is `set_kind("headeronly")`.

## The commands with no equivalent

The reader lists each of these with its line. They are not conversions, they are
decisions:

- `install(TARGETS ..)` → `set_installdir`, `add_installfiles`, or nothing if the
  project is not installed
- `configure_file(a.h.in a.h)` → `add_configfiles("a.h.in")` and `set_configvar`
- `add_custom_command(OUTPUT ..)` → a rule with `on_build_file`, or a
  `before_build` — read what it generates first
- `add_test(..)` → `add_tests` on the target, see `xmake-tests`
- `add_compile_options` at directory scope → it applies to everything below it;
  put it on the targets it actually reaches, or in `add_rules` if it is a policy
- `include(SomeModule)` → read the module. `GNUInstallDirs` is nothing,
  `FetchContent` is `add_requires`, `CheckSymbolExists` is `check_csnippets`

## Interface libraries and object libraries

```cmake
add_library(hdr INTERFACE)          → set_kind("headeronly")
add_library(objs OBJECT a.c b.c)    → set_kind("object")
```

An `OBJECT` library which is only ever linked into one target is usually better
inlined: add its sources to that target and delete it.

## What to check when it builds

- the include order: CMake's `BEFORE` and xmake's order differ, and a project
  with two headers of the same name notices
- the C++ standard: `CXX_STANDARD 17` is a property and the reader may not have
  seen it. `set_languages("c++17")`
- `POSITION_INDEPENDENT_CODE` — xmake does this for shared libraries already
