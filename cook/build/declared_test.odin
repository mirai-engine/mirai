package build

import "core:odin/ast"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:project"

// A test world (core.Test_World) reads the attributes of the type of each
// of its fields from the lines of its source, and the generator from the
// parsed source: for every component and storage of the engine and of its
// plugins both read the same options, so a test world describes them as a
// generated one does.
@(test)
a_test_world_reads_the_attributes_of_a_declaration_as_the_generator_does :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    root:=project.path_absolute(project.path(#directory,"../..",allocator=context.temp_allocator),context.temp_allocator)
    folders:=make([dynamic]string)
    for top in ([]string{"core","engine","editor","plugins"}) {folders_add(&folders,project.path(root,top))}
    checked:=0
    for folder in folders {
        errors:=make([dynamic]string)
        _,files,_:=sources_read(folder,&errors)
        for file in files {
            for stmt in file.decls {
                decl,is_value:=stmt.derived.(^ast.Value_Decl)
                if !is_value || len(decl.names)!=1 || len(decl.values)!=1 {continue}
                options:=attributes_read(decl.attributes[:])
                _,component:=options["component"]
                _,storage:=options["storage"]
                if !component && !storage {continue}
                at:=decl.names[0].pos
                read:=core.test_declared_options(file.src,at.line,at.column)
                same:=len(read)==len(options)
                for name,value in options {
                    other,found:=read[name]
                    same&&=found && other==value
                }
                testing.expectf(t,same,"%s(%d:%d): the generator reads %v and a test world %v",file.fullpath,at.line,at.column,options,read)
                checked+=1
            }
        }
    }
    testing.expect(t,checked>0)
}

@(private="file")
folders_add :: proc(folders:^[dynamic]string,folder:string) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    sources:=false
    for entry in entries {
        if entry.type==.Directory {
            if !strings.has_prefix(entry.name,".") && entry.name!="testdata" {folders_add(folders,project.path(folder,entry.name))}
        } else if strings.has_suffix(entry.name,".odin") && !strings.has_suffix(entry.name,"_test.odin") {
            sources=true
        }
    }
    if sources {append(folders,folder)}
}
