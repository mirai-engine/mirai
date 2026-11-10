package anim

import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"

@(private="file") Timeline_Flag :: enum u8 {Lit,Flickers}
@(private="file")
Timeline_Lamp :: struct {
    color:[4]f32,
    intensity:f64,
    on:bool,
    steps:i16,
    flags:bit_set[Timeline_Flag;u8],
    mode:Timeline_Flag,
}

@(private="file")
Timeline_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    names:core.Table(core.Name),
    targets:core.Table(Animation_Target),
    animations:core.Table(Animation),
    progress:core.Table(Animation_Progress),
    lamps:core.Table(Timeline_Lamp),
    hierarchy:core.Hierarchy,
    places:core.Places,
    requests:Animation_Requests,
    events:Animation_Events,
    playback:Playback,
    fields:Field_Playback,
    constraints:Animation_Constraints,
}

@(private="file")
Timeline_Track :: struct {target:string,property:lib.Property,keys:[]lib.Keyframe}

// A clip "open" of an .anim the application holds, with its "@field" curves as the load finds them.
@(private="file")
timeline_content :: proc(t:^testing.T,app:^host.App,id:base.Asset_Id,tracks:[]Timeline_Track,markers:[]asset.Animation_Marker_Desc={}) -> bool {
    source:=host.Content_Animation{id=id,generation=1,clip_count=1}
    keys:=0
    for track in tracks {keys+=len(track.keys)}
    if !testing.expect(t,lib.library_init(&source.lib,{max_clips=2,max_tracks=max(len(tracks),1),max_keys=max(keys,1),max_markers=len(markers),allocator=app.allocator})) {return false}
    descs:=make([]lib.Track_Desc,len(tracks),context.temp_allocator)
    rows:=make([]asset.Animation_Track,len(tracks),context.temp_allocator)
    for track,i in tracks {
        descs[i]={target=base.name_hash(track.target) if track.target!="" else 0,property=track.property,keys=track.keys}
        rows[i].property=track.property
        base.text_set(rows[i].target[:],track.target)
    }
    marks:=make([]lib.Marker,len(markers),context.temp_allocator)
    source.markers=make([]u64,len(markers),app.allocator)
    for marker,i in markers {marks[i]={time=marker.time,id=u32(i)};source.markers[i]=base.name_hash(marker.name)}
    clip,error:=lib.clip_add(&source.lib,{name=base.name_hash("open"),tracks=descs,markers=marks})
    if !testing.expect(t,clip==1 && error==.None) {return false}
    host.content_animation_loops(&source.lib,1)
    source.names=make([][asset.ANIMATION_NAME_CAPACITY]u8,1,app.allocator)
    base.text_set(source.names[0][:],"open")
    source.roots=make([]asset.Animation_Root,1,app.allocator)
    fielded:bool
    source.fields,fielded=host.content_animation_fields({tracks=rows},app.allocator)
    content:=host.app_content(app)
    append(&content.animations,source);content.index[id]={kind=.Animation,index=u32(len(content.animations)-1)}
    return testing.expect(t,fielded)
}

@(private="file")
timeline_tick :: proc(w:^Timeline_World,app:^host.App,problems:^core.Problems,dt:f32=.25) {
    time:=core.Time{dt=dt,playing=true}
    animation_tick(&w.animations,&w.transforms,&w.parents,core.ref(&w.hierarchy),&w.names,&w.requests,&w.events,&w.targets,{},&w.playback,app,time,{},nil,problems)
    animation_fields(core.test_world_ref(w),core.ref(&w.playback),&w.fields,{},app,problems)
    animation_finish(&w.playback,{problems=problems},&w.constraints,&w.transforms,&w.parents,dt,nil,{},places=&w.places)
    core.test_world_settle(w)
}

@(private="file")
timeline_named :: proc(w:^Timeline_World,text:string,parent:=core.NONE,transform:=core.TRANSFORM_IDENTITY) -> core.Entity {
    e:=core.create(&w.entities)
    name:core.Name;base.text_set(name.text[:],text)
    core.add(&w.names,e,name);core.add(&w.transforms,e,transform)
    if parent!=core.NONE {core.add(&w.parents,e,core.Parent{entity=parent})}
    return e
}

