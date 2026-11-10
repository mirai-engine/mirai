package camera

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"

// The body of the player has to go past the margin into the box for the
// trigger to ask for its sky and sun, once, and past it out to leave.
@(test)
a_trigger_turns_its_sky_on_once_the_body_is_well_inside :: proc(t:^testing.T) {
    w:Test_Cameras
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    w.seat_state.local_count=1

    seat,body,box,sky:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,seat,input.Seat{})
    core.add(&w.drivables,body,input.Drivable{seat=seat})
    core.add(&w.triggers,box,Environment_Trigger{sky=sky,extents={2,2,2},seconds=1})
    core.add(&w.worlds,box,core.World_Transform{transform={rotation=1,scale=1}})
    core.add(&w.worlds,body,core.World_Transform{transform={position={1.9,0,0},rotation=1,scale=1}})
    core.test_world_settle(&w)
    step :: proc(w:^Test_Cameras,x:f32) {
        core.edit(&w.worlds,core.entity_at(core.read(&w.worlds),1)).position.x=x
        environment_triggers(&w.triggers,core.read(&w.worlds),core.ref(&w.seat_state),core.read(&w.seats),core.read(&w.drivables),&w.environment)
        core.test_world_settle(w)
    }

    step(&w,1.9)
    testing.expect_value(t,len(w.environment.queue.items),0)
    step(&w,1.5)
    testing.expect_value(t,len(w.environment.queue.items),1)
    testing.expect_value(t,w.environment.queue.items[0].sky,sky)
    step(&w,2.1)
    step(&w,1.5)
    testing.expect_value(t,len(w.environment.queue.items),1)
    step(&w,2.4)
    step(&w,1.5)
    testing.expect_value(t,len(w.environment.queue.items),2)
}
