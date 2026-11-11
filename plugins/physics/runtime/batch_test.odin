package physics

import "core:testing"
import "mirai:core"

// A section that brings more bodies than a tick makes, and takes them away
// in one settle: they come over the next ticks, what does not move first,
// and leave over ticks too.
@(test)
bodies_come_and_go_a_part_of_each_tick :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    COUNT :: BODIES_PER_TICK*2+10
    f.settings.bodies,f.settings.shapes=COUNT+8,COUNT+8
    floors:[COUNT]core.Entity
    for &e,i in floors {e=physics_test_box(&f,{f32(i)*3,0,0},{1,0.1,1})}
    box:=physics_test_box(&f,{0,1,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
    made :: proc(f:^Physics_Test,entities:[]core.Entity) -> (count:int) {
        for e in entities {
            if l:=link_find(&f.state,e);l!=nil && l.kind==.Body {count+=1}
        }
        return
    }
    physics_test_step(&f)
    testing.expect_value(t,made(&f,floors[:]),BODIES_PER_TICK)
    testing.expect_value(t,made(&f,{box}),0)
    physics_test_step(&f)
    testing.expect_value(t,made(&f,floors[:]),BODIES_PER_TICK*2)
    physics_test_step(&f)
    testing.expect_value(t,made(&f,floors[:]),COUNT)
    testing.expect_value(t,made(&f,{box}),1)
    testing.expect_value(t,int(f.state.stats.bodies_created),COUNT+1)

    for e in floors {core.disable(&f.colliders,e)}
    physics_test_step(&f)
    testing.expect_value(t,made(&f,floors[:]),COUNT-BODIES_PER_TICK)
    physics_test_step(&f)
    physics_test_step(&f)
    testing.expect_value(t,made(&f,floors[:]),0)
    testing.expect_value(t,made(&f,{box}),1)
}
