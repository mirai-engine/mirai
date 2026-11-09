package animation_editor

import "core:fmt"
import "core:mem"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"
import anim "plugins:animation/runtime"

@(storage)
Animation_Inspector :: struct {provider:editor.Inspector_Provider}
ANIMATION_INSPECTOR_DEFAULT :: Animation_Inspector{provider={component=sequence_inspector,field=field_inspector}}

// The assets of the plugin in the browser and in the fields that name them (kind=).
@(storage)
Animation_Kinds :: struct {provider:editor.Asset_Kind_Provider}
ANIMATION_KINDS_DEFAULT :: Animation_Kinds{provider={
    kinds={
        0={kind=anim.MATCH_KIND,label="Matching",color={72,160,190,255},icon=.Move,extension=".match"},
        1={kind=anim.GRAPH_KIND,label="Anim graph",color={200,116,0,255},icon=ui.Icon(u8(ui.Icon.User)+u8(editor.User_Icon.Tree)),extension=".agraph"},
        2={kind=anim.BLEND_KIND,label="Blend space",color={255,168,111,255},icon=.Gauge,extension=".blend"},
        3={kind=anim.MOTION_KIND,label="Motion profile",color={120,180,90,255},icon=.Relative,extension=".motion"},
        4={kind=anim.POSE_KIND,label="Pose profile",color={210,90,150,255},icon=.Focus,extension=".pose"},
        5={kind=anim.ACTION_KIND,label="Actions",color={230,190,60,255},icon=.Lightning,extension=".action"},
    },
    count=6,
}}

@(storage)
Sequence_Editor :: struct {owner,source,reference:core.Entity,frame:int}

Sequence_Frame_Params :: struct {pose:mm.Transform `mirai:"optional"`,duration:f32 `mirai:"optional,min=0,unit=s,label=To arrive at the pose"`,hold:f32 `mirai:"optional,min=0,unit=s"`,ease:mm.Ease `mirai:"optional"`,interpolation:lib.Sequence_Interpolation `mirai:"optional"`}
Sequence_Value_Params :: struct {frames:[anim.KEYFRAME_PATH_FRAMES]Sequence_Frame_Params `mirai:"label=1 to 16; their count is the length"`,speed:f32 `mirai:"optional"`,loop:lib.Loop `mirai:"optional"`,playing,relative:bool `mirai:"optional"`}
Sequence_Set_Params :: struct {entity:editor.Api_Entity_Text `mirai:"text,entity"`,value:Sequence_Value_Params}
Sequence_Capture_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    frame:u32 `mirai:"min=0,max=15"`,
    source:editor.Api_Entity_Text `mirai:"text,entity,optional,label=The entity whose transform it captures; omitted is the owner"`,
    reference:editor.Api_Entity_Text `mirai:"text,entity,optional,label=Required by a relative sequence"`,
}
Sequence_Preview_Params :: struct {entity:editor.Api_Entity_Text `mirai:"text,entity"`,time:f32}
Sequence_Preview_Result :: struct {pose:mm.Transform,duration:f32}
Sequence_Edit_Result :: struct {id:base.Entity_Id,queued:bool}

@(private)
sequence_set_defaults :: proc() -> Sequence_Set_Params {
    value:=Sequence_Set_Params{value={speed=1,playing=true}}
    for &frame in value.value.frames {frame={pose=mm.TRANSFORM_IDENTITY,duration=1}}
    return value
}

@(private)
sequence_register :: proc(s:^editor.Session) {
    set_default:=sequence_set_defaults()
    editor.api_method_register(s,{name="animation.sequence.set",summary="Sets the transform frames of a Keyframe_Path sequence with their timing and its playback. One step of undo in Edit.",params=Sequence_Set_Params,params_info=type_info_of(Sequence_Set_Params),result=Sequence_Edit_Result,result_info=type_info_of(Sequence_Edit_Result),defaults=&set_default,run=sequence_set})
    editor.api_method_register(s,{name="animation.sequence.frame.set",summary="Captures the transform of an entity into a frame of a sequence. One step of undo.",params=Sequence_Capture_Params,params_info=type_info_of(Sequence_Capture_Params),result=Sequence_Edit_Result,result_info=type_info_of(Sequence_Edit_Result),run=sequence_capture})
    editor.api_method_register(s,{name="animation.sequence.preview",summary="Samples a sequence without changing the document or advancing gameplay.",params=Sequence_Preview_Params,params_info=type_info_of(Sequence_Preview_Params),result=Sequence_Preview_Result,result_info=type_info_of(Sequence_Preview_Result),flags={.Read_Only},run=sequence_preview})
}

