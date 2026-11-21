package anim

import "core:mem"
import "core:testing"
import "mirai:core"
import audio "mirai:engine/audio"
import "mirai:std/base"

@(private)
@(test_world)
Cue_World :: struct {
    using world:Test_World,
    bindings:core.Table(Animation_Cues),
    worlds:core.Table(core.World_Transform),
    events:Animation_Events,
    sounds:audio.Sound_Requests,
    births:core.Births,
}

@(test)
a_crossed_marker_emits_one_spatial_cue_and_replay_keeps_only_the_birth :: proc(t:^testing.T) {
    w:=new(Cue_World)
    defer free(w)
    if !test_world_init(t,w) {return}
    defer test_world_destroy(w)
    entity:=core.create(&w.entities)
    config:Animation_Cues
    config.bindings[0].sound={1,2}
    config.bindings[0].align_up=true
    base.text_set(config.bindings[0].marker[:],"step")
    base.text_set(config.bindings[0].channel[:],"dust")
    core.add(&w.bindings,entity,config)
    core.add(&w.worlds,entity,core.World_Transform{transform={position={2,3,4},rotation=1,scale=1}})
    test_world_settle(w)
    core.push(&w.events.queue,Animation_Event{entity=entity,kind=.Span_Begin,
        name=base.name_hash("step")})
    core.push(&w.events.queue,Animation_Event{entity=entity,kind=.Marker,
        name=base.name_hash("other")})
    core.push(&w.events.queue,Animation_Event{entity=entity,kind=.Marker,
        name=base.name_hash("step")})
    tick :: proc(w:^Cue_World,replay:bool) {
        animation_cues(core.read(&w.bindings),core.ref(&w.events),{},{},nil,nil,
            core.read(&w.worlds),&w.sounds,&w.births,{playing=true,resimulating=replay},nil)
    }
    tick(w,false)
    if !testing.expect(t,len(w.sounds.items)==1 && len(w.births.queue.items)==1) {return}
    testing.expect(t,w.sounds.items[0].placed && w.sounds.items[0].at=={2,3,4})
    birth:=w.births.queue.items[0]
    testing.expect(t,birth.channel==core.birth_channel("dust") && birth.normal=={0,1,0} &&
        birth.position=={2,3,4})
    _=core.take(&w.births.queue)
    _=core.take(&w.sounds.queue)
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    {
        context.allocator=mem.tracking_allocator(&tracker)
        tick(w,true)
    }
    testing.expect_value(t,tracker.total_allocation_count,i64(0))
    testing.expect(t,len(w.sounds.items)==0 && len(w.births.queue.items)==1 &&
        w.births.queue.items[0]==birth)
}
