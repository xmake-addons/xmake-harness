--!A generic AI agent harness framework based on xmake lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      ruki
-- @file        import.lua
--

-- imports
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.emit")
import("harness.plugins.xmake.import.cmake", {alias = "cmakereader"})
import("harness.plugins.xmake.import.vcxproj")
import("harness.plugins.xmake.import.meson")
import("harness.plugins.xmake.import.scons")
import("harness.plugins.xmake.import.import", {alias = "projectimport"})

-- a directory with the given files in it
function _project(files)
    local rootdir = os.tmpfile() .. ".import"
    os.mkdir(rootdir)
    for name, content in pairs(files) do
        local filepath = path.join(rootdir, name)
        os.mkdir(path.directory(filepath))
        io.writefile(filepath, content)
    end
    return rootdir
end

function _names(list)
    local out = {}
    for _, one in ipairs(list) do
        table.insert(out, type(one) == "table" and one.name or one)
    end
    table.sort(out)
    return table.concat(out, ",")
end

---------------------------------------------------------------------------------
-- the cmake reader
---------------------------------------------------------------------------------

function test_cmake_reads_the_targets_and_their_sources()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo LANGUAGES C CXX)
set(SRC src/main.c src/util.c)
add_executable(demo ${SRC})
add_library(mylib STATIC lib/a.c)
]]})
    local project = cmakereader.read(rootdir)
    assert(project, "it reads")
    assert(project.name == "demo", project.name)
    assert(_names(project.languages) == "c,c++", _names(project.languages))
    assert(#project.targets == 2, tostring(#project.targets))

    local demo = model.get(project, "demo")
    assert(demo.kind == "binary", demo.kind)
    assert(_names(demo.files) == "src/main.c,src/util.c", _names(demo.files))
    assert(model.get(project, "mylib").kind == "static")
end

function test_cmake_follows_a_variable_and_a_glob()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo)
file(GLOB EXTRA "src/extra/*.c")
set(SRC src/main.c)
list(APPEND SRC src/more.c)
add_executable(demo ${SRC} ${EXTRA})
]]})
    local demo = model.get(cmakereader.read(rootdir), "demo")
    assert(_names(demo.files) == "src/extra/*.c,src/main.c,src/more.c", _names(demo.files))
end

function test_cmake_reads_the_subdirectories()
    local rootdir = _project({
        ["CMakeLists.txt"] = "project(demo)\nadd_subdirectory(lib)\nadd_executable(demo main.c)\n",
        ["lib/CMakeLists.txt"] = "add_library(mylib STATIC a.c b.c)\n"})
    local project = cmakereader.read(rootdir)
    local mylib = model.get(project, "mylib")
    assert(mylib, "the target of the subdirectory is there")
    -- and its sources are where they really are, not where they were written
    assert(_names(mylib.files) == "lib/a.c,lib/b.c", _names(mylib.files))
end

function test_cmake_tells_a_dependency_from_a_library()
    -- a link which names a target of this project is a dependency, and it is
    -- regularly written above the add_subdirectory which declares it
    local rootdir = _project({
        ["CMakeLists.txt"] = [[
project(demo)
add_executable(demo main.c)
target_link_libraries(demo PRIVATE mylib m)
add_subdirectory(lib)
]],
        ["lib/CMakeLists.txt"] = "add_library(mylib STATIC a.c)\n"})
    local demo = model.get(cmakereader.read(rootdir), "demo")
    assert(_names(demo.deps) == "mylib", _names(demo.deps))
    assert(_names(demo.links) == "m", _names(demo.links))
end

function test_cmake_expands_the_directory_variables()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo)
add_executable(demo main.c)
target_include_directories(demo PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/vendor)
]]})
    local demo = model.get(cmakereader.read(rootdir), "demo")
    -- relative to the project, not the machine it was read on
    assert(_names(demo.includedirs) == "vendor", _names(demo.includedirs))
end

function test_cmake_records_a_condition_rather_than_deciding_it()
    -- `if(WIN32)` is a platform and `if(BUILD_TESTING)` is a choice: guessing
    -- which is which produces an xmake.lua that builds the wrong thing
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo)
add_executable(demo main.c)
if(WIN32)
  target_compile_definitions(demo PRIVATE ON_WINDOWS)
