package main

import "core:odin/parser"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// The tool writes render/shaders_gen.odin, so it builds without the engine:
// after a change of the shaders the new tool must compile against stale
// tables, and the old one cannot write the new ones. The compiler reads the
// _test.odin files of every imported package too, so those count.
@(test)
the_tool_imports_no_package_of_the_engine :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root,_:=filepath.abs(#directory+"../..")
    engine:=[]string{"render","host","editor","platform"}
    from:=map[string]string{}
    from["tools/mirai"]=""
    queue:=[dynamic]string{}
    append(&queue,"tools/mirai")
    for len(queue)>0 {
        name:=pop_front(&queue)
        collected,ok:=parser.collect_package(join(root,name))
        if !testing.expectf(t,ok,"%s could not be read",name) {return}
        p:=parser.default_parser()
        p.err=proc(pos:tokenizer.Pos,format:string,args:..any) {}
        if !testing.expectf(t,parser.parse_package(collected,&p),"%s does not parse",name) {return}
        for _,file in collected.files {
            for decl in file.imports {
                imported:=strings.trim(decl.fullpath,"\"`")
                if !strings.has_prefix(imported,"mirai:") {continue}
                imported=imported[len("mirai:"):]
                if imported in from {continue}
                from[imported]=name
                if !slice.contains(engine,imported) && !strings.has_prefix(imported,"engine/") {
                    append(&queue,imported)
                    continue
                }
                chain:=imported
                for at:=name;at!="";at=from[at] {chain=strings.concatenate({at," -> ",chain})}
                testing.expectf(t,false,"%s imports %s: %s",filepath.base(file.fullpath),imported,chain)
            }
        }
    }
}
