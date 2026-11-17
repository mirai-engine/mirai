package main

import "core:os"
import "core:path/filepath"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// An import is never run with an editor library its project's sources would
// not build: that of the project of the file, or of a root of --sync, is
// built first while it is missing or built from other sources. What is not
// in a project, a cache folder and what is not there build nothing.
@(test)
an_import_builds_the_editor_library_of_its_project_first_unless_it_is_current :: proc(t:^testing.T) {
    root,_:=filepath.abs(#directory+"../..",context.temp_allocator)
    folder:=base.test_folder(t,"import-library")
    if folder=="" {return}
    testing.expect(t,os.write_entire_file(project.path(folder,project.PROJECT_FILE),`{"name":"Stale","plugins":[]}`)==nil)
    testing.expect(t,os.make_directory_all(project.path(folder,"assets","props"))==nil)
    model:=project.path(folder,"assets","props","crate.glb",allocator=context.temp_allocator)
    testing.expect(t,os.write_entire_file(model,"glTF")==nil)
    outside:=project.path(root,"assets",allocator=context.temp_allocator)
    Case :: struct {name:string,args:[]string,stale:bool}
    cases:=[]Case{
        {"a model of the project",{model},true},
        {"a root to sync",{"--sync",folder},true},
        {"a cache folder",{"--texture-cache",folder,"--mesh-cache",folder},false},
        {"what is not there",{project.path(folder,"assets","gone.glb",allocator=context.temp_allocator)},false},
        {"what is in no project",{outside},false},
    }
    for c in cases {
        stale:=import_libraries_stale(root,c.args,.Dev)
        testing.expectf(t,(len(stale)==1 && stale[0]==project.path_absolute(folder,context.temp_allocator))==c.stale && (c.stale || len(stale)==0),"%s: %v",c.name,stale)
    }
}
