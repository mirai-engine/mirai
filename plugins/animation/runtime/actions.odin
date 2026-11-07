package anim

import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"

ACTION_KIND :: asset.Fourcc(u32('A')|u32('C')<<8|u32('T')<<16|u32('N')<<24)
ACTION_VERSION :: 2
ACTION_OLDEST :: 1
ACTION_CAPACITY :: 64
ACTION_ROWS :: 256
ACTION_EVENT_CAPACITY :: 1024
ACTION_PASSES :: 128

Action_Cancel_Policy :: enum u8 {Allow,Finish_Section,Deny}
Action_Request_Kind :: enum u8 {Fire,Cancel,Section}
Action_Event_Kind :: enum u8 {Started,Completed,Interrupted,Section,Window_Begin,Window_End}
Action_Info :: struct {animation:base.Asset_Id}
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
Action_Definition :: struct {
    name,clip:[64]u8 `mirai:"text"`,
    layer:u8 `mirai:"optional,min=1,max=3"`,
    over:Bone_Ref `mirai:"optional"`,
    mode:Layer_Mode `mirai:"optional"`,
    curves:Curve_Blend `mirai:"optional"`,
    root_motion:Root_Motion_Policy `mirai:"optional"`,
    reference,fade_in,fade_out:f32 `mirai:"optional,min=0,unit=s"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    speed:f32 `mirai:"optional,min=0"`,
    priority:i16 `mirai:"optional"`,
    cancel:Action_Cancel_Policy `mirai:"optional"`,
    animation:base.Asset_Id `mirai:"optional"`, // of the clip; empty is the profile's
    mesh_space:bool `mirai:"optional"`,         // Override: the rotations of its branch blend in the space of the rig, as Animation_Layer.mesh_space
    clock:Action_Clock `mirai:"optional"`,
    body_move:Action_Body_Move `mirai:"optional"`, // with root_motion: its root motion moves the body of its entity
    body_vertical:bool `mirai:"optional"`,         // with body_move: along the up of the body too; otherwise only across it
}
ACTION_DEFINITION_DEFAULT :: Action_Definition{layer=1,weight=1,speed=1,fade_in=.1,fade_out=.1}
Action_Policy_Error :: enum u8 {None,UnsupportedPolicy,ReservedLayer}
action_channel_equal :: proc(a,b:Action_Definition) -> bool {return a.over==b.over && a.mode==b.mode && a.reference==b.reference && a.curves==b.curves && a.root_motion==b.root_motion && a.mesh_space==b.mesh_space && a.body_move==b.body_move && a.body_vertical==b.body_vertical}
action_policy_check :: proc(value:Action_Definition,description:Animation) -> Action_Policy_Error {
    if value.layer==0 || value.layer>ANIMATION_LAYERS {return .UnsupportedPolicy}
    if description.layers[value.layer-1].clip!=0 {return .ReservedLayer}
    if value.root_motion!=.None && description.source!=core.NONE {return .UnsupportedPolicy}
    return .None
}
Action_Section :: struct {action:u16,name:[64]u8 `mirai:"text"`,start,end:f32,next:i16}
Action_Window :: struct {action:u16,name:[64]u8 `mirai:"text"`,start,end:f32}
Action_Profile :: struct {info:Action_Info,actions:[]Action_Definition,sections:[]Action_Section,windows:[]Action_Window}

action_profile_check :: proc(profile:Action_Profile) -> bool {
    if profile.info.animation=={} || len(profile.actions)==0 || len(profile.actions)>ACTION_CAPACITY || len(profile.sections)>ACTION_ROWS || len(profile.windows)>ACTION_ROWS {return false}
    for &value,i in profile.actions {
        if !blend_text_valid(value.name[:],false) || !blend_text_valid(value.clip[:],false) || value.layer==0 || value.layer>ANIMATION_LAYERS || value.mode>max(Layer_Mode) || value.curves>max(Curve_Blend) || value.root_motion>max(Root_Motion_Policy) || value.cancel>max(Action_Cancel_Policy) || !profile_bone(value.over) || !profile_weight(value.weight) || !finite(value.speed) || value.speed<=0 || value.clock>max(Action_Clock) || value.body_move>max(Action_Body_Move) {return false}
        if value.root_motion!=.None && (value.over!={} || value.mode!=.Override) {return false}
        if value.body_move!=.None && value.root_motion==.None || value.body_vertical && value.body_move==.None {return false}
        for number in ([?]f32{value.reference,value.fade_in,value.fade_out}) {if !finite(number) || number<0 {return false}}
        for previous in profile.actions[:i] {if previous.name==value.name || previous.layer==value.layer && !action_channel_equal(previous,value) {return false}}
    }
    for &section,i in profile.sections {
        if int(section.action)>=len(profile.actions) || !blend_text_valid(section.name[:],false) || !finite(section.start) || !finite(section.end) || section.start<0 || section.end<=section.start || section.next< -1 || int(section.next)>=len(profile.sections) {return false}
        if section.next>=0 && profile.sections[section.next].action!=section.action {return false}
        for previous in profile.sections[:i] {if previous.action==section.action && previous.name==section.name {return false}}
    }
    for &window,i in profile.windows {
        if int(window.action)>=len(profile.actions) || !blend_text_valid(window.name[:],false) || !finite(window.start) || !finite(window.end) || window.start<0 || window.end<=window.start {return false}
        for previous in profile.windows[:i] {if previous.action==window.action && previous.name==window.name {return false}}
    }
    return true
}
action_profile_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,profile:Action_Profile,allocator:=context.allocator) -> asset.Error {
    if !action_profile_check(profile) {return .Invalid}
    asset.document_init(doc,ACTION_KIND,id,allocator);doc.kind_version=ACTION_VERSION
    info:=[1]Action_Info{profile.info}
    _,error:=asset.document_put(doc,types,"info",info[:])
    if error==.None {_,error=asset.document_put(doc,types,"actions",profile.actions)}
    if error==.None {_,error=asset.document_put(doc,types,"sections",profile.sections)}
    if error==.None {_,error=asset.document_put(doc,types,"windows",profile.windows)}
    if error!=.None {asset.document_destroy(doc)}
    return error
}
action_profile_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,profile:Action_Profile,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document;action_profile_document(&doc,types,id,profile,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}
action_profile_view :: proc(file:^asset.Asset,types:^asset.Types) -> (profile:Action_Profile,error:asset.Error) {
    asset.kind_check(file,ACTION_KIND,ACTION_OLDEST,ACTION_VERSION) or_return
    info:=asset.asset_rows(file,types,"info","",Action_Info) or_return
    if len(info)!=1 {return {},.Corrupt};profile.info=info[0]
    profile.actions=asset.asset_rows(file,types,"actions","",Action_Definition) or_return
    profile.sections=asset.asset_rows(file,types,"sections","",Action_Section) or_return
    profile.windows=asset.asset_rows(file,types,"windows","",Action_Window) or_return
    if !action_profile_check(profile) {return {},.Corrupt}
    return profile,.None
}
action_profile_free :: proc(profile:^Action_Profile,allocator:=context.allocator) {delete(profile.actions,allocator);delete(profile.sections,allocator);delete(profile.windows,allocator);profile^={}}
@(private)
action_profile_clone :: proc(source:Action_Profile,allocator:mem.Allocator) -> (profile:Action_Profile,ok:bool) {
    profile.info=source.info
    clone :: proc(source:[]$T,allocator:mem.Allocator) -> ([]T,bool) {out,error:=make([]T,len(source),allocator);if error!=nil {return nil,false};copy(out,source);return out,true}
    profile.actions,ok=clone(source.actions,allocator);if !ok {action_profile_free(&profile,allocator);return {},false}
    profile.sections,ok=clone(source.sections,allocator);if !ok {action_profile_free(&profile,allocator);return {},false}
    profile.windows,ok=clone(source.windows,allocator);if !ok {action_profile_free(&profile,allocator);return {},false}
    return profile,true
}
Action_Content :: struct {id:base.Asset_Id,checked,revision:u64,stamp:[2]i64,profile:Action_Profile,valid:bool,error:asset.Error}
@(storage,host,free="actions_assets_free")
Actions_Assets :: struct {allocator:mem.Allocator,contents:[dynamic]Action_Content}
actions_assets_free :: proc(cache:^Actions_Assets) {if cache.allocator.procedure!=nil {context.allocator=cache.allocator};for &content in cache.contents {action_profile_free(&content.profile)};delete(cache.contents);cache^={}}
action_content :: proc(cache:^Actions_Assets,app:^host.App,id:base.Asset_Id,hint:^i32=nil) -> ^Action_Content {
    if cache==nil || app==nil || app.assets==nil || id=={} {return nil}
    context.allocator=app.allocator;cache.allocator=app.allocator
    row:=int(hint^)-1 if hint!=nil else -1
    if row<0 || row>=len(cache.contents) || cache.contents[row].id!=id {row=-1;for content,i in cache.contents {if content.id==id {row=i;break}}}
    if row<0 {row=len(cache.contents);if !program_array_reserve(&cache.contents,row+1) {return nil};append(&cache.contents,Action_Content{id=id})}
    if hint!=nil {hint^=i32(row+1)}
    content:=&cache.contents[row]
    if content.checked==assets_stamp(app) {return content if content.valid else nil}
    record,found:=asset.registry_find(&app.assets.registry,id);stamp:=[2]i64{}
    if found {stamp={record.size,record.time}}
    if content.checked!=0 && stamp==content.stamp {content.checked=assets_stamp(app);return content if content.valid else nil}
    profile:Action_Profile;error:=asset.Error.Not_Found
    if found {
        file:asset.Asset
        if error=host.assets_file(app.assets,id,ACTION_KIND,&file);error==.None {
            view,read:=action_profile_view(&file,&app.assets.types);error=read
            if error==.None {if copied,ok:=action_profile_clone(view,app.allocator);ok {profile=copied} else {error=.Out_Of_Memory}}
            asset.asset_close(&file)
        }
    }
    content.error=error
    if error==.Out_Of_Memory {content.checked=0;return nil}
    action_profile_free(&content.profile);content.profile=profile;content.valid=error==.None
    content.stamp,content.checked=stamp,assets_stamp(app);content.revision+=1
    return content if content.valid else nil
}

Action_Request :: struct {entity:core.Entity,kind:Action_Request_Kind,action,section:[64]u8 `mirai:"text"`}
@(storage,queue)
Action_Requests :: struct {queue:core.Queue(Action_Request)}
action_request :: proc(requests:^Action_Requests,entity:core.Entity,kind:Action_Request_Kind,name:string,section:string="") -> bool {
    if requests==nil || entity==core.NONE || kind>max(Action_Request_Kind) || name=="" || len(name)>=64 || len(section)>=64 || kind==.Section && section=="" {return false}
    if !program_array_reserve(&requests.queue.items,REQUEST_CAPACITY) {return false}
    if len(requests.queue.items)>=REQUEST_CAPACITY {return false}
    value:=Action_Request{entity=entity,kind=kind};base.text_set(value.action[:],name);base.text_set(value.section[:],section);core.push(&requests.queue,value);return true
}
action_fire :: proc(requests:^Action_Requests,entity:core.Entity,name:string,section:string="") -> bool {return action_request(requests,entity,.Fire,name,section)}
action_cancel :: proc(requests:^Action_Requests,entity:core.Entity,name:string) -> bool {return action_request(requests,entity,.Cancel,name)}
action_section :: proc(requests:^Action_Requests,entity:core.Entity,name,section:string) -> bool {return action_request(requests,entity,.Section,name,section)}
Action_Event :: struct {entity:core.Entity,action,section,window:u64,kind:Action_Event_Kind,time,weight:f32,layer:u8}
Action_Plan :: struct {asset:base.Asset_Id,revision:u64,profile:Action_Profile}
Action_Playing :: struct {
    action,section:i16,
    time:f32,
    active,starting,seeking,finishing,cancel_pending:bool,
    window_mask:[4]u64,
    delta,outgoing_delta:Root_Delta,
    root:Root_Motion,
    player:lib.Player,
    from,to,root_weight:f32,
    has_root,continuous:bool,
    layer:Animation_Layer, // the one it asked for in its last tick: a slot that finishes fades it out
    speed,fade_out:f32,    // of its action, which a change of the actions asset does not take from a finishing slot
    body:Action_Body_Move, // of its action, as speed
    body_vertical:bool,
}
Action_State :: struct {entity:core.Entity,plan,content:i32,layers:[ANIMATION_LAYERS]Action_Playing,seen:u64,retry:bool}
@(storage,free="actions_runtime_free")
Action_Runtime :: struct {allocator:mem.Allocator,plans:[dynamic]Action_Plan,states:[dynamic]Action_State,rows:[dynamic]i32,events:core.Queue(Action_Event),frame,animation_version,animation_layout:u64,discovered:bool}
actions_runtime_free :: proc(runtime:^Action_Runtime) {allocator:=runtime.allocator if runtime.allocator.procedure!=nil else context.allocator;for &plan in runtime.plans {action_profile_free(&plan.profile,allocator)};delete(runtime.plans);delete(runtime.states);delete(runtime.rows);delete(runtime.events.items);runtime^={}}
@(private)
action_state :: proc(runtime:^Action_Runtime,entity:core.Entity) -> ^Action_State {
    if runtime==nil || entity==core.NONE {return nil}
    index:=core.entity_index(entity);if index>=len(runtime.rows) {return nil}
    row:=int(runtime.rows[index])-1
    if row<0 || row>=len(runtime.states) || runtime.states[row].entity!=entity {return nil}
    return &runtime.states[row]
}
// Whether the action named name plays on the entity, from the tick it is fired until it completes or is
// interrupted (not while it fades out): its time in its clip, in seconds, and the base.name_hash of its
// section (0 without sections), as Action_Event gives them.
action_playing :: proc(runtime:core.Ref(Action_Runtime),entity:core.Entity,name:string) -> (time:f32,section:u64,ok:bool) {
    state:=action_state(runtime.ptr,entity);if state==nil || state.plan<0 || int(state.plan)>=len(runtime.plans) {return}
    profile:=runtime.plans[state.plan].profile
    for slot in state.layers {
        if !slot.active || slot.finishing || slot.action<0 || int(slot.action)>=len(profile.actions) || base.text_get(profile.actions[slot.action].name[:])!=name {continue}
        if slot.section>=0 && int(slot.section)<len(profile.sections) {section=base.name_hash(base.text_get(profile.sections[slot.section].name[:]))}
        return slot.time,section,true
    }
    return
}
@(private)
action_emit :: proc(runtime:^Action_Runtime,state:^Action_State,slot:^Action_Playing,kind:Action_Event_Kind,time:f32,problems:^core.Problems,window:u64=0) {
    if runtime==nil || state==nil || slot==nil || state.plan<0 || int(state.plan)>=len(runtime.plans) {return}
    profile:=runtime.plans[state.plan].profile
    if slot.action<0 || int(slot.action)>=len(profile.actions) {return}
    value:=profile.actions[slot.action];section:u64
    if slot.section>=0 && int(slot.section)<len(profile.sections) {section=base.name_hash(base.text_get(profile.sections[slot.section].name[:]))}
    if len(runtime.events.items)>=cap(runtime.events.items) {
        core.report(problems,state.entity,"animation.action_events","a %v event of action '%s' was lost: the actions of the world gave %d events in this tick, as many as fit; fire fewer actions in one tick, or give them fewer windows and sections",kind,base.text_get(value.name[:]),cap(runtime.events.items))
        return
    }
    core.push(&runtime.events,Action_Event{entity=state.entity,action=base.name_hash(base.text_get(value.name[:])),section=section,window=window,kind=kind,time=time,weight=value.weight,layer=value.layer})
}
@(private)
action_windows :: proc(runtime:^Action_Runtime,state:^Action_State,slot:^Action_Playing,from,to:f32,problems:^core.Problems,enter:bool=false,leave:bool=false) {
    profile:=runtime.plans[state.plan].profile
    for &window,i in profile.windows {
        if int(window.action)!=int(slot.action) {continue}
        word,bit:=i/64,u64(1)<<u32(i%64);inside:=slot.window_mask[word]&bit!=0
        if !inside && (enter && from>=window.start && from<window.end || window.start>from && window.start<=to || enter && window.start==from) {
            slot.window_mask[word]|=bit;action_emit(runtime,state,slot,.Window_Begin,max(from,window.start),problems,base.name_hash(base.text_get(window.name[:])));inside=true
        }
        if inside && (leave || to>=window.end) {slot.window_mask[word]&=~bit;action_emit(runtime,state,slot,.Window_End,min(to,window.end),problems,base.name_hash(base.text_get(window.name[:])))}
    }
}
@(private)
action_end :: proc(runtime:^Action_Runtime,state:^Action_State,slot:^Action_Playing,interrupted:bool,problems:^core.Problems) {action_windows(runtime,state,slot,slot.time,slot.time,problems,false,true);action_emit(runtime,state,slot,.Interrupted if interrupted else .Completed,slot.time,problems);slot.finishing=true;slot.cancel_pending=false}

@(private)
actions_discover :: proc(runtime:^Action_Runtime,animations:core.Read(Animation),has_requests:bool,problems:^core.Problems) -> bool {
    changed:=!runtime.discovered || runtime.animation_layout!=core.layout(animations) || runtime.animation_version!=core.version(animations)
    layout:=!runtime.discovered || runtime.animation_layout!=core.layout(animations)
    added,rows:=0,len(runtime.rows)
    if changed {for i in 0..<core.count(animations) {
        if !layout && core.stamp(animations,i)<=runtime.animation_version || animations.table.values[i].actions=={} {continue}
        index:=core.entity_index(core.entity_at(animations,i));rows=max(rows,index+1)
        slot:=int(runtime.rows[index])-1 if index<len(runtime.rows) else -1
        if slot<0 || slot>=len(runtime.states) || core.entity_index(runtime.states[slot].entity)!=index {added+=1}
    }}
    if len(runtime.states)+added>0 || has_requests {
        if !program_array_reserve(&runtime.events.items,ACTION_EVENT_CAPACITY) {memory_problem(problems,core.NONE,"the events of the actions of the world, so no action plays");return false}
    }
    if !changed {return true}
    if !program_array_reserve(&runtime.states,len(runtime.states)+added) || !program_array_resize(&runtime.rows,rows) {memory_problem(problems,core.NONE,"the entities that play actions, so no action plays");return false}
    for i in 0..<core.count(animations) {
        if !layout && core.stamp(animations,i)<=runtime.animation_version || animations.table.values[i].actions=={} {continue}
        entity:=core.entity_at(animations,i);index:=core.entity_index(entity);slot:=int(runtime.rows[index])-1
        if slot>=0 && slot<len(runtime.states) && core.entity_index(runtime.states[slot].entity)==index {
            if runtime.states[slot].entity==entity {continue}
            state:=&runtime.states[slot];for &layer in state.layers {if layer.active && !layer.finishing {action_end(runtime,state,&layer,true,problems)}}
            state^=Action_State{entity=entity,plan=-1}
        } else {slot=len(runtime.states);append(&runtime.states,Action_State{entity=entity,plan=-1})}
        runtime.rows[index]=i32(slot+1)
    }
    runtime.animation_layout,runtime.animation_version=core.layout(animations),core.version(animations);runtime.discovered=true
    return true
}

actions_prepare :: proc(runtime:^Action_Runtime,requests:^Action_Requests,assets:^Actions_Assets,animations:core.Read(Animation),playback:^Playback,app:^host.App,problems:^core.Problems) -> bool {
    if runtime==nil || requests==nil || assets==nil || playback==nil || app==nil || animations.table==nil {return false}
    context.allocator=app.allocator;runtime.allocator=app.allocator;runtime.frame+=1;clear(&runtime.events.items)
    if !actions_discover(runtime,animations,len(requests.queue.items)>0,problems) {return false}
    for &state in runtime.states {
        state.retry=false
        row:=core.row_of(animations,state.entity);if row<0 {continue}
        id:=animations.table.values[row].actions
        if id=={} {for &slot in state.layers {if slot.active {state.seen=runtime.frame;if !slot.finishing {action_end(runtime,&state,&slot,true,problems)}}};continue}
        state.seen=runtime.frame
        content:=action_content(assets,app,id,&state.content)
        if content==nil {
            asset_problem(problems,state.entity,app,"animation.actions_asset","Animation.actions",id,content_error(assets.contents[:],id))
            row=int(state.content)-1
            state.retry=row<0 || row>=len(assets.contents) || assets.contents[row].id!=id || assets.contents[row].checked==0
            if !state.retry {for &slot in state.layers {if slot.active && !slot.finishing {action_end(runtime,&state,&slot,true,problems)}};state.plan=-1}
            continue
        }
        plan:=int(state.plan)
        if plan<0 || plan>=len(runtime.plans) || runtime.plans[plan].asset!=content.id {plan=-1;for value,j in runtime.plans {if value.asset==content.id {plan=j;break}}}
        if plan<0 {
            copy,ok:=action_profile_clone(content.profile,app.allocator);if !ok {memory_problem(problems,state.entity,"its actions");state.retry=true;continue}
            plan=len(runtime.plans);if append(&runtime.plans,Action_Plan{asset=content.id,revision=content.revision,profile=copy})!=1 {action_profile_free(&copy,app.allocator);memory_problem(problems,state.entity,"its actions");state.retry=true;continue}
        } else if runtime.plans[plan].revision!=content.revision {
            copy,ok:=action_profile_clone(content.profile,app.allocator);if !ok {memory_problem(problems,state.entity,"its actions");state.retry=true;continue}
            for &previous in runtime.states {if int(previous.plan)==plan {for &slot in previous.layers {if slot.active && !slot.finishing {action_end(runtime,&previous,&slot,true,problems)}}}}
            action_profile_free(&runtime.plans[plan].profile);runtime.plans[plan].profile=copy;runtime.plans[plan].revision=content.revision
        }
        if state.plan!=i32(plan) {for &slot in state.layers {if slot.active && !slot.finishing {action_end(runtime,&state,&slot,true,problems)}};state.plan=i32(plan)}
    }
    pending:=0
    for request in requests.queue.items {
        request:=request
        name:=base.text_get(request.action[:])
        if request.kind>max(Action_Request_Kind) || request.kind==.Section && request.section==([64]u8{}) {
            core.report(problems,request.entity,"animation.action_request","a request for action '%s' has no known kind, or asks for a section without naming one; make requests with action_fire, action_cancel or action_section",name)
            continue
        }
        state:=action_state(runtime,request.entity)
        if state!=nil && state.retry {requests.queue.items[pending]=request;pending+=1;continue}
        row:=core.row_of(animations,request.entity)
        if row<0 || animations.table.values[row].actions=={} {
            core.report(problems,request.entity,"animation.action_owner","a %v of action '%s' was asked for this entity, and it has no Animation with actions; set Animation.actions to an actions asset, or ask the entity that has it",request.kind,name)
            continue
        }
        if state==nil || state.seen!=runtime.frame || state.plan<0 || int(state.plan)>=len(runtime.plans) {
            core.report(problems,request.entity,"animation.action_unloaded","a %v of action '%s' was refused: the actions asset of this entity is not loaded; another problem of this entity says why",request.kind,name)
            continue
        }
        profile:=runtime.plans[state.plan].profile;index:=-1
        for value,i in profile.actions {if value.name==request.action {index=i;break}}
        if index<0 {
            core.report(problems,request.entity,"animation.action_missing","a %v of action '%s' was refused: the actions asset of this entity has no action with that name; name one of its actions (animation.inspect lists them)",request.kind,name)
            continue
        }
        definition:=profile.actions[index];slot:=&state.layers[definition.layer-1]
        section:=-1
        if request.section!=([64]u8{}) {
            for value,i in profile.sections {if int(value.action)==index && value.name==request.section {section=i;break}}
            if section<0 {
                core.report(problems,request.entity,"animation.action_section","a %v of action '%s' asks for section '%s', which it does not have; name one of its sections, or none",request.kind,name,base.text_get(request.section[:]))
                continue
            }
        }
        if request.kind==.Fire {
            description,present:=core.get(animations,request.entity)
            if !present {continue}
            switch action_policy_check(definition,description) {
            case .None:
            case .UnsupportedPolicy:
                core.report(problems,request.entity,"animation.action_policy","action '%s' cannot play here: its layer is %d (1 to %d) or it has root motion and the Animation of this entity follows a source; fix the action, or play it on an entity without Animation.source",name,definition.layer,ANIMATION_LAYERS)
                continue
            case .ReservedLayer:
                core.report(problems,request.entity,"animation.action_layer","action '%s' cannot play: its layer %d holds a clip of animation_play, which a weight of 0 keeps; free it with animation_stop, or give the action another layer",name,definition.layer)
                continue
            }
            if slot.active && !slot.finishing {
                current:=profile.actions[slot.action]
                if definition.priority<current.priority || current.cancel!=.Allow {
                    core.report(problems,request.entity,"animation.action_busy","action '%s' cannot interrupt '%s' on layer %d: its priority is lower or '%s' does not let itself be cancelled; raise its priority, or wait until the other ends",name,base.text_get(current.name[:]),definition.layer,base.text_get(current.name[:]))
                    continue
                }
                action_end(runtime,state,slot,true,problems)
            }
            if section<0 {for value,i in profile.sections {if int(value.action)==index {section=i;break}}}
            slot^=Action_Playing{active=true,starting=true,seeking=true,action=i16(index),section=i16(section),time=profile.sections[section].start if section>=0 else 0,speed=definition.speed,fade_out=definition.fade_out,body=definition.body_move,body_vertical=definition.body_vertical}
            action_emit(runtime,state,slot,.Started,slot.time,problems)
            if section>=0 {action_emit(runtime,state,slot,.Section,slot.time,problems)}
            action_windows(runtime,state,slot,slot.time,slot.time,problems,true)
        } else {
            if !slot.active || int(slot.action)!=index || slot.finishing {
                core.report(problems,request.entity,"animation.action_idle","a %v of action '%s' was refused: it is not playing; fire it first",request.kind,name)
                continue
            }
            if request.kind==.Cancel {
                switch definition.cancel {
                case .Allow:action_end(runtime,state,slot,true,problems)
                case .Finish_Section:slot.cancel_pending=true
                case .Deny:core.report(problems,request.entity,"animation.action_cancel","action '%s' cannot be cancelled: its cancel policy is Deny; let it end, or give it Allow or Finish_Section",name)
                }
            } else {
                action_windows(runtime,state,slot,slot.time,slot.time,problems,false,true);slot.section=i16(section);slot.time=profile.sections[section].start;slot.seeking=true;action_emit(runtime,state,slot,.Section,slot.time,problems);action_windows(runtime,state,slot,slot.time,slot.time,problems,true)
            }
        }
    }
    kept:=0
    for &state,i in runtime.states {
        index:=core.entity_index(state.entity)
        if state.seen!=runtime.frame {for &slot in state.layers {if slot.active && !slot.finishing {action_end(runtime,&state,&slot,true,problems)}};if index<len(runtime.rows) && runtime.rows[index]==i32(i+1) {runtime.rows[index]=0};continue}
        if kept!=i {runtime.states[kept]=state};runtime.rows[index]=i32(kept+1);kept+=1
    }
    resize(&requests.queue.items,pending)
    resize(&runtime.states,kept)
    return true
}

// dt is the entity's own time; pace its seconds per second of the world, which a World action divides out.
actions_sample :: proc(runtime:^Action_Runtime,state:^Playing,description:^Animation,dt:f32,problems:^core.Problems,content:^host.Content_Animation=nil,playback:^Playback=nil,events:^Animation_Events=nil,distance:^Animation_Distance_Request=nil,pace:f32=1) {
    if runtime==nil || state==nil || description==nil || !finite(dt) || dt<0 {return}
    state.action_root_mask=0
    active:=action_state(runtime,state.entity);if active==nil {return}
    planned:=active.plan>=0 && int(active.plan)<len(runtime.plans)
    profile:=runtime.plans[active.plan].profile if planned else {}
    if content==nil {for &slot in active.layers {if slot.active && !slot.finishing {action_end(runtime,active,&slot,true,problems)}};return}
    for &slot,i in active.layers {
        if !slot.active {continue}
        if !planned && !slot.finishing {action_end(runtime,active,&slot,true,problems)}
        layer:=&state.layers[i]
        // A finishing slot fades out what it last asked for, whatever its actions asset has become.
        if slot.finishing {
            asked:=slot.layer;asked.clip=0;asked.weight=0;asked.speed=slot.speed;asked.fade=slot.fade_out
            slot.delta,slot.outgoing_delta=ROOT_DELTA_DEFAULT,ROOT_DELTA_DEFAULT;slot.root_weight=0
            if slot.has_root {
                state.action_roots[i]=slot.root;state.action_root_mask|=u8(1)<<u8(i)
                if description.playing {
                    root_bone:=bone_target(state,slot.root.bone)
                    position,rotation:=lib.fader_root_motion(&content.lib,layer.fader,root_bone,dt)
                    position,rotation=root_motion_to_rig(state,root_bone,position,rotation)
                    slot.delta={position if slot.root.translation else mm.Vec3{},rotation if slot.root.rotation else mm.Quat(1)}
                }
            }
            description.layers[i]=asked;continue
        }
        definition:=profile.actions[slot.action]
        speed:=definition.speed
        if definition.clock==.World && finite(pace) && pace>0 {speed/=pace}
        slot.speed=speed
        cause:string
        slot.delta,slot.outgoing_delta=ROOT_DELTA_DEFAULT,ROOT_DELTA_DEFAULT;slot.has_root=false;slot.continuous=true;slot.root_weight=0
        over,_:=bone_ref_hash(definition.over)
        source:=source_effective(definition.animation,profile.info.animation,description.library)
        asked:=Animation_Layer{clip=source_clip_name(content.id,source,base.name_hash(base.text_get(definition.clip[:]))),over=over,weight=definition.weight,speed=0,fade=definition.fade_in,mode=definition.mode,reference=definition.reference,curves=definition.curves,mesh_space=definition.mesh_space}
        slot.layer=asked
        handle:=lib.clip_find(&content.lib,asked.clip)
        duration:=lib.clip_duration(&content.lib,handle)
        valid:=true
        if handle==0 {valid,cause=false,"its clip is not in the animation it plays"} else if definition.reference>duration {valid,cause=false,"its reference is past the end of its clip"}
        if definition.root_motion!=.None {
            if description.source!=core.NONE {valid,cause=false,"it has root motion and the Animation follows a source"}
            if handle==0 || int(handle)>len(content.roots) {valid=false} else {
                metadata:=content.roots[handle-1]
                slot.root={bone={metadata.bone},translation=metadata.translation,rotation=metadata.rotation,in_place=definition.root_motion==.In_Place}
                slot.has_root=(metadata.translation || metadata.rotation) && metadata.bone!={}
                if !slot.has_root || bone_resolve(state,slot.root.bone)<0 {valid,cause=false,"it has root motion and its clip has none, or its root bone is not in this rig"}
                if state.program.ready && state.program.has_root && (state.program.root.bone!=slot.root.bone || state.program.root.translation!=slot.root.translation || state.program.root.rotation!=slot.root.rotation) {valid,cause=false,"its root motion differs from the one the program of the Animation plays"}
                if !state.program.ready && description.root_motion!=.None && state.clip>=0 && state.clip<len(content.roots) {
                    base:=content.roots[state.clip]
                    if (base.translation || base.rotation) && (base.bone!=metadata.bone || base.translation!=metadata.translation || base.rotation!=metadata.rotation) {valid,cause=false,"its root motion differs from the one of the clip of the Animation"}
                }
                for root,j in state.action_roots {if state.action_root_mask&(u8(1)<<u8(j))!=0 && (root.bone!=slot.root.bone || root.translation!=slot.root.translation || root.rotation!=slot.root.rotation) {valid,cause=false,"its root motion differs from the one of another action playing"}}
                for outgoing in layer.fader.outgoing[:layer.fader.outgoing_count] {
                    index:=int(outgoing.player.clip)-1
                    if index<0 || index>=len(content.roots) {valid,cause=false,"the clip it fades from has no root motion";break}
                    previous:=content.roots[index]
                    if previous.bone!=metadata.bone || previous.translation!=metadata.translation || previous.rotation!=metadata.rotation {valid,cause=false,"its root motion differs from the one of the clip it fades from";break}
                }
            }
        }
        for section in profile.sections {if section.action==u16(slot.action) && section.end>duration {valid,cause=false,"a section of it ends past the end of its clip"}}
        for window in profile.windows {if window.action==u16(slot.action) && window.end>duration {valid,cause=false,"a window of it ends past the end of its clip"}}
        if !valid {
            core.report(problems,state.entity,"animation.action_clip","action '%s' stopped: %s; fix the action with animation.action.set",base.text_get(definition.name[:]),cause)
            slot.has_root=false;action_end(runtime,active,&slot,true,problems);asked.clip=0;asked.weight=0;asked.fade=definition.fade_out;description.layers[i]=asked;continue
        }
        if slot.has_root {state.action_roots[i]=slot.root;state.action_root_mask|=u8(1)<<u8(i)}
        if slot.starting || layer.clip!=asked.clip {lib.fader_play(&layer.fader,handle,speed,definition.fade_in if layer.clip!=0 else 0);layer.clip=asked.clip;slot.starting=false}
        current:=&layer.fader.current
        if slot.seeking {current.time=slot.time;current.fresh=true;current.done=false;slot.seeking=false}
        current.speed=speed
        slot.player=current^;slot.from=slot.time
        controlled:=distance!=nil && distance.entity==state.entity && source_clip_name(content.id,distance.animation,distance.clip)==asked.clip
        seek:=controlled && distance.seek
        rejected:=false
        remaining:=dt if description.playing else 0
        if controlled {
            target:=distance.time;valid:=finite(target) && target>=0 && target<=duration
            if slot.section>=0 {
                section:=int(slot.section)
                if seek {valid &&=target>=profile.sections[section].start && target<=profile.sections[section].end} else {
                    for pass in 0..<ACTION_PASSES {
                        end:=profile.sections[section].end
                        if target<end {break}
                        next:=int(profile.sections[section].next)
                        if next<0 {valid &&=target<=end;break}
                        if profile.sections[next].start!=end {valid=false;break}
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
                slot.time=target;slot.from,slot.to=target,target;slot.continuous=false;slot.window_mask={}
                for window,w in profile.windows {if int(window.action)==int(slot.action) && target>=window.start && target<window.end {slot.window_mask[w/64]|=u64(1)<<u32(w%64)}}
                current.time,current.fresh,current.done=target,false,false;remaining=0
            } else {remaining=(target-slot.time)/speed}
        }
        target:=definition.weight
        step:=dt/definition.fade_in if definition.fade_in>0 else 1
        effective:=target if abs(target-layer.weight)<=step else layer.weight+(step if target>layer.weight else -step)
        incoming:=layer.fader;incoming.elapsed+=dt
        event_weight:=effective*description.weight*lib.fader_current_weight(incoming)
        if slot.has_root {
            for outgoing in layer.fader.outgoing[:layer.fader.outgoing_count] {
                root_bone:=bone_target(state,slot.root.bone)
                moving,turning:=lib.player_root_motion(&content.lib,outgoing.player,root_bone,dt)
                moving,turning=root_motion_to_rig(state,root_bone,moving,turning)
                outgoing:=outgoing;outgoing.elapsed+=dt
                weight:=lib.fade_out_weight(outgoing)
                if slot.root.translation {slot.outgoing_delta.translation+=moving*weight}
                if slot.root.rotation {slot.outgoing_delta.rotation*=mm.quat_slerp(1,turning,weight)}
            }
        }
        event_span,event_elapsed:=remaining,f32(0)
        for pass in 0..<ACTION_PASSES {
            if seek || rejected {break}
            end:=profile.sections[slot.section].end if slot.section>=0 else duration
            step:=min(remaining,max(end-slot.time,0)/speed)
            from:=slot.time;current.time=from;current.speed=speed;current.done=false
            batch:[EVENT_BATCH]lib.Event;written,dropped:=lib.player_advance(&content.lib,current,step,batch[:])
            for &event in batch[:written] {event.fraction=mm.saturate((event_elapsed+event.fraction*step)/event_span) if event_span>0 else 0}
            if playback!=nil && events!=nil {emit_events(playback,events,state.entity,content,batch[:written],dropped,problems,event_weight,u32(i+1),0,description^)}
            slot.time=current.time;action_windows(runtime,active,&slot,from,slot.time,problems)
            if slot.has_root {
                root_bone:=bone_target(state,slot.root.bone)
                moved,turned:=lib.clip_root_motion(&content.lib,current.clip,root_bone,from,slot.time)
                moved,turned=root_motion_to_rig(state,root_bone,moved,turned)
                if slot.root.translation {slot.delta.translation+=mm.quat_rotate(slot.delta.rotation,moved)}
                if slot.root.rotation {slot.delta.rotation*=turned}
            }
            remaining-=step
            event_elapsed+=step
            if slot.time<end || remaining<=0 && slot.time<end {break}
            next:=profile.sections[slot.section].next if slot.section>=0 else -1
            if slot.cancel_pending || next<0 {action_end(runtime,active,&slot,slot.cancel_pending,problems);break}
            action_windows(runtime,active,&slot,slot.time,slot.time,problems,false,true)
            if profile.sections[next].start!=slot.time {slot.continuous=false}
            slot.section=next;slot.time=profile.sections[next].start;current.time=slot.time;current.fresh=true;current.done=false
            action_emit(runtime,active,&slot,.Section,slot.time,problems);action_windows(runtime,active,&slot,slot.time,slot.time,problems,true)
            if remaining<=0 {break}
            if pass+1==ACTION_PASSES {
                core.report(problems,state.entity,"animation.action_sections","action '%s' crossed %d sections in one tick and was stopped: its sections loop without length between them; give them length",base.text_get(definition.name[:]),ACTION_PASSES)
                action_end(runtime,active,&slot,true,problems)
            }
        }
        current.speed=0
        slot.to=slot.time
        if slot.finishing {asked.weight=0;asked.fade=definition.fade_out}
        description.layers[i]=asked
    }
}
actions_layer_finish :: proc(runtime:^Action_Runtime,state:^Playing) {
    if runtime==nil || state==nil {return}
    active:=action_state(runtime,state.entity);if active==nil {return}
    for slot,i in active.layers {if slot.active {state.layers[i].fader.current.speed=slot.speed}}
}
actions_apply_root :: proc(runtime:^Action_Runtime,state:^Playing,description:Animation,content:^host.Content_Animation=nil) {
    if state==nil {return};state.has_action_root=false;state.body_motion={}
    active:=action_state(runtime,state.entity);if active==nil {return}
    moving,strongest:f32
    defer if !(moving>0) {state.body_motion={}}
    for &slot,i in active.layers {
        if !slot.active || !slot.has_root {continue}
        share:=state.layers[i].weight*mm.saturate(description.weight)
        slot.root_weight=share
        if share<=0 {continue}
        current:=lib.fader_current_weight(state.layers[i].fader)
        translation:=slot.delta.translation*current+slot.outgoing_delta.translation
        rotation:=mm.quat_slerp(1,slot.delta.rotation,current)*slot.outgoing_delta.rotation
        state.motion.translation=mm.lerp(state.motion.translation,translation,share)
        state.motion.rotation=mm.quat_slerp(state.motion.rotation,rotation,share)
        // The body takes the part of that blend the actions that move it give.
        state.body_motion.translation*=1-share;moving*=1-share
        if slot.body!=.None {
            state.body_motion.translation+=translation*share;moving+=share
            if share>=strongest {state.body_motion.move,state.body_motion.vertical,strongest=slot.body,slot.body_vertical,share}
        }
        state.root_enabled=true;state.action_root=slot.root;state.has_action_root=true
    }
}
action_player :: proc(runtime:^Action_Runtime,entity:core.Entity,clip:u64,content:^host.Content_Animation=nil,animation:base.Asset_Id={}) -> (player:lib.Player,ok:bool) {
    state:=action_state(runtime,entity);if state==nil || state.plan<0 || int(state.plan)>=len(runtime.plans) {return}
    profile:=runtime.plans[state.plan].profile
    for slot in state.layers {
        if !slot.active || slot.finishing || slot.player.clip==0 || int(slot.action)>=len(profile.actions) {continue}
        if content!=nil {if !lib.clip_valid(&content.lib,slot.player.clip) || lib.clip_data(&content.lib,slot.player.clip).name!=source_clip_name(content.id,animation,clip) {continue}} else if base.name_hash(base.text_get(profile.actions[slot.action].clip[:]))!=clip {continue}
        player=slot.player;player.time=slot.time
        return player,true
    }
    return
}

// The action that leads the root of its entity: the one with the most of it, at least half.
@(private)
action_root_slot :: proc(runtime:^Action_Runtime,entity:core.Entity) -> (leading:^Action_Playing) {
    state:=action_state(runtime,entity);if state==nil {return}
    for &slot in state.layers {
        if !slot.active || !slot.has_root || slot.root_weight<.5 || leading!=nil && slot.root_weight<leading.root_weight {continue}
        leading=&slot
    }
    return
}
action_clock :: proc(runtime:^Action_Runtime,entity:core.Entity) -> (clock:Motion_Clock) {
    slot:=action_root_slot(runtime,entity);if slot==nil {return}
    return {player=slot.player,from=slot.from,to=slot.to,root=slot.root,weight=slot.root_weight,active=slot.continuous && !slot.finishing}
}
actions_finish :: proc(runtime:^Action_Runtime,playback:^Playback,dt:f32) {
    if runtime==nil || playback==nil || !finite(dt) || dt<0 {return}
    for &active in runtime.states {
        state:=constraint_playing(playback,active.entity)
        if state==nil {continue}
        actions_layer_finish(runtime,state)
        for &slot,i in active.layers {if slot.active && slot.finishing && state.layers[i].weight<=0 {slot={}}}
    }
}
