package build

import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
release_steps_run_from_the_game_loop_with_the_id_of_the_world :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"release")
    if folder=="" {return}
    engine:=project.path(folder,"engine",allocator=context.temp_allocator)
    game:=project.path(folder,"project",allocator=context.temp_allocator)
    for path in ([]string{project.path(engine,"core",allocator=context.temp_allocator),project.path(engine,"editor",allocator=context.temp_allocator),project.path(game,"game",allocator=context.temp_allocator)}) {
        if !testing.expect(t,os.make_directory_all(path)==nil) {return}
    }
    source:=`package core
import "mirai:host"
@(storage,copy=false) World_Id :: struct {index,generation:u32}
@(storage,host) Pools :: struct {count:u32}
@(step="release")
pools_release :: proc(pools:^Pools,id:World_Id,app:^host.App) {}
@(step="release",loops="game editor")
later_release :: proc(pools:^Pools) {}
`
    testing.expect_value(t,os.write_entire_file(project.path(engine,"core","pools.odin",allocator=context.temp_allocator),source),nil)
    p:=project.Project{root=game,engine_root=engine}
    output:=world_generate(&p,context.temp_allocator)
    if !testing.expect_value(t,len(output.errors),0) {return}
    for text in ([]string{output.game_world,output.editor_world}) {
        testing.expect(t,strings.contains(text,"game_release :: proc"))
        testing.expect(t,strings.contains(text,"info.loops[.Game][.Release],info.order[.Game][.Release]=game_release,order_game_release[:]"))
        testing.expect(t,strings.contains(text,"p_core.pools_release(&s.pools,w.world_id,app)"))
        testing.expect(t,strings.contains(text,"game_release :: proc(world,shared,editor:rawptr,app_data:rawptr) {\n    call_pools_release(world,shared,editor,app_data)\n    call_later_release(world,shared,editor,app_data)\n}"))
        testing.expect(t,!strings.contains(text,"&dst.world_id") && !strings.contains(text,"a.world_id,b.world_id="))
    }
    // The application runs release from the game loop alone: an editor package has none.
    editor_source:=`package editor
@(step="release")
editor_release_attempt :: proc() {}
`
    testing.expect_value(t,os.write_entire_file(project.path(engine,"editor","release.odin",allocator=context.temp_allocator),editor_source),nil)
    output=world_generate(&p,context.temp_allocator)
    found:=false
    for message in output.errors {found||=strings.contains(message,"editor_release_attempt runs in release")}
    testing.expect(t,found)
}