endif()
]]})
    local project = cmakereader.read(rootdir)
    assert(#project.unresolved >= 2, tostring(#project.unresolved))

    local saidwin32 = false
    local saiddefine = false
    for _, one in ipairs(project.unresolved) do
        if one.text == "WIN32" then saidwin32 = true end
        if one.text and one.text:find("ON_WINDOWS", 1, true) then saiddefine = true end
    end
    assert(saidwin32, "the condition itself")
    assert(saiddefine, "and the value it guarded")
    assert(model.get(project, "demo").conditions[1] == "WIN32",
           _names(model.get(project, "demo").conditions))
end

function test_cmake_says_when_it_could_not_expand_something()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo)
add_executable(demo ${MYSTERY_SOURCES})
]]})
    local project = cmakereader.read(rootdir)
    local said = false
    for _, one in ipairs(project.unresolved) do
        if one.text and one.text:find("MYSTERY_SOURCES", 1, true) then
            said = true
        end
    end
    assert(said, "an unexpanded variable is a hole and is named as one")
end

function test_cmake_reads_the_packages_and_the_options()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo)
option(WITH_SSL "build with ssl" ON)
find_package(ZLIB REQUIRED)
add_executable(demo main.c)
target_link_libraries(demo PRIVATE ZLIB::ZLIB)
]]})
    local project = cmakereader.read(rootdir)
    assert(#project.options == 1 and project.options[1].name == "WITH_SSL")
    assert(project.options[1].default == true, tostring(project.options[1].default))
    assert(#project.packages == 1 and project.packages[1].name == "zlib")
    assert(_names(model.get(project, "demo").packages) == "zlib")
end

function test_cmake_comments_and_quoting()
    local rootdir = _project({["CMakeLists.txt"] = [==[
# a comment with add_executable(ghost x.c) in it
project(demo)
add_executable(demo "src/a file.c" src/b.c) # and one at the end
#[[ a bracket comment
add_executable(other y.c)
]]
]==]})
    local project = cmakereader.read(rootdir)
    assert(#project.targets == 1, _names(project.targets))
    assert(_names(model.get(project, "demo").files) == "src/a file.c,src/b.c",
           _names(model.get(project, "demo").files))
end

---------------------------------------------------------------------------------
-- the visual studio reader
---------------------------------------------------------------------------------

function _vcxproj(name, kind, body)
    return string.format([[<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0">
  <PropertyGroup Label="Globals"><ProjectName>%s</ProjectName></PropertyGroup>
  <PropertyGroup Label="Configuration"><ConfigurationType>%s</ConfigurationType></PropertyGroup>
  %s
</Project>]], name, kind, body)
end

function test_vcxproj_reads_a_project()
    local rootdir = _project({["demo.vcxproj"] = _vcxproj("demo", "Application", [[
  <ItemDefinitionGroup>
    <ClCompile>
      <PreprocessorDefinitions>WIN32;_CONSOLE;%(PreprocessorDefinitions)</PreprocessorDefinitions>
      <AdditionalIncludeDirectories>include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
      <LanguageStandard>stdcpp17</LanguageStandard>
    </ClCompile>
    <Link><AdditionalDependencies>ws2_32.lib;%(AdditionalDependencies)</AdditionalDependencies></Link>
  </ItemDefinitionGroup>
  <ItemGroup>
    <ClCompile Include="src\main.cpp" />
    <ClInclude Include="include\demo.h" />
  </ItemGroup>]])})
    local project = vcxproj.read(path.join(rootdir, "demo.vcxproj"))
    assert(project, "it reads")
    local demo = model.get(project, "demo")
    assert(demo and demo.kind == "binary", tostring(demo and demo.kind))
    -- the separators are turned round
    assert(_names(demo.files) == "src/main.cpp", _names(demo.files))
    assert(_names(demo.defines) == "WIN32,_CONSOLE", _names(demo.defines))
    -- the inherited `%(..)` is not a define
    assert(_names(demo.includedirs) == "include", _names(demo.includedirs))
    -- and the `.lib` comes off
    assert(_names(demo.syslinks) == "ws2_32", _names(demo.syslinks))
    assert(_names(demo.languages) == "c++17", _names(demo.languages))
end

function test_vcxproj_leaves_out_what_is_excluded()
    local rootdir = _project({["demo.vcxproj"] = _vcxproj("demo", "Application", [[
  <ItemGroup>
    <ClCompile Include="a.cpp" />
    <ClCompile Include="old.cpp"><ExcludedFromBuild>true</ExcludedFromBuild></ClCompile>
  </ItemGroup>]])})
    local demo = model.get(vcxproj.read(path.join(rootdir, "demo.vcxproj")), "demo")
    assert(_names(demo.files) == "a.cpp", _names(demo.files))
end

function test_vcxproj_marks_what_belongs_to_one_configuration()
    -- Debug|Win32 and Release|x64 describe one target twice: what differs is a
    -- mode rule in xmake and not a copy of the target
    local rootdir = _project({["demo.vcxproj"] = _vcxproj("demo", "Application", [[
  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='Release|x64'">
    <ClCompile><PreprocessorDefinitions>NDEBUG</PreprocessorDefinitions></ClCompile>
  </ItemDefinitionGroup>
  <ItemGroup><ClCompile Include="a.cpp" /></ItemGroup>]])})
    local project = vcxproj.read(path.join(rootdir, "demo.vcxproj"))
    local said = false
    for _, one in ipairs(project.unresolved) do
        if one.text and one.text:find("Release only", 1, true) then
            said = true
        end
    end
    assert(said, "the configuration it belongs to is named")
end

function test_a_solution_brings_its_projects_and_their_order()
    local rootdir = _project({
        ["demo/demo.vcxproj"] = _vcxproj("demo", "Application",
            [[<ItemGroup><ClCompile Include="main.cpp"/></ItemGroup>
              <ItemGroup><ProjectReference Include="..\mylib\mylib.vcxproj" /></ItemGroup>]]),
        ["mylib/mylib.vcxproj"] = _vcxproj("mylib", "StaticLibrary",
            [[<ItemGroup><ClCompile Include="a.cpp"/></ItemGroup>]]),
        ["all.sln"] = [[
Microsoft Visual Studio Solution File, Format Version 12.00
Project("{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}") = "demo", "demo\demo.vcxproj", "{A}"
EndProject
Project("{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}") = "mylib", "mylib\mylib.vcxproj", "{B}"
EndProject
]]})
    local project = vcxproj.read(path.join(rootdir, "all.sln"))
    assert(project, "it reads the solution")
    assert(#project.targets == 2, _names(project.targets))
    -- the sources are relative to the solution and not to each project
    assert(_names(model.get(project, "demo").files) == "demo/main.cpp",
           _names(model.get(project, "demo").files))
    assert(_names(model.get(project, "demo").deps) == "mylib",
           _names(model.get(project, "demo").deps))
end

---------------------------------------------------------------------------------
-- the other two
---------------------------------------------------------------------------------

function test_meson_reads_a_project()
    local rootdir = _project({["meson.build"] = [[
project('demo', 'c', 'cpp')
src = files('src/main.c', 'src/util.c')
zlib = dependency('zlib')
executable('demo', src, include_directories: 'include', dependencies: zlib)
]]})
    local project = meson.read(rootdir)
    assert(project and project.name == "demo", tostring(project and project.name))
    local demo = model.get(project, "demo")
    assert(demo and demo.kind == "binary")
    assert(_names(demo.files) == "src/main.c,src/util.c", _names(demo.files))
    assert(_names(demo.includedirs) == "include", _names(demo.includedirs))
    assert(#project.packages == 1 and project.packages[1].name == "zlib")
end

function test_scons_reads_what_it_can_and_says_what_it_cannot()
    local rootdir = _project({["SConstruct"] = [[
src = ['a.c', 'b.c']
env = Environment()
env.Program('demo', src)
]]})
    local project = scons.read(rootdir)
    assert(project, "it reads")
    local demo = model.get(project, "demo")
    assert(demo and _names(demo.files) == "a.c,b.c", _names(demo and demo.files or {}))
    -- and it is honest about the rest
    local said = false
    for _, one in ipairs(project.notes) do
        if one:find("python", 1, true) then
            said = true
        end
    end
    assert(said, "it says that an SConstruct is python")
end

---------------------------------------------------------------------------------
-- what is detected, and what is written
---------------------------------------------------------------------------------

function test_what_a_directory_is_built_with()
    local rootdir = _project({["CMakeLists.txt"] = "project(demo)\nadd_executable(demo a.c)\n",
                              ["meson.build"] = "project('demo', 'c')\n"})
    local found = projectimport.detect(rootdir)
    assert(#found == 2, tostring(#found))
    -- the one worth trying first
    assert(found[1].name == "cmake", found[1].name)
    assert(found[1].files[1] == "CMakeLists.txt")
end

function test_nothing_to_read_says_so()
    local rootdir = _project({["main.c"] = "int main(){}\n"})
    assert(#projectimport.detect(rootdir) == 0)
    local project, errors = projectimport.read(rootdir)
    assert(not project and errors:find("nothing", 1, true), tostring(errors))
end

function test_the_draft_is_an_xmake_lua()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo LANGUAGES C)
option(WITH_SSL "with ssl" ON)
find_package(ZLIB REQUIRED)
add_subdirectory(lib)
add_executable(demo src/main.c)
target_include_directories(demo PRIVATE include)
target_link_libraries(demo PRIVATE mylib ZLIB::ZLIB)
]],
        ["lib/CMakeLists.txt"] = "add_library(mylib STATIC a.c)\n"})

    local result, errors = projectimport.convert(rootdir, {dry = true})
    assert(result, tostring(errors))
    local text = result.text
    assert(text:find("add_rules(\"mode.debug\", \"mode.release\")", 1, true), text)
    assert(text:find("target(\"demo\")", 1, true), text)
    assert(text:find("set_kind(\"binary\")", 1, true), text)
    assert(text:find("add_deps(\"mylib\")", 1, true), text)
    assert(text:find("add_requires(\"zlib\")", 1, true), text)
    assert(text:find("option(\"WITH_SSL\")", 1, true), text)

    -- a dependency is written before what needs it, so the file reads the way
    -- the build runs
    assert(text:find("target(\"mylib\")", 1, true) < text:find("target(\"demo\")", 1, true),
           "mylib comes first")

    -- and nothing was written, because this was a look
    assert(not os.isfile(path.join(rootdir, "xmake.lua")), "a dry run writes nothing")
