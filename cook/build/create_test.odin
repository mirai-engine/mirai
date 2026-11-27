package build

import "core:os"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
a_new_project_gets_what_the_templates_share :: proc(t:^testing.T) {
    engine:=base.test_folder(t,"create")
    if engine=="" {return}
    write :: proc(t:^testing.T,file,text:string,loc:=#caller_location) {
        testing.expect(t,os.make_directory_all(file[:len(file)-len("/x")])==nil || os.is_dir(file[:len(file)-len("/x")]),loc=loc)
        testing.expect(t,os.write_entire_file(file,text)==nil,loc=loc)
    }
    join :: proc(parts:..string) -> string {return project.path(..parts,allocator=context.temp_allocator)}
    write(t,join(engine,"templates/common/.claude/x"),"shared")
    write(t,join(engine,"templates/common/x"),"shared")
    write(t,join(engine,"templates/small/x2"),"own")
    write(t,join(engine,"templates/small",project.PROJECT_FILE),`{"name": "Small", "build": {"compression": "none"}}`)

    listed:=templates_list(engine,context.temp_allocator)
    testing.expect_value(t,len(listed),1)
    testing.expect_value(t,listed[0].name,"small")

    folder:=join(engine,"made")
    testing.expect_value(t,project_create(template_folder(engine,"small",context.temp_allocator),folder,"Made"),Create_Error.None)
    for file in ([]string{"x","x2",".claude/x"}) {testing.expectf(t,os.is_file(join(folder,file)),"%s is missing",file)}
    m,read_error:=project.manifest_read(join(folder,project.PROJECT_FILE))
    testing.expect_value(t,read_error.code,project.Error_Code.None)
    testing.expect_value(t,string(m.name[:4]),"Made")
    testing.expect(t,base.text_get(m.build.compression[:])=="none","a new project uses the compression of its template")
}

// Cleaning the build cache of a project removes what its builds, the refresh of its assets and
// its shaders make again, and leaves its Kai workspace, its files and what an editor keeps for a
// person.
@(test)
cleaning_the_build_cache_keeps_the_kai_workspace_and_the_project :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cache-clean")
    if folder=="" {return}
    join :: proc(parts:..string) -> string {return project.path(..parts,allocator=context.temp_allocator)}
    write :: proc(t:^testing.T,file:string,loc:=#caller_location) {
        dir,_:=os.split_path(file)
        testing.expect(t,base.make_directory_all(dir)==nil,loc=loc)
        testing.expect(t,os.write_entire_file(file,"x")==nil,loc=loc)
    }
    gone:=[]string{".mirai/build/editor.stamp",".mirai/shaders/a.metallib",".mirai/gen/world.odin",".mirai/cache/registry",".mirai/plugins/lib/a.dylib",".mirai/shader-cache/generation.json",join(".mirai",project.library_file("editor",context.temp_allocator))}
    kept:=[]string{project.PROJECT_FILE,"assets/level.scene","packages.mirai",".mirai/kai/workspace",".mirai/ai/chat.json",".mirai/thumbs/a.png",".mirai/session.json",join(".mirai",project.library_file("game",context.temp_allocator))}
    for path in gone {write(t,join(folder,path))}
    for path in kept {write(t,join(folder,path))}
    removed,e:=cache_clean(folder)
    testing.expect_value(t,e,nil)
    testing.expect_value(t,removed,len(gone))
    for path in gone {testing.expectf(t,!os.exists(join(folder,path)),"%s is removed",path)}
    for path in kept {testing.expectf(t,os.is_file(join(folder,path)),"%s stays",path)}
    removed,e=cache_clean(folder)
    testing.expect(t,removed==0 && e==nil,"a clean project has nothing to remove")
}
