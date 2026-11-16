package physics

import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import "core:math/linalg"
import mm "mirai:std/math"

@(test)
fluids_follow_their_rows_their_volumes_and_their_entities :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    sea:=core.create(&f.entities)
    core.add(&f.fluids,sea,Fluid{density=1025,current={1,0,0}})
    core.add(&f.volumes,sea,volume.plane())
    core.add(&f.transforms,sea,core.Transform{{0,2,0},mm.quat_axis_angle({0,1,0},0.5*mm.PI),{1,1,1}})
    room:=core.create(&f.entities)
    core.add(&f.fluids,room,Fluid{priority=1})
    core.add(&f.volumes,room,volume.box({1,1,1}))
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
    // The priority of its Volume is what puts the air over the sea: at that of the sea, the sea is there.
    sample,_,_=fluid_at({&f.state},{10,0,0})
    testing.expect_value(t,sample.density,f32(0))
    core.edit(&f.fluids,room).priority=0
    physics_test_step(&f,0)
    sample,_,_=fluid_at({&f.state},{10,0,0})
    testing.expect(t,sample.density==1025 && f.state.world.fluid_count==2)
    core.remove(&f.fluids,room)
    physics_test_step(&f,0)
    testing.expect_value(t,f.state.world.fluid_count,1)
    // A Spline makes its Fluid water along it, as deep as the height of its points, flowing at their speed.
    river:=core.create(&f.entities)
    core.add(&f.fluids,river,Fluid{density=1000,current={0.5,0,0}})
    core.add(&f.splines,river,volume.Spline{count=2,points={0={{100,4,0},3,1,1.5},1={{88,3,0},3,1,1.5}}})
    physics_test_step(&f,0)
    sample,entity,ok=fluid_at({&f.state},{94,4,0})
    testing.expect(t,ok && entity==river && abs(sample.height-4.5)<0.05 && sample.density==1000)
    testing.expectf(t,abs(sample.current.x+1.5)<0.05 && abs(sample.current.z+0.5)<0.01,"it flows down its path and across to its right: %v",sample.current)
    _,entity,_=fluid_at({&f.state},{94,4,3})
    testing.expect(t,entity!=river,"past its banks")
    core.edit(&f.splines,river).points[1].width=0
    along:=core.create(&f.entities)
    core.add(&f.fluids,along,Fluid{density=1000,current={0,0,-1}})
    core.add(&f.splines,along,volume.Spline{count=2,points={0={{200,4,0},3,1,0},1={{188,3,0},3,1,0}}})
    physics_test_step(&f,0)
    for e in ([2]core.Entity{river,along}) {
        testing.expectf(t,core.problem_find(&f.problems,e,"physics.fluid_path")!=nil,"a point without width, or a current along the path, is a problem: %v",e)
    }
    testing.expect_value(t,f.state.world.fluid_count,1)
}