@(private)
sequence_valid :: proc(value:^anim.Keyframe_Path) -> bool {
    _,valid:=lib.sequence_duration(anim.keyframe_path_frames(value))
    return valid && finite(value.speed) && value.loop>=.Once && value.loop<=.Ping_Pong
}

@(private)
sequence_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Sequence_Set_Params)
    text:=api.json_member(call.raw,"value");nested:=api.Call{raw=text,allocator=call.allocator};count,_:=api.params_array_count(&nested,"frames")
    if count==0 || count>anim.KEYFRAME_PATH_FRAMES {authoring_failure(call,"value.frames","Capacity","1 to 16 frames",fmt.tprintf("%d",count),"The sequence requires frames");return}
    value:=anim.Keyframe_Path{count=u8(count),speed=p.value.speed,loop=p.value.loop,playing=p.value.playing,relative=p.value.relative}
    for frame,i in p.value.frames[:count] {value.frames[i]={pose=frame.pose,duration=frame.duration,hold=frame.hold,ease=frame.ease,interpolation=frame.interpolation}}
    if !sequence_valid(&value) {authoring_failure(call,"value","Invalid_Definition","valid transform frames and finite playback settings","invalid sequence","The sequence definition is invalid");return}
    w,e,ok:=subject(s,call,p.entity[:]);if !ok {return}
    table:=core.world_table_of(w,anim.Keyframe_Path)
    if table==nil {authoring_failure(call,"Keyframe_Path","Unavailable","the sequence runtime table","missing table","The sequence runtime is unavailable",api.SERVER_ERROR);return}
    if !edit_begin(s,call,"Set animation sequence") {return}
    core.add(table,e,value)
    if edit_end(s,call,w,true) {api.call_result(call,Sequence_Edit_Result)^={id=editor.api_entity_id(w,e)}}
}

sequence_capture_pose :: proc(w:core.World_Ref,owner,source,reference:core.Entity,relative:bool) -> (pose:mm.Transform,ok:bool) {
    if !editor.entity_has(w,owner,core.Transform) || !editor.entity_has(w,source,core.Transform) {return}
    if relative {
        if reference==core.NONE || source==reference || !editor.entity_has(w,reference,core.Transform) {return}
        return mm.transform_relative(editor.entity_world(w,source),editor.entity_world(w,reference))
    }
    return mm.transform_relative(editor.entity_world(w,source),editor.entity_parent_world(w,owner))
}

@(private)
sequence_capture :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Sequence_Capture_Params)
    w,e,ok:=subject(s,call,p.entity[:]);if !ok {return}
    value,present:=editor.entity_get(w,e,anim.Keyframe_Path)
    if !present || p.frame>=u32(value.count) || p.frame>=anim.KEYFRAME_PATH_FRAMES {authoring_failure(call,"frame","Out_Of_Range","an existing frame in a Keyframe_Path component",fmt.tprintf("%d",p.frame),"The sequence frame does not exist");return}
    source:=e
    if p.source[0]!=0 {
        named:bool
        if source,named=editor.api_call_entity(call,w,p.source[:],"source");!named {return}
    }
    reference:=core.NONE
    if p.reference[0]!=0 {
        named:bool
        if reference,named=editor.api_call_entity(call,w,p.reference[:],"reference");!named {return}
    }
    pose,captured:=sequence_capture_pose(w,e,source,reference,value.relative)
    if !captured {authoring_failure(call,"source","Invalid_Reference","a valid source and invertible parent; distinct reference for relative capture","missing or noninvertible reference","The sequence pose could not be captured");return}
    value.frames[p.frame].pose=pose
    if !sequence_valid(&value) {authoring_failure(call,"frame","Invalid_Value","a valid transform pose","invalid captured transform","The captured pose is invalid");return}
    if !edit_begin(s,call,"Capture animation frame") {return}
    core.add(core.world_table_of(w,anim.Keyframe_Path),e,value)
    if edit_end(s,call,w,true) {api.call_result(call,Sequence_Edit_Result)^={id=editor.api_entity_id(w,e)}}
}


