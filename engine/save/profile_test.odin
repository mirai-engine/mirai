package save

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:host"

@(private="file")
Progress :: struct {
    level:i32,
    best:f32,
}

// The same progress after the game added a field before the ones it had.
@(private="file")
Progress_Next :: struct {
    unlocked:bool,
    best:f32,
    level:i32,
}

@(private="file")
Profile_World :: struct {
    entities:core.Entities,
    progress:Progress,
    next:Progress_Next,
}

@(private="file")
profile_info :: proc(storages:^[1]core.Storage_Info,type:typeid,offset:uintptr) -> core.World_Info {
    storages[0]={name="Progress",library="game",type=type,info=type_info_of(type),offset=offset,place=.World,persist=true}
    info:=core.World_Info{entities=offset_of(Profile_World,entities),storages=storages[:]}
    info.sizes[.World],info.aligns[.World]=size_of(Profile_World),align_of(Profile_World)
    return info
}

// The progress goes to the profile and comes back; a storage whose layout
// changed reads it by the names of its fields and keeps the value of a new one.
@(test)
the_progress_of_the_player_comes_back_from_the_profile :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-engine-save-profile-%d",directory,os.get_pid())
    os.remove_all(root)
    defer os.remove_all(root)
    app:host.App
    state:Save_State
    defer delete(state.folder)
    app.allocator=context.allocator
    folder_set(&state,&app,fmt.tprintf("%s/saves",root))

    storages:[1]core.Storage_Info
    w:Profile_World
    info:=profile_info(&storages,Progress,offset_of(Profile_World,progress))
    ref:=core.world_ref(&w,&info)

    testing.expect_value(t,profile_read(ref,&app,&state),Error.Not_Found)
    w.progress={level=3,best=41.5}
    if !testing.expect_value(t,profile_write(ref,&app,&state),Error.None) {return}
    path,_:=profile_path(&state,&app)
    testing.expect(t,os.is_file(path))

    w.progress={}
    testing.expect_value(t,profile_read(ref,&app,&state),Error.None)
    testing.expect_value(t,w.progress,Progress{level=3,best=41.5})

    next_storages:[1]core.Storage_Info
    next_info:=profile_info(&next_storages,Progress_Next,offset_of(Profile_World,next))
    w.next={unlocked=true}
    testing.expect_value(t,profile_read(core.world_ref(&w,&next_info),&app,&state),Error.None)
    testing.expect_value(t,w.next,Progress_Next{unlocked=true,best=41.5,level=3})
}

@(private="file")
Progress_Kept :: struct {
    level:i32,
    shown:i32 `mirai:"transient"`,
}

@(private="file")
Progress_Named :: struct {
    level:i32,
    name:string,
}

@(private="file")
Profile_Other_World :: struct {
    entities:core.Entities,
    kept:Progress_Kept,
    named:Progress_Named,
}

// The profile keeps a storage as its schema saves it, without its transient
// fields; one it cannot hold is a problem that names it, and nothing is
// written nor read.
@(test)
the_profile_names_a_storage_it_cannot_hold :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-engine-save-profile-named-%d",directory,os.get_pid())
    os.remove_all(root)
    defer os.remove_all(root)
    app:host.App
    state:Save_State
    defer delete(state.folder)
    app.allocator=context.allocator
    folder_set(&state,&app,fmt.tprintf("%s/saves",root))
    w:Profile_Other_World
    problems:core.Problems

    kept:=[1]core.Storage_Info{{name="Progress",library="game",type=Progress_Kept,info=type_info_of(Progress_Kept),offset=offset_of(Profile_Other_World,kept),place=.World,persist=true}}
    info:=core.World_Info{entities=offset_of(Profile_Other_World,entities),storages=kept[:]}
    w.kept={level=2,shown=9}
    if !testing.expect_value(t,profile_write(core.world_ref(&w,&info),&app,&state,&problems),Error.None) {return}
    w.kept={}
    testing.expect_value(t,profile_read(core.world_ref(&w,&info),&app,&state,&problems),Error.None)
    testing.expect_value(t,w.kept,Progress_Kept{level=2})

    both:=[2]core.Storage_Info{kept[0],{name="Named",library="game",type=Progress_Named,info=type_info_of(Progress_Named),offset=offset_of(Profile_Other_World,named),place=.World,persist=true}}
    info.storages=both[:]
    w.kept={level=5}
    testing.expect_value(t,profile_write(core.world_ref(&w,&info),&app,&state,&problems),Error.Failed)
    testing.expect_value(t,problems.count,1)
    text:=core.problem_text(&problems.entries[0])
    testing.expectf(t,strings.contains(text,"game/Named") && strings.contains(text,"name"),"%s",text)
    testing.expect_value(t,profile_read(core.world_ref(&w,&info),&app,&state,&problems),Error.Failed)
    testing.expect_value(t,w.kept,Progress_Kept{level=5})
    info.storages=kept[:]
    w.kept={}
    testing.expect_value(t,profile_read(core.world_ref(&w,&info),&app,&state,&problems),Error.None)
    testing.expect_value(t,w.kept.level,i32(2))
}

// The profile is written by itself once its value rests: not while it keeps
// changing, unless it never rests, and at the latest when the world goes. A
// world that changed nothing writes nothing.
@(test)
the_profile_is_written_by_itself_when_it_rests_and_when_the_world_goes :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-engine-save-profile-kept-%d",directory,os.get_pid())
    os.remove_all(root)
    defer os.remove_all(root)
    app:host.App
    state:Save_State
    defer delete(state.folder)
    app.allocator=context.allocator
    folder_set(&state,&app,fmt.tprintf("%s/saves",root))
    path,_:=profile_path(&state,&app)
    storages:[1]core.Storage_Info
    w:Profile_World
    info:=profile_info(&storages,Progress,offset_of(Profile_World,progress))
    ref:=core.world_ref(&w,&info)
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

    kept_watch(&work,ref,&app,&state,nil,0,&problems)
    kept_watch(&work,ref,&app,&state,nil,KEPT_LOOK,&problems)
    testing.expect(t,!os.is_file(path),"nothing changed: nothing is written")

    w.progress.level=1
    kept_watch(&work,ref,&app,&state,nil,KEPT_LOOK/2,&problems)
    testing.expect(t,!os.is_file(path),"before the next look")
    kept_watch(&work,ref,&app,&state,nil,KEPT_LOOK/2,&problems)
    testing.expect(t,!os.is_file(path),"the look that sees the change waits for it to rest")
    kept_watch(&work,ref,&app,&state,nil,KEPT_LOOK,&problems)
    testing.expect_value(t,written(ref,&app,&state),i32(1))

    for look in 0..<KEPT_LOOKS {
        w.progress.level=i32(10+look)
        kept_watch(&work,ref,&app,&state,nil,KEPT_LOOK,&problems)
    }
    testing.expect_value(t,written(ref,&app,&state),i32(10+KEPT_LOOKS-1))

    w.progress.level=77
    kept_flush(&work,ref,&app,&state,nil,&problems)
    testing.expect_value(t,written(ref,&app,&state),i32(77))
    testing.expect_value(t,problems.count,0)

    other:Save_Work
    w.progress.level=88
    kept_flush(&other,ref,&app,&state,nil,&problems)
    testing.expect_value(t,written(ref,&app,&state),i32(77))
}
