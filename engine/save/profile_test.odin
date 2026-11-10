package save

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"

@(private="file")
@(storage,persist)
Progress :: struct {
    level:i32,
    best:f32,
}

// The same progress after the game added a field before the ones it had.
@(private="file")
@(storage,persist)
Progress_Next :: struct {
    unlocked:bool,
    best:f32,
    level:i32,
}

@(private="file")
Profile_World :: struct {
    using world:core.Test_World,
    progress:Progress `mirai:"game"`,
}

@(private="file")
Profile_Next_World :: struct {
    using world:core.Test_World,
    progress:Progress_Next `mirai:"game,name=Progress"`,
}

// The progress goes to the profile and comes back; a storage whose layout
// changed reads it by the names of its fields and keeps the value of a new one.
@(test)
the_progress_of_the_player_comes_back_from_the_profile :: proc(t:^testing.T) {
    root:=base.test_folder(t,"engine-save-profile")
    if root=="" {return}
    app:host.App
    state:Save_State
    defer delete(state.folder)
    app.allocator=context.allocator
    folder_set(&state,app.allocator,fmt.tprintf("%s/saves",root))

    w:Profile_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    ref:=core.test_world_ref(&w)

    testing.expect_value(t,profile_read(ref,&app,&state),Error.Not_Found)
    w.progress={level=3,best=41.5}
    if !testing.expect_value(t,profile_write(ref,&app,&state),Error.None) {return}
    path,_:=profile_path(&state,&app)
    testing.expect(t,os.is_file(path))

    w.progress={}
    testing.expect_value(t,profile_read(ref,&app,&state),Error.None)
    testing.expect_value(t,w.progress,Progress{level=3,best=41.5})

    next:Profile_Next_World
    if !core.test_world_init(t,&next) {return}
    defer core.test_world_destroy(&next)
    next.progress={unlocked=true}
    testing.expect_value(t,profile_read(core.test_world_ref(&next),&app,&state),Error.None)
    testing.expect_value(t,next.progress,Progress_Next{unlocked=true,best=41.5,level=3})
}

@(private="file")
@(storage,persist)
Progress_Kept :: struct {
    level:i32,
    shown:i32 `mirai:"transient"`,
}

@(private="file")
@(storage,persist)
Progress_Named :: struct {
    level:i32,
    name:string,
}

@(private="file")
Profile_Kept_World :: struct {
    using world:core.Test_World,
    kept:Progress_Kept `mirai:"game,name=Progress"`,
}

@(private="file")
Profile_Named_World :: struct {
    using world:core.Test_World,
    kept:Progress_Kept `mirai:"game,name=Progress"`,
    named:Progress_Named `mirai:"game,name=Named"`,
}

// The profile keeps a storage as its schema saves it, without its transient
// fields; one it cannot hold is a problem that names it, and nothing is
// written nor read.
@(test)
the_profile_names_a_storage_it_cannot_hold :: proc(t:^testing.T) {
    root:=base.test_folder(t,"engine-save-profile-named")
    if root=="" {return}
    app:host.App
    state:Save_State
    defer delete(state.folder)
    app.allocator=context.allocator
    folder_set(&state,app.allocator,fmt.tprintf("%s/saves",root))
    w:Profile_Kept_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    both:Profile_Named_World
    if !core.test_world_init(t,&both) {return}
    defer core.test_world_destroy(&both)
    // The profile names a storage by its library: that of these is this package, not the game.
    for &storage in core.test_world_info(&both).storages {storage.library="game"}
    problems:core.Problems

    w.kept={level=2,shown=9}
    if !testing.expect_value(t,profile_write(core.test_world_ref(&w),&app,&state,&problems),Error.None) {return}
    w.kept={}
    testing.expect_value(t,profile_read(core.test_world_ref(&w),&app,&state,&problems),Error.None)
    testing.expect_value(t,w.kept,Progress_Kept{level=2})

    both.kept={level=5}
    testing.expect_value(t,profile_write(core.test_world_ref(&both),&app,&state,&problems),Error.Failed)
    testing.expect_value(t,problems.count,1)
    text:=core.problem_text(&problems.entries[0])
    testing.expectf(t,strings.contains(text,"game/Named") && strings.contains(text,"name"),"%s",text)
    testing.expect_value(t,profile_read(core.test_world_ref(&both),&app,&state,&problems),Error.Failed)
    testing.expect_value(t,both.kept,Progress_Kept{level=5})
    w.kept={}
    testing.expect_value(t,profile_read(core.test_world_ref(&w),&app,&state,&problems),Error.None)
    testing.expect_value(t,w.kept.level,i32(2))
}

// The profile is written by itself once its value rests (project.Rest), and
// at the latest when the world goes. A world that changed nothing writes nothing.
@(test)
the_profile_is_written_by_itself_when_it_rests_and_when_the_world_goes :: proc(t:^testing.T) {
    root:=base.test_folder(t,"engine-save-profile-kept")
    if root=="" {return}
    app:host.App
    state:Save_State
    defer delete(state.folder)
    app.allocator=context.allocator
    folder_set(&state,app.allocator,fmt.tprintf("%s/saves",root))
    path,_:=profile_path(&state,&app)
    w:Profile_World
    if !core.test_world_init(t,&w) {return}
    defer core.test_world_destroy(&w)
    ref:=core.test_world_ref(&w)
    work:Save_Work
    problems:core.Problems
    written :: proc(ref:core.World_Ref,app:^host.App,state:^Save_State) -> i32 {
        w:=(^Profile_World)(ref.data)
        kept:=w.progress
        defer w.progress=kept
        w.progress={}
        if profile_read(ref,app,state)!=.None {return -1}
        return w.progress.level
    }

    kept_watch(&work,ref,&app,&state,0,&problems)
    kept_watch(&work,ref,&app,&state,project.REST_LOOK,&problems)
    testing.expect(t,!os.is_file(path),"nothing changed: nothing is written")

    w.progress.level=1
    kept_watch(&work,ref,&app,&state,project.REST_LOOK/2,&problems)
    testing.expect(t,!os.is_file(path),"before the next look")
    kept_watch(&work,ref,&app,&state,project.REST_LOOK/2,&problems)
    testing.expect(t,!os.is_file(path),"the look that sees the change waits for it to rest")
    kept_watch(&work,ref,&app,&state,project.REST_LOOK,&problems)
    testing.expect_value(t,written(ref,&app,&state),i32(1))

    w.progress.level=77
    kept_flush(&work,ref,&app,&state,&problems)
    testing.expect_value(t,written(ref,&app,&state),i32(77))
    testing.expect_value(t,problems.count,0)

    other:Save_Work
    w.progress.level=88
    kept_flush(&other,ref,&app,&state,&problems)
    testing.expect_value(t,written(ref,&app,&state),i32(77))
}
