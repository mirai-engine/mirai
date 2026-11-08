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
    actions:[anim.ACTION_CAPACITY]anim.Action_Definition `mirai:"label=Actions on one layer share over; mode; reference; curves; root_motion and body_move. A root action is a full-body Override of a clip with root motion; with body_move its root motion moves the Character of its entity"`,
    sections:[anim.ACTION_ROWS]Action_Section_Params `mirai:"optional"`,
    windows:[anim.ACTION_ROWS]Action_Window_Params `mirai:"optional,label=Gameplay windows"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Action_Inspect_Result :: struct {
    asset:base.Asset_Id,path:[1024]u8 `mirai:"text"`,animation:base.Asset_Id,
    actions_total,sections_total,windows_total:u32,
    actions:[anim.ACTION_CAPACITY]Authoring_Page(anim.Action_Definition),
    sections:[anim.ACTION_ROWS]Authoring_Page(Action_Section_Params),
    windows:[anim.ACTION_ROWS]Authoring_Page(Action_Window_Params),
}
Action_Playing_Result :: struct {name,section:[64]u8 `mirai:"text"`,layer:u8,time,weight:f32,finishing:bool,root_motion:anim.Root_Motion_Policy}
Action_Event_Result :: struct {name,section,window:[64]u8 `mirai:"text"`,kind:anim.Action_Event_Kind,layer:u8,time,weight:f32}

action_write_defaults :: proc() -> ^Action_Write_Params {
    defaults:=new(Action_Write_Params,context.temp_allocator);if defaults==nil {return nil}
    for &value in defaults.actions {value=anim.ACTION_DEFINITION_DEFAULT}
    return defaults
}
authoring_actions_register :: proc(s:^editor.Session) {
    defaults:=action_write_defaults();inspect:=Authoring_Inspect_Params{limit=64}
    authoring_method_register(s,{name="animation.action.set",summary="Makes or replaces an .action profile that entities share: named actions of clips with priorities and cancel policies, their sections and gameplay windows. In Edit.",params=Action_Write_Params,params_info=type_info_of(Action_Write_Params),defaults=defaults,run=authoring_action_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
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
    count,_:=api.params_array_count(call,"actions");sections,_:=api.params_array_count(call,"sections");windows,_:=api.params_array_count(call,"windows")
    if count==0 || count>anim.ACTION_CAPACITY || sections>anim.ACTION_ROWS || windows>anim.ACTION_ROWS {authoring_failure(call,"actions/sections/windows","Capacity","1 to 64 actions; at most 256 sections and windows",fmt.tprintf("%d/%d/%d",count,sections,windows),"Action capacity exceeded");return}
    profile.info.animation=p.animation
    profile.actions=make([]anim.Action_Definition,count,call.allocator);profile.sections=make([]anim.Action_Section,sections,call.allocator);profile.windows=make([]anim.Action_Window,windows,call.allocator)
    if profile.actions==nil || sections>0 && profile.sections==nil || windows>0 && profile.windows==nil {authoring_failure(call,"definition","Out_Of_Memory","memory for the action profile","allocation failed","The action profile could not be allocated",api.SERVER_ERROR);return}
    copy(profile.actions,p.actions[:count])
    for value,i in profile.actions {
        if value.body_move!=.None && value.root_motion==.None {authoring_failure(call,fmt.tprintf("actions[%d].body_move",i),"Missing_Root","root_motion Extract or In_Place with a body_move",fmt.tprintf("%v",value.body_move),"An action moves its body by its root motion; give it root_motion or set body_move to None");return}
        if value.body_vertical && value.body_move==.None {authoring_failure(call,fmt.tprintf("actions[%d].body_vertical",i),"Missing_Body_Move","a body_move with body_vertical","true","body_vertical keeps the vertical of a body_move; give it a body_move or leave it false");return}
        for previous in profile.actions[:i] {if previous.layer==value.layer && !anim.action_channel_equal(previous,value) {authoring_failure(call,fmt.tprintf("actions[%d]",i),"UnsupportedPolicy","the same over, mode, reference, curves, root_motion and body_move for every action on one layer","incompatible channel policy","Actions sharing a layer must share its channel policy");return}}
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
    if !anim.action_profile_check(profile) {authoring_failure(call,"definition","Invalid_Profile","unique names, finite positive speed, valid layer/root policy and time ranges","invalid action definition","Action profile validation failed");return}
    if host.content_animation_wait(s.app,p.animation)==nil {authoring_failure(call,"animation","Invalid_Asset","a loadable .anim asset","unavailable","The action source could not be loaded");return}
    for &definition,i in profile.actions {
        source:=definition.animation if definition.animation!={} else p.animation
        content:=host.content_animation_wait(s.app,source)
        if content==nil {authoring_failure(call,fmt.tprintf("actions[%d].animation",i),"Invalid_Asset","a loadable .anim asset","unavailable","The action source could not be loaded");return}
        clip:=lib.clip_find(&content.lib,base.name_hash(base.text_get(definition.clip[:])))
        if clip==0 {authoring_failure(call,fmt.tprintf("actions[%d].clip",i),"Missing_Clip","a clip in animation",base.text_get(definition.clip[:]),"The action clip does not exist");return}
        duration:=lib.clip_duration(&content.lib,clip)
        if definition.reference>duration {authoring_failure(call,fmt.tprintf("actions[%d].reference",i),"Range","a reference time inside the clip",fmt.tprintf("%g",definition.reference),"The additive reference exceeds clip duration");return}
        if definition.root_motion!=.None && (int(clip)>len(content.roots) || content.roots[clip-1].bone=={} || !content.roots[clip-1].translation && !content.roots[clip-1].rotation) {authoring_failure(call,fmt.tprintf("actions[%d].root_motion",i),"Incompatible_Root","root metadata on the action clip","missing root channels","Root action requires authored root metadata");return}
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
    _=authoring_publish(s,call,file,&doc)
}
authoring_action_profile_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Authoring_Inspect_Params);file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=action_authoring_open(s,call,p.asset,&file);if !ok {return}
    sections:=make([]Action_Section_Params,len(profile.sections),call.allocator);windows:=make([]Action_Window_Params,len(profile.windows),call.allocator)
    if len(profile.sections)>0 && sections==nil || len(profile.windows)>0 && windows==nil {authoring_failure(call,"definition","Out_Of_Memory","memory for named action sections and windows","allocation failed","The action profile could not be inspected",api.SERVER_ERROR);return}
    for section,i in profile.sections {sections[i]={action=profile.actions[section.action].name,name=section.name,start=section.start,end=section.end};if section.next>=0 {sections[i].next=profile.sections[section.next].name}}
    for window,i in profile.windows {windows[i]={action=profile.actions[window.action].name,name=window.name,start=window.start,end=window.end}}
    out:=call.out;serial.text_write_raw(out,"{");authoring_result(call,p.asset,file.path)
    api.write_key(out,"animation");serial.write_u8(out,'"');serial.text_write_asset_id(out,profile.info.animation);serial.write_u8(out,'"');api.write_int(out,"actions_total",i64(len(profile.actions)));api.write_int(out,"sections_total",i64(len(sections)));api.write_int(out,"windows_total",i64(len(windows)))
    program_rows(call,"actions",profile.actions,p.offset,p.limit);program_rows(call,"sections",sections,p.offset,p.limit);program_rows(call,"windows",windows,p.offset,p.limit)
    serial.text_write_raw(out,"}");
}
@(private)
action_control_policy :: proc(call:^api.Call,definition:anim.Action_Definition,description:anim.Animation,path:string) -> bool {
    switch anim.action_policy_check(definition,description) {
    case .None:return true
    case .ReservedLayer:authoring_failure(call,path,"ReservedLayer","an empty Animation.layers slot reserved for actions","a component clip occupies the requested action layer","The action layer is already assigned by the component")
    case .UnsupportedPolicy:authoring_failure(call,path,"UnsupportedPolicy","root action requests on the source rig","a retarget destination","Root actions must be requested on the source rig")
    }
    return false
}
authoring_action_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params);w,e,ok:=subject(s,call,p.id,p.entity);if !ok {return}
    description,present:=editor.entity_get(w,e,anim.Animation);if !present {authoring_failure(call,"id","Missing_Component","an Animation component","none","The entity has no Animation component");return}
    runtime:=core.world_storage_of(w,anim.Action_Runtime);playback:=core.world_storage_of(w,anim.Playback)
    out:=call.out;serial.text_write_raw(out,"{");api.write_key(out,"id",true);api.write_id(out,p.id);api.write_key(out,"profile");serial.write_u8(out,'"');serial.text_write_asset_id(out,description.actions);serial.write_u8(out,'"')
    problems:[PREVIEW_PROBLEMS]Problem_Result
    shown,_:=entity_problems(s.app,w,e,"animation.action",problems[:])
    serial.text_write_raw(out,",\"problems\":[")
    for &problem,i in problems[:shown] {if i>0 {serial.write_u8(out,',')};authoring_write_value(call,&problem,type_info_of(Problem_Result))}
    serial.text_write_raw(out,"],\"playing\":[");written:=0
    if runtime!=nil {for &state in runtime.states {if state.entity!=e || state.plan<0 || int(state.plan)>=len(runtime.plans) {continue};profile:=runtime.plans[state.plan].profile
        for slot,i in state.layers {if !slot.active {continue};definition:=profile.actions[slot.action];value:=Action_Playing_Result{name=definition.name,layer=u8(i+1),time=slot.time,finishing=slot.finishing,root_motion=definition.root_motion};if slot.section>=0 {value.section=profile.sections[slot.section].name}
            if playback!=nil {for played in playback.states {if played.entity==e {value.weight=played.layers[i].weight;break}}}
            if written>0 {serial.text_write_raw(out,",")};written+=1;authoring_write_value(call,&value,type_info_of(type_of(value)))
        }
    }}
    serial.text_write_raw(out,"],\"events\":[");written=0
    if runtime!=nil {for event in runtime.events.items {if event.entity!=e {continue};value:=Action_Event_Result{kind=event.kind,layer=event.layer,time=event.time,weight=event.weight}
        for &plan in runtime.plans {if plan.asset!=description.actions {continue};for &action in plan.profile.actions {if base.name_hash(base.text_get(action.name[:]))==event.action {value.name=action.name}};for &section in plan.profile.sections {if base.name_hash(base.text_get(section.name[:]))==event.section {value.section=section.name}};for &window in plan.profile.windows {if base.name_hash(base.text_get(window.name[:]))==event.window {value.window=window.name}}}
        if written>0 {serial.text_write_raw(out,",")};written+=1;authoring_write_value(call,&value,type_info_of(type_of(value)))
    }}
    serial.text_write_raw(out,"]}");
}