end

function test_it_will_not_replace_an_xmake_lua_by_accident()
    local rootdir = _project({["CMakeLists.txt"] = "project(demo)\nadd_executable(demo a.c)\n",
                              ["xmake.lua"] = "-- mine\n"})
    local result, errors = projectimport.convert(rootdir, {})
    assert(not result and errors:find("already exists", 1, true), tostring(errors))
    assert(io.readfile(path.join(rootdir, "xmake.lua")) == "-- mine\n", "it is untouched")

    assert(projectimport.convert(rootdir, {force = true}), "unless it is told to")
    assert(io.readfile(path.join(rootdir, "xmake.lua")):find("target(\"demo\")", 1, true))
end

function test_what_could_not_be_decided_is_written_beside_it()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo)
add_executable(demo a.c)
if(WIN32)
  target_compile_definitions(demo PRIVATE ON_WINDOWS)
endif()
]]})
    local result = projectimport.convert(rootdir, {})
    assert(result.todopath and os.isfile(result.todopath), "there is a list")
    local todo = io.readfile(result.todopath)
    assert(todo:find("WIN32", 1, true), todo)
    assert(todo:find("CMakeLists.txt:3", 1, true), todo)
end

function test_a_model_which_is_wrong_says_what_is_wrong_with_it()
    local project = model.new({from = "test"})
    assert(#model.problems(project) == 1, "an empty one has no target")

    local one = model.target(project, "demo", {kind = "binary"})
    assert(#model.problems(project) == 1, "and now it has no source")
    model.add(one.files, "a.c")
    assert(#model.problems(project) == 0, table.concat(model.problems(project), "; "))

    model.add(one.deps, "nothere")
    assert(#model.problems(project) == 1, "a dependency on something which is not here")
end

---------------------------------------------------------------------------------
-- saying it the way xmake says it
---------------------------------------------------------------------------------

function _converted(options)
    local rootdir = _project({["CMakeLists.txt"] = string.format([[
project(demo LANGUAGES CXX)
add_executable(demo main.cpp)
target_compile_options(demo PRIVATE %s)
]], options)})
    local result = projectimport.convert(rootdir, {dry = true})
    return result.text, result.project
end

function test_a_flag_which_is_a_setting_becomes_the_setting()
    -- `add_cxflags("-fvisibility=hidden")` works on the machine it was converted
    -- on and says nothing about what it wants
    local text = _converted("-fvisibility=hidden -Wall -Wextra")
    assert(text:find("set_symbols(\"hidden\")", 1, true), text)
    assert(text:find("set_warnings(\"all\", \"extra\")", 1, true), text)
    assert(not text:find("-fvisibility", 1, true), text)
    assert(not text:find("-Wall", 1, true), text)
end

function test_a_flag_a_mode_rule_already_sets_is_dropped()
    local text, project = _converted("-O2 -g -DNDEBUG")
    assert(not text:find("-O2", 1, true), text)
    assert(not text:find("-g\"", 1, true), text)
    assert(not text:find("NDEBUG", 1, true), text)

    -- and never silently: every one of them is said
    local said = 0
    for _, note in ipairs(project.notes) do
        if note:find("mode.", 1, true) then
            said = said + 1
        end
    end
    assert(said >= 3, tostring(said))
end

function test_a_standard_becomes_set_languages()
    assert(_converted("-std=c++17"):find("set_languages(\"c++17\")", 1, true))
    assert(_converted("/std:c++20"):find("set_languages(\"c++20\")", 1, true))
    assert(_converted("-std=gnu11"):find("set_languages(\"gnu11\")", 1, true))
end

function test_a_runtime_becomes_set_runtimes()
    assert(_converted("/MT"):find("set_runtimes(\"MT\")", 1, true))
    assert(_converted("/MDd"):find("set_runtimes(\"MDd\")", 1, true))
end

function test_a_value_written_as_a_flag_becomes_the_value()
    local text = _converted("-DFOO=1 -Iinclude")
    assert(text:find("add_defines(\"FOO=1\")", 1, true), text)
    assert(text:find("add_includedirs(\"include\")", 1, true), text)
end

function test_what_is_left_over_keeps_the_compiler_it_is_for()
    -- a `/GR-` handed to gcc is an error and a `-fno-rtti` handed to cl is a
    -- warning and a wasted afternoon
    local text = _converted("-fstack-protector /GR-")
    assert(text:find("{tools = {\"gcc\", \"clang\"}}", 1, true), text)
    assert(text:find("{tools = \"cl\"}", 1, true), text)
end

function test_a_system_library_is_a_syslink_and_the_rest_is_a_question()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo)
add_executable(demo main.c)
target_link_libraries(demo PRIVATE m pthread z)
]]})
    local result = projectimport.convert(rootdir, {dry = true})
    assert(result.text:find("add_syslinks(\"m\", \"pthread\")", 1, true), result.text)
    -- `z` is a library somebody has to look up, and saying so is the answer
    assert(result.text:find("add_links(\"z\")", 1, true), result.text)
    local asked = false
    for _, one in ipairs(result.project.unresolved) do
        if (one.why or ""):find("xrepo search", 1, true) then
            asked = true
        end
    end
    assert(asked, "it says to look it up")
