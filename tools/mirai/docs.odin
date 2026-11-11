package main

import "core:fmt"
import "mirai:editor/api"

DOCS_USAGE :: "docs [topic] [section]"

// mirai docs [topic] [section]: what the docs tool of MCP answers.
cmd_docs :: proc(root:string,args:[]string) -> int {
    if code:=positionals_only("docs",args);code!=0 {return code}
    if len(args)>2 {return argument_unknown("docs",args[2])}
    text,ok:=api.docs_answer(root,len(args)>0?args[0]:"",len(args)>1?args[1]:"")
    if !ok {fmt.eprintfln("mirai docs: %s",text);return 1}
    fmt.println(text)
    return 0
}
