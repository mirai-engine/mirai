package destruct

import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

@(private)
@(test_world)
Strain_World :: struct {
    using world:Test_World,
    fields:core.Table(Strain_Field),
    volumes:core.Table(volume.Volume),
    worlds:core.Table(core.World_Transform),
    bodies:phys.Body_Requests,
}

// A Strain_Field asks physics, each tick, for its strain by the tick in the
// Volume of its entity where the entity is, with its filter; a client asks
// for none, nor does a field off, without strain or without a box or a
// sphere, which says so.
@(test)
a_strain_field_asks_for_its_strain_in_the_volume_of_its_entity :: proc(t:^testing.T) {
    w:Strain_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    authority:core.Network
    problems:core.Problems
    step :: proc(w:^Strain_World,authority:^core.Network,problems:^core.Problems,time:core.Time) {
        strain_fields_step(core.read(&w.fields),core.read(&w.volumes),core.read(&w.worlds),{},{},core.ref(authority),&w.bodies,time,problems)
    }
    pose:=mm.Transform{{3,4,5},mm.quat_axis_angle({0,1,0},mm.PI*.5),{2,1,.5}}
    field:=core.create(&w.entities)
    config:=STRAIN_FIELD_DEFAULT
    config.strain,config.weakening,config.blend,config.filter.objects,config.filter.ignore_body=120,true,0.5,4,17
    core.add(&w.fields,field,config)
    core.add(&w.worlds,field,core.World_Transform{transform=pose})
    for area in ([?]volume.Volume{volume.box({1,2,3}),volume.sphere(3)}) {
        core.add(&w.volumes,field,area)
        test_world_settle(&w)
        step(&w,&authority,&problems,{playing=true,dt=.25})
        if !testing.expect_value(t,len(w.bodies.queue.items),1) {return}
        asked:=w.bodies.queue.items[0]
        testing.expect(t,asked.kind==.Area_Strain && asked.strength==30 && asked.override && asked.filter==config.filter)
        testing.expect(t,asked.area==area && asked.blend==config.blend)
        testing.expect(t,asked.position==pose.position && asked.rotation==pose.rotation && asked.scale==pose.scale)
        core.queue_clear(&w.bodies.queue)
        core.remove(&w.volumes,field)
        test_world_settle(&w)
    }
    testing.expect_value(t,problems.count,0)
    // The whole world and a plane are no region of a strain.
    for region in ([?]Maybe(volume.Volume){nil,volume.plane()}) {
        if v,has:=region.?;has {core.add(&w.volumes,field,v)}
        test_world_settle(&w)
        step(&w,&authority,&problems,{playing=true,dt=.25})
        testing.expect(t,len(w.bodies.queue.items)==0 && core.problem_find(&problems,field,"destruct.strain_field")!=nil)
        if region!=nil {core.remove(&w.volumes,field)}
        test_world_settle(&w)
    }
    core.add(&w.volumes,field,volume.sphere(3))
    test_world_settle(&w)
    authority.role=.Client
    step(&w,&authority,&problems,{playing=true,dt=.25})
    authority.role={}
    step(&w,&authority,&problems,{playing=false,dt=.25})
    core.disable(&w.fields,field)
    test_world_settle(&w)
    step(&w,&authority,&problems,{playing=true,dt=.25})
    testing.expect_value(t,len(w.bodies.queue.items),0)
}