end

function test_the_original_flags_can_be_kept_when_they_are_wanted()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo)
add_executable(demo main.c)
target_compile_options(demo PRIVATE -Wall)
]]})
    local project = projectimport.read(rootdir, {normalize = false})
    assert(table.contains(project.targets[1].cxflags, "-Wall"), "it is left as it was")
end

function test_what_every_target_agrees_on_is_said_once()
    -- every target in a build has to agree about the msvc runtime, and a
    -- project which sets it four times is one where somebody changes three
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo LANGUAGES CXX)
add_executable(demo a.cpp)
add_library(mylib STATIC b.cpp)
target_compile_options(demo PRIVATE /MT -std=c++17)
target_compile_options(mylib PRIVATE /MT -std=c++17)
]]})
    local text = projectimport.convert(rootdir, {dry = true}).text

    -- once, at the top, and not inside either target
    local first = text:find("set_runtimes", 1, true)
    assert(first, text)
    assert(first < text:find("target(", 1, true), "before the targets")
    assert(not text:find("set_runtimes", first + 1, true), "and only once")
    assert(not text:find("{plat = ", 1, true), "with no platform filter on it")

    local languages = text:find("set_languages", 1, true)
    assert(languages and languages < text:find("target(", 1, true), text)
end

function test_a_setting_they_do_not_agree_on_stays_where_it_is()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo LANGUAGES CXX)
add_executable(demo a.cpp)
add_library(mylib STATIC b.cpp)
target_compile_options(demo PRIVATE /MT)
target_compile_options(mylib PRIVATE /MD)
]]})
    local text = projectimport.convert(rootdir, {dry = true}).text
    assert(text:find("    set_runtimes(\"MT\")", 1, true), text)
    assert(text:find("    set_runtimes(\"MD\")", 1, true), text)
