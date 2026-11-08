package main

import "core:fmt"
import "core:strings"
import "mirai:editor/api"

DOCS_USAGE :: "docs [topic] [section]"

// mirai docs [topic] [section]: what the docs tool of MCP answers.
cmd_docs :: proc(root:string,args:[]string) -> int {
    if len(args)>2 || len(args)>0 && strings.has_prefix(args[0],"-") {fmt.eprintfln("Usage: mirai %s",DOCS_USAGE);return 2}
    text,ok:=api.docs_answer(root,len(args)>0?args[0]:"",len(args)>1?args[1]:"")
    if !ok {fmt.eprintfln("mirai docs: %s",text);return 1}
    fmt.println(text)
    return 0
}
