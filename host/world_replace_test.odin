package host

import "core:mem"
import "core:testing"
import "mirai:core"

@(private) @(storage,copy=false) Replace_Local :: struct {mark:u32}
@(private) Replace_World :: struct {using world:core.Test_World,values:core.Table(u32),state:[dynamic]u32,local:Replace_Local}

@(test)
world_replacement_out_of_memory_keeps_the_destination_and_a_warm_one_does_not_allocate :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Replace_World)
    if !described {return}
    defer core.test_info_destroy(&info)
    source:Replace_World
    if !testing.expect(t,core.world_init(&info,.World,&source,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&source)
    for value in 0..<40 {
        e:=core.create(&source.entities)
        core.add(&source.values,e,u32(value))
        append(&source.state,u32(value*3))
    }
    core.table_settle(&source.values,&source.entities)
    succeeded,failed:=false,false
    for budget in 0..<32 {
        tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
        allocation:=World_Create_Allocation{owner=mem.tracking_allocator(&tracking),remaining=-1}
        app:=App{info=&info,allocator={world_create_allocator,&allocation}}
        app.worlds=make([dynamic]World_Slot,app.allocator)
        live:=cast(^Replace_World)app_world_create(&app)
        if !testing.expect(t,live!=nil) {return}
        kept:=core.create(&live.entities)
        core.add(&live.values,kept,7);core.table_settle(&live.values,&live.entities)
        append(&live.state,9)
        live.local.mark=5
        values,state:=raw_data(live.values.values),raw_data(live.state)
        version:=core.version(&live.values)
        allocation.remaining=budget
        ok:=app_world_replace(&app,live,&source)
        allocation.remaining=-1
        if !ok {
            failed=true
            testing.expect(t,core.has(&live.values,kept) && core.count(&live.values)==1)
            testing.expect(t,raw_data(live.values.values)==values && raw_data(live.state)==state && len(live.state)==1)
            testing.expect_value(t,core.version(&live.values),version)
        } else {
            succeeded=true
            testing.expect_value(t,core.count(&live.values),40)
            testing.expect_value(t,len(live.state),40)
            testing.expect_value(t,live.state[39],u32(117))
            testing.expect(t,raw_data(live.state)!=raw_data(source.state))
            testing.expect(t,core.version(&live.values)>version)
            testing.expect_value(t,live.local.mark,u32(5))
            // The contents it traded are the room of the next ones: once both
            // sides fit the source, a replacement allocates nothing.
            testing.expect(t,app_world_replace(&app,live,&source))
            allocation.remaining=0
            saved:=context
            context.allocator=mem.nil_allocator()
            testing.expect(t,app_world_replace(&app,live,&source))
            context=saved
            testing.expect_value(t,core.count(&live.values),40)
        }
        app_world_free(&app,live)
        app_world_scratch_free(&app)
        delete(app.worlds)
        testing.expect_value(t,len(tracking.allocation_map),0)
        mem.tracking_allocator_destroy(&tracking)
        testing.expect_value(t,core.count(&source.values),40)
        if ok {break}
    }
    testing.expect(t,succeeded && failed)
}
