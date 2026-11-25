package anim

import "core:testing"
import "core:log"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"

@(private) Timeline_Flag :: enum u8 {Lit,Flickers}
@(private)
Timeline_Lamp :: struct {
    color:[4]f32,
    intensity:f64,
    on:bool,
    steps:i16,
    flags:bit_set[Timeline_Flag;u8],
    mode:Timeline_Flag,
}

@(private)
@(test_world)
Timeline_World :: struct {
    using world:Test_World,
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
    lives:core.Table(erender.Material_Live),
    hiddens:core.Table(erender.Hidden),
}

@(private)
Timeline_Track :: struct {target:string,property:lib.Property,keys:[]lib.Keyframe}

// A clip "open" of an .anim the application holds, with its "@field" curves as the load finds them.
@(private)
timeline_content :: proc(t:^testing.T,app:^host.App,id:base.Asset_Id,tracks:[]Timeline_Track,markers:[]asset.Animation_Marker_Desc={},name:string="open") -> bool {
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
    source.markers=make([]host.Content_Marker,len(markers),app.allocator)
    for marker,i in markers {
        marks[i]={time=marker.time,id=u32(i),duration=marker.duration}
        source.markers[i].name=base.name_hash(marker.name)
        if marker.target!="" {source.markers[i].target=base.name_hash(marker.target);base.text_set(source.markers[i].text[:],marker.name)}
    }
    clip,error:=lib.clip_add(&source.lib,{name=base.name_hash(name),tracks=descs,markers=marks})
    if !testing.expect(t,clip==1 && error==.None) {return false}
    host.content_animation_loops(&source.lib,1)
    source.names=make([][asset.ANIMATION_NAME_CAPACITY]u8,1,app.allocator)
    base.text_set(source.names[0][:],name)
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
    extra:Test_Storages;defer test_storages_free(&extra)
    test_tick(core.read(&w.animations),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),core.read(&w.names),&w.requests,&w.events,core.read(&w.targets),&w.playback,app,time,{},nil,problems,&extra)
    animation_fields(test_world_ref(w),core.ref(&w.playback),&w.fields,{},app,problems)
    constraints:Modifier_Runtime;defer modifier_runtime_free(&constraints)
    animation_finish(&w.playback,{problems=problems},&constraints,&w.transforms,&w.parents,dt,places=&w.places)
    test_world_settle(w)
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
        {"actor/@field/Hidden",.Float,flag},          // given from a half up, taken below
        {"actor/@field/Timeline_Lamp",.Float,flag},   // a component with fields is not given
        {"actor/@field/Timeline_Lamp.mode",.Float,ramp},  // an enum
        {"actor/@field/Timeline_Lamp.color",.Float,ramp}, // a color from a Float track
        {"actor/@field/Timeline_Lamp.nothing",.Float,ramp},
        {"actor/@field/Nothing.x",.Float,ramp},
        {"nobody/@field/Timeline_Lamp.color",.Vector,grow},
        {"leaf/@field/Timeline_Lamp.intensity",.Float,ramp}, // the leaf has no lamp: nothing to write
    },{{time=.6,name="half"}}) {return}
    w:Timeline_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
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
    test_world_settle(&w)
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
    testing.expect(t,animation_playing(core.ref(&w.playback),door),"a command plays a clip whose Animation does not")
    testing.expect_value(t,at(&w,door),[3]f32{0,1,0})
    testing.expect_value(t,at(&w,leaf),[3]f32{2,0,0})
    testing.expect_value(t,at(&w,actor),[3]f32{2,0,0})
    testing.expect_value(t,at(&w,other),[3]f32{0,0,0})
    progress,_:=core.get(&w.progress,door)
    testing.expect_value(t,progress.time,f32(3))
    lamp,_:=core.get(&w.lamps,actor)
    testing.expect_value(t,lamp,Timeline_Lamp{color={1.5,2,2.5,0},intensity=3,steps=-2,flags={.Lit}})
    testing.expect(t,!core.has(&w.hiddens,actor),"shown before its key")

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
    testing.expect(t,len(w.events.items)==2 && w.events.items[0].kind==.Started &&
        w.events.items[0].clip==base.name_hash("open") && w.events.items[0].action==0 &&
        w.events.items[1].entity==door && w.events.items[1].kind==.Marker &&
        w.events.items[1].name==base.name_hash("half"))
    lamp,_=core.get(&w.lamps,actor)
    testing.expect(t,lamp.on && lamp.flags=={.Lit,.Flickers} && lamp.intensity==5,"a Float track sets a flag and a member of a bit set from a half up")
    testing.expect(t,core.has(&w.hiddens,actor),"a Float track gives a component without fields from a half up")

    // An entity whose Transform another component owns is asked of its owner, at the place of the track.
    testing.expect(t,core.owner_set(&w.transforms,leaf,1))
    animation_command(&w.requests,door,.Seek,.25)
    timeline_tick(&w,&app,&problems)
    testing.expect_value(t,at(&w,leaf),[3]f32{6,0,0})
    if testing.expect_value(t,len(w.places.queue.items),1) {
        asked:=w.places.queue.items[0]
        testing.expect(t,asked.entity==leaf && asked.position==[3]f32{4,2,0},"the place is in the world: under the door the clip moved")
    }
    clear(&w.places.queue.items)
    testing.expect(t,core.owner_set(&w.transforms,leaf,0))

    // Stop takes it back to its start and it waits there; the end of a clip that does not loop holds.
    animation_command(&w.requests,door,.Stop)
    timeline_tick(&w,&app,&problems)
    testing.expect(t,!animation_playing(core.ref(&w.playback),door))
    testing.expect(t,w.events.items[len(w.events.items)-1].kind==.Interrupted &&
        w.events.items[len(w.events.items)-1].clip==base.name_hash("open"))
    testing.expect_value(t,at(&w,leaf),[3]f32{0,0,0})
    testing.expect(t,!core.has(&w.hiddens,actor),"and takes it below a half")
    // Animation.playing only starts it: once it plays, the game writing it changes nothing.
    core.edit(&w.animations,door).playing=true
    timeline_tick(&w,&app,&problems)
    testing.expect(t,!animation_playing(core.ref(&w.playback),door))
    play_clip(&w.requests,door,"open",fade=0,loop=false,speed=2)
    timeline_tick(&w,&app,&problems)
    play_clip(&w.requests,door,"open",speed=1)
    timeline_tick(&w,&app,&problems)
    at_time,_,_,_:=animation_progress(core.ref(&w.playback),door)
    testing.expect_value(t,at_time,f32(.75))
    play_clip(&w.requests,door,"open",restart=true)
    timeline_tick(&w,&app,&problems)
    at_time,_,_,_=animation_progress(core.ref(&w.playback),door)
    testing.expect_value(t,at_time,f32(.25))
    for _ in 0..<7 {timeline_tick(&w,&app,&problems)}
    testing.expect_value(t,at(&w,leaf),[3]f32{8,0,0})
    _,_,ended,_:=animation_progress(core.ref(&w.playback),door)
    testing.expect(t,ended)
    last:=w.events.items[len(w.events.items)-1]
    testing.expect(t,last.kind==.Ended && last.clip==base.name_hash("open") &&
        last.animation==id)

    // What a track cannot write is a problem of the entity that plays it, each with its cause.
    for code in ([]string{"animation.field_type","animation.field_path","animation.field_component","animation.field_target"}) {
        testing.expectf(t,core.problem_find(&problems,door,code)!=nil,"%s was not reported",code)
    }
    lamp,_=core.get(&w.lamps,actor)
    testing.expect_value(t,lamp.steps,min(i16))
    testing.expect_value(t,len(w.fields.fields),8)
    // Resume at a negative speed takes it back from where it is.
    animation_command(&w.requests,door,.Resume,speed=-1)
    timeline_tick(&w,&app,&problems)
    testing.expect(t,animation_playing(core.ref(&w.playback),door) && at(&w,leaf)==[3]f32{6,0,0})
    // A command needs an Animation, a real command and a finite time.
    animation_command(&w.requests,leaf,.Play)
    timeline_tick(&w,&app,&problems)
    testing.expect(t,core.problem_find(&problems,leaf,"animation.command")!=nil)
    refused:=w.requests.timeline.refused
    animation_command(&w.requests,core.NONE,.Play)
    animation_command(&w.requests,door,Timeline_Command(200))
    animation_command(&w.requests,door,.Seek,f32(0h7fc00000))
    animation_command(&w.requests,door,.Resume,speed=f32(0h7f800000))
    animation_command(nil,door,.Play)
    testing.expect_value(t,w.requests.timeline.refused,refused+4)
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
        {"@field/Hidden","","Hidden","",true},
        {"Gun/Magazine/@field/Hidden","Gun/Magazine","Hidden","",true},
        {target="Lamp"},{target=""},{target="@field/"},{target="@field/.x"},{target="@field/Light."},
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

