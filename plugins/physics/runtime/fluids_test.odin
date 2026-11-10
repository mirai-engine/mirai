package physics

import "core:testing"
import "mirai:core"
import "core:math/linalg"
import mm "mirai:std/math"

@(test)
fluid_volumes_follow_their_rows_and_entities :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    sea:=core.create(&f.entities)
    core.add(&f.volumes,sea,fluid_volume_sea(1025,{1,0,0}))
    core.add(&f.transforms,sea,core.Transform{{0,2,0},mm.quat_axis_angle({0,1,0},0.5*mm.PI),{1,1,1}})
    room:=core.create(&f.entities)
    core.add(&f.volumes,room,fluid_volume_dry({1,1,1}))
    core.add(&f.transforms,room,core.Transform{{10,0,0},1,{2,3,4}})
    physics_test_step(&f,0)
    testing.expect_value(t,f.problems.count,0)
    testing.expect_value(t,f.state.world.fluid_count,2)
    sample,entity,ok:=fluid_at({&f.state},{0,-1,0})
    testing.expect(t,ok && entity==sea)
    testing.expect(t,abs(sample.height-2)<1e-5 && sample.density==1025)
    // The current turns with the entity: +X a quarter turn to the left is -Z.
    testing.expect(t,linalg.length(sample.current-{0,0,-1})<1e-5)
    // The scale of the entity sizes the box: its air reaches 3 m down from its center, where the sea is.
    sample,entity,ok=fluid_at({&f.state},{10,-2,0})
    testing.expect(t,ok && abs(sample.height-(-3))<1e-5 && sample.density==0)
    sample,_,_=fluid_at({&f.state},{10,-4,0})
    testing.expect(t,abs(sample.height-(-3))<1e-5 && sample.density==1025)
    found:[4]Fluid_Info
    testing.expect_value(t,fluids_in({&f.state},{{9,-1,-1},{11,1,1}},found[:]),2)
    // Their surfaces, and what their volumes hold whatever a dry box takes out.
    testing.expect(t,found[0].entity==sea && abs(found[0].top-2)<1e-5 && found[1].entity==room && abs(found[1].top-3)<1e-5)
    testing.expect(t,fluid_holds({&f.state},found[1].fluid,{10,-2,0}) && !fluid_holds({&f.state},found[1].fluid,{10,-4,0}))
    testing.expect(t,fluid_holds({&f.state},found[0].fluid,{10,-2,0}) && !fluid_holds({&f.state},found[0].fluid,{0,3,0}))
    // The room floods: the floor of its air rises.
    core.edit(&f.transforms,room).position.y=2
    physics_test_step(&f,0)
    sample,_,_=fluid_at({&f.state},{10,-1.5,0})
    testing.expect(t,abs(sample.height-(-1))<1e-5 && sample.density==1025)
    // A copy of the world takes its fluids.
    copy:Physics_State
    defer state_destroy(&copy)
    testing.expect(t,state_copy(&copy,&f.state))
    sample,entity,ok=fluid_at({&copy},{10,-1.5,0})
    testing.expect(t,ok && entity==sea && abs(sample.height-(-1))<1e-5)
    core.remove(&f.volumes,room)
    physics_test_step(&f,0)
    testing.expect_value(t,f.state.world.fluid_count,1)
}

@(test)
a_fluid_volume_that_cannot_be_made_or_overlaps_another_is_a_problem :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    dry:=core.create(&f.entities)
    core.add(&f.volumes,dry,Fluid_Volume{shape=.Plane})
    core.add(&f.transforms,dry,core.Transform{{},1,{1,1,1}})
    a,b:=core.create(&f.entities),core.create(&f.entities)
    core.add(&f.volumes,a,fluid_volume_box({2,1,2}))
    core.add(&f.transforms,a,core.Transform{{0,0,0},1,{1,1,1}})
    core.add(&f.volumes,b,fluid_volume_box({2,1,2}))
    core.add(&f.transforms,b,core.Transform{{3,0,0},1,{1,1,1}})
    physics_test_step(&f,0)
    testing.expect(t,core.problem_find(&f.problems,dry,"physics.fluid")!=nil)
    testing.expect(t,core.problem_find(&f.problems,b,"physics.fluid_overlap")!=nil)
    testing.expect_value(t,f.state.world.fluid_count,2)
}

