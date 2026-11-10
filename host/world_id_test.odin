package host

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:core"

@(private) Id_Trace :: struct {released:[dynamic]core.World_Id,destroyed:int,ordered:bool}
@(private) Id_World :: struct {using world:core.Test_World,id:core.World_Id,frame:core.Frame_Time,values:[dynamic]u32}

@(private)
id_world_release :: proc(world,shared,editor,app_data:rawptr) {
    w:=cast(^Id_World)world
    trace:=cast(^Id_Trace)(cast(^App)app_data).shared
    append(&trace.released,w.id)
    trace.ordered=w.frame.phase==.Release
}

@(test)
world_ids_are_stable_and_a_freed_one_names_no_other_world :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Id_World)
    if !described {return}
    defer core.test_info_destroy(&info)
    info.loops[.Game][.Release]=id_world_release
    trace:Id_Trace;defer delete(trace.released)
    app:=App{info=&info,allocator=context.allocator,shared=&trace}
    defer delete(app.worlds)
    shown:=app_world_create(&app)
    if !testing.expect(t,shown!=nil) {return}
    shown_id:=app_world_id(&app,shown)
    testing.expect(t,shown_id.generation!=0 && (cast(^Id_World)shown).id==shown_id)
    // A preview world made and freed beside it does not touch the one shown.
    preview:=app_world_create(&app)
    preview_id:=app_world_id(&app,preview)
    testing.expect(t,preview_id!=shown_id && app_world_count(&app)==2)
    app_world_free(&app,preview)
    testing.expect_value(t,app_world_id(&app,shown),shown_id)
    testing.expect(t,len(trace.released)==1 && trace.released[0]==preview_id && trace.ordered)
    testing.expect(t,app_world_of(&app,preview_id)==nil && app_world_of(&app,shown_id)==shown)
    // The next world takes the free slot with another generation.
    next:=app_world_create(&app)
    next_id:=app_world_id(&app,next)
    testing.expect(t,next_id.index==preview_id.index && next_id!=preview_id && app_world_of(&app,preview_id)==nil)
    app_world_free(&app,next)
    // A replacement keeps the id of the live world; the World it traded with
    // releases what was kept for its own id, never for the live one.
    source:Id_World
    if !testing.expect(t,info.init[.World](&source,context.allocator)) {return}
    defer info.destroy[.World](&source)
    append(&source.values,7)
    testing.expect(t,app_world_replace(&app,shown,&source))
    testing.expect_value(t,(cast(^Id_World)shown).id,shown_id)
    testing.expect_value(t,(cast(^Id_World)shown).values[0],u32(7))
    scratch_id:=app_world_id(&app,app.scratch)
    testing.expect(t,scratch_id!=shown_id && (cast(^Id_World)app.scratch).id==scratch_id)
    clear(&trace.released)
    app_world_scratch_free(&app)
    testing.expect(t,len(trace.released)==1 && trace.released[0]==scratch_id)
    app_world_free(&app,shown)
    testing.expect(t,len(trace.released)==2 && trace.released[1]==shown_id)
    testing.expect_value(t,app_world_count(&app),0)
}

@(private) By_World_Shared :: struct {values:core.By_World(u32),seen_at_release:bool}

@(private)
by_world_test_attach :: proc(world,shared:rawptr,allocator:runtime.Allocator) -> bool {
    w,s:=cast(^Id_World)world,cast(^By_World_Shared)shared
    return core.by_world_attach(&s.values,w.id,u32(w.id.index)+10,allocator)
}

@(private)
by_world_test_detach :: proc(world,shared:rawptr) {
    w,s:=cast(^Id_World)world,cast(^By_World_Shared)shared
    core.by_world_release(&s.values,core.by_world_detach(&s.values,w.id))
}

@(private)
by_world_test_release :: proc(world,shared,editor,app_data:rawptr) {
    w,s:=cast(^Id_World)world,cast(^By_World_Shared)shared
    s.seen_at_release=core.by_world_get(&s.values,w.id)!=nil
}

@(test)
each_world_gets_its_by_world_value_when_made_and_loses_it_after_its_release :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Id_World)
    if !described {return}
    defer core.test_info_destroy(&info)
    info.attach,info.detach=by_world_test_attach,by_world_test_detach
    info.loops[.Game][.Release]=by_world_test_release
    succeeded,failed:=false,false
    for budget in 0..<64 {
        tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
        allocation:=World_Create_Allocation{owner=mem.tracking_allocator(&tracking),remaining=budget}
        shared:By_World_Shared
        app:=App{info=&info,allocator={world_create_allocator,&allocation},shared=&shared}
        app.worlds=make([dynamic]World_Slot,app.allocator)
        first:=app_world_create(&app)
        if first==nil {
            failed=true
            testing.expect_value(t,app_world_count(&app),0)
        } else {
            allocation.remaining=-1
            second:=app_world_create(&app)
            a,b:=app_world_id(&app,first),app_world_id(&app,second)
            testing.expect(t,core.by_world_get(&shared.values,a)^==u32(a.index)+10 && core.by_world_get(&shared.values,b)^==u32(b.index)+10)
            app_world_free(&app,first)
            testing.expect(t,shared.seen_at_release && core.by_world_get(&shared.values,a)==nil)
            testing.expect(t,core.by_world_get(&shared.values,b)!=nil)
            app_world_free(&app,second)
            succeeded=true
        }
        delete(shared.values.entries)
        delete(app.worlds)
        testing.expect_value(t,len(tracking.allocation_map),0)
        mem.tracking_allocator_destroy(&tracking)
        if succeeded {break}
    }
    testing.expect(t,succeeded && failed)
}