@(test)
a_character_plays_an_explicit_additive_clip_over_its_base :: proc(t:^testing.T) {
    assets:host.Assets
    app:=host.App{assets=&assets,allocator=context.allocator}
    defer {host.app_content_destroy(&app);test_registry_free(&assets)}
    w:Timeline_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    extra:Test_Storages
    defer test_storages_free(&extra)
    primary,gesture,character:=base.Asset_Id{8,1},base.Asset_Id{8,2},base.Asset_Id{8,3}
    if !timeline_content(t,&app,primary,{{"",.Position,{{time=1,value={2,0,0,0}}}}},
        name="idle") {return}
    if !timeline_content(t,&app,gesture,{{"",.Position,{{time=0},{time=1,value={0,4,0,0}}}}},
        name="rise") {return}
    test_character_register(&assets,character)
    layers:=[1]Stack_Layer{STACK_LAYER_DEFAULT}
    base.text_set(layers[0].name[:],"gesture")
    test_character_seed(&extra.characters,character,{info={animation=primary},
        actions={layers=layers[:]}})
    e:=timeline_named(&w,"actor")
    animation:=ANIMATION_DEFAULT
    animation.asset=character
    core.add(&w.animations,e,animation)
    test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    play_clip(&w.requests,e,"rise",asset=gesture,layer="gesture",additive=true,
        weight=.5,fade=0,speed=2)
    problems:core.Problems
    test_tick(core.read(&w.animations),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),
        core.read(&w.names),&w.requests,&w.events,core.read(&w.targets),&w.playback,&app,
        {dt=.25,playing=true},{},nil,&problems,&extra)
    if !testing.expect(t,len(w.playback.states)==1 && len(playing_pose(&w.playback.states[0],.Local))>0) {return}
    testing.expect_value(t,playing_pose(&w.playback.states[0],.Local)[0].position,[3]f32{2,1,0})
    for event in w.events.items {
        if event.kind==.Started && event.clip==base.name_hash("rise") {
            testing.expect(t,event.animation==gesture && event.action==0)
            testing.expect_value(t,problems.count,0)
            return
        }
    }
    testing.expect(t,false,"the additive clip did not report its source and name")
}

