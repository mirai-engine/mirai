package anim

import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import "base:runtime"

// What a .character plays over its base, its locomotion or the clip of its Animation: an ordered
// stack of layers, each over the ones before it, and the actions play asks for by name. A layer
// plays by itself a clip or a space of the set (aim offsets), over a branch of the body or all of
// it, replacing or adding; an action plays its clip once in a layer, or over the whole body when
// it names none. Its sections are spans of its clip it names; the other spans of its clip are its
// windows.
ACTION_CAPACITY :: 64
ACTION_ROWS :: 256
ACTION_PASSES :: 128
STACK_LAYERS :: 8
// Slot 0 is the whole body, where an action without a layer plays; slot n, layer n-1 of the set.
STACK_SLOTS :: STACK_LAYERS+1
STACK_PARAMETERS :: 16 // names set (set) on one entity
ACTION_WINDOWS :: 8    // windows of one action open at once

Layer_Mode :: enum u8 {Override,Additive}
Action_Cancel_Policy :: enum u8 {Allow,Finish_Section,Deny}
// Where the clip of an action starts when play names no section: at its start, at the time the
// base clip is at, or at the phase of its markers.
Action_Entry :: enum u8 {Start,Keep_Time,Match_Phase}
// What the time of an action counts.
Action_Clock :: enum u8 {
    Own,   // its entity's own time (core.Own_Pace), as the rest of its animation: slowed with it
    World, // the time of the world: it plays at its speed while its entity is slowed or sped up, as a clip whose play rate makes up for the dilation
}
// What the root motion of an action does to the body of its entity. With physics, animation_physics
// moves its Character by it on every tick the action plays, as a layered move of this mix.
Action_Body_Move :: enum u8 {
    None,     // only the pose and animation_root_delta have it
    Additive, // added to the velocity the locomotion of the body drives toward, which keeps its gravity and ground
    Override, // replaces that velocity on every axis, without gravity or ground
}
// The root motion of a tick that the actions of an entity which move its body give it: translation
// in the space of the entity, by the share of the root each one has, mirrored and warped with the
// root; move and vertical of the one with the most share.
Body_Motion :: struct {translation:mm.Vec3,move:Action_Body_Move,vertical:bool}

// A layer of the stack. The parameter of its name (set) is its weight; the axes of its space are
// parameters too.
Stack_Layer :: struct {
    name:[64]u8 `mirai:"text"`,
    over:Bone_Ref `mirai:"optional"`,       // the bone, @part or @region of the body whose branch it moves; empty: the whole pose
    mode:Layer_Mode `mirai:"optional"`,
    curves:Curve_Blend `mirai:"optional"`,
    mesh_space:bool `mirai:"optional"`,     // Override: the rotations of its branch blend in the space of the rig, so it keeps the turn its clip gives them whatever the base turns above it
    weight:f32 `mirai:"optional,min=0,max=1"`, // until set gives it another
    fade:f32 `mirai:"optional,min=0,unit=s"`,  // seconds its weight takes to follow, and of a change of what it plays
    clip:[64]u8 `mirai:"text,optional"`,    // what it plays while no action does; empty: nothing
    animation:base.Asset_Id `mirai:"optional"`, // of the clip; empty is the set's
    space:[32]u8 `mirai:"text,optional"`,   // instead of clip: the space of the set (aim offsets, additive poses) its axes sample
    speed:f32 `mirai:"optional"`,
    loop:bool `mirai:"optional"`,
    sync:bool `mirai:"optional"`,           // its clip keeps the phase of the base, by markers when both have them
    reference:f32 `mirai:"optional,min=0,unit=s"`,   // Additive: seconds into the reference clip whose pose it adds over
    reference_clip:[64]u8 `mirai:"text,optional"`,   // Additive: that clip; empty: the one that plays
}
STACK_LAYER_DEFAULT :: Stack_Layer{weight=1,fade=.2,speed=1,loop=true}