end

---------------------------------------------------------------------------------
-- autotools
---------------------------------------------------------------------------------

import("harness.plugins.xmake.import.autotools")
import("harness.plugins.xmake.import.qmake")
import("harness.plugins.xmake.import.compiledb")
import("harness.plugins.xmake.import.reader")

function test_autotools_reads_the_primaries()
    -- the prefix says where it installs and the suffix says what it is, so
    -- `bin_PROGRAMS` and `noinst_LIBRARIES` are a binary and a library
    local rootdir = _project({["Makefile.am"] = [[
bin_PROGRAMS = demo
noinst_LIBRARIES = libaux.a
demo_SOURCES = main.c util.c
libaux_a_SOURCES = aux.c
]]})
    local project = autotools.read(rootdir)
    assert(project, "it reads")
    assert(_names(project.targets) == "demo,libaux", _names(project.targets))
    assert(model.get(project, "demo").kind == "binary")
    assert(model.get(project, "libaux").kind == "static")
    assert(_names(model.get(project, "demo").files) == "main.c,util.c",
           _names(model.get(project, "demo").files))
    -- and which of them is installed
    assert(model.get(project, "demo").installed == true)
    assert(model.get(project, "libaux").installed == false)
end

function test_autotools_expands_the_directory_variables()
    -- `-I$(top_srcdir)/include` is an include directory, and leaving it as it
    -- was written makes one called `$(top_srcdir)/include`
    local rootdir = _project({
        ["Makefile.am"] = "SUBDIRS = src\n",
        ["src/Makefile.am"] = [[
bin_PROGRAMS = demo
demo_SOURCES = main.c
demo_CPPFLAGS = -I$(top_srcdir)/include -DDEMO=1
]]})
    local demo = model.get(autotools.read(rootdir), "demo")
    assert(demo, "the subdirectory was read")
    assert(_names(demo.files) == "src/main.c", _names(demo.files))
    assert(_names(demo.includedirs) == "include", _names(demo.includedirs))
    assert(_names(demo.defines) == "DEMO=1", _names(demo.defines))