// A prop or a timeline plays its clip alone: it makes no stack, no inertia, no matching and no
// retarget, so its state stays small, and a copy of its world (Play, a rollback snapshot) carries
// its clock, bindings and pose without the work of a tick; a copy back into a world that played
// allocates nothing.
@(test)
props_play_without_a_stack_and_copy_only_what_they_simulate :: proc(t:^testing.T) {
    problems:core.Problems
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    id:=base.Asset_Id{0x71,0x73}
    rise:=[]lib.Keyframe{{time=0,value={0,0,0,0}},{time=1,value={0,4,0,0}}}
    ramp:=[]lib.Keyframe{{time=0,value={2,0,0,0}},{time=1,value={6,0,0,0}}}
    if !timeline_content(t,&app,id,{{"",.Position,rise},{"leaf",.Position,rise},{"@field/Animation_Progress.time",.Float,ramp}}) {return}
    w:Timeline_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    PROPS :: 64
    doors:[PROPS]core.Entity
    for &door in doors {
        door=timeline_named(&w,"door")
        timeline_named(&w,"leaf",door)
        animation:=ANIMATION_DEFAULT;animation.asset=id
        core.add(&w.animations,door,animation)
        core.add(&w.progress,door,Animation_Progress{})
    }
    test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    for _ in 0..<2 {timeline_tick(&w,&app,&problems)}
    animation_command(&w.requests,doors[0],.Pause)
    timeline_tick(&w,&app,&problems)
    progress,_:=core.get(&w.progress,doors[1])
    sought,_:=core.get(&w.progress,doors[0])
    testing.expectf(t,problems.count==0 && len(w.playback.states)==PROPS && progress.time==5 && sought.time==4,"the props play, pause their clips and write their fields: %d problems, %v and %v",problems.count,progress.time,sought.time)
    for &state in w.playback.states {
        testing.expect(t,state.stack==nil && state.program.players==nil && state.follow==nil,"a prop has no stack, matching or follow")
    }
    // Taken into a world that never played, and back into this one.
    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    copied:Playback;defer playback_free(&copied)
    {
        context.allocator=mem.tracking_allocator(&tracking)
        testing.expect(t,playback_copy(&copied,&w.playback))
    }
    taken,bytes:=tracking.total_allocation_count,tracking.total_memory_allocated
    for &state in copied.states {testing.expect(t,state.stack==nil)}
    testing.expect(t,len(copied.work.rows)==0 && len(copied.work.contents)==0 && len(copied.work.jobs)==0,"a copy carries no work of a tick")
    // What one prop costs a copy is less than a stack alone would.
    testing.expectf(t,int(bytes)/PROPS<size_of(Playing)+size_of(Stack_Playing),"a copy takes %d B a prop",int(bytes)/PROPS)
    back:mem.Tracking_Allocator;mem.tracking_allocator_init(&back,context.allocator)
    {
        context.allocator=mem.tracking_allocator(&back)
        testing.expect(t,playback_copy(&w.playback,&copied))
    }
    again:=back.total_allocation_count;mem.tracking_allocator_destroy(&back)
    testing.expectf(t,again==0,"a copy back into a world that played allocates nothing (%d allocations)",again)
    timeline_tick(&w,&app,&problems)
    testing.expect(t,problems.count==0)
    log.infof("copy of %d props: %d allocations, %d B, Playing %d B (before the split of the stack and its scratch: 458 allocations, 450332 B, Playing 6416 B)",PROPS,taken,bytes,size_of(Playing))
}