Action_Definition :: struct {
    name,clip:[64]u8 `mirai:"text"`,
    layer:[64]u8 `mirai:"text,optional"`, // the layer of the set it plays in; empty: the whole body
    root_motion:Root_Motion_Policy `mirai:"optional"`,
    fade_in,fade_out:f32 `mirai:"optional,min=0,unit=s"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    speed:f32 `mirai:"optional,min=0"`,
    priority:i16 `mirai:"optional"`,
    cancel:Action_Cancel_Policy `mirai:"optional"`,
    animation:base.Asset_Id `mirai:"optional"`, // of the clip; empty is the set's
    clock:Action_Clock `mirai:"optional"`,
    body_move:Action_Body_Move `mirai:"optional"`, // with root_motion: its root motion moves the body of its entity
    body_vertical:bool `mirai:"optional"`,         // with body_move: along the up of the body too; otherwise only across it
    entry:Action_Entry `mirai:"optional"`,
    exit:f32 `mirai:"optional,min=0,max=1"`,       // share of its clip at which it ends; one with sections ends with the last
    exit_marker:[64]u8 `mirai:"text,optional"`,    // or the marker of its clip at which it ends
}
ACTION_DEFINITION_DEFAULT :: Action_Definition{weight=1,speed=1,fade_in=.1,fade_out=.1,exit=1}
// A section of an action: the span of its clip of that name; next, the section it goes on to.
Action_Section :: struct {action:u16,name:[64]u8 `mirai:"text"`,next:i16}
Action_Profile :: struct {layers:[]Stack_Layer,actions:[]Action_Definition,sections:[]Action_Section}

// The layer of the set an action plays in: its index, -1 for the whole body, and false for a
// name the set does not have.
action_layer_find :: proc(profile:Action_Profile,name:[64]u8) -> (index:int,ok:bool) {
    if name[0]==0 {return -1,true}
    for layer,i in profile.layers {if layer.name==name {return i,true}}
    return -1,false
}

action_profile_check :: proc(profile:Action_Profile) -> bool {
    if len(profile.actions)>ACTION_CAPACITY || len(profile.layers)>STACK_LAYERS || len(profile.sections)>ACTION_ROWS {return false}
    for &layer,i in profile.layers {
        if !blend_text_valid(layer.name[:],false) || !blend_text_valid(layer.clip[:],true) || !blend_text_valid(layer.reference_clip[:],true) || !blend_text_valid(layer.space[:],true) || !profile_bone(layer.over) || layer.mode>max(Layer_Mode) || layer.curves>max(Curve_Blend) || !profile_weight(layer.weight) {return false}
        for number in ([?]f32{layer.fade,layer.reference}) {if !finite(number) || number<0 {return false}}
        if !finite(layer.speed) || layer.clip[0]!=0 && layer.space[0]!=0 || layer.sync && layer.clip[0]==0 || layer.animation!={} && layer.clip[0]==0 {return false}
        for previous in profile.layers[:i] {if previous.name==layer.name {return false}}
    }
    for &value,i in profile.actions {
        if !blend_text_valid(value.name[:],false) || !blend_text_valid(value.clip[:],false) || !blend_text_valid(value.layer[:],true) || !blend_text_valid(value.exit_marker[:],true) || value.root_motion>max(Root_Motion_Policy) || value.cancel>max(Action_Cancel_Policy) || value.entry>max(Action_Entry) || !profile_weight(value.weight) || !finite(value.speed) || value.speed<=0 || value.clock>max(Action_Clock) || value.body_move>max(Action_Body_Move) || !finite(value.exit) || value.exit<=0 || value.exit>1 {return false}
        layer,found:=action_layer_find(profile,value.layer)
        if !found {return false}
        if value.root_motion!=.None && layer>=0 && (profile.layers[layer].over!={} || profile.layers[layer].mode!=.Override) {return false}
        if value.body_move!=.None && value.root_motion==.None || value.body_vertical && value.body_move==.None {return false}
        for number in ([?]f32{value.fade_in,value.fade_out}) {if !finite(number) || number<0 {return false}}
        for previous in profile.actions[:i] {if previous.name==value.name {return false}}
    }
    for &section,i in profile.sections {
        if int(section.action)>=len(profile.actions) || !blend_text_valid(section.name[:],false) || section.next< -1 || int(section.next)>=len(profile.sections) {return false}
        if section.next>=0 && profile.sections[section.next].action!=section.action {return false}
        for previous in profile.sections[:i] {if previous.action==section.action && previous.name==section.name {return false}}
    }
    return true
}
action_profile_free :: proc(profile:^Action_Profile,allocator:=context.allocator) {delete(profile.layers,allocator);delete(profile.actions,allocator);delete(profile.sections,allocator);profile^={}}
@(private)
action_profile_clone :: proc(source:Action_Profile,allocator:mem.Allocator) -> (profile:Action_Profile,ok:bool) {
    profile.layers,ok=rows_clone(source.layers,allocator);if !ok {action_profile_free(&profile,allocator);return {},false}
    profile.actions,ok=rows_clone(source.actions,allocator);if !ok {action_profile_free(&profile,allocator);return {},false}
    profile.sections,ok=rows_clone(source.sections,allocator);if !ok {action_profile_free(&profile,allocator);return {},false}
    return profile,true
}
// What play, stop and set ask of the animation of an entity; animation_sample serves them.
Play_Request :: struct {entity:core.Entity,stop:bool,action,section:[64]u8 `mirai:"text"`}
Value_Request :: struct {entity:core.Entity,name:u64,value:f32}

// Plays the action named name of the .character of entity, from section when
// one is given. An action that plays in the slot it takes gives way when name has at least its
// priority and its cancel policy allows it; otherwise the request is refused with a problem of
// the entity. Naming a section of the action while it plays moves it there instead. What happens
// to it arrives in Animation_Events.
play :: proc(requests:^Animation_Requests,entity:core.Entity,name:string,section:string="") {
    if requests==nil {return}
    if entity==core.NONE || name=="" || len(name)>=64 || len(section)>=64 {core.refuse(&requests.plays);return}
    value:=Play_Request{entity=entity};base.text_set(value.action[:],name);base.text_set(value.section[:],section);core.offer(&requests.plays,value)
}
// Ends the action named name on entity as its cancel policy says: at once, at the end of its
// section, or not at all.
stop :: proc(requests:^Animation_Requests,entity:core.Entity,name:string) {
    if requests==nil {return}
    if entity==core.NONE || name=="" || len(name)>=64 {core.refuse(&requests.plays);return}
    value:=Play_Request{entity=entity,stop=true};base.text_set(value.action[:],name);core.offer(&requests.plays,value)
}
// Sets the parameter named name of the .character of entity: the weight of the layer of that name,
// from 0 to 1, or the place on the axis of that name of the space of a layer (an aim yaw). It
// stays until set again; a value past the range of its axis is the end of the range.
set :: proc(requests:^Animation_Requests,entity:core.Entity,name:string,value:f32) {
    if requests==nil {return}
    if entity==core.NONE || name=="" || len(name)>=64 || !finite(value) {core.refuse(&requests.values);return}
    core.offer(&requests.values,Value_Request{entity,base.name_hash(name),value})
}
// Turns the first Look row of the .character of entity toward target, by weight; 0 lets go.
look :: proc(requests:^Animation_Requests,entity:core.Entity,target:Spatial_Target,weight:f32=1) {
    if requests==nil {return}
    modifier_goal(requests,Modifier_Goal{rig=entity,kind=.Look,target=target,weight=weight,enabled=weight>0})
}

Action_Plan :: struct {
    asset:base.Asset_Id,revision:u64,profile:Action_Profile,
    animation:base.Asset_Id,           // of the clips of its set
    slots:[ACTION_CAPACITY]u8,         // by action: the slot it plays in
    layers:[STACK_LAYERS]Layer_Ask,    // by layer: what it asks for by itself, its clips named as its source names them
    layer_names:[STACK_LAYERS]u64,     // base.name_hash of the name of each layer: the parameter that is its weight
}
Action_Playing :: struct {
    action,section:i16,
    time:f32,
    active,starting,seeking,finishing,cancel_pending:bool,
    entering:bool,          // the next sample starts it at its section, from the span of its clip, and tells it
    late:f32,               // seconds of its clip it starts past its section: another end started it that much before
    windows:[ACTION_WINDOWS]u64, // the names of the spans of its clip it is inside of; 0: free
    player:lib.Player,
    from,to:f32,
    continuous:bool,
    speed,fade_out:f32,    // of its action, which a change of the actions asset does not take from a finishing slot
}
// heard: by slot, the tick of the last action Animation_Played told of an entity another end decides.
Action_State :: struct {entity:core.Entity,plan,content:i32,slots:[STACK_SLOTS]Action_Playing,heard:[STACK_SLOTS]u64,seen:u64,retry:bool}
@(storage,free="actions_runtime_free")
Action_Runtime :: struct {allocator:mem.Allocator,plans:[dynamic]Action_Plan,states:[dynamic]Action_State,rows:[dynamic]i32,frame:u64,animations_seen:core.Seen}
actions_runtime_free :: proc(runtime:^Action_Runtime) {allocator:=runtime.allocator if runtime.allocator.procedure!=nil else context.allocator;for &plan in runtime.plans {action_profile_free(&plan.profile,allocator)};delete(runtime.plans);delete(runtime.states);delete(runtime.rows);runtime^={}}

// An action started, stopped or moved to a section by the end that decides its entity: base.name_hash
// of its name and section, and the tick it was asked at.
Action_Started :: struct {action,section,tick:u64,stop:bool}
// What the end that decides an entity asked of its actions, by slot of its stack: the other ends
// play each from the tick it was asked, so what a mind or a server plays reaches every player.
@(component,replicated,description="The actions the end that decides this entity started on it, by layer: the others play each from the tick it started.")
Animation_Played :: struct {slots:[STACK_SLOTS]Action_Started `mirai:"readonly,hidden"`}
@(private)
action_state :: proc(runtime:^Action_Runtime,entity:core.Entity) -> ^Action_State {
    if runtime==nil || entity==core.NONE {return nil}
    index:=core.entity_index(entity);if index>=len(runtime.rows) {return nil}
    row:=int(runtime.rows[index])-1
    if row<0 || row>=len(runtime.states) || runtime.states[row].entity!=entity {return nil}
    return &runtime.states[row]
}
// The plan of the .character of an entity; nil while it has none loaded.
@(private)
action_plan :: proc(runtime:^Action_Runtime,entity:core.Entity) -> ^Action_Plan {
    state:=action_state(runtime,entity)
    if state==nil || state.plan<0 || int(state.plan)>=len(runtime.plans) {return nil}
    return &runtime.plans[state.plan]
}
// What the layers and the actions of a set resolve to once, when its plan takes it.
@(private)
action_plan_bind :: proc(plan:^Action_Plan,set:Character_Set) {
    plan.animation=set.info.animation
    plan.slots,plan.layers,plan.layer_names={},{},{}
    for &layer,i in plan.profile.layers {
        over,_:=bone_ref_hash(layer.over)
        plan.layer_names[i]=base.name_hash(base.text_get(layer.name[:]))
        plan.layers[i]={
            clip=base.name_hash(base.text_get(layer.clip[:])) if layer.clip[0]!=0 else 0,over=over,weight=layer.weight,speed=layer.speed,fade=layer.fade,loop=layer.loop,sync=layer.sync,
            mode=layer.mode,reference=layer.reference,reference_clip=base.name_hash(base.text_get(layer.reference_clip[:])) if layer.reference_clip[0]!=0 else 0,curves=layer.curves,mesh_space=layer.mesh_space,space=u8(character_space(set,layer.space)+1) if layer.space[0]!=0 else 0,
        }
    }
    for &value,i in plan.profile.actions {
        if layer,found:=action_layer_find(plan.profile,value.layer);found {plan.slots[i]=u8(layer+1)}
    }
}
// The name of the layer of a slot of the stack of an entity, for a message.
@(private)
stack_slot_name :: proc(runtime:^Action_Runtime,entity:core.Entity,slot:int) -> string {
    plan:=action_plan(runtime,entity)
    if slot<=0 || plan==nil || slot>len(plan.profile.layers) {return "the whole body"}
    return base.text_get(plan.profile.layers[slot-1].name[:])
}
// A parameter the .character of an entity declares, for a tool: the weight of a layer, or an axis
// of the space of one with its range, at the value set gave it or the one it has by itself.
Stack_Parameter_Info :: struct {name:[64]u8 `mirai:"text"`,value,min,max:f32,axis:bool}
stack_parameters :: proc(runtime:^Action_Runtime,characters:^Character_Assets,playback:^Playback,entity:core.Entity,out:[]Stack_Parameter_Info) -> (count:int) {
    plan:=action_plan(runtime,entity);if plan==nil {return}
    content:^Character_Content
    if characters!=nil {for &value in characters.contents {if value.id==plan.asset && value.valid {content=&value}}}
    state:=constraint_playing(playback,entity) if playback!=nil else nil
    value_of :: proc(state:^Playing,name:u64,fallback:f32) -> f32 {
        if state!=nil {for parameter in state.parameters {if parameter.name==name && name!=0 {return parameter.value}}}
        return fallback
    }
    for &layer,i in plan.profile.layers {
        if count<len(out) {out[count]={name=layer.name,value=mm.saturate(value_of(state,plan.layer_names[i],layer.weight)),min=0,max=1};count+=1}
        space:=int(plan.layers[i].space)-1
        if space<0 || content==nil || space>=len(content.spaces) {continue}
        info:=content.set.spaces[space]
        axes:=[2]Blend_Axis{info.x,info.y}
        for &axis,a in axes[:2 if info.dimension==.Two else 1] {
            if count>=len(out) {break}
            row:=Stack_Parameter_Info{value=clamp(value_of(state,content.spaces[space].axis_names[a],0),axis.min,axis.max),min=axis.min,max=axis.max,axis=true}
            copy(row.name[:],axis.name[:]);out[count]=row;count+=1
        }
    }
    return
}

// Whether the action named name plays on the entity, from the tick it is asked for until it ends or is
// interrupted (not while it fades out): its time in its clip, in seconds, and the base.name_hash of its
// section (0 without sections), as Animation_Event gives them.
action_playing :: proc(runtime:core.Ref(Action_Runtime),entity:core.Entity,name:string) -> (time:f32,section:u64,ok:bool) {
    state:=action_state(runtime.ptr,entity);if state==nil || state.plan<0 || int(state.plan)>=len(runtime.plans) {return}
    profile:=runtime.plans[state.plan].profile
    for slot in state.slots {
        if !slot.active || slot.finishing || slot.action<0 || int(slot.action)>=len(profile.actions) || base.text_get(profile.actions[slot.action].name[:])!=name {continue}
        if slot.section>=0 && int(slot.section)<len(profile.sections) {section=base.name_hash(base.text_get(profile.sections[slot.section].name[:]))}
        return slot.time,section,true
    }
    return
}
// The span named name of clip handle of content: where it starts and ends. False for a clip that
// has none.
@(private)
clip_span :: proc(content:^host.Content_Animation,handle:lib.Clip,name:u64) -> (start,end:f32,ok:bool) {
    if content==nil || !lib.clip_valid(&content.lib,handle) {return}
    for marker in lib.clip_markers(&content.lib,handle) {
        if marker.duration>0 && int(marker.id)<len(content.markers) && content.markers[marker.id]==name {return marker.time,marker.time+marker.duration,true}
    }
    return
}
// The span of a section of an action on the clip it plays.
@(private)
section_span :: proc(profile:Action_Profile,content:^host.Content_Animation,handle:lib.Clip,section:int) -> (start,end:f32,ok:bool) {
    if section<0 || section>=len(profile.sections) {return}
    return clip_span(content,handle,base.name_hash(base.text_get(profile.sections[section].name[:])))
}
// name: of the span for Span_Begin and Span_End; otherwise the section the action is in.
@(private)
action_emit :: proc(runtime:^Action_Runtime,state:^Action_State,slot:^Action_Playing,kind:Animation_Event_Kind,time:f32,playback:^Playback,events:^Animation_Events,problems:^core.Problems,span:u64=0) {
    if runtime==nil || state==nil || slot==nil || playback==nil || events==nil || state.plan<0 || int(state.plan)>=len(runtime.plans) {return}
    profile:=runtime.plans[state.plan].profile
    if slot.action<0 || int(slot.action)>=len(profile.actions) {return}
    value:=profile.actions[slot.action];name:=span
    if span==0 && slot.section>=0 && int(slot.section)<len(profile.sections) {name=base.name_hash(base.text_get(profile.sections[slot.section].name[:]))}
    if !event_push(playback,events,Animation_Event{entity=state.entity,kind=kind,action=base.name_hash(base.text_get(value.name[:])),name=name,time=time,weight=value.weight}) {
        core.report(problems,state.entity,"animation.events_lost","a %v event of action '%s' was lost: memory ran out, or the animations of the world gave more events in this tick than fit in Animation_Events; free memory, or play fewer actions in one tick, with fewer windows and sections",kind,base.text_get(value.name[:]))
    }
}
// The windows of an action are the spans of its clip that are not its sections: their begin and
// end between from and to, in the clip handle of content. leave ends those it is inside of.
@(private)
action_windows :: proc(runtime:^Action_Runtime,state:^Action_State,slot:^Action_Playing,content:^host.Content_Animation,handle:lib.Clip,from,to:f32,playback:^Playback,events:^Animation_Events,problems:^core.Problems,enter:bool=false,leave:bool=false) {
    if leave {
        for &name in slot.windows {if name!=0 {action_emit(runtime,state,slot,.Span_End,to,playback,events,problems,name);name=0}}
        return
    }
    if content==nil || !lib.clip_valid(&content.lib,handle) {return}
    profile:=runtime.plans[state.plan].profile
    spans:for marker in lib.clip_markers(&content.lib,handle) {
        if marker.duration<=0 || int(marker.id)>=len(content.markers) {continue}
        name:=content.markers[marker.id]
        for &section in profile.sections {if int(section.action)==int(slot.action) && base.name_hash(base.text_get(section.name[:]))==name {continue spans}}
        start,end:=marker.time,marker.time+marker.duration
        open:=-1;free:=-1
        for value,k in slot.windows {if value==name {open=k};if value==0 && free<0 {free=k}}
        if open<0 && free>=0 && (enter && from>=start && from<end || start>from && start<=to || enter && start==from) {
            slot.windows[free]=name;open=free;action_emit(runtime,state,slot,.Span_Begin,max(from,start),playback,events,problems,name)
        }
        if open>=0 && to>=end {slot.windows[open]=0;action_emit(runtime,state,slot,.Span_End,min(to,end),playback,events,problems,name)}
    }
}
// Ends the action of a slot; one that has not started playing yet ends without a word.
@(private)
action_end :: proc(runtime:^Action_Runtime,state:^Action_State,slot:^Action_Playing,interrupted:bool,playback:^Playback,events:^Animation_Events,problems:^core.Problems) {
    if !(slot.entering && slot.starting) {action_windows(runtime,state,slot,nil,0,slot.time,slot.time,playback,events,problems,leave=true);action_emit(runtime,state,slot,.Interrupted if interrupted else .Ended,slot.time,playback,events,problems)}
    slot.finishing=true;slot.cancel_pending=false
}
@(private)
actions_interrupt :: proc(runtime:^Action_Runtime,state:^Action_State,playback:^Playback,events:^Animation_Events,problems:^core.Problems) {
    for &slot in state.slots {if slot.active && !slot.finishing {action_end(runtime,state,&slot,true,playback,events,problems)}}
}

@(private)
actions_discover :: proc(runtime:^Action_Runtime,animations:core.Read(Animation),playback:^Playback,events:^Animation_Events,assets:^host.Assets,problems:^core.Problems) -> bool {
    // Kept only when the entities found have their room: without it they are looked for again.
    seen:=runtime.animations_seen
    c:=core.changes(animations,&seen)
    changed:=seen!=runtime.animations_seen
    added,rows:=0,len(runtime.rows)
    counted:=c
    for i in core.each_changed(animations,&counted) {
        if animation_character(assets,animations.table.values[i])=={} {continue}
        index:=core.entity_index(core.entity_at(animations,i));rows=max(rows,index+1)
        slot:=int(runtime.rows[index])-1 if index<len(runtime.rows) else -1
        if slot<0 || slot>=len(runtime.states) || core.entity_index(runtime.states[slot].entity)!=index {added+=1}
    }
    if !changed {return true}
    if !program_array_reserve(&runtime.states,len(runtime.states)+added) || !program_array_resize(&runtime.rows,rows) {memory_problem(problems,core.NONE,"the entities that play actions, so no action plays");return false}
    for i in core.each_changed(animations,&c) {
        if animation_character(assets,animations.table.values[i])=={} {continue}
        entity:=core.entity_at(animations,i);index:=core.entity_index(entity);slot:=int(runtime.rows[index])-1
        if slot>=0 && slot<len(runtime.states) && core.entity_index(runtime.states[slot].entity)==index {
            if runtime.states[slot].entity==entity {continue}
            state:=&runtime.states[slot];actions_interrupt(runtime,state,playback,events,problems)
            state^=Action_State{entity=entity,plan=-1}
        } else {slot=len(runtime.states);append(&runtime.states,Action_State{entity=entity,plan=-1})}
        runtime.rows[index]=i32(slot+1)
    }
    runtime.animations_seen=seen
    return true
}

// Plays, moves to section or stops action index of state, by the priority and cancel policy of
// what its slot plays, unless forced: another end decided it. late: seconds of its clip it starts
// past its section. False, with a problem of the entity, when it is refused.
@(private)
action_ask :: proc(runtime:^Action_Runtime,state:^Action_State,index,section:int,stop:bool,late:f32,forced:bool,playback:^Playback,events:^Animation_Events,problems:^core.Problems) -> bool {
    plan:=&runtime.plans[state.plan];profile:=plan.profile
    definition:=profile.actions[index];slot:=&state.slots[plan.slots[index]]
    name:=base.text_get(definition.name[:])
    playing:=slot.active && !slot.finishing && int(slot.action)==index
    if stop {
        if !playing {
            if !forced {core.report(problems,state.entity,"animation.action_idle","a stop of action '%s' was refused: it is not playing",name)}
            return false
        }
        switch definition.cancel if !forced else Action_Cancel_Policy.Allow {
        case .Allow:action_end(runtime,state,slot,true,playback,events,problems)
        case .Finish_Section:slot.cancel_pending=true
        case .Deny:core.report(problems,state.entity,"animation.action_cancel","action '%s' cannot be stopped: its cancel policy is Deny; let it end, or give it Allow or Finish_Section",name);return false
        }
        return true
    }
    // A section asked of the action while it plays moves it there: its span starts it in the
    // next sample, which tells the section and the windows it enters.
    if playing && section>=0 {
        action_windows(runtime,state,slot,nil,0,slot.time,slot.time,playback,events,problems,leave=true)
        slot.section,slot.seeking,slot.entering,slot.late=i16(section),true,true,late
        return true
    }
    if slot.active && !slot.finishing {
        current:=profile.actions[slot.action]
        if !forced && (definition.priority<current.priority || current.cancel!=.Allow) {
            core.report(problems,state.entity,"animation.action_busy","action '%s' cannot interrupt '%s': its priority is lower or '%s' does not let itself be cancelled; raise its priority, or wait for the Ended event of the other",name,base.text_get(current.name[:]),base.text_get(current.name[:]))
            return false
        }
        action_end(runtime,state,slot,true,playback,events,problems)
    }
    section:=section
    if section<0 {for value,i in profile.sections {if int(value.action)==index {section=i;break}}}
    slot^=Action_Playing{active=true,starting=true,seeking=true,entering=true,late=late,action=i16(index),section=i16(section),speed=definition.speed,fade_out=definition.fade_out}
    return true
}

// Loads the set of each entity and serves the plays and stops asked for: which action takes
// which slot, by priority and cancel policy.
actions_prepare :: proc(runtime:^Action_Runtime,requests:^Animation_Requests,characters:^Character_Assets,animations:core.Read(Animation),playback:^Playback,events:^Animation_Events,app:^host.App,remotes:core.Read(core.Remote),played:^core.Table(Animation_Played),time:core.Time,problems:^core.Problems) -> bool {
    allocator:=app.allocator
    context.allocator=allocator;runtime.allocator=allocator;runtime.frame+=1
    if !actions_discover(runtime,animations,playback,events,app.assets,problems) {return false}
    for &state in runtime.states {
        state.retry=false
        row:=core.row_of(animations,state.entity);if row<0 {continue}
        id:=animation_character(app.assets,animations.table.values[row])
        if id=={} {for &slot in state.slots {if slot.active {state.seen=runtime.frame;if !slot.finishing {action_end(runtime,&state,&slot,true,playback,events,problems)}}};continue}
        state.seen=runtime.frame
        content:=character_content(characters,app.assets,allocator,id,&state.content)
        if content==nil {
            row=int(state.content)-1
            state.retry=row<0 || row>=len(characters.contents) || characters.contents[row].id!=id || characters.contents[row].checked==0
            if !state.retry {actions_interrupt(runtime,&state,playback,events,problems);state.plan=-1}
            continue
        }
        plan:=int(state.plan)
        if plan<0 || plan>=len(runtime.plans) || runtime.plans[plan].asset!=content.id {plan=-1;for value,j in runtime.plans {if value.asset==content.id {plan=j;break}}}
        if plan<0 || runtime.plans[plan].revision!=content.revision {
            copy,ok:=action_profile_clone(content.set.actions,allocator);if !ok {memory_problem(problems,state.entity,"its actions");state.retry=true;continue}
            if plan<0 {
                plan=len(runtime.plans);if append(&runtime.plans,Action_Plan{})!=1 {action_profile_free(&copy,allocator);memory_problem(problems,state.entity,"its actions");state.retry=true;continue}
            } else {
                for &previous in runtime.states {if int(previous.plan)==plan {actions_interrupt(runtime,&previous,playback,events,problems)}}
                action_profile_free(&runtime.plans[plan].profile)
            }
            runtime.plans[plan]=Action_Plan{asset=content.id,revision=content.revision,profile=copy}
            action_plan_bind(&runtime.plans[plan],content.set)
        }
        if state.plan!=i32(plan) {actions_interrupt(runtime,&state,playback,events,problems);state.plan=i32(plan)}
    }
    pending:=0
    for request in requests.plays.items {
        request:=request
        name:=base.text_get(request.action[:]);verb:="stop" if request.stop else "play"
        state:=action_state(runtime,request.entity)
        if state!=nil && state.retry {requests.plays.items[pending]=request;pending+=1;continue}
        row:=core.row_of(animations,request.entity)
        if row<0 || animation_character(app.assets,animations.table.values[row])=={} {
            core.report(problems,request.entity,"animation.action_owner","a %s of action '%s' was asked of this entity, and it has no Animation that plays a .character; set Animation.asset to one, or ask the entity that has it",verb,name)
            continue
        }
        if state==nil || state.seen!=runtime.frame || state.plan<0 || int(state.plan)>=len(runtime.plans) {
            core.report(problems,request.entity,"animation.action_unloaded","a %s of action '%s' was refused: the .character of this entity is not loaded; another problem of this entity says why",verb,name)
            continue
        }
        plan:=&runtime.plans[state.plan];profile:=plan.profile;index:=-1
        for value,i in profile.actions {if value.name==request.action {index=i;break}}
        if index<0 {
            core.report(problems,request.entity,"animation.action_missing","a %s of action '%s' was refused: the .character of this entity has no action with that name; name one of its actions (animation.inspect lists them), or add it with animation.action.set",verb,name)
            continue
        }
        section:=-1
        if request.section!=([64]u8{}) {
            for value,i in profile.sections {if int(value.action)==index && value.name==request.section {section=i;break}}
            if section<0 {
                core.report(problems,request.entity,"animation.action_section","a %s of action '%s' asks for section '%s', which it does not have; name one of its sections, or none",verb,name,base.text_get(request.section[:]))
                continue
            }
        }
        if !action_ask(runtime,state,index,section,request.stop,0,false,playback,events,problems) || !time.playing || !core.owned(remotes,request.entity) {continue}
        // What the end that decides the entity asks, the others play from the same tick.
        record,_:=core.get(played,request.entity)
        record.slots[plan.slots[index]]={action=base.name_hash(name),section=base.name_hash(base.text_get(request.section[:])) if section>=0 else 0,tick=time.tick,stop=request.stop}
        if at:=core.row_of(played,request.entity);at>=0 {core.edit_at(played,at)^=record} else {core.add(played,request.entity,record)}
    }
    // An entity another end decides plays what that end asked, as far into it as that end is.
    for &state in runtime.states {
        if !time.playing || state.seen!=runtime.frame || state.plan<0 || int(state.plan)>=len(runtime.plans) || core.owned(remotes,state.entity) {continue}
        record,found:=core.get(played,state.entity);if !found {continue}
        profile:=runtime.plans[state.plan].profile
        for started,slot in record.slots {
            if started.tick==state.heard[slot] {continue}
            state.heard[slot]=started.tick
            index,section:=-1,-1
            for &value,i in profile.actions {if base.name_hash(base.text_get(value.name[:]))==started.action {index=i;break}}
            for &value,i in profile.sections {if started.section!=0 && int(value.action)==index && base.name_hash(base.text_get(value.name[:]))==started.section {section=i;break}}
            if index<0 {continue}
            action_ask(runtime,&state,index,section,started.stop,f32(time.tick-started.tick)*time.dt if time.tick>started.tick else 0,true,playback,events,problems)
        }
    }
    kept:=0
    for &state,i in runtime.states {
        index:=core.entity_index(state.entity)
        if state.seen!=runtime.frame {actions_interrupt(runtime,&state,playback,events,problems);if index<len(runtime.rows) && runtime.rows[index]==i32(i+1) {runtime.rows[index]=0};continue}
        if kept!=i {runtime.states[kept]=state};runtime.rows[index]=i32(kept+1);kept+=1
    }
    base.truncate(&requests.plays.items,pending)
    base.truncate(&runtime.states,kept)
    return true
}

// What each layer of the stack of an entity asks for by itself in this tick, into state.asked: its
// clip or its space, at the weight its parameter gives it. The actions that play ask over it.
@(private)
stack_asks :: proc(runtime:^Action_Runtime,state:^Playing,animation:Animation,content:^host.Content_Animation) {
    plan:=action_plan(runtime,state.entity)
    count:=len(plan.profile.layers)+1 if plan!=nil && content!=nil else 0
    if count<int(state.stack) {for &layer in state.layers[count:state.stack] {layer={}}}
    if count==0 && state.stack==0 {return}
    state.stack=u8(count);state.asked={}
    // The root motion of a layer counts from where its clip is now.
    for &layer in state.layers[:state.stack] {layer.from,layer.carried=layer.fader.current.time,ROOT_DELTA_DEFAULT}
    if plan==nil || content==nil {return}
    for &layer,i in plan.profile.layers {
        ask:=plan.layers[i]
        if value,given:=stack_parameter(state,plan.layer_names[i]);given {ask.weight=mm.saturate(value)}
        source:=source_effective(layer.animation,plan.animation,animation.library)
        if ask.clip!=0 {ask.clip=source_clip_name(content.id,source,ask.clip)}
        if ask.reference_clip!=0 {ask.reference_clip=source_clip_name(content.id,source,ask.reference_clip)}
        state.asked[i+1]=ask
    }
}

// The time of its clip an action that names no section ends at: its exit marker, or the share
// of its clip its exit says.
@(private)
action_exit :: proc(content:^host.Content_Animation,handle:lib.Clip,definition:^Action_Definition,duration:f32) -> f32 {
    if definition.exit_marker[0]!=0 {
        name:=base.name_hash(base.text_get(definition.exit_marker[:]))
        for marker in lib.clip_markers(&content.lib,handle) {
            if int(marker.id)<len(content.markers) && content.markers[marker.id]==name && marker.time>0 {return min(marker.time,duration)}
        }
    }
    return duration*definition.exit
}

// Advances the actions of an entity and asks their slots for their clips. dt is the entity's own
// time; pace its seconds per second of the world, which a World action divides out.
actions_sample :: proc(runtime:^Action_Runtime,state:^Playing,animation:Animation,dt:f32,problems:^core.Problems,content:^host.Content_Animation,playback:^Playback,events:^Animation_Events,distance:^Animation_Distance_Request,pace:f32) {
    if !finite(dt) || dt<0 {return}
    active:=action_state(runtime,state.entity);if active==nil {return}
    planned:=active.plan>=0 && int(active.plan)<len(runtime.plans)
    profile:=runtime.plans[active.plan].profile if planned else {}
    if content==nil {actions_interrupt(runtime,active,playback,events,problems);return}
    for &slot,i in active.slots {
        if !slot.active {continue}
        if !planned && !slot.finishing {action_end(runtime,active,&slot,true,playback,events,problems)}
        layer:=&state.layers[i]
        // A finishing slot hands its layer back to what it plays by itself over the fade out of its
        // action, whatever its actions asset has become, and its root motion fades out with it.
        if slot.finishing {
            state.asked[i].fade=slot.fade_out
            if state.asked[i].clip==0 && state.asked[i].space==0 {state.asked[i].weight=0}
            continue
        }
        definition:=&profile.actions[slot.action]
        speed:=definition.speed
        if definition.clock==.World && finite(pace) && pace>0 {speed/=pace}
        slot.speed=speed
        cause:string
        slot.continuous=true
        source:=source_effective(definition.animation,runtime.plans[active.plan].animation,animation.library)
        // The layer keeps its branch, its mode and its reference; the action gives the clip.
        standing:=state.asked[i]
        asked:=standing
        asked.clip,asked.space,asked.weight,asked.speed,asked.fade,asked.loop,asked.sync=source_clip_name(content.id,source,base.name_hash(base.text_get(definition.clip[:]))),0,definition.weight,0,definition.fade_in,false,false
        handle:=lib.clip_find(&content.lib,asked.clip)
        duration:=lib.clip_duration(&content.lib,handle)
        // A play asked in this tick starts at the span of its section, and tells it started.
        entered:=slot.entering
        if entered {
            if start,_,spanned:=section_span(profile,content,handle,int(slot.section));spanned {slot.time=start}
            if slot.starting {action_emit(runtime,active,&slot,.Started,slot.time,playback,events,problems)}
            slot.entering=false
        }
        valid:=true
        if handle==0 {valid,cause=false,"its clip is not in the animation it plays"} else if asked.mode==.Additive && asked.reference_clip==0 && asked.reference>duration {valid,cause=false,"the reference of its layer is past the end of its clip"}
        if definition.root_motion!=.None && valid {
            // The stack has one root: an action moves the root bone of its base.
            root:=clip_root(content,handle)
            if !(root.translation || root.rotation) || root.bone=={} || bone_resolve(state,root.bone)<0 {valid,cause=false,"it has root motion and its clip has none, or its root bone is not in this rig"} else if (state.root.translation || state.root.rotation) && state.root.bone!=root.bone {valid,cause=false,"its root bone is not the one the base of the Animation moves"}
        }
        for &section,k in profile.sections {
            if section.action!=u16(slot.action) {continue}
            if _,end,ok:=section_span(profile,content,handle,k);!ok || end>duration {valid,cause=false,"its clip has no span for a section of it, or the span ends past the end of the clip"}
        }
        if !valid {
            core.report(problems,state.entity,"animation.action_clip","action '%s' stopped: %s; fix the action with animation.action.set",base.text_get(definition.name[:]),cause)
            action_end(runtime,active,&slot,true,playback,events,problems)
            state.asked[i].fade=definition.fade_out
            if standing.clip==0 && standing.space==0 {state.asked[i].weight=0}
            continue
        }
        layer.root_motion,layer.body,layer.body_vertical=definition.root_motion,definition.body_move,definition.body_vertical
        if slot.starting && slot.section<0 {
            // Where its clip starts, by the clip the base plays.
            switch definition.entry {
            case .Start:
            case .Keep_Time: slot.time=clamp(state.time,0,duration)
            case .Match_Phase: if phase,phased:=lib.sync_phase(&content.lib,state.fader.current);phased && state.clip>=0 {if time,ok:=lib.sync_time(&content.lib,handle,phase);ok {slot.time=clamp(time,0,duration)}}
            }
        }
        if entered {
            slot.time=min(slot.time+slot.late*speed,duration);slot.late=0
            if slot.section>=0 {action_emit(runtime,active,&slot,.Section,slot.time,playback,events,problems)}
            action_windows(runtime,active,&slot,content,handle,slot.time,slot.time,playback,events,problems,true)
        }
        if slot.starting || layer.clip!=asked.clip {
            lib.fader_play(&layer.fader,handle,speed,definition.fade_in if layer.clip!=0 && layer.space==0 else 0)
            layer.clip,layer.space,layer.leaf_count,layer.from=asked.clip,0,0,layer.fader.current.time;slot.starting=false
        }
        current:=&layer.fader.current
        if slot.seeking {current.time,layer.from=slot.time,slot.time;current.fresh=true;current.done=false;slot.seeking=false}
        current.speed=speed
        slot.player=current^;slot.from=slot.time
        controlled:=distance!=nil && distance.entity==state.entity && source_clip_name(content.id,distance.animation,distance.clip)==asked.clip
        seek:=controlled && distance.seek
        rejected:=false
        remaining:=dt if animation.playing else 0
        exit:=action_exit(content,handle,definition,duration)
        if controlled {
            target:=distance.time;valid:=finite(target) && target>=0 && target<=duration
            if slot.section>=0 {
                section:=int(slot.section)
                start,end,_:=section_span(profile,content,handle,section)
                if seek {valid &&=target>=start && target<=end} else {
                    for pass in 0..<ACTION_PASSES {
                        if target<end {break}
                        next:=int(profile.sections[section].next)
                        if next<0 {valid &&=target<=end;break}
                        next_start,next_end,_:=section_span(profile,content,handle,next)
                        if next_start!=end {valid=false;break}
                        end=next_end
                        section=next
                        if pass+1==ACTION_PASSES {valid=false}
                    }
                }
            }
            if !seek {valid &&=target>=slot.time}
            if !valid {
                core.report(problems,state.entity,"animation.action_distance","a distance-matched request for action '%s' was refused: its time %f is outside the clip or its section, or before the time the action is at without seek; ask for a time ahead within them",base.text_get(definition.name[:]),target)
                remaining=0;rejected=true
            } else if seek {
                slot.time=target;slot.from,slot.to=target,target;slot.continuous=false;slot.windows={}
                windows:for marker in lib.clip_markers(&content.lib,handle) {
                    if marker.duration<=0 || target<marker.time || target>=marker.time+marker.duration || int(marker.id)>=len(content.markers) {continue}
                    for &section in profile.sections {if int(section.action)==int(slot.action) && base.name_hash(base.text_get(section.name[:]))==content.markers[marker.id] {continue windows}}
                    for &open in slot.windows {if open==0 {open=content.markers[marker.id];break}}
                }
                current.time,current.fresh,current.done,layer.from=target,false,false,target;remaining=0
            } else {remaining=(target-slot.time)/speed}
        }
        target:=definition.weight
        step:=dt/definition.fade_in if definition.fade_in>0 else 1
        effective:=target if abs(target-layer.weight)<=step else layer.weight+(step if target>layer.weight else -step)
        incoming:=layer.fader;incoming.elapsed+=dt
        event_weight:=effective*animation.weight*lib.fader_current_weight(incoming)
        action_name:=base.name_hash(base.text_get(definition.name[:]))
        event_span,event_elapsed:=remaining,f32(0)
        for pass in 0..<ACTION_PASSES {
            if seek || rejected {break}
            end:=exit
            if slot.section>=0 {_,end,_=section_span(profile,content,handle,int(slot.section))}
            step:=min(remaining,max(end-slot.time,0)/speed)
            from:=slot.time;current.time=from;current.speed=speed;current.done=false
            batch:[EVENT_BATCH]lib.Event;written,dropped:=lib.player_advance(&content.lib,current,step,batch[:])
            for &event in batch[:written] {event.fraction=mm.saturate((event_elapsed+event.fraction*step)/event_span) if event_span>0 else 0}
            emit_events(playback,events,state.entity,content,batch[:written],dropped,problems,event_weight,u32(i+1),0,animation,action_name)
            slot.time=current.time;action_windows(runtime,active,&slot,content,handle,from,slot.time,playback,events,problems)
            remaining-=step
            event_elapsed+=step
            if slot.time<end || remaining<=0 && slot.time<end {break}
            next:=profile.sections[slot.section].next if slot.section>=0 else -1
            if slot.cancel_pending || next<0 {action_end(runtime,active,&slot,slot.cancel_pending,playback,events,problems);break}
            action_windows(runtime,active,&slot,nil,0,slot.time,slot.time,playback,events,problems,leave=true)
            next_start,_,_:=section_span(profile,content,handle,int(next))
            // The root motion before a jump is kept, and what follows counts from where it lands.
            if next_start!=slot.time {
                slot.continuous=false
                if root:=clip_root(content,handle);layer.root_motion!=.None && (root.translation || root.rotation) {
                    moved,turned:=lib.clip_root_motion(&content.lib,current.clip,bone_target(state,root.bone),layer.from,slot.time)
                    layer.carried.translation+=mm.quat_rotate(layer.carried.rotation,moved);layer.carried.rotation*=turned
                }
                layer.from=next_start
            }
            slot.section=next;slot.time=next_start;current.time=slot.time;current.fresh=true;current.done=false
            action_emit(runtime,active,&slot,.Section,slot.time,playback,events,problems);action_windows(runtime,active,&slot,content,handle,slot.time,slot.time,playback,events,problems,true)
            if remaining<=0 {break}
            if pass+1==ACTION_PASSES {
                core.report(problems,state.entity,"animation.action_sections","action '%s' crossed %d sections in one tick and was stopped: its sections loop without length between them; give them length",base.text_get(definition.name[:]),ACTION_PASSES)
                action_end(runtime,active,&slot,true,playback,events,problems)
            }
        }
        // One that ends in this tick plays its last part at its weight, and fades out from the next.
        current.speed=0
        slot.to=slot.time
        state.asked[i]=asked
    }
}
actions_layer_finish :: proc(runtime:^Action_Runtime,state:^Playing) {
    active:=action_state(runtime,state.entity);if active==nil {return}
    for slot,i in active.slots {if slot.active && state.layers[i].fader.current.clip==slot.player.clip {state.layers[i].fader.current.speed=slot.speed}}
}
action_player :: proc(runtime:^Action_Runtime,entity:core.Entity,clip:u64,content:^host.Content_Animation=nil,animation:base.Asset_Id={}) -> (player:lib.Player,ok:bool) {
    state:=action_state(runtime,entity);if state==nil || state.plan<0 || int(state.plan)>=len(runtime.plans) {return}
    profile:=runtime.plans[state.plan].profile
    for slot in state.slots {
        if !slot.active || slot.finishing || slot.player.clip==0 || int(slot.action)>=len(profile.actions) {continue}
        if content!=nil {if !lib.clip_valid(&content.lib,slot.player.clip) || lib.clip_data(&content.lib,slot.player.clip).name!=source_clip_name(content.id,animation,clip) {continue}} else if base.name_hash(base.text_get(profile.actions[slot.action].clip[:]))!=clip {continue}
        player=slot.player;player.time=slot.time
        return player,true
    }
    return
}

// The clock of the action that plays in the layer leading, which has share of the root of state;
// none for a layer without one.
action_clock :: proc(runtime:^Action_Runtime,state:^Playing,content:^host.Content_Animation,leading:int,share:f32) -> (clock:Motion_Clock) {
    active:=action_state(runtime,state.entity)
    if active==nil || leading<0 || leading>=STACK_SLOTS || !active.slots[leading].active {return}
    slot:=active.slots[leading]
    root:=clip_root(content,slot.player.clip);root.in_place=state.layers[leading].root_motion==.In_Place
    return {player=slot.player,from=slot.from,to=slot.to,root=root,weight=share,active=slot.continuous && !slot.finishing}
}
// Frees the slots whose action has faded out of its layer.
actions_finish :: proc(runtime:^Action_Runtime,playback:^Playback,dt:f32) {
    if !finite(dt) || dt<0 {return}
    for &active in runtime.states {
        state:=constraint_playing(playback,active.entity)
        if state==nil {continue}
        actions_layer_finish(runtime,state)
        for &slot,i in active.slots {
            if !slot.active || !slot.finishing {continue}
            layer:=state.layers[i]
            fading:=layer.weight>0 && layer.fader.current.clip==slot.player.clip
            for outgoing in layer.fader.outgoing[:layer.fader.outgoing_count] {fading ||= layer.weight>0 && outgoing.player.clip==slot.player.clip}
            if !fading {slot={}}
        }
    }
}
