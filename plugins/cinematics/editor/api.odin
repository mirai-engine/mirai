package cinematics_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import cine "plugins:cinematics/runtime"

@(storage)
Cinematics_Api :: struct {provider:editor.Api_Provider}
CINEMATICS_API_DEFAULT :: Cinematics_Api{provider={register=register}}

Inspect_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The timeline or one of its tracks shots markers or viewers"`,
    position:f32 `mirai:"optional,min=-1,unit=ticks,label=Where the values of the tracks and the view are sampled; -1: the head of the preview in Edit or the position of the timeline in Play"`,
}
Inspect_Key :: struct {tick:f32 `mirai:"unit=ticks"`,value:[4]f32,ease:mm.Ease,interpolation:lib.Interpolation}
Inspect_Track :: struct {
    id,target:base.Entity_Id,
    target_name:[64]u8 `mirai:"text"`,
    property:cine.Cinematic_Property,
    valid:bool `mirai:"label=Its keys are in order of tick and its target can take them"`,
    value:[4]f32 `mirai:"label=At the position: xyz in the world for Position; a quaternion xyzw for Rotation; xyz of its own for Scale; x for Fov in radians or Near in meters"`,
    keys:[1]Inspect_Key `mirai:"list"`,
}
Inspect_Shot :: struct {id,camera:base.Entity_Id,camera_name:[64]u8 `mirai:"text"`,tick,blend_ticks:u32 `mirai:"unit=ticks"`,ease:mm.Ease}
Inspect_Marker :: struct {id:base.Entity_Id,name:[64]u8 `mirai:"text"`,tick:u32 `mirai:"unit=ticks"`,marker:[16]u8 `mirai:"text,label=Its id in hexadecimal"`,values:[4]f32}
Inspect_Viewer :: struct {id,seat:base.Entity_Id}
Inspect_View :: struct {camera:base.Entity_Id,position:[3]f32,rotation:[4]f32 `mirai:"label=Quaternion xyzw"`,fov:f32 `mirai:"angle"`,near:f32 `mirai:"unit=m"`}
Inspect_Preview :: struct {on,playing,shot_view:bool,head:f32 `mirai:"unit=ticks"`}
Inspect_Result :: struct {
    id:base.Entity_Id,
    name:[64]u8 `mirai:"text"`,
    duration_ticks:u32 `mirai:"unit=ticks"`,
    tick_rate:f32 `mirai:"label=Ticks per second"`,
    looping,auto_play:bool,
    status:cine.Cinematic_Status,
    position:f32 `mirai:"unit=ticks,label=Where tracks and view are sampled"`,
    tracks:[1]Inspect_Track `mirai:"list"`,
    shots:[1]Inspect_Shot `mirai:"list"`,
    markers:[1]Inspect_Marker `mirai:"list"`,
    viewers:[1]Inspect_Viewer `mirai:"list"`,
    view:Inspect_View `mirai:"optional,label=What the viewers show at the position; absent without a shot in force"`,
    preview:Inspect_Preview `mirai:"label=The Cinematics tool of the editor"`,
}

Control_Command :: enum u8 {Play,Pause,Resume,Stop,Seek}
Control_View :: enum u8 {Keep,Shot,Editor}
Control_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The timeline or one of its parts"`,
    command:Control_Command,
    position:f32 `mirai:"optional,min=0,unit=ticks,label=Where Play and Seek put the head"`,
    speed:f32 `mirai:"optional,min=0,max=4,label=Edit: the speed of the preview; 0 keeps it"`,
    view:Control_View `mirai:"optional,label=Edit: Shot looks through the shot at the head and Editor gives the viewport its view back"`,
}
Control_Result :: struct {
    mode:[16]u8 `mirai:"text,label=Edit drives the preview of the editor; Play the running world"`,
    status:cine.Cinematic_Status,
    position:f32 `mirai:"unit=ticks"`,
    duration_ticks:u32 `mirai:"unit=ticks"`,
    queued:bool `mirai:"label=Play: the command runs at the next tick of the world"`,
}