// A fluid fills a plane or a box: without a Volume, in one of another shape, dry in a plane or in a box
// without size it is not made, and says why. Two fluids that meet are a problem only at the same priority.
@(test)
a_fluid_that_cannot_be_made_or_meets_another_of_its_priority_is_a_problem :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    Case :: struct {fluid:Fluid,region:Maybe(volume.Volume),made:bool}
    cases:=[?]Case{
        {Fluid{density=1000},nil,false},
        {Fluid{density=1000},volume.sphere(3),false},
        {Fluid{density=1000},volume.world(),false},
        {Fluid{},volume.plane(),false},
        {Fluid{density=1000},volume.box({2,0,2}),false},
        {Fluid{density=1000},volume.box({2,1,2}),true},
    }
    made:=0
    refused:[len(cases)]core.Entity
    for c,i in cases {
        e:=core.create(&f.entities)
        core.add(&f.fluids,e,c.fluid)
        if region,has:=c.region.?;has {core.add(&f.volumes,e,region)}
        core.add(&f.transforms,e,core.Transform{{f32(i)*100,0,0},1,{1,1,1}})
        if c.made {made+=1} else {refused[i]=e}
    }
    a,b,over:=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    for e,i in ([3]core.Entity{a,b,over}) {
        core.add(&f.fluids,e,Fluid{density=FLUID_DEFAULT.density,priority=i==2?1:0})
        core.add(&f.volumes,e,volume.box({2,1,2}))
        core.add(&f.transforms,e,core.Transform{{-100+f32(i)*3,0,0},1,{1,1,1}})
    }
    physics_test_step(&f,0)
    for e,i in refused {
        if !cases[i].made {testing.expectf(t,core.problem_find(&f.problems,e,"physics.fluid")!=nil,"case %d says nothing",i)}
    }
    testing.expect(t,core.problem_find(&f.problems,b,"physics.fluid_overlap")!=nil)
    testing.expect(t,core.problem_find(&f.problems,over,"physics.fluid_overlap")==nil,"a higher priority decides where they meet")
    testing.expect_value(t,f.state.world.fluid_count,i32(made+3))
    // They meet where a column holds both, not where their boxes do: a river that winds around a lake, or
    // that runs into the notch of an L outline whose box it is in.
    Meeting :: struct {name:string,river:[4][3]f32,outline:bool,meets:bool}
    into_the_notch:=[4][3]f32{{4,0,10},{4,0,-2},{4,0,-14},{4,0,-18}}
    meetings:=[?]Meeting{
        {"winds around the lake",{{-20,0,0},{-20,0,-40},{20,0,-40},{20,0,0}},false,false},
        {"crosses the lake",{{-20,0,-20},{-6,0,-20},{6,0,-20},{20,0,-20}},false,true},
        {"runs into a box lake",into_the_notch,false,true},
        {"runs into the notch of an L",into_the_notch,true,false},
        {"crosses the arm of an L",{{-20,0,-24},{-6,0,-24},{6,0,-24},{20,0,-24}},true,true},
    }
    l:=volume.Spline{count=6,points={0={position={-8,0,-8}},1={position={8,0,-8}},2={position={8,0,0}},3={position={0,0,0}},4={position={0,0,8}},5={position={-8,0,8}}}}
    pairs:[len(meetings)][2]core.Entity
    for m,i in meetings {
        at:=[3]f32{300+100*f32(i),0,0}
        lake,river:=core.create(&f.entities),core.create(&f.entities)
        core.add(&f.fluids,lake,FLUID_DEFAULT)
        if m.outline {
            core.add(&f.volumes,lake,volume.outline(2))
            core.add(&f.splines,lake,l)
        } else {
            core.add(&f.volumes,lake,volume.box({8,1,8}))
        }

        core.add(&f.transforms,lake,core.Transform{at+{0,0,-20},1,{1,1,1}})
        spline:=volume.Spline{count=4}
        for p,k in m.river {spline.points[k]={p,4,1,1}}
        core.add(&f.fluids,river,FLUID_DEFAULT)
        core.add(&f.splines,river,spline)
        core.add(&f.transforms,river,core.Transform{at,1,{1,1,1}})
        pairs[i]={lake,river}
    }
    physics_test_step(&f,0)
    for m,i in meetings {
        reported:=core.problem_find(&f.problems,pairs[i][0],"physics.fluid_overlap")!=nil || core.problem_find(&f.problems,pairs[i][1],"physics.fluid_overlap")!=nil
        testing.expectf(t,reported==m.meets,"a river that %s: reported %v",m.name,reported)
    }
}

@(test)
a_body_floats_on_a_fluid_of_the_world :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.gravity={0,-9.81,0}
    sea:=core.create(&f.entities)
    core.add(&f.fluids,sea,FLUID_DEFAULT)
    core.add(&f.volumes,sea,volume.plane())
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
        core.add(&f.fluids,pool,FLUID_DEFAULT)
        core.add(&f.volumes,pool,volume.box({0.4,0.4,0.4}))
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
