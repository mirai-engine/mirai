package camera

import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import volume "mirai:engine/volume"

// The body of the player has to go past the margin into the Volume of the
// trigger for it to ask for its sky and sun, once, and past it out to leave.
@(test)
a_trigger_turns_its_sky_on_once_the_body_is_well_inside_its_volume :: proc(t:^testing.T) {
    w:Test_Cameras
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    w.seat_state.local_count=1

    seat,body,box,sky:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.seats,seat,input.Seat{body=body})
    core.add(&w.triggers,box,Environment_Trigger{sky=sky,seconds=1})
    core.add(&w.volumes,box,volume.box({2,2,2}))
    core.add(&w.worlds,box,core.World_Transform{transform={rotation=1,scale=1}})
    core.add(&w.worlds,body,core.World_Transform{transform={position={1.9,0,0},rotation=1,scale=1}})
    test_world_settle(&w)
    step :: proc(w:^Test_Cameras,x:f32) {
        core.edit(&w.worlds,core.entity_at(&w.worlds,1)).position.x=x
        environment_triggers(&w.triggers,core.read(&w.volumes),core.read(&w.worlds),core.ref(&w.seat_state),core.read(&w.seats),&w.environment)
        test_world_settle(w)
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
    // The same trigger in a sphere: its border is where the sphere says.
    core.edit(&w.volumes,box)^=volume.sphere(3)
    step(&w,3.3)
    step(&w,2.9)
    testing.expect_value(t,len(w.environment.queue.items),2)
    step(&w,2.5)
    testing.expect_value(t,len(w.environment.queue.items),3)
}