Add_Params :: struct {
    part:Part,
    timeline:editor.Api_Entity_Text `mirai:"text,entity,optional,label=The timeline the part goes under; not for a Timeline"`,
    target:editor.Api_Entity_Text `mirai:"text,entity,optional,label=Track: the entity it moves; Shot: its camera"`,
    property:cine.Cinematic_Property `mirai:"optional"`,
    tick:u32 `mirai:"optional,unit=ticks,label=Of a shot or a marker or of the first key of a track which takes the target as it is"`,
    duration_ticks:u32 `mirai:"optional,unit=ticks,label=Timeline; 0: five seconds"`,
    blend_ticks:u32 `mirai:"optional,unit=ticks"`,
    ease:mm.Ease `mirai:"optional"`,
    marker:[64]u8 `mirai:"text,optional,label=Marker: a name whose name hash is its id"`,
    values:[4]f32 `mirai:"optional"`,
}
Add_Result :: struct {id:base.Entity_Id}

Key_Params :: struct {
    track:editor.Api_Entity_Text `mirai:"text,entity"`,
    tick:f32 `mirai:"min=0,unit=ticks"`,
    value:[4]f32 `mirai:"optional,label=As cinematics.inspect gives the value of a track"`,
    capture:bool `mirai:"optional,label=Takes the value from the target as it is instead of value"`,
    remove:bool `mirai:"optional,label=Takes the key at tick out"`,
    ease:mm.Ease `mirai:"optional"`,
    interpolation:lib.Interpolation `mirai:"optional"`,
}
Key_Result :: struct {track:base.Entity_Id,key_count:u32}

@(private)
register :: proc(s:^editor.Session) {
    inspect_defaults:=Inspect_Params{position=-1}
    editor.api_method_register(s,{name="cinematics.inspect",summary="A timeline with its tracks and their keys, shots, markers and viewers, the values of its tracks and what its viewers show at a position, and the preview of the editor.",params=Inspect_Params,params_info=type_info_of(Inspect_Params),result=Inspect_Result,result_info=type_info_of(Inspect_Result),defaults=&inspect_defaults,writes_result=true,flags={.Read_Only},run=api_inspect})
    editor.api_method_register(s,{name="cinematics.control",summary="Plays, pauses, resumes, stops or seeks a timeline: in Edit the preview of the Cinematics tool, which puts its targets where the tracks say without changing the document; in Play the running world.",params=Control_Params,params_info=type_info_of(Control_Params),result=Control_Result,result_info=type_info_of(Control_Result),run=api_control})
    editor.api_method_register(s,{name="cinematics.add",summary="Adds a timeline, or a track, shot or marker of one as an entity under it. One step of undo.",params=Add_Params,params_info=type_info_of(Add_Params),result=Add_Result,result_info=type_info_of(Add_Result),run=api_add})
    editor.api_method_register(s,{name="cinematics.key.set",summary="Sets the key of a track at a tick, from a value or from its target as it is, or takes it out. One step of undo.",params=Key_Params,params_info=type_info_of(Key_Params),result=Key_Result,result_info=type_info_of(Key_Result),run=api_key_set})
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
    c:=tool_state(s)
    previewed:=c!=nil && s.mode==.Edit && c.timeline==timeline && editor.tool_on(s,TOOL)
    position:=p.position
    if position<0 {position=previewed?c.head:f32(value.position)}
    out:=call.out
    serial.write_u8(out,'{')
    api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(w,timeline))
    api.write_text(out,"name",editor.entity_name(w,timeline))
    api.write_uint(out,"duration_ticks",u64(value.duration_ticks))
    api.write_key(out,"tick_rate");api.write_number(out,tick_rate(s))
    api.write_bool(out,"looping",value.looping)
    api.write_bool(out,"auto_play",value.auto_play)
    api.write_text(out,"status",fmt.tprintf("%v",value.status))
    api.write_key(out,"position");api.write_number(out,position)
    api.write_key(out,"tracks");serial.write_u8(out,'[')
    tracks,track_values:=parts_of(w,timeline,cine.Cinematic_Track)
    for &track,i in track_values {
        if i>0 {serial.write_u8(out,',')}
        sampled,valid:=cine.cinematic_track_value(&track,position)
        _,capturable:=track_capture(w,track)
        serial.write_u8(out,'{')
        api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(w,tracks[i]))
        api.write_key(out,"target");api.write_id(out,editor.api_entity_id(w,track.target))
        api.write_text(out,"target_name",editor.entity_name(w,track.target))
        api.write_text(out,"property",fmt.tprintf("%v",track.property))
        api.write_bool(out,"valid",valid && capturable)
        value:=([4]f32)(sampled)
        api.write_numbers(out,"value",value[:])
        api.write_key(out,"keys");serial.write_u8(out,'[')
        for key,j in track.keys[:min(track.key_count,cine.CINEMATIC_KEYS)] {
            if j>0 {serial.write_u8(out,',')}
            serial.write_u8(out,'{')
            api.write_key(out,"tick",true);api.write_number(out,key.time)
            key_value:=([4]f32)(key.value)
            api.write_numbers(out,"value",key_value[:])
            api.write_text(out,"ease",fmt.tprintf("%v",key.ease))
            api.write_text(out,"interpolation",fmt.tprintf("%v",key.interpolation))
            serial.write_u8(out,'}')
        }
        serial.text_write_raw(out,"]}")
    }
    serial.write_u8(out,']')
    api.write_key(out,"shots");serial.write_u8(out,'[')
    shots,shot_values:=parts_of(w,timeline,cine.Cinematic_Shot)
    for shot,i in shot_values {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(w,shots[i]))
        api.write_key(out,"camera");api.write_id(out,editor.api_entity_id(w,shot.camera))
        api.write_text(out,"camera_name",editor.entity_name(w,shot.camera))
        api.write_uint(out,"tick",u64(shot.tick))
        api.write_uint(out,"blend_ticks",u64(shot.blend_ticks))
        api.write_text(out,"ease",fmt.tprintf("%v",shot.ease))
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    api.write_key(out,"markers");serial.write_u8(out,'[')
    markers,marker_values:=parts_of(w,timeline,cine.Cinematic_Marker)
    for marker,i in marker_values {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(w,markers[i]))
        api.write_text(out,"name",editor.entity_name(w,markers[i]))
        api.write_uint(out,"tick",u64(marker.tick))
        api.write_text(out,"marker",fmt.tprintf("%016x",marker.id))
        values:=marker.values
        api.write_numbers(out,"values",values[:])
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    api.write_key(out,"viewers");serial.write_u8(out,'[')
    viewers,viewer_values:=parts_of(w,timeline,cine.Cinematic_Viewer)
    for viewer,i in viewer_values {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(w,viewers[i]))
        api.write_key(out,"seat");api.write_id(out,editor.api_entity_id(w,viewer.seat))
        serial.write_u8(out,'}')
    }
    serial.write_u8(out,']')
    if shot,sample,ok:=shot_view(w,timeline,position);ok {
        api.write_key(out,"view");serial.write_u8(out,'{')
        api.write_key(out,"camera",true);api.write_id(out,editor.api_entity_id(w,shot.camera))
        api.write_numbers(out,"position",sample.pose.position)
        rotation:=([4]f32)(lib.quat_vec4(sample.pose.rotation))
        api.write_numbers(out,"rotation",rotation[:])
        api.write_key(out,"fov");api.write_number(out,sample.fov)
        api.write_key(out,"near");api.write_number(out,sample.near)
        serial.write_u8(out,'}')
    }
    api.write_key(out,"preview");serial.write_u8(out,'{')
    api.write_bool(out,"on",previewed && c.previewing,true)
    api.write_bool(out,"playing",previewed && c.playing)
    api.write_bool(out,"shot_view",previewed && c.shot_view)
    api.write_key(out,"head");api.write_number(out,previewed?c.head:0)
    serial.text_write_raw(out,"}}")
}

