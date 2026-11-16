package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"

@(test_world)
Simulation_Test_World :: struct {
    using world:Test_World,
    using scene_tables:Test_Scene,
}

@(test)
simulation_poses_apply_atomically_under_selected_parents_and_undo_together :: proc(t:^testing.T) {
    world:Simulation_Test_World
    if !test_world_init(t,&world) {return}
    defer test_world_destroy(&world)
    parent,child:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,parent,core.Id{1})
    core.add(&world.ids,child,core.Id{2})
    core.add(&world.transforms,parent,core.Transform{{10,0,0},1,{1,1,1}})
    core.add(&world.transforms,child,core.Transform{{2,0,0},1,{1,1,1}})
    core.add(&world.parents,child,core.Parent{parent,0})
    test_world_settle(&world)
    edits:history.Edits
    selection:history.Selection
    viewport:Viewport
    gui:Editor_Ui
    s:=Session{info=test_world_info(&world),edit_world=&world,edits=&edits,selection=&selection,viewport=&viewport,gui=&gui}
    w:=edited_world(&s)
    history.edits_reset(&edits,w)
    defer history.edits_free(&edits)
    defer delete(selection.entities)
    history.selection_set(&selection,{child})
    poses:=[2]Simulation_Pose{
        {id=2,position={25,0,0},rotation={0,0,0,1},scale={1,1,1}},
        {id=1,position={20,0,0},rotation={0,0,0,1},scale={1,1,1}},
    }
    testing.expect(t,simulation_apply_poses(&s,poses[:]))
    testing.expect_value(t,edits.cursor,1)
    testing.expect_value(t,entity_local(w,child).position.x,f32(5))
    testing.expect_value(t,entity_world(w,child).position.x,f32(25))
    testing.expect(t,history.undo(&edits,w,&selection))
    testing.expect_value(t,entity_local(w,child).position.x,f32(2))
    testing.expect_value(t,entity_world(w,child).position.x,f32(12))
    testing.expect(t,history.redo(&edits,w,&selection))
    testing.expect_value(t,entity_world(w,child).position.x,f32(25))
    invalid:=poses
    invalid[0].position.x=30
    invalid[1].id=999
    testing.expect(t,!simulation_apply_poses(&s,invalid[:]))
    testing.expect_value(t,entity_world(w,child).position.x,f32(25))
    testing.expect_value(t,edits.cursor,1)
    invalid[1]=invalid[0]
    testing.expect(t,!simulation_apply_poses(&s,invalid[:]))
    s.mode=.Simulate
    testing.expect(t,!simulation_apply_poses(&s,poses[:]))
    testing.expect_value(t,edits.cursor,1)
    s.mode=.Edit
    grandchild:=core.create(&world.entities)
    core.add(&world.ids,grandchild,core.Id{3})
    core.add(&world.transforms,grandchild,core.Transform{{1,2,3},1,{1,1,1}})
    core.add(&world.parents,grandchild,core.Parent{child,0})
    core.edit(&world.transforms,parent)^={{10,0,0},quaternion(x=0,y=0,z=0.70710677,w=0.70710677),{2,3,4}}
    core.edit(&world.transforms,child)^={{2,0,0},quaternion(x=0,y=0.70710677,z=0,w=0.70710677),{1,2,1}}
    test_world_settle(&world)
    history.edits_reset(&edits,w)
    deep:=[1]Simulation_Pose{{id=3,position={7,8,9},rotation={0,0,0,1},scale={2,3,4}}}
    testing.expect(t,simulation_apply_poses(&s,deep[:]))
    actual:=entity_world(w,grandchild)
    for axis in 0..<3 {
        testing.expect(t,abs(actual.position[axis]-deep[0].position[axis])<0.001)
        testing.expect(t,abs(actual.scale[axis]-deep[0].scale[axis])<0.001)
    }
    testing.expect(t,abs(actual.rotation.w-1)<0.001)
    testing.expect_value(t,edits.cursor,1)
}
