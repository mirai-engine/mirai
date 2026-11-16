package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import anim "plugins:animation/runtime"

Action_Section_Params :: struct {action,name:[64]u8 `mirai:"text,label=The action and the span of its clip of that name"`,next:[64]u8 `mirai:"text,optional,label=The section of the same action that follows in any row; empty completes the action"`}
Action_Write_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .character: its layers, actions and sections are replaced, its other parts kept"`,
    animation:base.Asset_Id `mirai:"optional,label=The .anim of its clips; needed for a new .character"`,
    layers:[anim.STACK_LAYERS]anim.Stack_Layer `mirai:"optional,label=The stack over the base in order: each plays a clip or a space of the set by itself over a branch of the body or all of it; replacing or adding. The parameter of its name is its weight and the axes of its space are parameters (animation.request parameters)"`,
    actions:[anim.ACTION_CAPACITY]anim.Action_Definition `mirai:"optional,label=What animation.request actions plays by name: a clip once in its layer; or over the whole body when it names none. Over locomotion that one takes the rig from the search through an inertial blend. With root_motion and body_move its root motion moves the Character of its entity. The spans of its clip that are not its sections are its windows"`,
    sections:[anim.ACTION_ROWS]Action_Section_Params `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
// layer: of the set it plays in; empty: the whole body.
Action_Playing_Result :: struct {name,section,layer:[64]u8 `mirai:"text"`,time,weight:f32,finishing:bool,root_motion:anim.Root_Motion_Policy}
// An event of Animation_Events. action: the action it is of, empty for a marker of a clip no action
// plays; name: the section it is in (its span for Span_Begin and Span_End).
Action_Event_Result :: struct {kind:anim.Animation_Event_Kind,action,name:[64]u8 `mirai:"text"`,time,weight:f32}

action_write_defaults :: proc() -> ^Action_Write_Params {
    defaults:=new(Action_Write_Params,context.temp_allocator);if defaults==nil {return nil}
    for &value in defaults.actions {value=anim.ACTION_DEFINITION_DEFAULT}
    for &value in defaults.layers {value=anim.STACK_LAYER_DEFAULT}
    return defaults
}
authoring_actions_register :: proc(s:^editor.Session) {
    defaults:=action_write_defaults()
    editor.api_method_register(s,{params=type_info_of(Action_Write_Params),result=type_info_of(Authoring_Write_Result),name="animation.action.set",summary="Replaces what plays over the base of a .character that entities share: the stack of layers (a clip or a space of the set each, over a branch or the whole body, replacing or adding) and the named actions of clips with their layer, priorities, cancel policies, entry and exit, and sections, spans of their clips. In Edit.",defaults=defaults,run=authoring_action_set})
}
@(private)
action_named_index :: proc(values:[]anim.Action_Definition,name:[64]u8) -> int {for value,i in values {if value.name==name {return i}};return -1}
@(private)
action_authoring_prepare :: proc(s:^editor.Session,call:^api.Call,p:^Action_Write_Params,set:anim.Character_Set) -> (profile:anim.Action_Profile,ok:bool) {
    count,_:=api.params_array_count(call,"actions");sections,_:=api.params_array_count(call,"sections");layers,_:=api.params_array_count(call,"layers")
    if count>anim.ACTION_CAPACITY || layers>anim.STACK_LAYERS || sections>anim.ACTION_ROWS {authoring_failure(call,"layers/actions/sections","Capacity",fmt.tprintf("at most %d layers, %d actions and 256 sections",anim.STACK_LAYERS,anim.ACTION_CAPACITY),fmt.tprintf("%d/%d/%d",layers,count,sections),"Action capacity exceeded");return}
    animation:=set.info.animation
    profile.layers=make([]anim.Stack_Layer,layers,call.allocator)
    profile.actions=make([]anim.Action_Definition,count,call.allocator);profile.sections=make([]anim.Action_Section,sections,call.allocator)
    if layers>0 && profile.layers==nil || count>0 && profile.actions==nil || sections>0 && profile.sections==nil {authoring_failure(call,"definition","Out_Of_Memory","memory for the actions","allocation failed","The actions could not be allocated",api.SERVER_ERROR);return}
    copy(profile.layers,p.layers[:layers]);copy(profile.actions,p.actions[:count])
    for &layer,i in profile.layers {
        if layer.clip[0]!=0 && layer.space[0]!=0 {authoring_failure(call,fmt.tprintf("layers[%d].space",i),"Two_Contents","a clip or a space","both","A layer plays a clip or samples a space; give it one");return}
        if layer.space[0]!=0 && anim.character_space(set,layer.space)<0 {authoring_failure(call,fmt.tprintf("layers[%d].space",i),"Missing_Reference","a space of the .character",base.text_get(layer.space[:]),"The layer names a space the set does not have",fix="Make it with animation.space.set");return}
        for previous in profile.layers[:i] {if previous.name==layer.name {authoring_failure(call,fmt.tprintf("layers[%d].name",i),"Duplicate_Name","a name no other layer has",base.text_get(layer.name[:]),"Two layers have this name");return}}
    }
    for &value,i in profile.actions {
        layer,found:=anim.action_layer_find(profile,value.layer)
        if !found {authoring_failure(call,fmt.tprintf("actions[%d].layer",i),"Missing_Reference","a layer of this set, or none for the whole body",base.text_get(value.layer[:]),"The action names a layer the set does not have");return}
        if value.root_motion!=.None && layer>=0 && (anim.layer_over(profile.layers[layer].over)!={} || profile.layers[layer].mode!=.Override) {authoring_failure(call,fmt.tprintf("actions[%d].root_motion",i),"UnsupportedPolicy","the whole body, or an Override layer without over","a layer over a branch or an Additive one","An action with root motion takes the whole pose; leave its layer empty or give it a layer without over");return}
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
        profile.sections[i]={action=u16(action),name=section.name,next=i16(next)}
    }
    if !anim.action_profile_check(profile) {authoring_failure(call,"definition","Invalid_Profile","unique names, weights from 0 to 1, a finite positive speed and an exit over 0 up to 1","invalid actions","Action validation failed");return}
    if host.content_animation_wait(s.app,animation)==nil {authoring_failure(call,"animation","Invalid_Asset","a loadable .anim asset","unavailable","The animation of the .character could not be loaded");return}
    for &layer,i in profile.layers {
        if layer.clip[0]==0 && layer.reference_clip[0]==0 {continue}
        content:=host.content_animation_wait(s.app,layer.animation if layer.animation!={} else animation)
        if content==nil {authoring_failure(call,fmt.tprintf("layers[%d].animation",i),"Invalid_Asset","a loadable .anim asset","unavailable","The source of the layer could not be loaded");return}
        if layer.clip[0]!=0 && lib.clip_find(&content.lib,base.name_hash(base.text_get(layer.clip[:])))==0 {authoring_failure(call,fmt.tprintf("layers[%d].clip",i),"Missing_Clip","a clip in animation",base.text_get(layer.clip[:]),"The clip of the layer does not exist");return}
        if layer.reference_clip[0]!=0 && lib.clip_find(&content.lib,base.name_hash(base.text_get(layer.reference_clip[:])))==0 {authoring_failure(call,fmt.tprintf("layers[%d].reference_clip",i),"Missing_Clip","a clip in animation",base.text_get(layer.reference_clip[:]),"The reference clip of the layer does not exist");return}
    }
    for &definition,i in profile.actions {
        source:=definition.animation if definition.animation!={} else animation
        content:=host.content_animation_wait(s.app,source)
        if content==nil {authoring_failure(call,fmt.tprintf("actions[%d].animation",i),"Invalid_Asset","a loadable .anim asset","unavailable","The action source could not be loaded");return}
        clip:=lib.clip_find(&content.lib,base.name_hash(base.text_get(definition.clip[:])))
        if clip==0 {authoring_failure(call,fmt.tprintf("actions[%d].clip",i),"Missing_Clip","a clip in animation",base.text_get(definition.clip[:]),"The action clip does not exist");return}
        duration:=lib.clip_duration(&content.lib,clip)
        if marker:=base.text_get(definition.exit_marker[:]);marker!="" {
            known:=false
            for value in lib.clip_markers(&content.lib,clip) {known ||= int(value.id)<len(content.markers) && content.markers[value.id].name==base.name_hash(marker)}
            if !known {authoring_failure(call,fmt.tprintf("actions[%d].exit_marker",i),"Missing_Marker","a marker of the action clip",marker,"The clip has no such marker",fix="List its markers with animation.asset.inspect and the clip, or leave exit_marker empty to end at exit");return}
        }
        if definition.root_motion!=.None && (int(clip)>len(content.roots) || content.roots[clip-1].bone=={} || !content.roots[clip-1].translation && !content.roots[clip-1].rotation) {authoring_failure(call,fmt.tprintf("actions[%d].root_motion",i),"Incompatible_Root","root metadata on the action clip","none","The action clip has no root motion");return}
        for &section,j in profile.sections {
            if int(section.action)!=i {continue}
            spanned:=false
            for value in lib.clip_markers(&content.lib,clip) {spanned ||= value.duration>0 && value.time+value.duration<=duration && int(value.id)<len(content.markers) && content.markers[value.id].name==base.name_hash(base.text_get(section.name[:]))}
            if !spanned {authoring_failure(call,fmt.tprintf("sections[%d].name",j),"Missing_Span","a span of the action clip of that name",base.text_get(section.name[:]),"A section is a span of the clip of its action",fix="Mark the span with animation.marker.set and a duration");return}
        }
    }
    return profile,true
}
@(private)
authoring_action_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Action_Write_Params);if !authoring_editable(s,call) {return}
    file:Authoring_File;defer asset.asset_close(&file.file)
    set,id,ok:=character_target(s,call,base.text_get(p.path[:]),p.animation,&file);if !ok {return}
    profile,valid:=action_authoring_prepare(s,call,p,set);defer anim.action_profile_free(&profile,call.allocator);if !valid {return}
    set.actions=profile
    _=character_publish(s,call,file,id,set)
}
// The events of the tick of an entity, from Animation_Events: those of its actions, or with markers all.
@(private)
action_events :: proc(call:^api.Call,world:core.World_Ref,entity:core.Entity,set:base.Asset_Id,markers:bool) -> []Action_Event_Result {
    rows:=make([dynamic]Action_Event_Result,call.allocator)
    events:=core.world_storage_of(world,anim.Animation_Events);runtime:=core.world_storage_of(world,anim.Action_Runtime)
    if events!=nil {for event in events.items {
        if event.entity!=entity || event.kind==.Marker && !markers {continue}
        value:=Action_Event_Result{kind=event.kind,time=event.time,weight=event.weight}
        if runtime!=nil {for &plan in runtime.plans {
            if plan.asset!=set {continue}
            for &action in plan.profile.actions {if base.name_hash(base.text_get(action.name[:]))==event.action {value.action=action.name}}
            for &section in plan.profile.sections {if base.name_hash(base.text_get(section.name[:]))==event.name && event.kind!=.Span_Begin && event.kind!=.Span_End {value.name=section.name}}
        }}
        append(&rows,value)
    }}
    return rows[:]
}
@(private)
authoring_action_inspect :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,e:core.Entity) -> (r:Instance_Actions) {
    description,present:=editor.entity_get(w,e,anim.Animation);if !present {authoring_failure(call,"entity","Missing_Component","an Animation component","none","The entity has no Animation component");return}
    runtime:=core.world_storage_of(w,anim.Action_Runtime);playback:=core.world_storage_of(w,anim.Playback)
    r.id,r.character=editor.api_entity_id(w,e),description.asset
    problems:=make([]Problem_Result,PREVIEW_PROBLEMS,call.allocator)
    shown,_:=entity_problems(s.app,w,e,"animation.action",problems)
    r.problems=problems[:shown]
    parameters:=make([]anim.Stack_Parameter_Info,anim.STACK_PARAMETERS*2,call.allocator)
    characters:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Character_Assets)
    r.parameters=parameters[:anim.stack_parameters(runtime,characters,playback,e,parameters)]
    playing:=make([dynamic]Action_Playing_Result,call.allocator)
    if runtime!=nil {for &state in runtime.states {if state.entity!=e || state.plan<0 || int(state.plan)>=len(runtime.plans) {continue};profile:=runtime.plans[state.plan].profile
        for slot,i in state.slots {if !slot.active {continue};definition:=profile.actions[slot.action];value:=Action_Playing_Result{name=definition.name,layer=definition.layer,time=slot.time,finishing=slot.finishing,root_motion=definition.root_motion};if slot.section>=0 {value.section=profile.sections[slot.section].name}
            if playback!=nil {for played in playback.states {if played.entity==e {value.weight=played.layers[i].weight;break}}}
            append(&playing,value)
        }
    }}
    r.playing,r.events=playing[:],action_events(call,w,e,description.asset,false)
    return
}
