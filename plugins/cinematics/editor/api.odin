package cinematics_editor

import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import lib "mirai:std/anim"
import "mirai:std/base"
import "mirai:ui"
import aed "plugins:animation/editor"
import anim "plugins:animation/runtime"
import cine "plugins:cinematics/runtime"

@(storage)
Cinematics_Api :: struct {provider:editor.Api_Provider}
CINEMATICS_API_DEFAULT :: Cinematics_Api{provider={register=register}}

Inspect_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The timeline or one of its actors"`,
    time:f32 `mirai:"optional,min=-1,unit=s,label=The time of the clip whose shot is given; -1: the head of the Tracks tool in Edit or where the clip is in Play"`,
}
Inspect_Marker :: struct {
    entity:base.Entity_Id `mirai:"label=The camera or the actor it is on; 0: no entity has its target"`,
    target:string `mirai:"label=Its target in animation.marker.set"`,
    name:string `mirai:"label=Of an action: the action it plays"`,
    time,duration:f32 `mirai:"unit=s,label=Of a shot, the duration is its blend"`,
}
Inspect_Actor :: struct {
    id:base.Entity_Id,
    name:string,
    target:string `mirai:"label=What the tracks and markers of the clip call it: the target of animation.track.set and animation.marker.set; its field tracks are target/@field/Component.field"`,
}
Inspect_View :: struct {camera:base.Entity_Id,position:[3]f32,rotation:[4]f32 `mirai:"label=Quaternion xyzw"`,fov:f32 `mirai:"angle"`,near:f32 `mirai:"unit=m"`}
Inspect_Preview :: struct {on,playing,shot_view:bool,head:f32 `mirai:"unit=s"`}
Inspect_Result :: struct {
    id:base.Entity_Id,
    name:string,
    clip:base.Asset_Id `mirai:"label=The .anim of the Animation of the timeline: animation.track.set and animation.key.set write its keys and animation.marker.set its markers, its shots and its actions"`,
    clip_name:string `mirai:"label=Animation.clip; empty: the first of the asset"`,
    duration:f32 `mirai:"unit=s,label=Of the clip as the world plays it; 0 before it has one"`,
    loop,playing:bool `mirai:"label=Of its Animation"`,
    status:cine.Cinematic_Status,
    time:f32 `mirai:"unit=s,label=The time the shot is given at"`,
    shots:[]Inspect_Marker `mirai:"label=The markers of the clip on cameras"`,
    actions:[]Inspect_Marker `mirai:"label=The markers of the clip on the other actors"`,
    actors:[]Inspect_Actor `mirai:"label=The entities out of the timeline that its clip moves by name"`,
    view:Inspect_View `mirai:"optional,label=What its seat sees at the time with the scene as it is; absent without a shot in force"`,
    preview:Inspect_Preview `mirai:"label=The Tracks tool of the editor on the clip, and the shot view of the Cinematics tool"`,
}

Control_View :: enum u8 {Keep,Shot,Editor}
Control_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The timeline or one of its actors"`,
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

@(private)
register :: proc(s:^editor.Session) {
    editor.tool_entry(s,TOOL,"Cinematics",ui.icon_user(u8(editor.User_Icon.Camera)))
    inspect_defaults:=Inspect_Params{time=-1}
    editor.api_method_register(s,{params=type_info_of(Inspect_Params),result=type_info_of(Inspect_Result),name="cinematics.inspect",summary="A timeline: the clip of its Animation and where it is, its shots and actions (the markers of the clip on its cameras and actors), the actors its clip moves, what its seat sees at a time, and the preview of the editor. animation.asset.inspect reads the keys and markers of the clip.",defaults=&inspect_defaults,flags={.Read_Only},run=api_inspect})
    editor.api_method_register(s,{params=type_info_of(Control_Params),result=type_info_of(Control_Result),name="cinematics.control",summary="Plays, pauses, resumes, stops or seeks the clip of a timeline: in Edit the head of the Tracks tool in the Cinematics tool, which shows the scene there without changing the document (animation.request with seek for any clip); in Play the running world, as anim.animation_command does.",run=api_control})
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
    if !editor.entity_has(w,timeline,cine.Cinematic) {api.call_failf(call,api.INVALID_PARAMS,"%s %s is no timeline nor an actor of one: give the entity with Cinematic, or make one: scene.write with preset cinematic",field,base.text_get(named));return core.NONE}
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
    playback:=core.world_storage_of(w,anim.Playback)
    at,duration,ended,clipped:=anim.animation_progress(playback,timeline)
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
    markers,content:=anim.animation_markers(playback,core.world_storage_of(w,anim.Source_Assets),s.app,timeline)
    cameras:=core.world_table_of(w,erender.Camera)
    shots,actions:=make([dynamic]Inspect_Marker,call.allocator),make([dynamic]Inspect_Marker,call.allocator)
    for marker in markers {
        if int(marker.id)>=len(content.markers) || content.markers[marker.id].target==0 {continue}
        on:=anim.animation_bound(playback,timeline,content.markers[marker.id].target)
        if !editor.entity_alive(w,on) {on=core.NONE}
        row:=Inspect_Marker{editor.api_entity_id(w,on),strings.clone(actor_target(w,on),call.allocator) if on!=core.NONE else "",strings.clone(base.text_get(content.markers[marker.id].text[:]),call.allocator),marker.time,marker.duration}
        append(&shots if on!=core.NONE && cameras!=nil && core.has(cameras,on) else &actions,row)
    }
    r.shots,r.actions=shots[:],actions[:]
    actors,_:=actors_of(w,timeline)
    r.actors=make([]Inspect_Actor,len(actors),call.allocator)
    for actor,i in actors {r.actors[i]={editor.api_entity_id(w,actor),editor.entity_name(w,actor),strings.clone(actor_target(w,actor),call.allocator)}}
    if shot,pose,ok:=shot_view(s,w,timeline,time);ok {
        r.view={editor.api_entity_id(w,shot.camera),pose.position,([4]f32)(lib.quat_vec4(pose.rotation)),pose.fov,pose.near}
    }
}

@(private)
api_control :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Control_Params)
    if s.mode==.Watch {api.call_fail(call,api.INVALID_PARAMS,"this editor watches another one: control the timeline in the editor that runs it");return}
    w:=editor.shown_world(s)
    timeline:=timeline_find(call,w,p.entity[:],"entity")
    if timeline==core.NONE {return}
    if !editor.entity_has(w,timeline,anim.Animation) {api.call_fail(call,api.INVALID_PARAMS,"the timeline has no Animation, so it has no clip to control: add one to its entity whose asset is the .anim of its clip (scene.write with components Animation asset)");return}
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