end

function test_autotools_reads_configure_ac()
    local rootdir = _project({
        ["configure.ac"] = [[
AC_INIT([mydemo], [1.2.0])
AC_PROG_CC
AC_CHECK_LIB([z], [deflate])
PKG_CHECK_MODULES([DEPS], [glib-2.0 >= 2.40 gtk+-3.0])
]],
        ["Makefile.am"] = "bin_PROGRAMS = demo\ndemo_SOURCES = main.c\n"})
    local project = autotools.read(rootdir)
    assert(project.name == "mydemo", project.name)
    -- the version constraint is a constraint and not a third package
    assert(_names(project.packages) == "glib-2.0,gtk+-3.0,z", _names(project.packages))
end

function test_autotools_links_a_library_of_its_own_as_a_dependency()
    local rootdir = _project({["Makefile.am"] = [[
bin_PROGRAMS = demo
noinst_LIBRARIES = libaux.a
demo_SOURCES = main.c
demo_LDADD = libaux.a -lz
libaux_a_SOURCES = aux.c
]]})
    local demo = model.get(autotools.read(rootdir), "demo")
    assert(_names(demo.deps) == "libaux", _names(demo.deps))
    assert(_names(demo.links) == "z", _names(demo.links))
end

function test_autotools_says_what_libtool_leaves_open()
    local rootdir = _project({["Makefile.am"] =
        "lib_LTLIBRARIES = libfoo.la\nlibfoo_la_SOURCES = foo.c\n"})
    local project = autotools.read(rootdir)
    assert(model.get(project, "libfoo"), _names(project.targets))
    local said = false
    for _, note in ipairs(project.notes) do
        if note:find("libtool", 1, true) then
            said = true
        end
    end
    assert(said, "it says a libtool library is two libraries")
end

---------------------------------------------------------------------------------
-- qmake
---------------------------------------------------------------------------------

function test_qmake_reads_a_pro_file()
    local rootdir = _project({["demo.pro"] = [[
TEMPLATE = app
TARGET   = demo
CONFIG  += c++17 warn_on
SOURCES += src/main.cpp \
           src/window.cpp
HEADERS += src/window.h
INCLUDEPATH += include
DEFINES += DEMO_BUILD=1
LIBS    += -L../lib -lz
]]})
    local project = qmake.read(rootdir)
    assert(project, "it reads")
    local demo = model.get(project, "demo")
    assert(demo and demo.kind == "binary", tostring(demo and demo.kind))
    -- the backslash continues the line
    assert(_names(demo.files) == "src/main.cpp,src/window.cpp", _names(demo.files))
    assert(_names(demo.includedirs) == "include", _names(demo.includedirs))
    assert(_names(demo.defines) == "DEMO_BUILD=1", _names(demo.defines))
    assert(_names(demo.links) == "z", _names(demo.links))
    assert(_names(demo.linkdirs) == "../lib", _names(demo.linkdirs))
    assert(_names(demo.languages) == "c++17", _names(demo.languages))
end

