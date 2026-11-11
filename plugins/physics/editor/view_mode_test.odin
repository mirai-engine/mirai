package physics_editor

import "core:testing"
import "mirai:core"
import "mirai:host"
import phys "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"

@(private="file")
Collision_View_Test_World :: struct {
    using world:core.Test_World,
    physics:phys.Physics_State,
    settings:phys.Collision_Settings,
}

// The Collision mode draws the shapes of the layers asked for, hidden behind
// the scene, and makes its lines again only when the physics moves on.
@(test)
collision_view_draws_the_layers_asked_for_and_keeps_its_lines_while_physics_stays :: proc(t:^testing.T) {
    world:Collision_View_Test_World
    if !core.test_world_init(t,&world,phys.test_types) {return}
    defer core.test_world_destroy(&world)
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=16,16,64,4
    if !testing.expect(t,sim.world_init(&world.physics.world,desc)) {return}
    world.physics.ready=true
    body:=sim.body_create(&world.physics.world,{type=.Static,rotation=1})
    sim.shape_create(&world.physics.world,body,{geometry=sim.Box{{0.5,0.5,0.5}},filter={layers=1,block=0xffffffff}})
    view:Collision_View
    defer collision_view_free(&view)
    app:host.App
    w:=core.test_world_ref(&world)
    lines_of :: proc(app:^host.App) -> int {
        count:=0
        for lines in app.extras.debug[:app.extras.debug_count] {count+=lines.count/2}
        app.extras.debug_count=0
        return count
    }
    collision_view_draw(&view,w,~sim.Collision_Layers(0),&app.extras)
    testing.expect_value(t,lines_of(&app),12)
    testing.expect(t,app.extras.debug[0].depth_test,"hidden behind the scene")
    collision_view_draw(&view,w,2,&app.extras)
    testing.expect_value(t,lines_of(&app),0)
    // A shape added without a step of the physics shows when the physics moves on.
    sim.shape_create(&world.physics.world,body,{geometry=sim.Box{{0.5,0.5,0.5}},transform={{2,0,0},1},filter={layers=2,block=0xffffffff}})
    collision_view_draw(&view,w,2,&app.extras)
    testing.expect_value(t,lines_of(&app),0)
    world.physics.world.tick+=1
    collision_view_draw(&view,w,2,&app.extras)
    testing.expect_value(t,lines_of(&app),12)
    collision_view_draw(&view,w,~sim.Collision_Layers(0),&app.extras)
    testing.expect_value(t,lines_of(&app),24)
}
