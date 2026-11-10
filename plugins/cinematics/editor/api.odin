package cinematics_editor

import "core:fmt"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import aed "plugins:animation/editor"
import anim "plugins:animation/runtime"
import cine "plugins:cinematics/runtime"

@(storage)
Cinematics_Api :: struct {provider:editor.Api_Provider}
CINEMATICS_API_DEFAULT :: Cinematics_Api{provider={register=register}}

Inspect_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The timeline or one of its shots viewers or actors"`,
    time:f32 `mirai:"optional,min=-1,unit=s,label=The time of the clip whose shot is given; -1: the head of the Tracks tool in Edit or where the clip is in Play"`,
}
Inspect_Shot :: struct {id,camera:base.Entity_Id,camera_name:string,time,blend:f32 `mirai:"unit=s"`,ease:mm.Ease}
Inspect_Actor :: struct {
    id:base.Entity_Id,
    name:string,
    target:string `mirai:"label=What the tracks of the clip call it: the target of animation.track.set; its field tracks are target/@field/Component.field"`,
}
Inspect_Viewer :: struct {id,seat:base.Entity_Id}
Inspect_View :: struct {camera:base.Entity_Id,position:[3]f32,rotation:[4]f32 `mirai:"label=Quaternion xyzw"`,fov:f32 `mirai:"angle"`,near:f32 `mirai:"unit=m"`}
Inspect_Preview :: struct {on,playing,shot_view:bool,head:f32 `mirai:"unit=s"`}
Inspect_Result :: struct {
    id:base.Entity_Id,
    name:string,
    clip:base.Asset_Id `mirai:"label=The .anim of the Animation of the timeline: animation.track.set and animation.key.set write its keys and animation.marker.set its markers"`,
    clip_name:string `mirai:"label=Animation.clip; empty: the first of the asset"`,
    duration:f32 `mirai:"unit=s,label=Of the clip as the world plays it; 0 before it has one"`,
    loop,playing:bool `mirai:"label=Of its Animation"`,
    status:cine.Cinematic_Status,
    time:f32 `mirai:"unit=s,label=The time the shot is given at"`,
    shots:[]Inspect_Shot,
    actors:[]Inspect_Actor `mirai:"label=The entities out of the timeline that its clip moves by name"`,
    viewers:[]Inspect_Viewer,
    view:Inspect_View `mirai:"optional,label=What the viewers show at the time with the scene as it is; absent without a shot in force"`,
    preview:Inspect_Preview `mirai:"label=The Tracks tool of the editor on the clip, and the shot view of the Cinematics tool"`,
}

Control_View :: enum u8 {Keep,Shot,Editor}
Control_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The timeline or one of its parts"`,
    command:anim.Timeline_Command,
    time:f32 `mirai:"optional,min=0,unit=s,label=Where Seek puts the clip"`,
    speed:f32 `mirai:"optional,min=0,max=4,label=Edit: the speed of the preview of the Tracks tool; 0 keeps it"`,
    view:Control_View `mirai:"optional,label=Edit: Shot looks through the shot at the head and Editor gives the viewport its view back"`,
}
Control_Result :: struct {
    mode:[16]u8 `mirai:"text,label=Edit drives the head of the Tracks tool; Play the running world"`,
    status:cine.Cinematic_Status,
    time:f32 `mirai:"unit=s"`,
    duration:f32 `mirai:"unit=s"`,
    queued:bool `mirai:"label=Play: the command runs at the next tick of the world"`,
}

Add_Params :: struct {
    part:Part,
    timeline:editor.Api_Entity_Text `mirai:"text,entity,optional,label=The timeline the part is of; not for a Timeline"`,
    target:editor.Api_Entity_Text `mirai:"text,entity,optional,label=Shot: its camera; Actor: the entity the clip moves"`,
    clip:base.Asset_Id `mirai:"optional,label=Timeline: the .anim its Animation plays (animation.clip.create makes one)"`,
    playing:bool `mirai:"optional,label=Timeline: it starts by itself when its scene does"`,
    time:f32 `mirai:"optional,min=0,unit=s,label=Shot: the time of the clip it starts at"`,
    blend:f32 `mirai:"optional,min=0,unit=s,label=Shot: how long it blends in from the shot before"`,
    ease:mm.Ease `mirai:"optional"`,
    name:[64]u8 `mirai:"text,optional,label=Actor: what the tracks of the clip call it; empty: the name of its entity"`,
}
Add_Result :: struct {id:base.Entity_Id}

