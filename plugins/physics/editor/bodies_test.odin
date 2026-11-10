package physics_editor

import "core:testing"
import "mirai:core"
import "mirai:editor"
import phys "plugins:physics/runtime"

@(private="file")
Bodies_Test_World :: struct {
    using world:core.Test_World,
    states:core.Table(phys.Character_State),
    characters:core.Table(phys.Character),
    walks:core.Table(phys.Walk),
}

@(private="file") Bodies_Test_Editor :: struct {bodies:Physics_Bodies}

// The editor hears of a character whether it stands and its measures, as its
// components say them, and of a body that is not one, nothing: it is measured
// as a person.
@(test)
a_character_says_whether_it_stands_and_its_measures_and_another_body_says_nothing :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Bodies_Test_World,core.Test_None,Bodies_Test_Editor,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Bodies_Test_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    walker,jumper,crate:=core.create(&world.entities),core.create(&world.entities),core.create(&world.entities)
    core.add(&world.states,walker,phys.Character_State{standing=true,height=3})
    giant,stride:=phys.character_default(),phys.WALK_DEFAULT
    giant.step_height,stride.max_speed,stride.jump_height=0.5,8,0
    core.add(&world.characters,walker,giant)
    core.add(&world.walks,walker,stride)
    core.add(&world.states,jumper,phys.Character_State{})
    core.settle(&info,&world,nil)
    tools:Bodies_Test_Editor
    session:=editor.Session{info=&info,editor_world=&tools}
    w:=core.world_ref(&world,&info)
    testing.expect_value(t,editor.play_stance(&session,w,walker),editor.Stance.Standing)
    testing.expect_value(t,editor.play_stance(&session,w,jumper),editor.Stance.Airborne)
    testing.expect_value(t,editor.play_stance(&session,w,crate),editor.Stance.Unknown)
    person:=editor.BODY_PERSON
    testing.expect_value(t,editor.play_body_measure(&session,w,walker),editor.Body_Measure{height=3,step_height=0.5,speed=8,jump_height=person.jump_height})
    testing.expect_value(t,editor.play_body_measure(&session,w,crate),person)
}
