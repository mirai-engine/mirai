package main

import "core:slice"
import "core:strings"
import "mirai:cook/build"
import "core:testing"

// mirai ui and mirai scene hand the author program of the engine the project
// and the engine before what the command was given, in its order.
@(test)
the_author_program_is_told_the_project_and_the_engine_it_works_for :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,rest,ok:=author_project_take({"write","hud/hud.ui","--project","games/arena","hud.json"})
    testing.expect(t,ok && folder=="games/arena" && slice.equal(rest,[]string{"write","hud/hud.ui","hud.json"}))
    folder,rest,ok=author_project_take({"check"})
    testing.expect(t,ok && folder=="." && slice.equal(rest,[]string{"check"}))
    _,_,ok=author_project_take({"check","--project"})
    testing.expect(t,!ok,"--project without a folder is a misuse")
    command:=author_command("/m/.mirai/engine/dev/mirai-author","/m","/p","scene",{"read","arena/main.scene","--out","main.json"})
    testing.expect(t,slice.equal(command[:],[]string{"/m/.mirai/engine/dev/mirai-author","--project","/p","--engine","/m","scene","read","arena/main.scene","--out","main.json"}))
}

// Only reading an interface goes on without the library of the project; what
// is missing or stale is refused with the command that builds it.
@(test)
a_command_that_reads_the_types_of_the_game_needs_its_library_current :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    testing.expect(t,!author_needs_library("ui",{"read","hud/hud.ui"}))
    testing.expect(t,author_needs_library("ui",{"write","hud/hud.ui","hud.json"}) && author_needs_library("ui",{"check"}) && author_needs_library("scene",{"read","a.scene"}))
    testing.expect_value(t,author_library_problem(.Current,"/p",true),"")
    for state in ([]build.Target_State{.Missing,.Stale}) {
        problem:=author_library_problem(state,"/p",true)
        testing.expect(t,strings.contains(problem,`mirai build editor "/p" --dev`),problem)
    }
}