@(private)
register :: proc(s:^editor.Session) {
    editor.tool_entry(s,TOOL,"Cinematics",.Play)
    inspect_defaults:=Inspect_Params{time=-1}
    editor.api_method_register(s,{params=type_info_of(Inspect_Params),result=type_info_of(Inspect_Result),name="cinematics.inspect",summary="A timeline: the clip of its Animation and where it is, its shots, the actors its clip moves, its viewers, what the viewers show at a time, and the preview of the editor. The keys and markers are of the clip: animation.asset.inspect reads them.",defaults=&inspect_defaults,flags={.Read_Only},run=api_inspect})
    editor.api_method_register(s,{params=type_info_of(Control_Params),result=type_info_of(Control_Result),name="cinematics.control",summary="Plays, pauses, resumes, stops or seeks the clip of a timeline: in Edit the head of the Tracks tool in the Cinematics tool, which shows the scene there without changing the document (animation.tracks.show for any clip); in Play the running world, as anim.animation_command does.",run=api_control})
    editor.api_method_register(s,{params=type_info_of(Add_Params),result=type_info_of(Add_Result),name="cinematics.add",summary="Adds a timeline (an entity with a Cinematic and the Animation that plays its clip), a shot under one, or an actor: an entity anywhere that the clip moves by a name. One step of undo.",run=api_add})
}

@(private)
tool_state :: proc(s:^editor.Session) -> ^Cinematic_Editor {
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Cinematic_Editor)
}

// The timeline of an id in a world, or the failure of the call.
@(private)
timeline_find :: proc(call:^api.Call,w:core.World_Ref,named:[]u8,field:string) -> core.Entity {
    e,found:=editor.api_call_entity(call,w,named,field)
    if !found {return core.NONE}
    timeline:=timeline_of(w,e)
    if !editor.entity_has(w,timeline,cine.Cinematic) {api.call_failf(call,api.INVALID_PARAMS,"%s %s is no timeline nor a part of one: give the entity with Cinematic, or add one with cinematics.add part Timeline",field,base.text_get(named));return core.NONE}
    return timeline
}

@(private)
api_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Inspect_Params)
    w:=editor.shown_world(s)
    timeline:=timeline_find(call,w,p.entity[:],"entity")
    if timeline==core.NONE {return}
    value,_:=editor.entity_get(w,timeline,cine.Cinematic)
    animation,_:=editor.entity_get(w,timeline,anim.Animation)
    at,duration,ended,clipped:=anim.animation_progress(core.world_storage_of(w,anim.Playback),timeline)
    c:=tool_state(s)
    head,playing,previewed:=aed.tracks_head(s,timeline)
    previewed&&=s.mode==.Edit
    time:=p.time
    if time<0 {time=previewed?head:at}
    status:=value.status
    if s.mode==.Edit {status=clipped?cine.cinematic_status(false,ended,at):.Stopped}
    r:=api.call_result(call,Inspect_Result)
    r^={
        id=editor.api_entity_id(w,timeline),name=editor.entity_name(w,timeline),clip=animation.asset,clip_name=strings.clone(base.text_get(animation.clip[:]),call.allocator),
        duration=clipped?duration:0,loop=animation.loop,playing=animation.playing,status=status,time=time,
        preview={previewed,previewed && playing,previewed && c!=nil && c.shot_view && editor.tool_on(s,TOOL),previewed?head:0},
    }
    shots,shot_values:=parts_of(w,timeline,cine.Cinematic_Shot)
    r.shots=make([]Inspect_Shot,len(shot_values),call.allocator)
    for shot,i in shot_values {r.shots[i]={editor.api_entity_id(w,shots[i]),editor.api_entity_id(w,shot.camera),editor.entity_name(w,shot.camera),shot.time,shot.blend,shot.ease}}
    actors,actor_values:=actors_of(w,timeline)
    r.actors=make([]Inspect_Actor,len(actor_values),call.allocator)
    for &actor,i in actor_values {
        name:=editor.entity_name(w,actors[i])
        target:=base.text_get(actor.path[:])
        r.actors[i]={editor.api_entity_id(w,actors[i]),name,target if target!="" else name}
    }
    viewers,viewer_values:=parts_of(w,timeline,cine.Cinematic_Viewer)
    r.viewers=make([]Inspect_Viewer,len(viewer_values),call.allocator)
    for viewer,i in viewer_values {r.viewers[i]={editor.api_entity_id(w,viewers[i]),editor.api_entity_id(w,viewer.seat)}}
    if shot,sample,ok:=shot_view(w,timeline,time);ok {
        r.view={editor.api_entity_id(w,shot.camera),sample.pose.position,([4]f32)(lib.quat_vec4(sample.pose.rotation)),sample.fov,sample.near}
    }
}

