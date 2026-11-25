package anim

import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:core"
import audio "mirai:engine/audio"
import "mirai:std/base"

@(private)
@(test_world)
Cue_World :: struct {
    using world:Test_World,
    animations:core.Table(Animation),
    worlds:core.Table(core.World_Transform),
    events:Animation_Events,
    sounds:audio.Sound_Requests,
    births:core.Births,
}

// Every marker the cues of a .character name plays its cue, however many the
// rig has, once per crossing, at the entity, by the hashes the set resolved
// when it loaded: no allocation in the tick, and a marker it does not name
// plays nothing.
@(test)
every_marker_cue_of_a_character_plays_without_allocating :: proc(t:^testing.T) {
    w:=new(Cue_World)
    defer free(w)
    if !test_world_init(t,w) {return}
    defer test_world_destroy(w)
    CUES :: 20
    Case :: struct {name:string,markers:[]string,plays:int}
    cases:=[]Case{
        {"one marker",{"step_0"},1},
        {"every marker of twenty",nil,CUES},
        {"a marker no cue names",{"other"},0},
    }
    rows:=make([]Marker_Cue,CUES);defer delete(rows)
    for &row,i in rows {
        base.text_set(row.marker[:],fmt.tprintf("step_%d",i))
        row.cue.sound={1,u64(i+1)}
        base.text_set(row.cue.channel[:],"dust")
    }
    testing.expect(t,marker_cues_check(rows))
    characters:Character_Assets
    defer delete(characters.contents)
    id:=base.Asset_Id{7,7}
    content:=Character_Content{id=id,valid=true,set={cues=rows}}
    content.cues=make([]Cue_Ready,CUES);defer delete(content.cues)
    marker_cues_ready(rows,content.cues)
    append(&characters.contents,content)
    entity:=core.create(&w.entities)
    core.add(&w.animations,entity,Animation{asset=id})
    core.add(&w.worlds,entity,core.World_Transform{transform={position={2,3,4},rotation=1,scale=1}})
    test_world_settle(w)
    // The room audio_requests and the first birth keep.
    testing.expect(t,reserve(&w.sounds.items,audio.SOUND_REQUESTS)==nil && reserve(&w.births.log.items,core.BIRTHS_CAPACITY)==nil)
    for c in cases {
        clear(&w.events.items)
        if c.markers==nil {
            for i in 0..<CUES {core.push(&w.events.queue,Animation_Event{entity=entity,kind=.Marker,name=base.name_hash(fmt.tprintf("step_%d",i))})}
        }
        for name in c.markers {core.push(&w.events.queue,Animation_Event{entity=entity,kind=.Marker,name=base.name_hash(name)})}
        core.push(&w.events.queue,Animation_Event{entity=entity,kind=.Span_Begin,name=base.name_hash("step_0")})
        _=core.take(&w.sounds.queue)
        clear(&w.births.log.items)
        tracker:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker,context.allocator)
        {
            context.allocator=mem.tracking_allocator(&tracker)
            animation_cues(core.read(&w.animations),core.ref(&w.events),{},core.ref(&characters),{},nil,nil,
                core.read(&w.worlds),&w.sounds,&w.births,{playing=true},nil)
        }
        testing.expectf(t,tracker.total_allocation_count==0,"%s: the tick allocates",c.name)
        mem.tracking_allocator_destroy(&tracker)
        testing.expectf(t,len(w.sounds.items)==c.plays && len(w.births.log.items)==c.plays,"%s: %d sounds and %d births, wants %d",c.name,len(w.sounds.items),len(w.births.log.items),c.plays)
        for s in w.sounds.items {testing.expect(t,s.placed && s.at=={2,3,4} && s.by==entity)}
        for b in w.births.log.items {testing.expect(t,b.channel==core.birth_channel("dust") && b.position=={2,3,4})}
    }
}