// The "@field/Material_Live" curves of a clip are the look of the meshes of its rig: the render
// phase gives it them (animation_skin), of slot 0, of a slot or of every one, as their keys step,
// and takes it away when the curve stops or the clip changes. The fields the fixed phase writes
// leave Material_Live alone, so a server or a rollback never writes it.
@(test)
material_live_curves_give_the_meshes_of_a_rig_their_look_in_the_render_phase :: proc(t:^testing.T) {
    problems:core.Problems
    assets:host.Assets;app:=host.App{assets=&assets,allocator=context.allocator};defer host.app_content_destroy(&app)
    face_id,plain_id:=base.Asset_Id{0x7a,1},base.Asset_Id{0x7a,2}
    frames:=[]lib.Keyframe{{time=0},{time=.5,value={1,0,0,0},interpolation=.Step},
        {time=1,value={2,0,0,0},interpolation=.Step}}
    glow:=[]lib.Keyframe{{time=0},{time=1,value={4,2,0,0}}}
    rough:=[]lib.Keyframe{{time=0,value={.5,0,0,0}},{time=1,value={.5,0,0,0}}}
    if !timeline_content(t,&app,face_id,{
        {"@field/Material_Live.1.frame",.Float,frames},
        {"@field/Material_Live.*.emission",.Vector,glow},
        {"@field/Material_Live.roughness",.Float,rough},
        {"@field/Material_Live.9.frame",.Float,frames}, // past the slots: written nowhere
    }) {return}
    if !timeline_content(t,&app,plain_id,{{"",.Position,rough}}) {return}
    w:Timeline_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    face:=timeline_named(&w,"face")
    animation:=ANIMATION_DEFAULT;animation.asset,animation.loop,animation.fade=face_id,false,0
    core.add(&w.animations,face,animation)
    test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    for _ in 0..<3 {timeline_tick(&w,&app,&problems,.3)}
    time,_,_,_:=animation_progress(core.ref(&w.playback),face)
    testing.expectf(t,time>.5 && time<1,"between the keys of its frames: %v",time)
    testing.expect(t,problems.count==0 && core.count(&w.lives)==0,"the fixed phase writes no look")
    cache:Skin_Runtime;defer skin_runtime_free(&cache)
    meshes:=[2]core.Entity{core.create(&w.entities),core.create(&w.entities)}
    instances:[2]Skin_Instance
    state:=constraint_playing(core.ref(&w.playback),face)
    draw :: proc(w:^Timeline_World,cache:^Skin_Runtime,instances:^[2]Skin_Instance,meshes:[2]core.Entity,
        state:^Playing,app:^host.App,problems:^core.Problems) {
        for mesh,i in meshes {
            material_curves_apply(cache,&instances[i],&w.lives,mesh,2,core.ref(&w.playback),state,{},app,problems)
        }
        test_world_settle(w)
    }
    value :: proc(w:^Timeline_World,mesh:core.Entity,slot:int,name:string) -> (found:[4]f32,ok:bool) {
        live:=core.get(&w.lives,mesh) or_return
        at:=erender.material_value_find(&live,slot,base.name_hash(name))
        return live.values[at] if at>=0 else {},at>=0
    }
    draw(&w,&cache,&instances,meshes,state,&app,&problems)
    for mesh in meshes {
        live,_:=core.get(&w.lives,mesh)
        frame,framed:=value(&w,mesh,1,"frame")
        testing.expectf(t,framed && frame==[4]f32{1,0,0,0},"slot 1 shows the frame its keys step to: %v",frame)
        _,unslotted:=value(&w,mesh,0,"frame")
        lit,lit_ok:=value(&w,mesh,0,"emission");lit_too,lit_too_ok:=value(&w,mesh,1,"emission")
        testing.expectf(t,!unslotted && lit_ok && lit_too_ok && lit==lit_too && abs(lit.x-4*time)<1e-4 &&
            abs(lit.y-2*time)<1e-4,"every slot glows as its Vector curve: %v",lit)
        surface,surface_ok:=value(&w,mesh,0,"roughness")
        testing.expect(t,surface_ok && surface==[4]f32{.5,0,0,0},"an unslotted value is of slot 0")
        testing.expect_value(t,live.count,4)
    }
    testing.expect(t,core.problem_find(&problems,face,"animation.material_field")!=nil,
        "a field past the slots is a problem of the rig")
    // A curve that stops takes its values away, and the component with the last of them.
    for &curve in state.curves {curve.weight=0}
    draw(&w,&cache,&instances,meshes,state,&app,&problems)
    testing.expect(t,!core.has(&w.lives,meshes[0]) && !core.has(&w.lives,meshes[1]))
    timeline_tick(&w,&app,&problems,.05)
    draw(&w,&cache,&instances,meshes,state,&app,&problems)
    testing.expect(t,core.has(&w.lives,meshes[0]) && core.has(&w.lives,meshes[1]),"they play again")
    // A clip without them takes them away, and so does the change on the mesh of the rig alone.
    core.edit(&w.animations,face).asset=plain_id
    timeline_tick(&w,&app,&problems,.05)
    draw(&w,&cache,&instances,meshes,state,&app,&problems)
    testing.expect(t,!core.has(&w.lives,meshes[0]) && !core.has(&w.lives,meshes[1]),"the new clip has no look")
    for code in ([3]string{"animation.field_component","animation.field_path","animation.field_type"}) {
        testing.expectf(t,core.problem_find(&problems,face,code)==nil,"the fields leave Material_Live alone: %s",code)
    }
}

