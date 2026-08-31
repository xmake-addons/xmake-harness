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
-- @file        xml.lua
--

-- imports
import("harness.util.xml")

function test_elements_attributes_and_text()
    local root = xml.parse([[<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="4.0">
  <ItemGroup>
    <ClCompile Include="src/main.c" />
    <ClCompile Include="src/util.c"/>
  </ItemGroup>
  <PropertyGroup>
    <ConfigurationType>Application</ConfigurationType>
  </PropertyGroup>
</Project>]])
    assert(root, "it parses")
    assert(root.name == "Project", root.name)
    assert(root.attrs.ToolsVersion == "4.0", root.attrs.ToolsVersion)

    local sources = xml.find(root, "ClCompile")
    assert(#sources == 2, tostring(#sources))
    assert(sources[1].attrs.Include == "src/main.c", sources[1].attrs.Include)
    assert(xml.text(xml.find(root, "ConfigurationType")[1]) == "Application")
end

function test_an_attribute_may_hold_a_bracket()
    -- this is where reading xml with patterns stops working
    local root = xml.parse([[<a><b Condition="'$(C)|$(P)'=='Debug|Win32'" Value="x > y"/></a>]])
    assert(root, "it parses")
    local b = xml.child(root, "b")
    assert(b.attrs.Condition == "'$(C)|$(P)'=='Debug|Win32'", b.attrs.Condition)
    assert(b.attrs.Value == "x > y", b.attrs.Value)
end

function test_the_entities_come_back_as_characters()
    local root = xml.parse([[<a>&lt;flags&gt; &amp; &quot;more&quot; &#65;&#x42;</a>]])
    assert(xml.text(root) == "<flags> & \"more\" AB", xml.text(root))
end

function test_comments_and_cdata()
    -- a longer bracket, because the CDATA in it closes a plain one
    local root = xml.parse([==[<a><!-- a > b --><b><![CDATA[raw < & > text]]></b></a>]==])
    assert(#xml.children(root) == 1, tostring(#xml.children(root)))
    assert(xml.text(xml.child(root, "b")) == "raw < & > text", xml.text(xml.child(root, "b")))
end

function test_a_document_split_across_lines()
    local root = xml.parse([[<a
      one="1"
      two="2"
    >text</a>]])
    assert(root.attrs.one == "1" and root.attrs.two == "2")
    assert(xml.text(root) == "text", xml.text(root))
end

function test_a_byte_order_mark_is_not_part_of_it()
    local root = xml.parse("\239\187\191<a/>")
    assert(root and root.name == "a", tostring(root and root.name))
end

function test_what_is_not_well_formed_says_so()
    assert(not xml.parse("<a><b></a>"), "a mismatched tag")
    assert(not xml.parse("<a>"), "an unclosed tag")
    assert(not xml.parse(""), "nothing at all")
    assert(not xml.parse("<a/><b/>"), "two roots")
    local _, errors = xml.parse("<a><b></a>")
    assert(errors and errors:find("closed by", 1, true), tostring(errors))
end

function test_the_namespace_stays_on_the_name()
    local root = xml.parse([[<msb:Project xmlns:msb="x"><msb:Item/></msb:Project>]])
    assert(root.name == "msb:Project", root.name)
    assert(#xml.find(root, "msb:Item") == 1)
end
