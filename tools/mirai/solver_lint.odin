package main

import "core:fmt"
import "core:odin/ast"
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

// Prints where a source imports the solver. False when it does.
solver_lint_print :: proc(file:^ast.File) -> bool {
    line,column,found:=solver_import(file)
    if found {fmt.eprintfln("%s(%d:%d) Error: `%s` is the solver of the physics plugin, which only that plugin imports. Import `plugins:physics/runtime` instead: a library makes bodies of its own with physics.owned_body_create and its shapes with physics.owned_shape_create, makes what breaks with physics.breakable_create, moves the bodies of entities through physics.Body_Requests, and reads the simulation with the queries of physics (physics.body_info for a body); a test or a tool without a world makes a simulation with physics.state_make and steps it with physics.simulate.",file.fullpath,line,column,SOLVER_IMPORT)}
    return !found
}

// Where a parsed source imports the solver.
solver_import :: proc(file:^ast.File) -> (line,column:int,found:bool) {
    for decl in file.imports {
        if strings.trim(decl.fullpath,"\"`")==SOLVER_IMPORT {return decl.pos.line,decl.pos.column,true}
    }
    return
}