@(private)
api_control :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Control_Params)
    if s.mode==.Watch {api.call_fail(call,api.INVALID_PARAMS,"this editor watches another one: control the timeline in the editor that runs it");return}
    w:=editor.shown_world(s)
    timeline:=timeline_find(call,w,p.entity[:],"entity")
    if timeline==core.NONE {return}
    value,_:=editor.entity_get(w,timeline,cine.Cinematic)
    out:=api.call_result(call,Control_Result)
    out.duration_ticks=value.duration_ticks
    if s.mode!=.Edit {
        requests:=core.world_storage_of(w,cine.Cinematic_Requests)
        if requests==nil {api.call_fail(call,api.SERVER_ERROR,"the running world has no cinematic requests: the project does not use the cinematics plugin");return}
        switch p.command {
        case .Play:
            cine.cinematic_play(requests,timeline)
            if p.position>0 {cine.cinematic_seek(requests,timeline,u32(p.position))}
        case .Pause: cine.cinematic_pause(requests,timeline)
        case .Resume: cine.cinematic_resume(requests,timeline)
        case .Stop: cine.cinematic_stop(requests,timeline)
        case .Seek: cine.cinematic_seek(requests,timeline,u32(p.position))
        }
        copy(out.mode[:],"Play")
        out.status,out.position,out.queued=value.status,f32(value.position),true
        return
    }
    c:=tool_state(s)
    if c==nil {api.call_fail(call,api.SERVER_ERROR,"the Cinematics tool is not in this build of the editor");return}
    editor.tool_set(s,TOOL,true)
    if !editor.tool_on(s,TOOL) {api.call_fail(call,api.INVALID_PARAMS,"the Cinematics tool works on the scene: bring the scene to the front with editor.document first");return}
    if c.timeline!=timeline {c.timeline,c.head,c.playing,c.strip=timeline,0,false,{}}
    duration:=f32(min(value.duration_ticks,cine.MAX_DURATION))
    switch p.command {
    case .Play: c.head,c.playing,c.previewing=min(p.position,duration),true,true
    case .Pause: c.playing=false
    case .Resume: c.playing,c.previewing=true,true
    case .Stop:
        c.head,c.playing,c.previewing=0,false,false
        if editor.tool_preview_active(s,TOOL) {editor.tool_preview_end(s,TOOL,false)}
    case .Seek: c.head,c.playing,c.previewing=min(p.position,duration),false,true
    }
    c.shown=-1
    if p.speed>0 {c.speed=p.speed}
    switch p.view {
    case .Keep:
    case .Shot: c.shot_view=true
    case .Editor: c.shot_view=false
    }
    copy(out.mode[:],"Edit")
    out.position=c.head
    out.status=c.playing?.Playing:(c.previewing?.Paused:.Stopped)
}