@(test)
a_body_floats_on_a_fluid_volume_of_the_world :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    sea:=core.create(&f.entities)
    core.add(&f.volumes,sea,fluid_volume_sea(1000))
    core.add(&f.transforms,sea,core.Transform{{},1,{1,1,1}})
    raft:=core.create(&f.entities)
    collider:=collider_box({1,0.1,1})
    collider.density=500
    core.add(&f.rigids,raft,RIGID_BODY_DYNAMIC)
    core.add(&f.colliders,raft,collider)
    core.add(&f.transforms,raft,core.Transform{{0,1,0},1,{1,1,1}})
    for _ in 0..<600 {physics_test_step(&f)}
    placed,_:=core.get(&f.transforms,raft)
    // Half its thickness under the surface.
    testing.expectf(t,abs(placed.position.y)<0.002,"floats at %v",placed.position.y)
}

@(test)
fluids_in_lists_more_fluids_than_one_batch :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.settings.fluids=100
    for i in 0..<80 {
        pool:=core.create(&f.entities)
        core.add(&f.volumes,pool,fluid_volume_box({0.4,0.4,0.4}))
        core.add(&f.transforms,pool,core.Transform{{f32(i),0,0},1,{1,1,1}})
    }
    physics_test_step(&f,0)
    testing.expect_value(t,f.state.world.fluid_count,80)
    found:[100]Fluid_Info
    testing.expect_value(t,fluids_in({&f.state},{{-1,-1,-1},{100,1,1}},found[:]),80)
    for info,i in found[:80] {testing.expectf(t,abs(info.desc.position.x-f32(i))<1e-5,"%d is at %v",i,info.desc.position)}
    few:[3]Fluid_Info
    testing.expect_value(t,fluids_in({&f.state},{{-1,-1,-1},{100,1,1}},few[:]),80)
    testing.expect(t,abs(few[2].desc.position.x-2)<1e-5)
}

// The waves of a Fluid_Waves: its own first, turned by the yaw of the plane,
// then a sea of the wind as high as Pierson-Moskowitz says, along it, the
// same for the same seed.
@(test)
the_waves_of_a_plane_are_its_own_and_the_sea_of_the_wind :: proc(t:^testing.T) {
    raised:=FLUID_WAVES_DEFAULT
    raised.waves[0]={amplitude=0.4,length=30,yaw=0}
    raised.spread=0
    blowing:=[2]f32{0,-10} // 10 m/s towards -Z
    waves:=fluid_waves_of(raised,0.5*mm.PI,blowing)
    testing.expect_value(t,waves.count,u32(FLUID_WAVES))
    own:=waves.waves[0]
    testing.expect(t,own.amplitude==0.4 && own.length==30)
    testing.expectf(t,linalg.length(own.direction-{-1,0})<1e-5,"the forward of a plane turned a quarter is -X: %v",own.direction)
    testing.expectf(t,abs(own.speed-6.84)<0.01,"%v m/s",own.speed)
    energy:f32
    for wave in waves.waves[1:waves.count] {
        energy+=0.5*wave.amplitude*wave.amplitude
        testing.expectf(t,linalg.length(wave.direction-{0,-1})<1e-5,"along the wind: %v",wave.direction)
    }
    height:=4*linalg.sqrt(energy)
    testing.expectf(t,abs(height-0.21*100/9.81)<1e-3,"significant height %v",height)
    testing.expect(t,waves==fluid_waves_of(raised,0.5*mm.PI,blowing))
    raised.seed=7
    testing.expect(t,waves!=fluid_waves_of(raised,0.5*mm.PI,blowing))
    still:=fluid_waves_of(raised,0,{})
    testing.expect_value(t,still.count,u32(1))
}
