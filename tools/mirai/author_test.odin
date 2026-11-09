package main

import "core:slice"
import "core:testing"

// mirai ui and mirai scene hand the author program of the engine the project
// and the engine before what the command was given, in its order.
@(test)
the_author_program_is_told_the_project_and_the_engine_it_works_for :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder,rest,ok:=author_project_take({"write","source","--project","games/arena","hud.ui.json"})
    testing.expect(t,ok && folder=="games/arena" && slice.equal(rest,[]string{"write","source","hud.ui.json"}))
    folder,rest,ok=author_project_take({"check"})
    testing.expect(t,ok && folder=="." && slice.equal(rest,[]string{"check"}))
    _,_,ok=author_project_take({"check","--project"})
    testing.expect(t,!ok,"--project without a folder is a misuse")
    command:=author_command("/m/.mirai/engine/dev/mirai-author","/m","/p","scene",{"read","arena/main.scene","--out","main.json"})
    testing.expect(t,slice.equal(command[:],[]string{"/m/.mirai/engine/dev/mirai-author","--project","/p","--engine","/m","scene","read","arena/main.scene","--out","main.json"}))
}