// A clip is the one timeline: its tracks move the entity that plays it, what is below it by name,
// an entity anywhere that names it, and the fields of their components; the commands of one queue
// play, pause, resume, stop and seek it, and a clip that does not move leaves what it drives alone.
@(test)
a_clip_drives_the_transforms_and_the_fields_it_is_bound_to_while_it_moves :: proc(t:^testing.T) {
    problems:core.Problems
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    id:=base.Asset_Id{0x71,0x72}
    rise:=[]lib.Keyframe{{time=0,value={0,0,0,0}},{time=1,value={0,4,0,0}}}
    slide:=[]lib.Keyframe{{time=0,value={0,0,0,0}},{time=1,value={8,0,0,0}}}
    ramp:=[]lib.Keyframe{{time=0,value={2,0,0,0}},{time=1,value={6,0,0,0}}}
    grow:=[]lib.Keyframe{{time=0,value={1,1,1,0}},{time=1,value={3,5,7,0}}}
    dive:=[]lib.Keyframe{{time=0,value={-2.4,0,0,0}},{time=1,value={-1e9,0,0,0},interpolation=.Step}}
    flag:=[]lib.Keyframe{{time=0,value={0,0,0,0}},{time=.5,value={1,0,0,0},interpolation=.Step}}
    if !timeline_content(t,&app,id,{
        {"",.Position,rise},{"leaf",.Position,slide},{"actor",.Position,slide},
        {"@field/Animation_Progress.time",.Float,ramp},
        {"actor/@field/Timeline_Lamp.color",.Vector,grow},
        {"actor/@field/Timeline_Lamp.intensity",.Float,ramp},
        {"actor/@field/Timeline_Lamp.on",.Float,flag},
        {"actor/@field/Timeline_Lamp.steps",.Float,dive},
        {"actor/@field/Timeline_Lamp.flags.Flickers",.Float,flag},
        {"actor/@field/Timeline_Lamp.mode",.Float,ramp},  // an enum
        {"actor/@field/Timeline_Lamp.color",.Float,ramp}, // a color from a Float track
        {"actor/@field/Timeline_Lamp.nothing",.Float,ramp},
        {"actor/@field/Nothing.x",.Float,ramp},
        {"nobody/@field/Timeline_Lamp.color",.Vector,grow},
        {"leaf/@field/Timeline_Lamp.intensity",.Float,ramp}, // the leaf has no lamp: nothing to write
    },{{time=.6,name="half"}}) {return}
    w:Timeline_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    door:=timeline_named(&w,"door")
    leaf:=timeline_named(&w,"leaf",door)
    actor:=timeline_named(&w,"somebody")
    other:=timeline_named(&w,"actor") // has the name of the track and is not below the door
    target:Animation_Target;base.text_set(target.path[:],"actor");target.animation=door
    core.add(&w.targets,actor,target)
    core.add(&w.lamps,actor,Timeline_Lamp{flags={.Lit}})
    animation:=ANIMATION_DEFAULT;animation.asset,animation.loop,animation.fade,animation.playing=id,false,0,false
    core.add(&w.animations,door,animation)
    core.add(&w.progress,door,Animation_Progress{})
    core.test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    at :: proc(w:^Timeline_World,e:core.Entity) -> [3]f32 {value,_:=core.get(&w.transforms,e);return value.position}

    // Not playing, it writes where its clip starts once, and then leaves what it drives alone.
    timeline_tick(&w,&app,&problems)
    testing.expect_value(t,at(&w,leaf),[3]f32{0,0,0})
    core.edit(&w.transforms,leaf).position={9,9,9}
    timeline_tick(&w,&app,&problems)
    testing.expect_value(t,at(&w,leaf),[3]f32{9,9,9})
    testing.expect(t,len(w.events.items)==0)

    // Play starts it from its start; every kind of target follows its track.
    animation_command(&w.requests,door,.Play)
    timeline_tick(&w,&app,&problems)
    testing.expect(t,animation_playing(&w.playback,door),"a command plays a clip whose Animation does not")
    testing.expect_value(t,at(&w,door),[3]f32{0,1,0})
    testing.expect_value(t,at(&w,leaf),[3]f32{2,0,0})
    testing.expect_value(t,at(&w,actor),[3]f32{2,0,0})
    testing.expect_value(t,at(&w,other),[3]f32{0,0,0})
    progress,_:=core.get(&w.progress,door)
    testing.expect_value(t,progress.time,f32(3))
    lamp,_:=core.get(&w.lamps,actor)
    testing.expect_value(t,lamp,Timeline_Lamp{color={1.5,2,2.5,0},intensity=3,steps=-2,flags={.Lit}})

    // Paused it holds nothing; resumed it goes on from where it was, and reports the marker it crosses.
    animation_command(&w.requests,door,.Pause)
    timeline_tick(&w,&app,&problems)
    core.edit(&w.transforms,leaf).position={9,9,9}
    core.edit(&w.lamps,actor).intensity=40
    timeline_tick(&w,&app,&problems)
    testing.expect_value(t,at(&w,leaf),[3]f32{9,9,9})
    lamp,_=core.get(&w.lamps,actor)
    testing.expect_value(t,lamp.intensity,f64(40))
    animation_command(&w.requests,door,.Resume)
    timeline_tick(&w,&app,&problems)
    testing.expect_value(t,at(&w,leaf),[3]f32{4,0,0})
    timeline_tick(&w,&app,&problems)
    testing.expect_value(t,at(&w,leaf),[3]f32{6,0,0})
    testing.expect(t,len(w.events.items)==1 && w.events.items[0].entity==door && w.events.items[0].kind==.Marker && w.events.items[0].name==base.name_hash("half"))
    lamp,_=core.get(&w.lamps,actor)
    testing.expect(t,lamp.on && lamp.flags=={.Lit,.Flickers} && lamp.intensity==5,"a Float track sets a flag and a member of a bit set from a half up")

    // An entity whose Transform another component owns is asked of its owner, at the place of the track.
    index:=core.entity_index(leaf)
    resize(&w.transforms.owners,index+1)
    w.transforms.owners[index]={core.entity_generation(leaf),1}
    animation_seek(&w.requests,door,.25)
    timeline_tick(&w,&app,&problems)
    testing.expect_value(t,at(&w,leaf),[3]f32{6,0,0})
    if testing.expect_value(t,len(w.places.queue.items),1) {
        asked:=w.places.queue.items[0]
        testing.expect(t,asked.entity==leaf && asked.position==[3]f32{4,2,0},"the place is in the world: under the door the clip moved")
    }
    clear(&w.places.queue.items)
    w.transforms.owners[index]={}

    // Stop takes it back to its start and it waits there; the end of a clip that does not loop holds.
    animation_command(&w.requests,door,.Stop)
    timeline_tick(&w,&app,&problems)
    testing.expect(t,!animation_playing(&w.playback,door))
    testing.expect_value(t,at(&w,leaf),[3]f32{0,0,0})
    // The Animation is the game's: when the game writes playing, that is what the clip does.
    core.edit(&w.animations,door).playing=true
    timeline_tick(&w,&app,&problems)
    testing.expect(t,animation_playing(&w.playback,door))
    testing.expect_value(t,at(&w,leaf),[3]f32{2,0,0})
    progress,_=core.get(&w.progress,door)
    testing.expect_value(t,progress.transport,Timeline_Transport.Component)
    animation_command(&w.requests,door,.Play)
    for _ in 0..<6 {timeline_tick(&w,&app,&problems)}
    testing.expect_value(t,at(&w,leaf),[3]f32{8,0,0})
    _,_,ended,_:=animation_progress(&w.playback,door)
    testing.expect(t,ended)

    // What a track cannot write is a problem of the entity that plays it, each with its cause.
    for code in ([]string{"animation.field_type","animation.field_path","animation.field_component","animation.field_target"}) {
        testing.expectf(t,core.problem_find(&problems,door,code)!=nil,"%s was not reported",code)
    }
    lamp,_=core.get(&w.lamps,actor)
    testing.expect_value(t,lamp.steps,min(i16))
    testing.expect_value(t,len(w.fields.fields),7)
    // A command needs an Animation, a real command and a finite time.
    animation_command(&w.requests,leaf,.Play)
    timeline_tick(&w,&app,&problems)
    testing.expect(t,core.problem_find(&problems,leaf,"animation.command")!=nil)
    refused:=w.requests.timeline.refused
    animation_command(&w.requests,core.NONE,.Play)
    animation_command(&w.requests,door,Timeline_Command(200))
    animation_command(&w.requests,door,.Seek,f32(0h7fc00000))
    animation_command(nil,door,.Play)
    testing.expect_value(t,w.requests.timeline.refused,refused+3)
    testing.expect_value(t,len(w.requests.timeline.items),0)
}

