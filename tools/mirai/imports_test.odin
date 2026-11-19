package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "mirai:std/base"

// A build of the tool that read a package of the engine is not published,
// and the last build of this checkout's tool read none. The compiler reads
// the _test.odin files of every imported package too, so those count.
@(test)
the_tool_reads_no_package_of_the_engine :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    engine,_:=filepath.abs(#directory+"../..")
    testing.expect_value(t,tool_engine_read(engine,build_sources_file(engine,"mirai")),"")
    root:=base.test_folder(t,"tool-reads")
    if root=="" {return}
    cases:=[?]struct{sources:[]string,read:string}{
        {{"tools/mirai/main.odin","render/abi/abi.odin","editor/api/client.odin"},""},
        {{"tools/mirai/main.odin","render/shaders_gen.odin"},"render/shaders_gen.odin"},
        {{"cook/build/build.odin","engine/render/render_test.odin"},"engine/render/render_test.odin"},
        {{"host/host.odin"},"host/host.odin"},
    }
    sources:=join(root,"sources.json")
    for c in cases {
        list:=make([dynamic]string)
        for file in c.sources {append(&list,fmt.aprintf(`"%s/%s"`,root,file))}
        testing.expect(t,os.write_entire_file(sources,strings.concatenate({`{"source_files":[`,strings.join(list[:],","),`],"load_files":[]}`}))==nil)
        testing.expect_value(t,tool_engine_read(root,sources),c.read)
    }
}