@(test)
a_material_live_field_names_a_slot_and_a_value :: proc(t:^testing.T) {
    Case :: struct {field:string,slot:int,parameter:string,ok:bool}
    cases:=[]Case{
        {"emission",0,"emission",true},{"1.frame",1,"frame",true},{"*.emission",-1,"emission",true},
        {"7.base_color",7,"base_color",true},
        {field="8.frame"},{field="12.frame"},{field=""},{field=".frame"},{field="1."},{field="a.frame"},
        {field="1.a.b"},{field="*."},{field="-1.frame"},
    }
    for c in cases {
        slot,parameter,ok:=material_field(c.field)
        testing.expectf(t,ok==c.ok && (!ok || slot==c.slot && parameter==c.parameter),"%q: %d %q %v",c.field,slot,parameter,ok)
    }
}

// A prop plays its clip alone, without a stack; an additive clip a command plays over the clip of
// an entity without a .character makes its stack and plays in its first slot.
@(test)
an_additive_clip_over_an_entity_without_a_character_plays_in_the_first_slot_of_its_stack :: proc(t:^testing.T) {
    assets:host.Assets
    app:=host.App{assets=&assets,allocator=context.allocator}
    defer host.app_content_destroy(&app)
    w:Timeline_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    primary,gesture:=base.Asset_Id{8,11},base.Asset_Id{8,12}
    if !timeline_content(t,&app,primary,{{"",.Position,{{time=1,value={2,0,0,0}}}}},name="idle") {return}
    if !timeline_content(t,&app,gesture,{{"",.Position,{{time=0},{time=1,value={0,4,0,0}}}}},
        name="rise") {return}
    prop,actor:=timeline_named(&w,"prop"),timeline_named(&w,"actor")
    for e in ([2]core.Entity{prop,actor}) {
        animation:=ANIMATION_DEFAULT;animation.asset=primary
        core.add(&w.animations,e,animation)
    }
    test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    play_clip(&w.requests,actor,"rise",asset=gesture,additive=true,weight=.5,fade=0,speed=2)
    problems:core.Problems
    timeline_tick(&w,&app,&problems)
    plain,layered:=constraint_playing(core.ref(&w.playback),prop),constraint_playing(core.ref(&w.playback),actor)
    if !testing.expect(t,plain!=nil && layered!=nil) {return}
    testing.expect(t,plain.stack==nil,"a prop makes no stack")
    if !testing.expect(t,layered.stack!=nil && layered.stack.slots==1) {return}
    testing.expect(t,layered.stack.clips[0].active && layered.stack.clips[0].additive)
    testing.expect_value(t,playing_pose(layered,.Local)[0].position,[3]f32{2,1,0})
    started:=false
    for event in w.events.items {
        started ||= event.kind==.Started && event.clip==base.name_hash("rise") &&
            event.animation==gesture && event.group==1
    }
    testing.expect(t,started && problems.count==0,"the clip tells it started, of its .anim, in slot 0")
}

