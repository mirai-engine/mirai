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
    parents:core.Table(core.Parent),
    cues:core.Table(Marker_Cue),
    index:Marker_Cues_Ready,
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
            animation_cues(core.read(&w.animations),core.ref(&w.events),{},core.ref(&characters),{},core.read(&w.cues),&w.index,nil,
                core.read(&w.parents),core.read(&w.worlds),&w.sounds,&w.births,{playing=true},nil)
        }
        testing.expectf(t,tracker.total_allocation_count==0,"%s: the tick allocates",c.name)
        mem.tracking_allocator_destroy(&tracker)
        testing.expectf(t,len(w.sounds.items)==c.plays && len(w.births.log.items)==c.plays,"%s: %d sounds and %d births, wants %d",c.name,len(w.sounds.items),len(w.births.log.items),c.plays)
        for s in w.sounds.items {testing.expect(t,s.placed && s.at=={2,3,4} && s.by==entity)}
        for b in w.births.log.items {testing.expect(t,b.channel==core.birth_channel("dust") && b.position=={2,3,4})}
    }
}

// Something that plays a plain clip plays the Marker_Cue rows on it or under it each time a clip
// crosses their marker, by that entity: the tick a rollback runs again asks the same sound of the
// same entity and tick, which audio plays once, and the same birth by it, which vfx draws once.
// The .character of a rig wins over Marker_Cue rows on it. The rows are found when they change:
// the ticks allocate nothing.
@(test)
marker_cues_play_on_what_plays_a_plain_clip :: proc(t:^testing.T) {
    w:=new(Cue_World)
    defer free(w)
    if !test_world_init(t,w) {return}
    defer test_world_destroy(w)
    CREAK,SLAM,STEP_SET,STEP_ROW:=base.Asset_Id{1,1},base.Asset_Id{1,2},base.Asset_Id{1,3},base.Asset_Id{1,4}
    row :: proc(marker:string,sound:base.Asset_Id,channel:string) -> (cue:Marker_Cue) {
        base.text_set(cue.marker[:],marker)
        base.text_set(cue.cue.channel[:],channel)
        cue.cue.sound=sound
        return
    }
    set_rows:=[1]Marker_Cue{row("step",STEP_SET,"")}
    characters:Character_Assets
    defer delete(characters.contents)
    character:=base.Asset_Id{7,7}
    content:=Character_Content{id=character,valid=true,set={cues=set_rows[:]}}
    ready:=[1]Cue_Ready{}
    content.cues=ready[:]
    marker_cues_ready(set_rows[:],content.cues)
    append(&characters.contents,content)
    door,hinge,rig:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.animations,door,Animation{asset={9,9}})
    core.add(&w.worlds,door,core.World_Transform{transform={position={2,3,4},rotation=1,scale=1}})
    core.add(&w.cues,door,row("creak",CREAK,"dust"))
    core.add(&w.parents,hinge,core.Parent{entity=door})
    core.add(&w.cues,hinge,row("slam",SLAM,""))
    core.add(&w.animations,rig,Animation{asset=character})
    core.add(&w.worlds,rig,core.World_Transform{transform={position={5,0,0},rotation=1,scale=1}})
    core.add(&w.cues,rig,row("step",STEP_ROW,"dust"))
    test_world_settle(w)
    testing.expect(t,reserve(&w.sounds.items,audio.SOUND_REQUESTS)==nil && reserve(&w.births.log.items,core.BIRTHS_CAPACITY)==nil)
    tick :: proc(w:^Cue_World,characters:^Character_Assets,again:bool) {
        animation_cues(core.read(&w.animations),core.ref(&w.events),{},core.ref(characters),{},core.read(&w.cues),&w.index,nil,
            core.read(&w.parents),core.read(&w.worlds),&w.sounds,&w.births,{tick=5,playing=true,resimulating=again},nil)
    }
    // The rows are found as the scene loads.
    tick(w,&characters,false)
    testing.expect_value(t,len(w.index.rows),3)
    Case :: struct {name:string,entity:core.Entity,marker:string,sound:base.Asset_Id,births:int}
    cases:=[]Case{
        {"a row on the prop",door,"creak",CREAK,1},
        {"a row under the prop",door,"slam",SLAM,0},
        {"a marker no row names",door,"other",{},0},
        {"the .character of a rig wins over its rows",rig,"step",STEP_SET,0},
    }
    for c in cases {
        for again in ([2]bool{false,true}) {
            clear(&w.events.items)
            core.push(&w.events.queue,Animation_Event{entity=c.entity,kind=.Marker,name=base.name_hash(c.marker)})
            _=core.take(&w.sounds.queue)
            clear(&w.births.log.items)
            tracker:mem.Tracking_Allocator
            mem.tracking_allocator_init(&tracker,context.allocator)
            {
                context.allocator=mem.tracking_allocator(&tracker)
                tick(w,&characters,again)
            }
            testing.expectf(t,tracker.total_allocation_count==0,"%s: the tick allocates",c.name)
            mem.tracking_allocator_destroy(&tracker)
            sounds:=1 if c.sound!={} else 0
            testing.expectf(t,len(w.sounds.items)==sounds && len(w.births.log.items)==c.births,"%s (again: %v): %d sounds and %d births, wants %d and %d",c.name,again,len(w.sounds.items),len(w.births.log.items),sounds,c.births)
            for s in w.sounds.items {testing.expectf(t,s.sound==c.sound && s.by==c.entity && s.placed,"%s: %v",c.name,s)}
            for b in w.births.log.items {testing.expectf(t,b.by==c.entity && b.position=={2,3,4},"%s: %v",c.name,b)}
        }
    }
}