function test_qmake_turns_the_qt_modules_into_frameworks_and_a_rule()
    -- `QT += widgets` is not a list of libraries, it is a rule and its frameworks
    local rootdir = _project({["demo.pro"] =
        "TEMPLATE = app\nTARGET = demo\nQT += core gui widgets\nSOURCES += main.cpp\n"})
    local demo = model.get(qmake.read(rootdir), "demo")
    assert(_names(demo.frameworks) == "QtCore,QtGui,QtWidgets", _names(demo.frameworks))
    assert(_names(demo.rules) == "qt.widgetapp", _names(demo.rules))
end

function test_qmake_records_a_scope_rather_than_deciding_it()
    local rootdir = _project({["demo.pro"] = [[
TEMPLATE = app
TARGET = demo
SOURCES += main.cpp
win32: LIBS += -lws2_32
unix {
    LIBS += -ldl
}
]]})
    local project = qmake.read(rootdir)
    local scopes = 0
    for _, one in ipairs(project.unresolved) do
        if (one.why or ""):find("scope", 1, true) then
            scopes = scopes + 1
        end
    end
    assert(scopes >= 2, tostring(scopes))
end

function test_qmake_a_library_says_what_qmake_would_have_built()
    local rootdir = _project({["mylib.pro"] =
        "TEMPLATE = lib\nTARGET = mylib\nSOURCES += a.cpp\n"})
    local project = qmake.read(rootdir)
    assert(model.get(project, "mylib").kind == "shared", model.get(project, "mylib").kind)
    local said = false
    for _, note in ipairs(project.notes) do
        if note:find("shared library by default", 1, true) then
            said = true
        end
    end
    assert(said, "and says that is qmake's default rather than a fact")
end

---------------------------------------------------------------------------------
-- the compile database
---------------------------------------------------------------------------------

function _database(rootdir, rows)
    local pieces = {}
    for _, row in ipairs(rows) do
        table.insert(pieces, string.format(
            "{\"directory\": %q, \"file\": %q, \"command\": %q}", rootdir, row[1], row[2]))
    end
    io.writefile(path.join(rootdir, "compile_commands.json"),
                 "[" .. table.concat(pieces, ",\n") .. "]")
end