@(private)
api_control :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Control_Params)
    if s.mode==.Watch {api.call_fail(call,api.INVALID_PARAMS,"this editor watches another one: control the timeline in the editor that runs it");return}
    w:=editor.shown_world(s)
    timeline:=timeline_find(call,w,p.entity[:],"entity")
    if timeline==core.NONE {return}
    if !editor.entity_has(w,timeline,anim.Animation) {api.call_fail(call,api.INVALID_PARAMS,"the timeline has no Animation, so it has no clip to control: add one to its entity whose asset is the .anim of its clip (scene.write, or cinematics.add part Timeline with clip)");return}
    value,_:=editor.entity_get(w,timeline,cine.Cinematic)
    out:=api.call_result(call,Control_Result)
    _,out.duration,_,_=anim.animation_progress(core.world_storage_of(w,anim.Playback),timeline)
    if s.mode!=.Edit {
        requests:=core.world_storage_of(w,anim.Animation_Requests)
        if requests==nil {api.call_fail(call,api.SERVER_ERROR,"the running world has no animation requests: the project does not use the animation plugin");return}
        waiting:=len(requests.timeline.items)
        anim.animation_command(requests,timeline,p.command,p.time)
        if len(requests.timeline.items)==waiting {api.call_fail(call,api.SERVER_ERROR,"the command could not be queued: the timeline commands of this tick are full (Animation_Settings.requests)");return}
        copy(out.mode[:],"Play")
        out.status,out.time,out.queued=value.status,value.time,true
        return
    }
    c:=tool_state(s)
    if c==nil {api.call_fail(call,api.SERVER_ERROR,"the Cinematics tool is not in this build of the editor");return}
    editor.tool_set(s,TOOL,true)
    if !editor.tool_on(s,TOOL) {api.call_fail(call,api.INVALID_PARAMS,"the Cinematics tool works on the scene: bring the scene to the front with editor.document first");return}
    c.timeline=timeline
    head,playing,_:=aed.tracks_command(s,timeline,p.command,p.time,true,p.speed)
    switch p.view {
    case .Keep:
    case .Shot: c.shot_view=true
    case .Editor: c.shot_view=false
    }
    copy(out.mode[:],"Edit")
    out.time=head
    out.status=.Stopped if p.command==.Stop else (.Playing if playing else .Paused)
}

@(private)
api_add :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Add_Params)
    w:=editor.edited_world(s)
    desc:=Part_Desc{part=p.part,clip=p.clip,playing=p.playing,time=p.time,blend=p.blend,ease=p.ease,name=serial.text_field(p.name[:])}
    if p.part!=.Timeline {
        desc.timeline=timeline_find(call,w,p.timeline[:],"timeline")
        if desc.timeline==core.NONE {return}
        found:bool
        if desc.target,found=editor.api_call_entity(call,w,p.target[:],"target");!found {return}
    }
    if !editor.api_edit_begin(s,call,fmt.tprintf("Add %v",p.part)) {return}
    e,problem:=part_add(s,w,desc)
    if problem!="" {api.call_failf(call,api.INVALID_PARAMS,"the %v was not added: %s",p.part,problem)}
    if !editor.api_edit_end(s,call,e!=core.NONE) {return}
    // A new actor takes its place at the head.
    if p.part==.Actor {aed.tracks_command(s,desc.timeline,.Seek,0,false,0)}
    api.call_result(call,Add_Result).id=editor.api_entity_id(w,e)
}
