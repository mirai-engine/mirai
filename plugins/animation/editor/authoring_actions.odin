package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Action_Section_Params :: struct {action,name:[64]u8 `mirai:"text"`,start,end:f32 `mirai:"min=0,unit=s"`,next:[64]u8 `mirai:"text,optional,label=The section of the same action that follows in any row; empty completes the action"`}
Action_Window_Params :: struct {action,name:[64]u8 `mirai:"text"`,start,end:f32 `mirai:"min=0,unit=s"`}
Action_Write_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .action: what is there is replaced keeping its id"`,
    animation:base.Asset_Id,
    layers:[anim.STACK_LAYERS]anim.Stack_Layer `mirai:"optional,label=The stack over the base in order: each plays a clip or the space of a .blend by itself over a branch of the body or all of it; replacing or adding. The parameter of its name is its weight and the axes of its space are parameters (animation.request parameters)"`,
    actions:[anim.ACTION_CAPACITY]anim.Action_Definition `mirai:"optional,label=What animation.request actions plays by name: a clip once in its layer; or over the whole body when it names none. On a .match that one takes the rig from the search through an inertial blend. With root_motion and body_move its root motion moves the Character of its entity"`,
    sections:[anim.ACTION_ROWS]Action_Section_Params `mirai:"optional"`,
    windows:[anim.ACTION_ROWS]Action_Window_Params `mirai:"optional,label=Gameplay windows"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Action_Inspect_Result :: struct {
    asset:base.Asset_Id,path:[1024]u8 `mirai:"text"`,animation:base.Asset_Id,
    layers_total,actions_total,sections_total,windows_total:u32,
    layers:[anim.STACK_LAYERS]Authoring_Page(anim.Stack_Layer),
    actions:[anim.ACTION_CAPACITY]Authoring_Page(anim.Action_Definition),
    sections:[anim.ACTION_ROWS]Authoring_Page(Action_Section_Params),
    windows:[anim.ACTION_ROWS]Authoring_Page(Action_Window_Params),
}
// layer: of the set it plays in; empty: the whole body.
Action_Playing_Result :: struct {name,section,layer:[64]u8 `mirai:"text"`,time,weight:f32,finishing:bool,root_motion:anim.Root_Motion_Policy}
// An event of Animation_Events. action: the action it is of, empty for a marker of a clip no action
// plays; name: the marker, the section or the window.
Action_Event_Result :: struct {kind:anim.Animation_Event_Kind,action,name:[64]u8 `mirai:"text"`,time,weight:f32}

action_write_defaults :: proc() -> ^Action_Write_Params {
    defaults:=new(Action_Write_Params,context.temp_allocator);if defaults==nil {return nil}
    for &value in defaults.actions {value=anim.ACTION_DEFINITION_DEFAULT}
    for &value in defaults.layers {value=anim.STACK_LAYER_DEFAULT}
    return defaults
}
authoring_actions_register :: proc(s:^editor.Session) {
    defaults:=action_write_defaults();inspect:=Authoring_Inspect_Params{limit=64}
    editor.api_method_register(s,Action_Write_Params,Authoring_Write_Result,{name="animation.action.set",summary="Makes or replaces an .action set that entities share: the stack of layers over their base (a clip or the aim offsets of a .blend each, over a branch or the whole body, replacing or adding) and the named actions of clips with their layer, priorities, cancel policies, entry and exit, sections and gameplay windows. In Edit.",defaults=defaults,run=authoring_action_set})
}
@(private)
action_authoring_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^Authoring_File) -> (anim.Action_Profile,bool) {
    if !authoring_open(s,call,id,anim.ACTION_KIND,file) {return {},false}
    profile,error:=anim.action_profile_view(&file.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Profile","a valid .action profile","invalid version or content","The action profile is invalid");return {},false}
    return profile,true
}
@(private)
action_named_index :: proc(values:[]anim.Action_Definition,name:[64]u8) -> int {for value,i in values {if value.name==name {return i}};return -1}
@(private)
action_authoring_prepare :: proc(s:^editor.Session,call:^api.Call,p:^Action_Write_Params) -> (profile:anim.Action_Profile,ok:bool) {
    count,_:=api.params_array_count(call,"actions");sections,_:=api.params_array_count(call,"sections");windows,_:=api.params_array_count(call,"windows");layers,_:=api.params_array_count(call,"layers")
    if count+layers==0 || count>anim.ACTION_CAPACITY || layers>anim.STACK_LAYERS || sections>anim.ACTION_ROWS || windows>anim.ACTION_ROWS {authoring_failure(call,"layers/actions/sections/windows","Capacity",fmt.tprintf("a layer or an action; at most %d layers and %d actions; at most 256 sections and windows",anim.STACK_LAYERS,anim.ACTION_CAPACITY),fmt.tprintf("%d/%d/%d/%d",layers,count,sections,windows),"Action set capacity exceeded");return}
    profile.info.animation=p.animation
    profile.layers=make([]anim.Stack_Layer,layers,call.allocator)
    profile.actions=make([]anim.Action_Definition,count,call.allocator);profile.sections=make([]anim.Action_Section,sections,call.allocator);profile.windows=make([]anim.Action_Window,windows,call.allocator)
    if layers>0 && profile.layers==nil || count>0 && profile.actions==nil || sections>0 && profile.sections==nil || windows>0 && profile.windows==nil {authoring_failure(call,"definition","Out_Of_Memory","memory for the action set","allocation failed","The action set could not be allocated",api.SERVER_ERROR);return}
    copy(profile.layers,p.layers[:layers]);copy(profile.actions,p.actions[:count])
    for &layer,i in profile.layers {
        if layer.clip[0]!=0 && layer.space!={} {authoring_failure(call,fmt.tprintf("layers[%d].space",i),"Two_Contents","a clip or a space","both","A layer plays a clip or samples a space; give it one");return}
        for previous in profile.layers[:i] {if previous.name==layer.name {authoring_failure(call,fmt.tprintf("layers[%d].name",i),"Duplicate_Name","a name no other layer has",base.text_get(layer.name[:]),"Two layers have this name");return}}
    }
    for &value,i in profile.actions {
        layer,found:=anim.action_layer_find(profile,value.layer)
        if !found {authoring_failure(call,fmt.tprintf("actions[%d].layer",i),"Missing_Reference","a layer of this set, or none for the whole body",base.text_get(value.layer[:]),"The action names a layer the set does not have");return}
        if value.root_motion!=.None && layer>=0 && (profile.layers[layer].over!={} || profile.layers[layer].mode!=.Override) {authoring_failure(call,fmt.tprintf("actions[%d].root_motion",i),"UnsupportedPolicy","the whole body, or an Override layer without over","a layer over a branch or an Additive one","An action with root motion takes the whole pose; leave its layer empty or give it a layer without over");return}
        if value.body_move!=.None && value.root_motion==.None {authoring_failure(call,fmt.tprintf("actions[%d].body_move",i),"Missing_Root","root_motion Extract or In_Place with a body_move",fmt.tprintf("%v",value.body_move),"An action moves its body by its root motion; give it root_motion or set body_move to None");return}
        if value.body_vertical && value.body_move==.None {authoring_failure(call,fmt.tprintf("actions[%d].body_vertical",i),"Missing_Body_Move","a body_move with body_vertical","true","body_vertical keeps the vertical of a body_move; give it a body_move or leave it false");return}
    }
    for &section,i in p.sections[:sections] {
        action:=action_named_index(profile.actions,section.action)
        if action<0 {authoring_failure(call,fmt.tprintf("sections[%d].action",i),"Missing_Reference","an action name",base.text_get(section.action[:]),"The section references an unknown action");return}
        next:=-1
        if base.text_get(section.next[:])!="" {
            for candidate,j in p.sections[:sections] {if candidate.action==section.action && candidate.name==section.next {next=j;break}}
            if next<0 {authoring_failure(call,fmt.tprintf("sections[%d].next",i),"Missing_Reference","a section in the same action",base.text_get(section.next[:]),"The next section does not exist");return}
        }
        profile.sections[i]={action=u16(action),name=section.name,start=section.start,end=section.end,next=i16(next)}
    }
    for &window,i in p.windows[:windows] {
        action:=action_named_index(profile.actions,window.action)
        if action<0 {authoring_failure(call,fmt.tprintf("windows[%d].action",i),"Missing_Reference","an action name",base.text_get(window.action[:]),"The window references an unknown action");return}
        profile.windows[i]={action=u16(action),name=window.name,start=window.start,end=window.end}
    }
    if !anim.action_profile_check(profile) {authoring_failure(call,"definition","Invalid_Profile","unique names, weights from 0 to 1, a finite positive speed, an exit over 0 up to 1 and valid time ranges","invalid action set","Action set validation failed");return}
    if host.content_animation_wait(s.app,p.animation)==nil {authoring_failure(call,"animation","Invalid_Asset","a loadable .anim asset","unavailable","The source of the action set could not be loaded");return}
    for &layer,i in profile.layers {
        if layer.space!={} {
            file:Authoring_File;defer asset.asset_close(&file.file)
            if _,opened:=program_blend_open(s,call,layer.space,&file);!opened {return}
        }
        if layer.clip[0]==0 && layer.reference_clip[0]==0 {continue}
        content:=host.content_animation_wait(s.app,layer.animation if layer.animation!={} else p.animation)
        if content==nil {authoring_failure(call,fmt.tprintf("layers[%d].animation",i),"Invalid_Asset","a loadable .anim asset","unavailable","The source of the layer could not be loaded");return}
        if layer.clip[0]!=0 && lib.clip_find(&content.lib,base.name_hash(base.text_get(layer.clip[:])))==0 {authoring_failure(call,fmt.tprintf("layers[%d].clip",i),"Missing_Clip","a clip in animation",base.text_get(layer.clip[:]),"The clip of the layer does not exist");return}
        if layer.reference_clip[0]!=0 && lib.clip_find(&content.lib,base.name_hash(base.text_get(layer.reference_clip[:])))==0 {authoring_failure(call,fmt.tprintf("layers[%d].reference_clip",i),"Missing_Clip","a clip in animation",base.text_get(layer.reference_clip[:]),"The reference clip of the layer does not exist");return}
    }
    for &definition,i in profile.actions {
        source:=definition.animation if definition.animation!={} else p.animation
        content:=host.content_animation_wait(s.app,source)
        if content==nil {authoring_failure(call,fmt.tprintf("actions[%d].animation",i),"Invalid_Asset","a loadable .anim asset","unavailable","The action source could not be loaded");return}
        clip:=lib.clip_find(&content.lib,base.name_hash(base.text_get(definition.clip[:])))
        if clip==0 {authoring_failure(call,fmt.tprintf("actions[%d].clip",i),"Missing_Clip","a clip in animation",base.text_get(definition.clip[:]),"The action clip does not exist");return}
        duration:=lib.clip_duration(&content.lib,clip)
        if marker:=base.text_get(definition.exit_marker[:]);marker!="" {
            known:=false
            for value in lib.clip_markers(&content.lib,clip) {known ||= int(value.id)<len(content.markers) && content.markers[value.id]==base.name_hash(marker)}
            if !known {authoring_failure(call,fmt.tprintf("actions[%d].exit_marker",i),"Missing_Marker","a marker of the action clip",marker,"The clip has no such marker",fix="List its markers with animation.asset.inspect and the clip, or leave exit_marker empty to end at exit");return}
        }
        if definition.root_motion!=.None && (int(clip)>len(content.roots) || content.roots[clip-1].bone=={} || !content.roots[clip-1].translation && !content.roots[clip-1].rotation) {authoring_failure(call,fmt.tprintf("actions[%d].root_motion",i),"Incompatible_Root","root metadata on the action clip","none","The action clip has no root motion");return}
        for section,j in profile.sections {if int(section.action)==i && section.end>duration {authoring_failure(call,fmt.tprintf("sections[%d].end",j),"Range","a time inside the action clip",fmt.tprintf("%g",section.end),"The section exceeds clip duration");return}}
        for window,j in profile.windows {if int(window.action)==i && window.end>duration {authoring_failure(call,fmt.tprintf("windows[%d].end",j),"Range","a time inside the action clip",fmt.tprintf("%g",window.end),"The window exceeds clip duration");return}}
    }
    return profile,true
}
@(private)
authoring_action_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Action_Write_Params);if !authoring_editable(s,call) {return}
    file:Authoring_File;defer asset.asset_close(&file.file)
    id,ok:=authoring_set_target(s,call,base.text_get(p.path[:]),anim.ACTION_KIND,".action",&file);if !ok {return}
    profile,valid:=action_authoring_prepare(s,call,p);defer anim.action_profile_free(&profile,call.allocator);if !valid {return}
    doc:asset.Document
    if anim.action_profile_document(&doc,&s.app.assets.types,id,profile,call.allocator)!=.None {authoring_failure(call,"definition","Invalid_Profile","a serializable action profile","invalid","The action profile could not be serialized");return};defer asset.document_destroy(&doc)
    _=authoring_publish(s,call,file,&doc,api.call_result(call,Authoring_Write_Result))
}
authoring_action_profile_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Authoring_Inspect_Params);file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=action_authoring_open(s,call,p.asset,&file);if !ok {return}
    sections:=make([]Action_Section_Params,len(profile.sections),call.allocator);windows:=make([]Action_Window_Params,len(profile.windows),call.allocator)
    if len(profile.sections)>0 && sections==nil || len(profile.windows)>0 && windows==nil {authoring_failure(call,"definition","Out_Of_Memory","memory for named action sections and windows","allocation failed","The action profile could not be inspected",api.SERVER_ERROR);return}
    for section,i in profile.sections {sections[i]={action=profile.actions[section.action].name,name=section.name,start=section.start,end=section.end};if section.next>=0 {sections[i].next=profile.sections[section.next].name}}
    for window,i in profile.windows {windows[i]={action=profile.actions[window.action].name,name=window.name,start=window.start,end=window.end}}
    out:=call.out;serial.text_write_raw(out,"{");authoring_result(call,p.asset,file.path)
    api.write_key(out,"animation");serial.write_u8(out,'"');serial.text_write_asset_id(out,profile.info.animation);serial.write_u8(out,'"');api.write_int(out,"layers_total",i64(len(profile.layers)));api.write_int(out,"actions_total",i64(len(profile.actions)));api.write_int(out,"sections_total",i64(len(sections)));api.write_int(out,"windows_total",i64(len(windows)))
    program_rows(call,"layers",profile.layers,p.offset,p.limit);program_rows(call,"actions",profile.actions,p.offset,p.limit);program_rows(call,"sections",sections,p.offset,p.limit);program_rows(call,"windows",windows,p.offset,p.limit)
    serial.text_write_raw(out,"}");
}
// Whether an action can be asked of the Animation: one with root motion not of one that follows a source.
@(private)
action_control_policy :: proc(call:^api.Call,definition:anim.Action_Definition,description:anim.Animation,path:string) -> bool {
    if definition.root_motion!=.None && description.source!=core.NONE {authoring_failure(call,path,"UnsupportedPolicy","root action requests on the source rig","a retarget destination","Root actions must be requested on the source rig");return false}
    return true
}
// The events of the tick of an entity, from Animation_Events: those of its actions, or with markers all.
@(private)
action_events_write :: proc(call:^api.Call,world:core.World_Ref,entity:core.Entity,set:base.Asset_Id,markers:bool) {
    out:=call.out;written:=0
    events:=core.world_storage_of(world,anim.Animation_Events);runtime:=core.world_storage_of(world,anim.Action_Runtime)
    serial.text_write_raw(out,"[")
    if events!=nil {for event in events.items {
        if event.entity!=entity || event.kind==.Marker && !markers {continue}
        value:=Action_Event_Result{kind=event.kind,time=event.time,weight=event.weight}
        if runtime!=nil {for &plan in runtime.plans {
            if plan.asset!=set {continue}
            for &action in plan.profile.actions {if base.name_hash(base.text_get(action.name[:]))==event.action {value.action=action.name}}
            for &section in plan.profile.sections {if base.name_hash(base.text_get(section.name[:]))==event.name && event.kind!=.Span_Begin && event.kind!=.Span_End {value.name=section.name}}
            for &window in plan.profile.windows {if base.name_hash(base.text_get(window.name[:]))==event.name && (event.kind==.Span_Begin || event.kind==.Span_End) {value.name=window.name}}
        }}
        if written>0 {serial.text_write_raw(out,",")};written+=1;authoring_write_value(call,&value,type_info_of(Action_Event_Result))
    }}
    serial.text_write_raw(out,"]")
}
authoring_action_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params);w,e,ok:=subject(s,call,p.entity[:],p.handle);if !ok {return}
    description,present:=editor.entity_get(w,e,anim.Animation);if !present {authoring_failure(call,"entity","Missing_Component","an Animation component","none","The entity has no Animation component");return}
    runtime:=core.world_storage_of(w,anim.Action_Runtime);playback:=core.world_storage_of(w,anim.Playback)
    out:=call.out;serial.text_write_raw(out,"{");api.write_key(out,"id",true);api.write_id(out,editor.api_entity_id(w,e));api.write_key(out,"profile");serial.write_u8(out,'"');serial.text_write_asset_id(out,description.actions);serial.write_u8(out,'"')
    problems:[PREVIEW_PROBLEMS]Problem_Result
    shown,_:=entity_problems(s.app,w,e,"animation.action",problems[:])
    serial.text_write_raw(out,",\"problems\":[")
    for &problem,i in problems[:shown] {if i>0 {serial.write_u8(out,',')};authoring_write_value(call,&problem,type_info_of(Problem_Result))}
    serial.text_write_raw(out,"],\"parameters\":[")
    parameters:[anim.STACK_PARAMETERS*2]anim.Stack_Parameter_Info
    blends:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Blend_Assets)
    for &parameter,i in parameters[:anim.stack_parameters(runtime,blends,playback,e,parameters[:])] {if i>0 {serial.write_u8(out,',')};authoring_write_value(call,&parameter,type_info_of(anim.Stack_Parameter_Info))}
    serial.text_write_raw(out,"],\"playing\":[");written:=0
    if runtime!=nil {for &state in runtime.states {if state.entity!=e || state.plan<0 || int(state.plan)>=len(runtime.plans) {continue};profile:=runtime.plans[state.plan].profile
        for slot,i in state.slots {if !slot.active {continue};definition:=profile.actions[slot.action];value:=Action_Playing_Result{name=definition.name,layer=definition.layer,time=slot.time,finishing=slot.finishing,root_motion=definition.root_motion};if slot.section>=0 {value.section=profile.sections[slot.section].name}
            if playback!=nil {for played in playback.states {if played.entity==e {value.weight=1 if slot.injected else played.layers[i].weight;break}}}
            if written>0 {serial.text_write_raw(out,",")};written+=1;authoring_write_value(call,&value,type_info_of(type_of(value)))
        }
    }}
    serial.text_write_raw(out,"],\"events\":");action_events_write(call,w,e,description.actions,false)
    serial.text_write_raw(out,"}");
}