@(private)
api_add :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Add_Params)
    w:=editor.edited_world(s)
    desc:=Part_Desc{part=p.part,property=p.property,tick=p.tick,duration_ticks=p.duration_ticks,blend_ticks=p.blend_ticks,ease=p.ease,values=p.values}
    if p.part!=.Timeline {
        desc.timeline=timeline_find(call,w,p.timeline[:],"timeline")
        if desc.timeline==core.NONE {return}
    } else if desc.duration_ticks==0 {desc.duration_ticks=u32(tick_rate(s)*5)}
    if p.part==.Track || p.part==.Shot {
        found:bool
        if desc.target,found=editor.api_call_entity(call,w,p.target[:],"target");!found {return}
    }
    if name:=serial.text_field(p.marker[:]);name!="" {desc.id=base.name_hash(name)}
    if !editor.api_edit_begin(s,call,fmt.tprintf("Add %v",p.part)) {return}
    e,problem:=part_add(s,w,desc)
    if problem!="" {api.call_failf(call,api.INVALID_PARAMS,"the %v was not added: %s",p.part,problem)}
    if !editor.api_edit_end(s,call,e!=core.NONE) {return}
    if c:=tool_state(s);c!=nil {c.shown=-1}
    api.call_result(call,Add_Result).id=editor.api_entity_id(w,e)
}

@(private)
api_key_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Key_Params)
    w:=editor.edited_world(s)
    e,named:=editor.api_call_entity(call,w,p.track[:],"track")
    if !named {return}
    track,found:=editor.entity_get(w,e,cine.Cinematic_Track)
    if !found {api.call_failf(call,api.INVALID_PARAMS,"track %s has no Cinematic_Track: take a track from cinematics.inspect",base.text_get(p.track[:]));return}
    key:=lib.Keyframe{time=p.tick,value=mm.Vec4(p.value),ease=p.ease,interpolation=p.interpolation}
    if p.capture && !p.remove {
        captured:bool
        key.value,captured=track_capture(w,track)
        if !captured {api.call_failf(call,api.INVALID_PARAMS,"the target of the track has no %s to take the key from: give value instead",track.property>.Scale?"Camera":"Transform");return}
    }
    if !key_put(&track,key,p.remove) {
        if p.remove {api.call_failf(call,api.INVALID_PARAMS,"the track has no key at tick %v: take the ticks of its keys from cinematics.inspect",p.tick)} else {api.call_failf(call,api.INVALID_PARAMS,"the track holds %d keys: take one out with remove, or move it with a tick of a key it has",cine.CINEMATIC_KEYS)}
        return
    }
    if !editor.api_edit_begin(s,call,p.remove?"Delete key":"Set key") {return}
    written:=component_write(s,w,e,track)
    if !editor.api_edit_end(s,call,written) {return}
    if c:=tool_state(s);c!=nil {c.shown=-1}
    out:=api.call_result(call,Key_Result)
    out.track,out.key_count=editor.api_entity_id(w,e),track.key_count
}
