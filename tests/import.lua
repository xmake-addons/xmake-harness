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