@(private)
sequence_preview :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Sequence_Preview_Params)
    w,e,ok:=subject(s,call,p.entity[:]);if !ok {return}
    value,present:=editor.entity_get(w,e,anim.Keyframe_Path)
    if !present {authoring_failure(call,"entity","Missing_Component","a Keyframe_Path component","missing component","The entity has no Keyframe_Path component");return}
    pose,sampled:=lib.sequence_sample(anim.keyframe_path_frames(&value),p.time,value.loop)
    if !sampled {authoring_failure(call,"time","Invalid_Value","a valid sequence and sample time",fmt.tprintf("%v",p.time),"The sequence or sample time is invalid");return}
    if value.relative {
        origin:=editor.entity_local(w,e)
        if progress,has:=anim.keyframe_path_progress(core.world_storage_of(w,anim.Keyframe_Path_Playback),e);has && progress.ready {origin=progress.origin}
        pose=mm.transform_compose(origin,pose)
    }
    out:=api.call_result(call,Sequence_Preview_Result)
    out.pose=pose
    out.duration,_=lib.sequence_duration(anim.keyframe_path_frames(&value))
}

@(private)
sequence_entity_choice :: proc(s:^editor.Session,w:core.World_Ref,label:string,value:^core.Entity) {
    table:=core.world_table_of(w,core.Transform)
    if table==nil {return}
    names:=make([]string,len(table.entities)+1,context.temp_allocator)
    names[0]="None"
    selected:=0
    for e,i in table.entities {
        names[i+1]=fmt.tprintf("%s (%d)",editor.entity_name(w,e),i+1)
        if e==value^ {selected=i+1}
    }
    ctx:=s.gui.ctx
    if ui.property(ctx,label) {
        if ui.dropdown(ctx,ui.id(ctx,label),names,&selected,{width=-1}) {value^=selected==0?core.NONE:table.entities[selected-1]}
    }
}

@(private)
sequence_write :: proc(c:editor.Inspector_Context,value:anim.Keyframe_Path) {
    value:=value
    if !sequence_valid(&value) {editor.notify(c.session,"The sequence contains an invalid frame");return}
    editor.field_write(c.session,c.table,c.entities,0,mem.ptr_to_bytes(&value))
}

@(private)
sequence_inspector :: proc(c:editor.Inspector_Context) -> bool {
    if c.table.type!=anim.Keyframe_Path {return false}
    s,w:=c.session,c.world
    editor.inspector_fields(c,type_info_of(anim.Keyframe_Path))
    if len(c.entities)!=1 {return true}
    e:=c.entities[0]
    state:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Sequence_Editor)
    if state==nil {return true}
    if state.owner!=e {state^={owner=e}}
    value,_:=editor.entity_get(w,e,anim.Keyframe_Path)
    count:=clamp(int(value.count),1,anim.KEYFRAME_PATH_FRAMES)
    state.frame=clamp(state.frame,0,count-1)
    ctx:=s.gui.ctx
    names:[anim.KEYFRAME_PATH_FRAMES]string
    for i in 0..<count {names[i]=fmt.tprintf("Frame %d",i+1)}
    if ui.property(ctx,"Frame") {ui.dropdown(ctx,ui.id(ctx,"frame"),names[:count],&state.frame,{width=-1})}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        if ui.button(ctx,ui.id(ctx,"append"),{label="Add",style=.Field,width=-1,disabled=count>=anim.KEYFRAME_PATH_FRAMES}).clicked {
            value.frames[count]=value.frames[state.frame];value.count=u8(count+1);state.frame=count;sequence_write(c,value)
        }
        if ui.button(ctx,ui.id(ctx,"remove"),{label="Remove",style=.Field,width=-1,disabled=count<=1}).clicked {
            for i in state.frame..<count-1 {value.frames[i]=value.frames[i+1]}
            value.frames[count-1]=lib.TRANSFORM_FRAME_DEFAULT;value.count-=1;state.frame=min(state.frame,count-2);sequence_write(c,value)
        }
    }
    editor.inspector_fields(c,type_info_of(lib.Transform_Frame),offset_of(anim.Keyframe_Path,frames)+uintptr(state.frame*size_of(lib.Transform_Frame)))
    sequence_entity_choice(s,w,"Copy source",&state.source)
    if value.relative {sequence_entity_choice(s,w,"Reference",&state.reference)}
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        own:=ui.button(ctx,ui.id(ctx,"capture"),{label="Capture pose",style=.Field,width=-1}).clicked
        copy_source:=ui.button(ctx,ui.id(ctx,"copy"),{label="Copy source",style=.Field,width=-1,disabled=state.source==core.NONE}).clicked
        if own || copy_source {
            source:=state.source if copy_source else e
            pose,ok:=sequence_capture_pose(w,e,source,state.reference,value.relative)
            if ok {value.frames[state.frame].pose=pose;sequence_write(c,value)} else {editor.notify(s,"Choose a distinct reference with nonzero scale for relative capture")}
        }
    }
    return true
}