// Each slot of the stack of a .character plays its own: a clip a command plays in a layer, of any
// .anim, or an action, which takes the slot from the clip there and tells it interrupted it.
// Actions that end in the same tick each chain their next clip in their own slot.
@(test)
each_slot_of_a_stack_plays_its_own_clip_or_action :: proc(t:^testing.T) {
    assets:host.Assets
    app:=host.App{assets=&assets,allocator=context.allocator}
    defer {host.app_content_destroy(&app);test_registry_free(&assets)}
    w:Timeline_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    extra:Test_Storages
    defer test_storages_free(&extra)
    primary,swing,character:=base.Asset_Id{9,1},base.Asset_Id{9,2},base.Asset_Id{9,3}
    waves:=[4]base.Asset_Id{{9,4},{9,5},{9,6},{9,7}}
    if !timeline_content(t,&app,primary,{{"",.Position,{{time=1,value={2,0,0,0}}}}},name="idle") {return}
    if !timeline_content(t,&app,swing,{{"",.Position,{{time=0},{time=.5,value={0,1,0,0}}}}},
        name="swing") {return}
    for id,i in waves {
        if !timeline_content(t,&app,id,{{"",.Position,{{time=0},{time=1,value={0,0,f32(i+1),0}}}}},
            name="wave") {return}
    }
    test_character_register(&assets,character)
    names:=[4]string{"a","b","c","d"}
    layers:[4]Stack_Layer
    for &layer,i in layers {layer=STACK_LAYER_DEFAULT;base.text_set(layer.name[:],names[i])}
    definitions:[2]Action_Definition
    for &definition,i in definitions {
        definition=ACTION_DEFINITION_DEFAULT;definition.animation=swing
        base.text_set(definition.name[:],"swing_a" if i==0 else "swing_b")
        base.text_set(definition.clip[:],"swing");base.text_set(definition.layer[:],names[i])
    }
    test_character_seed(&extra.characters,character,{info={animation=primary},
        actions={layers=layers[:],actions=definitions[:]}})
    e:=timeline_named(&w,"actor")
    animation:=ANIMATION_DEFAULT;animation.asset=character
    core.add(&w.animations,e,animation)
    test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    problems:core.Problems
    tick :: proc(w:^Timeline_World,app:^host.App,extra:^Test_Storages,problems:^core.Problems) {
        clear(&w.events.items)
        test_tick(core.read(&w.animations),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),
            core.read(&w.names),&w.requests,&w.events,core.read(&w.targets),&w.playback,app,
            {dt=.1,playing=true},{},nil,problems,extra)
    }
    // A wave of another .anim in each layer: four sources besides those of the set play at once.
    for id,i in waves {play_clip(&w.requests,e,"wave",asset=id,layer=names[i],fade=0)}
    tick(&w,&app,&extra,&problems)
    state:=constraint_playing(core.ref(&w.playback),e)
    if !testing.expect(t,state!=nil && state.stack!=nil) {return}
    started:[4]bool
    for event in w.events.items {
        slot:=int(event.group)-2
        if event.kind==.Started && event.clip==base.name_hash("wave") && slot>=0 && slot<4 {
            started[slot]=event.animation==waves[slot]
        }
    }
    testing.expectf(t,problems.count==0 && started==[4]bool{true,true,true,true},
        "each layer plays the wave of its .anim: %v, %d problems",started,problems.count)
    testing.expect_value(t,len(source_ids(core.ref(&extra.sources),state)),6)
    // The actions take their slots from the waves there, which they interrupt.
    play(&w.requests,e,"swing_a",next_clip="swing")
    play(&w.requests,e,"swing_b",next_clip="swing")
    tick(&w,&app,&extra,&problems)
    interrupted:=0
    for event in w.events.items {
        if event.kind==.Interrupted && event.clip==base.name_hash("wave") {interrupted+=1}
    }
    clips:=&state.stack.clips
    testing.expect(t,interrupted==2 && !clips[1].active && !clips[2].active && clips[3].active &&
        clips[4].active,"two actions interrupt the waves of their slots, the others play on")
    // Both end in one tick and chain their next clip each in its slot, the tick after.
    ended,chained:[2]int
    for tick_index in 1..=12 {
        tick(&w,&app,&extra,&problems)
        for event in w.events.items {
            for name,i in ([2]string{"swing_a","swing_b"}) {
                if event.kind==.Ended && event.action==base.name_hash(name) {ended[i]=tick_index}
            }
            slot:=int(event.group)-2
            if event.kind==.Started && event.action==0 && event.clip==base.name_hash("swing") &&
                slot>=0 && slot<2 && event.animation==swing {chained[slot]=tick_index}
        }
    }
    testing.expectf(t,ended[0]>0 && ended[0]==ended[1] && chained==[2]int{ended[0]+1,ended[0]+1},
        "ended %v, chained %v",ended,chained)
    testing.expect_value(t,problems.count,0)
}
