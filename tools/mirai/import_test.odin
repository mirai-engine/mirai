package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "mirai:cook/build"
import "mirai:project"
import "mirai:std/base"

// An import is never run with an editor library its project's sources would
// not build: that of the project of the file, or of a root of --refresh, is
// built first while it is missing or built from other sources (the
// fingerprint of its last build no longer matches, or what the engine
// generates for it changed). What is not in a project, a store and
// what is not there build nothing.
@(test)
an_import_builds_the_editor_library_of_its_project_first_unless_it_is_current :: proc(t:^testing.T) {
    root,_:=filepath.abs(#directory+"../..",context.temp_allocator)
    folder:=base.test_folder(t,"import-library")
    if folder=="" {return}
    testing.expect(t,os.write_entire_file(project.path(folder,project.PROJECT_FILE),`{"name":"Stale","plugins":[]}`)==nil)
    testing.expect(t,base.make_directory_all(project.path(folder,"assets","props"))==nil)
    model:=project.path(folder,"assets","props","crate.glb",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(model,"glTF")==nil)
    outside:=project.path(root,"assets",allocator=context.temp_allocator)
    // The library a build left, as it leaves it: its output, what the engine
    // generated for it, the sources it read and the fingerprint of other ones.
    Library :: enum {None,Other_Sources,Other_Generation}
    stage :: proc(t:^testing.T,root,folder:string,library:Library) {
        if library==.None {return}
        p,error:=project.open(folder,root,context.temp_allocator)
        if !testing.expect(t,error.code==.None) {return}
        _,generated:=build.generated_write(&p,.Editor)
        testing.expect(t,generated)
        if library==.Other_Generation {
            world:=project.path(build.generated_root(folder,context.temp_allocator),"editor_world","world.odin",allocator=context.temp_allocator)
            text,_:=os.read_entire_file(world,context.temp_allocator)
            testing.expect(t,os.write_entire_file(world,fmt.tprintf("%s// what an engine of other components generated\n",string(text)))==nil)
        }
        work:=project.path(project.folder_path(folder,.Generated,context.temp_allocator),"build",allocator=context.temp_allocator)
        testing.expect(t,base.make_directory_all(work)==nil)
        game:=project.path(folder,"game","game.odin",allocator=context.temp_allocator)
        testing.expect(t,base.make_directory_all(project.path(folder,"game"))==nil && os.write_entire_file(game,"package game\n")==nil)
        testing.expect(t,os.write_entire_file(project.path(work,"editor.sources.json"),fmt.tprintf(`{{"source_files":["%s"],"load_files":[]}}`,base_slashes(game)))==nil)
        testing.expect(t,os.write_entire_file(project.path(work,"editor.stamp"),"0123456789abcdef")==nil)
        testing.expect(t,os.write_entire_file(project.project_library(folder,"editor",context.temp_allocator),"library")==nil)
    }
    Case :: struct {name:string,library:Library,args:[]string,stale:bool}
    cases:=[]Case{
        {"a model of a project never built",.None,{model},true},
        {"a root to refresh",.None,{"--refresh",folder},true},
        {"a store",.None,{"--store",folder,"--from",folder},false},
        {"what is not there",.None,{project.path(folder,"assets","gone.glb",allocator=context.temp_allocator)},false},
        {"what is in no project",.None,{outside},false},
        {"a library built from other sources",.Other_Sources,{model},true},
        {"a library of what an engine of other components generated",.Other_Generation,{model},true},
    }
    for c in cases {
        stage(t,root,folder,c.library)
        stale:=import_libraries_stale(root,c.args,.Dev)
        testing.expectf(t,(len(stale)==1 && stale[0]==project.path_absolute(folder,context.temp_allocator))==c.stale && (c.stale || len(stale)==0),"%s: %v",c.name,stale)
    }
}

@(private="file")
base_slashes :: proc(path:string) -> string {
    out:=transmute([]u8)fmt.tprint(path)
    for &c in out {if c=='\\' {c='/'}}
    return string(out)
}
