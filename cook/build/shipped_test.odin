package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// What the library of a game depends on moves its key, each by itself; an
// edit of the game alone leaves the library that stands.
@(test)
the_key_of_the_shipped_engine_follows_everything_it_is_built_from :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"shipped")
    if folder=="" {return}
    root:=project.path(folder,"engine",allocator=context.temp_allocator)
    path:=proc(root,file:string) -> string {return project.path(root,file,allocator=context.temp_allocator)}
    compiler:=path(root,"tools/odin.exe")
    game:=path(folder,"project/game/game.odin")
    files:=[][2]string{
        {path(root,"core/a.odin"),"package core\nICON :: #load(\"icon.bin\")\n"},
        {path(root,"core/icon.bin"),"icon"},
        {path(root,"core/windows/thing.lib"),"library"},
        {path(root,"plugins/physics/runtime/p.odin"),"package physics\n"},
        {compiler,"compiler"},
        {game,"package game\n"},
    }
    write:=proc(t:^testing.T,file,text:string) -> bool {
        at:=file[:strings.last_index_byte(file,'/')]
        return testing.expect(t,(os.make_directory_all(at)==nil || os.is_dir(at)) && os.write_entire_file(file,text)==nil)
    }
    for file in files {
        if !write(t,file[0],file[1]) {return}
    }
    engine:=[]string{"core"}
    plugins:=[]string{"physics/runtime"}
    flags:=[]string{"-o:speed","-define:A=1"}
    key:=proc(root,compiler:string,flags,engine,plugins:[]string) -> u64 {
        hash,_:=shipped_engine_key(root,compiler,flags,engine,plugins,context.temp_allocator)
        return hash
    }
    before:=key(root,compiler,flags,engine,plugins)
    testing.expect_value(t,key(root,compiler,flags,engine,plugins),before)
    if !write(t,game,"package game\n// another line\n") {return}
    testing.expect_value(t,key(root,compiler,flags,engine,plugins),before)

    Change :: struct {name,file,text:string}
    changes:=[]Change{
        {"an engine source",path(root,"core/a.odin"),"package core\nICON :: #load(\"icon.bin\")\nX :: 1\n"},
        {"a new engine source",path(root,"core/b.odin"),"package core\n"},
        {"what a source loads",path(root,"core/icon.bin"),"other icon"},
        {"a static library",path(root,"core/windows/thing.lib"),"other library"},
        {"a plugin source",path(root,"plugins/physics/runtime/p.odin"),"package physics\nY :: 2\n"},
        {"the compiler",compiler,"another compiler"},
    }
    for change in changes {
        if !write(t,change.file,change.text) {return}
        now:=key(root,compiler,flags,engine,plugins)
        testing.expectf(t,now!=before,"%s does not move the key",change.name)
        before=now
    }
    alternatives:=[]struct{name:string,flags:[]string}{
        {"a define",[]string{"-o:speed","-define:A=2"}},
        {"the optimization",[]string{"-o:size","-define:A=1"}},
        {"the target",[]string{"-o:speed","-define:A=1","-target:linux_amd64"}},
    }
    for other in alternatives {
        testing.expectf(t,key(root,compiler,other.flags,engine,plugins)!=before,"%s does not move the key",other.name)
    }
    testing.expectf(t,key(root,compiler,flags,engine,{})!=before,"the plugins that ship do not move the key")
}

// A file the compiler loaded that the key did not count leaves the library
// out of the cache; those of the compiler are the compiler.
@(test)
a_load_the_key_did_not_count_is_found_after_the_compile :: proc(t:^testing.T) {
    loads:=[]string{"C:/engine/render/shaders.bin"}
    compiler:="C:/odin/odin.exe"
    testing.expect(t,shipped_loads_covered({"C:/engine/render/a.odin","c:/engine/render/shaders.bin","C:/odin/vendor/x.bin"},loads,compiler))
    testing.expect(t,!shipped_loads_covered({"C:/engine/assets/font.ttf"},loads,compiler))
}