function test_a_compile_database_is_read_as_facts()
    local rootdir = _project({["src/main.c"] = "int main(void){return 0;}\n"})
    _database(rootdir, {{"src/main.c", "cc -I include -I vendor -DDEMO=1 -c src/main.c -o m.o"}})

    local items = compiledb.entries(compiledb.find(rootdir), rootdir)
    assert(#items == 1, tostring(#items))
    assert(items[1].file == "src/main.c", items[1].file)
    assert(items[1].language == "c", tostring(items[1].language))

    -- `-I include` is a flag and its value, not a flag and a source file
    local facts = compiledb.factsof(items, "src/main.c")
    assert(_names(facts.includedirs) == "include,vendor", _names(facts.includedirs))
    assert(_names(facts.defines) == "DEMO=1", _names(facts.defines))
end

function test_a_compile_database_alone_becomes_a_project()
    local rootdir = _project({["src/a.c"] = "int a(void){return 0;}\n",
                              ["src/b.c"] = "int b(void){return 0;}\n"})
    _database(rootdir, {{"src/a.c", "cc -I include -c src/a.c -o a.o"},
                        {"src/b.c", "cc -I include -c src/b.c -o b.o"}})
    local project = compiledb.read(rootdir)
    assert(project, "it reads")
    -- the same flags means one target
    assert(#project.targets == 1, _names(project.targets))
    assert(_names(project.targets[1].files) == "src/a.c,src/b.c",
           _names(project.targets[1].files))
    -- and it says the names are guesses
    assert(#project.unresolved > 0, "the names and kinds are not in a database")
end

function test_files_compiled_differently_are_different_targets()
    local rootdir = _project({["src/a.c"] = "int a(void){return 0;}\n",
                              ["src/b.c"] = "int b(void){return 0;}\n"})
    _database(rootdir, {{"src/a.c", "cc -I include -DA=1 -c src/a.c -o a.o"},
                        {"src/b.c", "cc -I include -c src/b.c -o b.o"}})
    local project = compiledb.read(rootdir)
    assert(#project.targets == 2, _names(project.targets))
    -- and the two do not fight over one name
    assert(project.targets[1].name ~= project.targets[2].name, _names(project.targets))
end

function test_the_order_of_the_flags_does_not_make_a_second_target()
    local rootdir = _project({["a.c"] = "int a(void){return 0;}\n",
                              ["b.c"] = "int b(void){return 0;}\n"})
    _database(rootdir, {{"a.c", "cc -I one -I two -c a.c -o a.o"},
                        {"b.c", "cc -I two -I one -c b.c -o b.o"}})
    assert(#compiledb.read(rootdir).targets == 1, "the same set written in another order")
end

function test_it_catches_a_conversion_which_lost_a_flag()
    -- this is the check nothing else can do: the right targets with the wrong
    -- `-I` compiles, passes every other check, and behaves differently
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo LANGUAGES C)
add_executable(demo src/main.c)
target_include_directories(demo PRIVATE include)
]],
        ["src/main.c"] = "int main(void){return 0;}\n"})
    _database(rootdir, {{"src/main.c",
        "cc -I include -I vendor -DEXTRA=2 -c src/main.c -o m.o"}})

    local project = projectimport.read(rootdir, {reader = "cmake"})
    local items = compiledb.entries(compiledb.find(rootdir), rootdir)
    local differences = compiledb.differences(project, items)
    assert(#differences == 1, tostring(#differences))

    local said = table.concat(differences[1].missing, "; ")
    assert(said:find("vendor", 1, true), said)
    assert(said:find("EXTRA=2", 1, true), said)
end

function test_a_conversion_which_matches_says_nothing()
    local rootdir = _project({["CMakeLists.txt"] = [[
project(demo LANGUAGES C)
add_executable(demo src/main.c)
target_include_directories(demo PRIVATE include)
target_compile_definitions(demo PRIVATE DEMO=1)
]],
        ["src/main.c"] = "int main(void){return 0;}\n"})
    _database(rootdir, {{"src/main.c", "cc -I include -DDEMO=1 -c src/main.c -o m.o"}})

    local project = projectimport.read(rootdir, {reader = "cmake"})
    local items = compiledb.entries(compiledb.find(rootdir), rootdir)
    assert(#compiledb.differences(project, items) == 0, "nothing to report")
end

---------------------------------------------------------------------------------
-- what every reader shares
---------------------------------------------------------------------------------

function test_the_shared_path_rule()
    local state = {rootdir = "/home/u/demo"}
    assert(reader.join(state, "src", "main.c") == "src/main.c")
    assert(reader.join(state, "", "main.c") == "main.c")
    -- an absolute path inside the project comes back relative to it
    assert(reader.join(state, "src", "/home/u/demo/include") == "include",
           reader.join(state, "src", "/home/u/demo/include"))
    -- and one outside it stays as it is, because that is worth seeing
    assert(reader.join(state, "src", "/usr/include") == "/usr/include")
    -- windows separators are separators
    assert(reader.join(state, "src", "a\\b.c") == "src/a/b.c",
           reader.join(state, "src", "a\\b.c"))
end

function test_the_shared_line_reader()
    local filepath = os.tmpfile() .. ".mk"
    io.writefile(filepath, "A = 1 # a comment\nB = 2 \\\n    3\n# all comment\n\nC = \"a # b\"\n")
    local lines = reader.lines(filepath)
    assert(#lines == 3, tostring(#lines))
    assert(lines[1].text == "A = 1", lines[1].text)
    -- the continuation is joined and keeps the line it started on
    assert(lines[2].text == "B = 2 3", lines[2].text)
    assert(lines[2].line == 2, tostring(lines[2].line))
    -- and a `#` inside a string is not a comment
    assert(lines[3].text == "C = \"a # b\"", lines[3].text)
end

function test_the_shared_command_line_splitter()
    local argv = reader.argv("cc -I \"a b\" -DX='y z' -c main.c")
    assert(#argv == 6, table.concat(argv, "|"))
    assert(argv[3] == "a b", argv[3])
    assert(argv[4] == "-DX=y z", argv[4])
end

function test_the_shared_flag_reader()
    local one = {includedirs = {}, sysincludedirs = {}, defines = {}, links = {},
                 linkdirs = {}, frameworks = {}, cxflags = {}}
    local rest = reader.flags({rootdir = "/x"}, one,
        {"-Iinc", "-I", "other", "-DA=1", "-lz", "-L../lib", "-isystem", "sys", "-Wall"}, "")
    assert(_names(one.includedirs) == "inc,other", _names(one.includedirs))
    assert(_names(one.sysincludedirs) == "sys", _names(one.sysincludedirs))
    assert(_names(one.defines) == "A=1", _names(one.defines))
    assert(_names(one.links) == "z", _names(one.links))
    assert(_names(one.linkdirs) == "../lib", _names(one.linkdirs))
    assert(_names(rest) == "-Wall", _names(rest))
end
