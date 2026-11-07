package host

import "core:testing"
import "mirai:render"

@(test)
a_frame_keeps_every_instance_libraries_add_past_the_room_it_reserves :: proc(t:^testing.T) {
    app:=App{allocator=context.allocator}
    defer app_extras_free(&app)
    count:=FRAME_INSTANCE_RESERVE*4+1
    for i in 0..<count {
        testing.expect(t,app_instance_add(&app,render.Instance_Desc{object_id=u64(i)+1}),"no instance is refused")
    }
    instances:=app_instances(&app)
    testing.expect_value(t,len(instances),count)
    testing.expect_value(t,instances[count-1].object_id,u64(count))
    testing.expect_value(t,app.stats.extras_dropped,0)
}
