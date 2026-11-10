package host

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:core"

@(private) World_Create_Allocation :: struct {owner:runtime.Allocator,remaining:int}
@(private)
world_create_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=cast(^World_Create_Allocation)data
    if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}
@(private) World_Create_Value :: struct {using world:core.Test_World,owned:core.Table(u64)}

@(test)
world_creation_frees_every_partial_initializer_and_publishes_no_failed_clock :: proc(t:^testing.T) {
    info,described:=core.test_info(t,World_Create_Value)
    if !described {return}
    defer core.test_info_destroy(&info)
    succeeded:=false
    for budget in 0..<64 {
        tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
        allocation:=World_Create_Allocation{owner=mem.tracking_allocator(&tracking),remaining=budget}
        app:=App{info=&info,allocator={world_create_allocator,&allocation}}
        app.worlds=make([dynamic]World_Slot,app.allocator)
        data:=app_world_create(&app)
        if data!=nil {
            succeeded=true
            testing.expect_value(t,app_world_count(&app),1)
            testing.expect_value(t,app_world_id(&app,data),core.World_Id{0,1})
            app_world_free(&app,data)
        } else {
            testing.expect_value(t,app_world_count(&app),0)
        }
        delete(app.worlds)
        testing.expect_value(t,len(tracking.allocation_map),0)
        mem.tracking_allocator_destroy(&tracking)
        if data!=nil {break}
    }
    testing.expect(t,succeeded)
}
