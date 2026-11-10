package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:project"

// The solver of physics is the model of its plugin: what is legal between two of its steps, its handles and
// its flags are known to the integration (plugins:physics/runtime), which the other plugins and the games use.
SOLVER_IMPORT :: "plugins:physics/runtime/sim"

// The only plugin whose packages import the solver.
@(private="file")
SOLVER_PLUGIN :: "physics"

// Whether mirai check looks for an import of the solver in folder: any package of the engine at root, its
// tools and the games of its demo and templates included, but those of the physics plugin.
solver_lint_applies :: proc(root,folder:string) -> bool {
    inside:=project.path_absolute(folder,context.temp_allocator)
    engine:=strings.trim_right(project.path_absolute(root,context.temp_allocator),"/")
    if !path_inside(inside,engine) || len(inside)<=len(engine) {return false}
    parts:=strings.split(inside[len(engine)+1:],"/",context.temp_allocator)
    return !(len(parts)>=2 && parts[0]=="plugins" && project.path_same(parts[1],SOLVER_PLUGIN))
}

// Prints the sources of a package, its tests included, that import the solver. False when there is one or a
// source does not parse.
solver_lint_package :: proc(folder:string) -> bool {
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    clean:=true
    for entry in entries {
        if entry.type!=.Regular || !strings.has_suffix(entry.name,".odin") {continue}
        data,error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if error!=nil {fmt.eprintfln("mirai check: could not read %s",entry.fullpath);clean=false;continue}
        line,column,found,parsed:=solver_lint_source(entry.fullpath,string(data))
        if !parsed {clean=false}
        if !found {continue}
        clean=false
        fmt.eprintfln("%s(%d:%d) Error: `%s` is the solver of the physics plugin, which only that plugin imports. Import `plugins:physics/runtime` instead: a library makes bodies of its own with physics.owned_body_create and its shapes with physics.owned_shape_create, makes what breaks with physics.breakable_create, moves the bodies of entities through physics.Body_Requests, and reads the simulation with the queries of physics (physics.body_info for a body); a test or a tool without a world makes a simulation with physics.state_make and steps it with physics.simulate.",entry.fullpath,line,column,SOLVER_IMPORT)
    }
    return clean
}

// Where a source imports the solver. parsed is false when it does not parse: the parser has printed where.
solver_lint_source :: proc(path,text:string) -> (line,column:int,found,parsed:bool) {
    context.allocator=context.temp_allocator
    file:=ast.File{src=text,fullpath=path}
    p:=parser.default_parser()
    if !parser.parse_file(&p,&file) || file.syntax_error_count>0 {return}
    for decl in file.imports {
        if strings.trim(decl.fullpath,"\"`")==SOLVER_IMPORT {return decl.pos.line,decl.pos.column,true,true}
    }
    return 0,0,false,true
}
