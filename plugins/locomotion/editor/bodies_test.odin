package locomotion_editor

import "core:testing"
import "mirai:core"
import "mirai:editor"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"

@(private)
@(test_world,editor="Bodies_Test_Editor")
Bodies_Test_World :: struct {
    using world:Test_World,
    states:core.Table(phys.Character_State),
    characters:core.Table(phys.Character),
    walks:core.Table(locomotion.Walk),
}

@(private) Bodies_Test_Editor :: struct {bodies:Locomotion_Bodies}

// The editor measures a walker by its Walk, its Character and the height its capsule took, and a body
// that does not walk as a person.
@(test)
a_walker_is_measured_by_its_character_and_its_walk :: proc(t:^testing.T) {
    info,described:=test_info(t,Bodies_Test_World)
    if !described {return}
    defer test_info_destroy(&info)
    world:Bodies_Test_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    walker,crate:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.states,walker,phys.Character_State{standing=true,height=3})
    giant,stride:=phys.character_default(),locomotion.WALK_DEFAULT
    giant.step_height,stride.max_speed,stride.jump_height=0.5,8,0
    core.add(&world.characters,walker,giant)
    core.add(&world.walks,walker,stride)
    core.settle(&info,&world,nil)
    tools:=Bodies_Test_Editor{LOCOMOTION_BODIES_DEFAULT}
    session:=editor.Session{info=&info,editor_world=&tools}
    w:=core.world_ref(&world,&info)
    person:=editor.BODY_PERSON
    testing.expect_value(t,editor.play_body_measure(&session,w,walker),editor.Body_Measure{height=3,step_height=0.5,speed=8,jump_height=person.jump_height})
    testing.expect_value(t,editor.play_body_measure(&session,w,crate),person)
}
