package main

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:editor/api"
import "mirai:project"

@(private="file")
DOCS_TOPIC :: `---
name: core
description: Core of a game - components, steps
  and phases.
---

# Game core

Intro.

## Spawn ` + "`a`" + ` [thing](other.md)

Spawn body.

### Inner

Inner body.

## Same

First.

## Same

Second.

` + "```" + `
## Fenced
` + "```" + `

## Last

Last body.
`

@(private="file")
docs_root :: proc(t:^testing.T) -> string {
    directory,error:=os.make_directory_temp("","mirai-docs-*",context.temp_allocator)
    testing.expect(t,error==nil)
    root:=project.path_absolute(directory,context.temp_allocator)
    write :: proc(t:^testing.T,root,name,text:string) {
        file:=project.path(root,api.DOCS_FOLDER,name,allocator=context.temp_allocator)
        testing.expect(t,os.make_directory_all(file[:strings.last_index_byte(file,'/')])==nil)
        testing.expect(t,os.write_entire_file(file,transmute([]u8)text)==nil)
    }
    write(t,root,"core.md",DOCS_TOPIC)
    write(t,root,"core/prefabs.md","Prefab body.\n")
    write(t,root,"ship.md","---\nname: ship\ndescription: Ship a game.\n---\n\n# Ship\n")
    return root
}

// A section is its heading and what is under it, by the anchor of the heading,
// or a task file; what is unknown names what is valid and is never a path.
@(test)
docs_finds_one_section_and_names_what_is_valid :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=docs_root(t)
    defer os.remove_all(root)

    found:=[?]struct{section,has,lacks:string}{
        {"spawn-a-thing","Inner body.","First."},
        {"inner","Inner body.","Spawn body."},
        {"same","First.","Second."},
        {"same-1","Second.","First."},
        {"prefabs","Prefab body.","Intro."},
    }
    for c in found {
        text,ok:=api.docs_answer(root,"core",c.section)
        testing.expect(t,ok,c.section)
        testing.expect(t,strings.contains(text,c.has),text)
        testing.expect(t,!strings.contains(text,c.lacks),text)
    }

    wrong:=[?]struct{topic,section:string,names:[]string}{
        {"nope","",{"core","ship"}},
        {"../../secret","",{"core","ship"}},
        {"core","nope",{"spawn-a-thing","same-1","last","prefabs"}},
        {"core","fenced",{"last"}},
        {"core","../ship",{"prefabs"}},
        {"","same",{"topic"}},
    }
    for c in wrong {
        text,ok:=api.docs_answer(root,c.topic,c.section)
        testing.expect(t,!ok,text)
        for name in c.names {testing.expect(t,strings.contains(text,name),text)}
    }

    whole,_:=api.docs_answer(root,"core","")
    testing.expect(t,strings.contains(whole,"Last body."))
    index,_:=api.docs_answer(root,"","")
    testing.expect(t,strings.contains(index,"Core of a game - components, steps and phases."),index)
    testing.expect_value(t,strings.count(index,"\n"),1)

    empty,_:=os.make_directory_temp("","mirai-docs-*",context.temp_allocator)
    defer os.remove_all(empty)
    _,ok:=api.docs_answer(empty,"","")
    testing.expect(t,!ok)
    testing.expect_value(t,api.docs_compact(empty),"")
}

// The tool works without an editor: answered here, listed beside what the
// editor or the placeholder gave, and named by the instructions.
@(test)
the_docs_tool_is_answered_by_the_bridge :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=docs_root(t)
    defer os.remove_all(root)

    call :: proc(root,arguments:string) -> (text,error:string,answered:bool) {
        reply,was:=mcp_docs_call(root,strings.concatenate({`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"docs","arguments":`,arguments,"}}"}))
        content,_:=api.json_elements(api.json_member(api.json_member(reply,"result"),"content"))
        if len(content)==0 {return "","",was}
        text,_=api.json_string(api.json_member(content[0],"text"))
        return text,api.json_member(api.json_member(reply,"result"),"isError"),was
    }
    text,error,answered:=call(root,`{"topic":"core","section":"last"}`)
    testing.expect(t,answered && error=="false" && strings.contains(text,"Last body."),text)
    text,error,_=call(root,`{"topic":"nope"}`)
    testing.expect(t,error=="true" && strings.contains(text,"core"),text)
    text,error,_=call(root,`{"topic":1}`)
    testing.expect(t,error=="true" && strings.contains(text,"topic"),text)
    text,error,_=call(root,`{}`)
    testing.expect(t,error=="false" && strings.contains(text,"ship"),text)
    _,other:=mcp_docs_call(root,`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scene_inspect"}}`)
    testing.expect(t,!other,"another tool goes on to the editor")

    list,_:=mcp_no_editor("C:/games/mine",`{"jsonrpc":"2.0","id":"l","method":"tools/list"}`)
    tools,_:=api.json_elements(api.json_member(api.json_member(mcp_docs_listed(list,`{"id":"l"}`),"result"),"tools"))
    if testing.expect_value(t,len(tools),2) {
        name,_:=api.json_string(api.json_member(tools[0],"name"))
        testing.expect_value(t,name,api.MCP_DOCS_TOOL)
        testing.expect(t,api.json_valid(context.allocator,tools[0]))
    }
    none,_:=api.json_elements(api.json_member(api.json_member(mcp_docs_listed(`{"id":1,"result":{"tools":[]}}`,`{"id":1}`),"result"),"tools"))
    testing.expect_value(t,len(none),1)
    later:=`{"id":1,"result":{"tools":[]}}`
    testing.expect_value(t,mcp_docs_listed(later,`{"id":1,"params":{"cursor":"9"}}`),later)
    served:=`{"id":1,"result":{"tools":[{"name":"docs"}]}}`
    testing.expect_value(t,mcp_docs_listed(served,`{"id":1}`),served)

    reply,_:=mcp_no_editor("C:/games/mine",`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
    instructions,_:=api.json_string(api.json_member(api.json_member(mcp_docs_instructions(root,reply),"result"),"instructions"))
    testing.expect(t,strings.contains(instructions,"mirai session start"),instructions)
    testing.expect(t,strings.contains(instructions,api.DOCS_INSTRUCTION),instructions)
    testing.expect(t,strings.contains(instructions,"- core: Core of a game\n- ship: Ship a game."),instructions)
}
