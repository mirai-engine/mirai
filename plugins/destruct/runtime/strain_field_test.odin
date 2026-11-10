package destruct

import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

@(private="file")
Strain_World :: struct {
    using world:core.Test_World,
    fields:core.Table(Strain_Field),
    volumes:core.Table(volume.Volume),
    worlds:core.Table(core.World_Transform),
    objects:core.Table(Destructible),
    colliders:core.Table(phys.Collider),
    damage:Destruct_Requests,
}

// A Strain_Field asks, each tick, for its strain by the tick on every
// destructible its filter sees, in the region of the Volume of its entity
// where the entity is; a client asks for none, nor does a field off, without
// strain or without a box or a sphere, which says so.
@(test)
a_strain_field_strains_what_its_filter_sees_in_the_volume_of_its_entity :: proc(t:^testing.T) {
    w:Strain_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    authority:core.Network
    problems:core.Problems
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    step :: proc(w:^Strain_World,authority:^core.Network,collision:^phys.Collision_Settings,problems:^core.Problems,time:core.Time) {
        strain_fields_step(core.read(&w.fields),core.read(&w.volumes),core.read(&w.worlds),core.read(&w.objects),core.read(&w.colliders),core.ref(authority),&w.damage,time,core.ref(collision),problems)
    }
    turn:=mm.quat_axis_angle({0,1,0},mm.PI*.5)
    field,target,filtered:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    config:=STRAIN_FIELD_DEFAULT
    config.strain,config.weakening,config.filter.objects,config.filter.ignore_body=120,true,4,17
    core.add(&w.fields,field,config)
    core.add(&w.worlds,field,core.World_Transform{transform={{3,4,5},turn,{2,1,.5}}})
    for category,i in ([2]phys.Collision_Category{2,3}) {
        e:=i==0?target:filtered
        core.add(&w.objects,e,destructible())
        collider:=collider_fracture()
        phys.collision_custom(&collider,phys.collision_layers(category),phys.COLLISION_LAYERS_ALL)
        core.add(&w.colliders,e,collider)
    }
    Case :: struct {region:volume.Volume,want:Destruct_Region}
    cases:=[?]Case{
        {volume.box({1,2,3}),{point={3,4,5},rotation=turn,half_extents={2,2,1.5},falloff=.Constant}},
        {volume.box({1,2,3},blend=1),{point={3,4,5},rotation=turn,half_extents={2,2,1.5},falloff=.Linear}},
        {volume.sphere(3),{point={3,4,5},rotation=turn,radius=6,falloff=.Constant}},
    }
    for c in cases {
        core.add(&w.volumes,field,c.region)
        core.test_world_settle(&w)
        step(&w,&authority,&collision,&problems,{playing=true,dt=.25})
        if !testing.expect_value(t,len(w.damage.queue.items),1) {return}
        event:=w.damage.queue.items[0]
        testing.expect(t,event.entity==target && event.kind==.Weaken && event.strain==30 && event.vector==mm.Vec3{} && event.ignore_body==config.filter.ignore_body)
        testing.expect_value(t,event.region,c.want)
        core.queue_clear(&w.damage.queue)
        core.remove(&w.volumes,field)
        core.test_world_settle(&w)
    }
    testing.expect_value(t,problems.count,0)
    // The whole world and a plane are no region of a fracture.
    for region in ([?]Maybe(volume.Volume){nil,volume.plane()}) {
        if v,has:=region.?;has {core.add(&w.volumes,field,v)}
        core.test_world_settle(&w)
        step(&w,&authority,&collision,&problems,{playing=true,dt=.25})
        testing.expect(t,len(w.damage.queue.items)==0 && core.problem_find(&problems,field,"destruct.strain_field")!=nil)
        if region!=nil {core.remove(&w.volumes,field)}
        core.test_world_settle(&w)
    }
    core.add(&w.volumes,field,volume.sphere(3))
    core.test_world_settle(&w)
    authority.role=.Client
    step(&w,&authority,&collision,&problems,{playing=true,dt=.25})
    authority.role={}
    step(&w,&authority,&collision,&problems,{playing=false,dt=.25})
    core.disable(&w.fields,field)
    core.test_world_settle(&w)
    step(&w,&authority,&collision,&problems,{playing=true,dt=.25})
    testing.expect_value(t,len(w.damage.queue.items),0)
}
