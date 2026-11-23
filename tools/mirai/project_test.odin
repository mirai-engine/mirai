package main

import "core:os"
import "core:path/filepath"
import "core:testing"
import kai_assets "mirai:cook/kai"
import "mirai:project"
import "mirai:std/base"

// mirai new makes the project a Kai workspace of its own in the store it is
// given; with --no-kai the project has no version control and the store is
// not touched.
@(test)
mirai_new_makes_a_kai_workspace_unless_told_no_kai :: proc(t:^testing.T) {
    root,_:=filepath.abs(#directory+"../..",context.temp_allocator)
    folder:=base.test_folder(t,"new-kai")
    if folder=="" {return}
    store_root:=project.path(folder,"store",allocator=context.temp_allocator)
    Case :: struct {name:string,args:[]string,kai:bool}
    cases:=[]Case{
        {"with",{"--store",store_root},true},
        {"without",{"--store",store_root,"--no-kai"},false},
    }
    // A command lives as long as the process: what it keeps goes with the test's temp memory.
    context.allocator=context.temp_allocator
    for c in cases {
        made:=project.path(folder,c.name,allocator=context.temp_allocator)
        args:=make([dynamic]string,context.temp_allocator)
        append(&args,made)
        append(&args,..c.args)
        if !testing.expectf(t,cmd_new(root,args[:])==0,"mirai new %s",c.name) {continue}
        testing.expect(t,os.exists(project.path(made,project.PROJECT_FILE,allocator=context.temp_allocator)))
        testing.expectf(t,kai_assets.project_exists(made)==c.kai,"%s: a Kai workspace is %v",c.name,c.kai)
    }
}