// The parts of a track target that drives a field, whatever is given.
@(test)
a_field_target_names_its_entity_component_and_field :: proc(t:^testing.T) {
    Case :: struct {target,node,component,field:string,ok:bool}
    long:=make([]u8,asset.ANIMATION_FIELD_CAPACITY+16,context.temp_allocator)
    for &c in long {c='a'}
    cases:=[]Case{
        {"@field/Point_Light.intensity","","Point_Light","intensity",true},
        {"Lamp/@field/Point_Light.color","Lamp","Point_Light","color",true},
        {"Room/Lamp/@field/Camera.lens.fov","Room/Lamp","Camera","lens.fov",true},
        {"a/@field/b/@field/C.d[2]","a/@field/b","C","d[2]",true},
        {target="Lamp"},{target=""},{target="@field/"},{target="@field/Light"},{target="@field/.x"},{target="@field/Light."},
        {target="Lamp@field/Light.x"},{target="Lamp/@morph/smile"},
    }
    for c in cases {
        node,component,field,ok:=asset.animation_field_target(c.target)
        testing.expectf(t,ok==c.ok && node==c.node && component==c.component && field==c.field,"%q: %q %q %q %v",c.target,node,component,field,ok)
    }
    _,_,_,ok:=asset.animation_field_target(string(long))
    testing.expect(t,!ok)
    copy(long,"@field/C.")
    _,_,_,ok=asset.animation_field_target(string(long))
    testing.expect(t,!ok,"a field path too long for its row is no field target")
}
