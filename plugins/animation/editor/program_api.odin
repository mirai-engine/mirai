package animation_editor

import "mirai:asset"
import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Program_Blend_Sample :: struct {position:mm.Vec2 `mirai:"label=In the units of the axes"`,clip:[64]u8 `mirai:"text,label=A clip of its animation"`,speed:f32 `mirai:"optional"`,animation:base.Asset_Id `mirai:"optional,label=Empty is that of the .character"`}
Program_Blend_Info :: struct {name:[32]u8 `mirai:"text,label=Of the space, which a layer names"`,dimension:lib.Blend_Dimension,x:anim.Blend_Axis,y:anim.Blend_Axis `mirai:"optional"`}
Blend_Write_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .character: the space of that name is replaced or added, its other parts kept"`,
    animation:base.Asset_Id `mirai:"optional,label=The .anim of the clips of a new .character"`,
    info:Program_Blend_Info,
    samples:[lib.BLEND_MAX_SAMPLES]Program_Blend_Sample `mirai:"optional,label=1 to 256"`,
    remove:bool `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Blend_Sample_Params :: struct {asset:base.Asset_Id `mirai:"label=The .character"`,space:[32]u8 `mirai:"text"`,position:mm.Vec2 `mirai:"label=Outside the hull it projects to the nearest edge"`}
Blend_Contribution :: struct {index:u32 `mirai:"label=The sample"`,clip:[64]u8 `mirai:"text"`,animation:base.Asset_Id,weight:f32}
Blend_Sample_Result :: struct {samples:[3]Blend_Contribution}
Modifier_Inspect_Params :: struct {entity:editor.Api_Entity_Text `mirai:"text,entity"`,handle:core.Entity `mirai:"transient"`,offset:u32 `mirai:"optional"`,limit:u32 `mirai:"optional,min=1,max=256,clamp"`,diagnostics:bool `mirai:"optional"`}
Modifier_Goal_Kind :: enum u8 {IK,Look,Grounding,Chain_IK,Spring,Multi_IK,Spline_IK,Follow}
MODIFIER_GOAL_KINDS :: [Modifier_Goal_Kind]anim.Modifier_Kind{.IK=.IK,.Look=.Look,.Grounding=.Grounding,.Chain_IK=.Chain_IK,.Spring=.Spring,.Multi_IK=.Multi_IK,.Spline_IK=.Spline_IK,.Follow=.Follow}
@(private)
program_modifier_goal_kind :: proc(kind:Modifier_Goal_Kind) -> anim.Modifier_Kind {kinds:=MODIFIER_GOAL_KINDS;return kinds[kind]}
Modifier_Diagnostic_Result :: struct {valid,reached:bool,residual,angular_error:f32,iterations:int,blocked_legs:u16 `mirai:"optional"`}
Modifier_Effector_Result :: struct {name:[64]u8 `mirai:"text"`}

@(private)
program_blend_defaults :: proc() -> ^Blend_Write_Params {
    blend:=new(Blend_Write_Params,context.temp_allocator);if blend==nil {return nil}
    for &sample in blend.samples {sample.speed=1}
    return blend
}
@(private)
program_register :: proc(s:^editor.Session) {
    inspect:=Authoring_Inspect_Params{limit=128}
    blend:=program_blend_defaults()
    if blend==nil {return}
    modifiers:=Modifier_Inspect_Params{limit=128}
    editor.api_method_register(s,Blend_Write_Params,Authoring_Write_Result,{name="animation.space.set",summary="Replaces, adds or removes a space of a .character by its name: clips placed on one or two axes. A layer of the set that names it (animation.action.set) samples it: aim offsets or additive poses its axes sample, set by name. An invalid one changes nothing. In Edit.",defaults=blend,run=program_blend_set,writes_result=true})
    editor.api_method_register(s,Blend_Sample_Params,Blend_Sample_Result,{name="animation.space.sample",summary="The samples of a space of a .character that contribute at a position and their weights, without advancing the world.",flags={.Read_Only},run=program_blend_sample,writes_result=true})
}

@(private)
program_animation_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^Authoring_File) -> (asset.Animation_View,bool) {
    if !authoring_open(s,call,id,asset.KIND_ANIMATION,file) {return {},false}
    view,error:=asset.animation_view(&file.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"animation","Invalid_Asset","a valid source .anim asset",fmt.tprintf("%v",error),"The source animation is invalid");return {},false}
    return view,true
}

@(private)
program_clip_exists :: proc(view:asset.Animation_View,name:[]u8) -> bool {
    for &clip in view.clips {if base.text_get(clip.name[:])==base.text_get(name) {return true}}
    return false
}

@(private)
program_clip_reference :: proc(s:^editor.Session,call:^api.Call,default:asset.Animation_View,source:base.Asset_Id,name:[]u8,path:string) -> bool {
    view:=default
    file:Authoring_File;defer asset.asset_close(&file.file)
    if source!={} {loaded:bool;view,loaded=program_animation_open(s,call,source,&file);if !loaded {return false}}
    if !program_clip_exists(view,name) {authoring_failure(call,path,"Missing_Clip","a clip in its selected animation",base.text_get(name),"The source animation has no clip with this name");return false}
    return true
}

@(private)
program_rows :: proc(call:^api.Call,name:string,rows:[]$T,offset,limit:u32) {
    api.write_key(call.out,name);serial.text_write_raw(call.out,"[")
    start:=min(int(offset),len(rows));end:=min(start+int(limit),len(rows))
    for &row,i in rows[start:end] {
        if i>0 {serial.text_write_raw(call.out,",")}
        serial.text_write_raw(call.out,"{");api.write_uint(call.out,"index",u64(start+i),true);api.write_key(call.out,"value");authoring_write_value(call,&row,type_info_of(T));serial.text_write_raw(call.out,"}")
    }
    serial.text_write_raw(call.out,"]")
}

@(private)
program_blend_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Blend_Write_Params)
    if !authoring_editable(s,call) {return}
    target:Authoring_File;defer asset.asset_close(&target.file)
    set,id,ok:=character_target(s,call,base.text_get(p.path[:]),p.animation,&target);if !ok {return}
    at:=anim.character_space(set,p.info.name)
    if p.remove && at<0 {authoring_failure(call,"info.name","Missing_Reference","a space of the .character",base.text_get(p.info.name[:]),"The set has no space of that name");return}
    for layer in set.actions.layers {if p.remove && layer.space==p.info.name {authoring_failure(call,"info.name","In_Use","a space no layer samples",base.text_get(p.info.name[:]),"A layer of the set samples this space",fix="Give the layer another space or a clip with animation.action.set first");return}}
    sample_count,_:=api.params_array_count(call,"samples")
    if !p.remove && (sample_count==0 || sample_count>lib.BLEND_MAX_SAMPLES) {authoring_failure(call,"samples","Capacity","1 to 256 samples",fmt.tprintf("%d",sample_count),"A space needs samples");return}
    source:Authoring_File;defer asset.asset_close(&source.file)
    animation,loaded:=program_animation_open(s,call,set.info.animation,&source);if !loaded {return}
    if p.info.dimension==.Two && p.info.x.name==p.info.y.name {authoring_failure(call,"info.y.name","Duplicate_Name","an axis name distinct from x",base.text_get(p.info.y.name[:]),"The axes of a space need distinct names");return}
    // The spaces of the set in their order, this one in its place or last, each with its samples.
    spaces:=make([dynamic]anim.Blend_Info,0,len(set.spaces)+1,call.allocator)
    samples:=make([dynamic]anim.Blend_Sample,0,len(set.space_samples)+sample_count,call.allocator)
    added:=false
    put :: proc(spaces:^[dynamic]anim.Blend_Info,samples:^[dynamic]anim.Blend_Sample,info:anim.Blend_Info,rows:[]anim.Blend_Sample) {
        for row in rows {row:=row;row.space=u16(len(spaces));append(samples,row)}
        append(spaces,info)
    }
    own:=make([]anim.Blend_Sample,sample_count,call.allocator)
    for &value,i in p.samples[:sample_count] {
        if !program_clip_reference(s,call,animation,value.animation,value.clip[:],fmt.tprintf("samples[%d].clip",i)) {return}
        own[i]={position=value.position,clip=value.clip,speed=value.speed,animation=value.animation}
    }
    info:=anim.Blend_Info{name=p.info.name,dimension=p.info.dimension,x=p.info.x,y=p.info.y}
    for &space,i in set.spaces {
        if i==at {if !p.remove {put(&spaces,&samples,info,own)};added=true;continue}
        first,count:=anim.character_space_samples(set,i)
        put(&spaces,&samples,space,set.space_samples[first:][:count])
    }
    if !added {put(&spaces,&samples,info,own)}
    set.spaces,set.space_samples=spaces[:],samples[:]
    if !p.remove {
        points:[lib.BLEND_MAX_SAMPLES]mm.Vec2
        for row,i in own {points[i]=anim.blend_position(info,row.position)}
        failure:lib.Blend_Error
        if prepared,valid:=lib.blend_space_prepare(points[:sample_count],info.dimension,call.allocator,&failure);valid {lib.blend_space_destroy(&prepared)} else {
            authoring_failure(call,"samples","Out_Of_Memory" if failure==.Out_Of_Memory else "Invalid_Definition","valid axes, positions and distinct noncollinear samples",fmt.tprintf("%v",failure),"The space cannot be prepared",api.SERVER_ERROR if failure==.Out_Of_Memory else api.INVALID_PARAMS)
            return
        }
    }
    _=character_publish(s,call,target,id,set)
}

@(private)
program_blend_sample :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Blend_Sample_Params)
    file:Authoring_File;defer asset.asset_close(&file.file)
    set,ok:=character_open(s,call,p.asset,&file);if !ok {return}
    at:=anim.character_space(set,p.space)
    if at<0 {authoring_failure(call,"space","Missing_Reference","a space of the .character",base.text_get(p.space[:]),"The set has no space of that name");return}
    info:=set.spaces[at];first,count:=anim.character_space_samples(set,at)
    points:[lib.BLEND_MAX_SAMPLES]mm.Vec2
    for row,i in set.space_samples[first:][:count] {points[i]=anim.blend_position(info,row.position)}
    space,prepared:=lib.blend_space_prepare(points[:count],info.dimension,call.allocator);defer lib.blend_space_destroy(&space)
    weights,sampled:=lib.blend_space_sample(space,anim.blend_position(info,p.position))
    if !prepared || !sampled {authoring_failure(call,"position","Invalid_Value","a finite position",fmt.tprintf("%v",p.position),"The position in the space must be finite");return}
    serial.text_write_raw(call.out,`{"samples":[`)
    for weight,i in weights.weights[:weights.count] {
        if i>0 {serial.text_write_raw(call.out,",")}
        sample:=set.space_samples[first+int(weights.samples[i])]
        serial.text_write_raw(call.out,"{");api.write_uint(call.out,"index",u64(weights.samples[i]),true);api.write_text(call.out,"clip",base.text_get(sample.clip[:]));api.write_key(call.out,"animation");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,sample.animation if sample.animation!={} else set.info.animation);serial.write_u8(call.out,'"');api.write_key(call.out,"weight");api.write_number(call.out,weight);serial.text_write_raw(call.out,"}")
    }
    serial.text_write_raw(call.out,"]}")
}

// Checks that the .character of the Animation declares a parameter with this name: a layer, whose
// weight it is, or an axis of the space of one, within its range.
@(private)
program_parameter_check :: proc(s:^editor.Session,call:^api.Call,animation:anim.Animation,name:string,value:f32) -> bool {
    if name=="" {authoring_failure(call,"name","Required","a layer or an axis of the .character","empty","The parameter name is required");return false}
    if !finite(value) {authoring_failure(call,"value","Invalid_Value","a finite parameter value",fmt.tprintf("%v",value),"The parameter value must be finite");return false}
    character:=anim.animation_character(s.app.assets,animation)
    if character=={} {authoring_failure(call,"name","Missing_Character","Animation.asset a .character","none","The entity plays no .character, so it has no parameters",fix="Make one with animation.character.setup or animation.action.set and set Animation.asset to it");return false}
    file:Authoring_File;defer asset.asset_close(&file.file)
    set,loaded:=character_open(s,call,character,&file);if !loaded {return false}
    names:=make([dynamic]string,context.temp_allocator)
    for &layer in set.actions.layers {
        append(&names,base.text_get(layer.name[:]))
        if base.text_get(layer.name[:])==name {
            if value<0 || value>1 {authoring_failure(call,"value","Out_Of_Range","0 to 1",fmt.tprintf("%v",value),"The weight of a layer is a share");return false}
            return true
        }
    }
    for &layer in set.actions.layers {
        at:=anim.character_space(set,layer.space) if layer.space[0]!=0 else -1
        if at<0 {continue}
        space:=set.spaces[at]
        axes:=[2]anim.Blend_Axis{space.x,space.y}
        for &axis in axes[:2 if space.dimension==.Two else 1] {
            append(&names,base.text_get(axis.name[:]))
            if base.text_get(axis.name[:])!=name {continue}
            if value<axis.min || value>axis.max {authoring_failure(call,"value","Out_Of_Range",fmt.tprintf("%v to %v",axis.min,axis.max),fmt.tprintf("%v",value),"The parameter is outside the range of its axis");return false}
            return true
        }
    }
    authoring_failure(call,"name","Unknown_Reference","a layer of the .character or an axis of the space of one",name,"The .character declares no such parameter",fix=fmt.tprintf("Parameters: %s",strings.join(names[:],", ",context.temp_allocator)))
    return false
}

@(private)
program_modifier_count :: proc(profile:anim.Pose_Profile,kind:anim.Modifier_Kind) -> int {
    switch kind {
    case .IK: return len(profile.ik)
    case .Look: return len(profile.look)
    case .Grounding: return 1 if profile.grounding.count>0 else 0
    case .Limit: return len(profile.limits)
    case .Chain_IK: return len(profile.chain_ik)
    case .Twist: return len(profile.twist)
    case .Spring: return len(profile.springs)
    case .Multi_IK: return len(profile.multi_ik)
    case .Chain_Retarget: return len(profile.retarget_chains)
    case .Spline_IK: return len(profile.spline_ik)
    case .Corrective: return len(profile.correctives)
    case .Follow: return len(profile.follow)
    }
    return 0
}

@(private) Program_Modifier_Definition :: struct {name:[256]u8,weight:f32,enabled:bool}
@(private)
program_modifier_definition :: proc(profile:anim.Pose_Profile,kind:anim.Modifier_Kind,slot:u16) -> (result:Program_Modifier_Definition,ok:bool) {
    if int(slot)>=program_modifier_count(profile,kind) {return}
    name:string
    switch kind {
    case .IK:name=anim.modifier_operation_name(&profile.ik[slot]);result.weight,result.enabled=profile.ik[slot].weight,profile.ik[slot].enabled
    case .Look:name=anim.modifier_operation_name(&profile.look[slot]);result.weight,result.enabled=profile.look[slot].weight,profile.look[slot].enabled
    case .Grounding:grounding:=profile.grounding;name=anim.modifier_operation_name(&grounding);result.weight,result.enabled=grounding.weight,grounding.enabled
    case .Limit:name=anim.modifier_operation_name(&profile.limits[slot]);result.weight,result.enabled=profile.limits[slot].weight,profile.limits[slot].enabled
    case .Chain_IK:name=anim.modifier_operation_name(&profile.chain_ik[slot]);result.weight,result.enabled=profile.chain_ik[slot].weight,profile.chain_ik[slot].enabled
    case .Twist:name=anim.modifier_operation_name(&profile.twist[slot]);result.weight,result.enabled=profile.twist[slot].weight,profile.twist[slot].enabled
    case .Spring:name=anim.modifier_operation_name(&profile.springs[slot]);result.weight,result.enabled=profile.springs[slot].weight,profile.springs[slot].enabled
    case .Multi_IK:name=anim.modifier_operation_name(&profile.multi_ik[slot]);result.weight,result.enabled=profile.multi_ik[slot].weight,profile.multi_ik[slot].enabled
    case .Chain_Retarget:name=anim.modifier_operation_name(&profile.retarget_chains[slot]);result.weight,result.enabled=profile.retarget_chains[slot].weight,profile.retarget_chains[slot].enabled
    case .Spline_IK:name=anim.modifier_operation_name(&profile.spline_ik[slot]);result.weight,result.enabled=profile.spline_ik[slot].weight,profile.spline_ik[slot].enabled
    case .Corrective:name=anim.modifier_operation_name(&profile.correctives[slot]);result.weight,result.enabled=profile.correctives[slot].weight,profile.correctives[slot].enabled
    case .Follow:name=anim.modifier_operation_name(&profile.follow[slot]);result.weight,result.enabled=profile.follow[slot].weight,profile.follow[slot].enabled
    }
    base.text_set(result.name[:],name)

    return result,true
}
@(private)
program_modifier_slot :: proc(call:^api.Call,profile:anim.Pose_Profile,kind:anim.Modifier_Kind,name:[]u8) -> (u16,bool) {
    wanted:=base.text_get(name)
    if wanted=="" {authoring_failure(call,"name","Required","an operation name from animation.inspect parts Modifiers","empty","The operation name is required");return 0,false}
    found:=-1
    for index in 0..<program_modifier_count(profile,kind) {
        definition,_:=program_modifier_definition(profile,kind,u16(index))
        if base.text_get(definition.name[:])!=wanted {continue}
        if found>=0 {authoring_failure(call,"name","Ambiguous_Reference","a unique operation name of this kind",wanted,"The operation name matches multiple definitions");return 0,false}
        found=index
    }
    if found<0 {authoring_failure(call,"name","Missing_Reference","an operation name of this kind",wanted,"The named rig operation does not exist");return 0,false}
    return u16(found),true
}
// The modifiers of the .character an entity plays.
@(private)
program_modifier_profile :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,file:^Authoring_File) -> (profile:anim.Pose_Profile,id:base.Asset_Id,ok:bool) {
    value,present:=editor.entity_get(world,entity,anim.Animation)
    if present {id=anim.animation_character(s.app.assets,value)}
    if id=={} {authoring_failure(call,"entity","Missing_Character","an Animation that plays a .character","none","The entity has no modifiers: it plays no .character",fix="Set Animation.asset to a .character (animation.character.setup makes one)");return}
    set:anim.Character_Set
    set,ok=character_open(s,call,id,file)
    return set.pose,id,ok
}

@(private)
program_grounding_diagnostic :: proc(world:core.World_Ref,entity:core.Entity,slot:u16,config:anim.Foot_Grounding) -> (result:Modifier_Diagnostic_Result) {
    if slot!=0 {return}
    grounding:=core.world_storage_of(world,anim.Grounding_Runtime)
    playback:=core.world_storage_of(world,anim.Playback)
    if grounding==nil || playback==nil {return}
    record:^anim.Grounding_Record
    for &value in grounding.records {if value.rig==entity {record=&value;break}}
    state:^anim.Playing
    for &value in playback.states {if value.entity==entity {state=&value;break}}
    if record==nil || !record.initialized || record.count<1 || record.count>anim.GROUNDING_LEGS || state==nil || !state.pose_ready {return}
    ground:=core.world_query(world,core.ref(core.world_storage_of(world,core.World_Queries)))
    ignore:=anim.ground_ignore(ground,core.read(core.world_table_of(world,core.Parent)),entity)
    result.blocked_legs=record.blocked
    for i in 0..<int(record.count) {
        if record.targets[i].weight<=0 {continue}
        bones:=record.bones[i]
        for bone in bones {if bone<0 || bone>=len(state.world) {return {}}}
        result.valid=true
        result.residual=max(result.residual,linalg.length(state.world[bones[2]].position-record.targets[i].position))
        result.angular_error=max(result.angular_error,mm.quat_angle(state.world[bones[2]].rotation,record.rotations[i]))
        _,blocked:=anim.grounding_limb_hit(ground,state.world[bones[0]].position,state.world[bones[1]].position,state.world[bones[2]].position,ignore,config.collision_mask)
        if blocked {result.blocked_legs|=u16(1)<<u16(i)}
    }
    result.reached=result.valid && result.residual<=.001 && result.angular_error<=.001 && result.blocked_legs==0
    return
}

@(private)
program_modifier_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Modifier_Inspect_Params)
    world,entity,ok:=subject(s,call,p.entity[:],p.handle);if !ok {return}
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,id,loaded:=program_modifier_profile(s,call,world,entity,&file);if !loaded {return}
    runtime:=core.world_storage_of(world,anim.Modifier_Runtime)
    total:=0;for kind in anim.Modifier_Kind {total+=program_modifier_count(profile,kind)}
    serial.text_write_raw(call.out,"{");api.write_key(call.out,"id",true);api.write_id(call.out,editor.api_entity_id(world,entity))
    api.write_key(call.out,"character");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,id);serial.write_u8(call.out,'"')
    api.write_uint(call.out,"total",u64(total));api.write_key(call.out,"last_request_error");request_error:=anim.modifier_request_error(runtime,entity);authoring_write_value(call,&request_error,type_info_of(anim.Modifier_Request_Error));api.write_key(call.out,"modifiers");serial.text_write_raw(call.out,"[")
    offset,written:=0,0
    for kind in anim.Modifier_Kind {
        for slot in 0..<program_modifier_count(profile,kind) {
            index:=offset;offset+=1
            if index<int(p.offset) || written>=int(p.limit) {continue}
            definition,_:=program_modifier_definition(profile,kind,u16(slot));weight,enabled:=definition.weight,definition.enabled
            alpha,target:f32=1,1;requested:=true;remaining:f32
            if state:=anim.modifier_control_state(runtime,entity,kind,u16(slot));state!=nil {
                weight,enabled=state.base_weight*state.weight,state.base_enabled && (state.enabled || state.weight>0)
                alpha,target,requested,remaining=state.weight,state.target,state.enabled,max(0,state.duration-state.elapsed)
            }
            if written>0 {serial.text_write_raw(call.out,",")};written+=1
            tag:=kind
            serial.text_write_raw(call.out,"{");api.write_key(call.out,"kind",true);authoring_write_value(call,&tag,type_info_of(anim.Modifier_Kind))
            api.write_text(call.out,"name",base.text_get(definition.name[:]))
            api.write_key(call.out,"weight");api.write_number(call.out,weight);api.write_bool(call.out,"enabled",enabled)
            if p.diagnostics {
                api.write_key(call.out,"alpha");api.write_number(call.out,alpha);api.write_key(call.out,"target_alpha");api.write_number(call.out,target);api.write_bool(call.out,"requested_enabled",requested);api.write_key(call.out,"fade_remaining");api.write_number(call.out,remaining)
                diagnostic,_:=anim.animation_rig_diagnostic(runtime,entity,kind,u16(slot),core.world_storage_of(world,anim.Animation_Constraints))
                result:=Modifier_Diagnostic_Result{valid=diagnostic.valid,reached=diagnostic.reached,residual=diagnostic.residual,angular_error=diagnostic.angular_error,iterations=diagnostic.iterations}
                if kind==.Grounding {result=program_grounding_diagnostic(world,entity,u16(slot),profile.grounding)}
                api.write_key(call.out,"diagnostic");authoring_write_value(call,&result,type_info_of(Modifier_Diagnostic_Result))
            }
            api.write_key(call.out,"effectors");serial.write_u8(call.out,'[')
            if kind==.Multi_IK {for &effector,e in profile.multi_ik[slot].effectors[:profile.multi_ik[slot].effector_count] {if e>0 {serial.write_u8(call.out,',')};item:=Modifier_Effector_Result{effector.name};authoring_write_value(call,&item,type_info_of(Modifier_Effector_Result))}}
            if kind==.Spline_IK {for name,e in anim.SPLINE_CONTROLS {if e>0 {serial.write_u8(call.out,',')};item:Modifier_Effector_Result;base.text_set(item.name[:],name);authoring_write_value(call,&item,type_info_of(Modifier_Effector_Result))}}
            serial.write_u8(call.out,']')
            serial.text_write_raw(call.out,"}")
        }
    }
    serial.text_write_raw(call.out,"]}")
}


@(private)
program_modifier_goal_value :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,profile:anim.Pose_Profile,p:^$T,raw:string,prefix:string="") -> (anim.Modifier_Goal,bool) {
    kind:=program_modifier_goal_kind(p.kind)
    resolved,valid:=program_modifier_slot(call,profile,kind,p.name[:]);if !valid {return {},false}
    field_path :: proc(prefix,field:string) -> string {return fmt.tprintf("%s.%s",prefix,field) if prefix!="" else field}
    targeted:=kind in anim.MODIFIER_TARGETED
    supported:=kind==.Grounding
    for field in ([5]string{"target","position","contact","grounded","effector"}) {
        present:=api.json_member(raw,field)!=""
        allowed:bool
        switch field {
        case "target":allowed=targeted
        case "position":allowed=kind==.Spring
        case "contact","grounded":allowed=supported
        case "effector":allowed=kind==.Multi_IK || kind==.Spline_IK
        }
        if present && !allowed {authoring_failure(call,field_path(prefix,field),"Kind","a field used by this operation",fmt.tprintf("%v",kind),"This field does not apply to the operation");return {},false}
        if !present && allowed && (field=="target" || field=="effector") {authoring_failure(call,field_path(prefix,field),"Required",fmt.tprintf("the %s of this operation",field),"missing","Supply it: animation.inspect parts Modifiers lists effectors");return {},false}
    }
    effector:u8
    wanted:=base.text_get(p.effector[:])
    #partial switch kind {
    case .Multi_IK:
        config:=profile.multi_ik[resolved]
        found:bool
        effector,found=anim.multi_ik_effector_named(&config,wanted)
        if !found {authoring_failure(call,field_path(prefix,"effector"),"Missing_Reference","an effector name of this Multi IK operation",wanted,"The named Multi IK effector does not exist");return {},false}
    case .Spline_IK:
        found:=false
        for name,i in anim.SPLINE_CONTROLS {if name==wanted {effector,found=u8(i),true;break}}
        if !found {authoring_failure(call,field_path(prefix,"effector"),"Missing_Reference","start, tangent_start, tangent_end or end",wanted,"Name a control of the spline");return {},false}
    }
    for number,i in p.position {if !finite(number) {authoring_failure(call,field_path(prefix,fmt.tprintf("position[%d]",i)),"Non_Finite","a finite number",fmt.tprintf("%g",number),"The modifier goal position is invalid");return {},false}}
    if supported && (!finite(p.contact) || p.contact<0 || p.contact>1) {authoring_failure(call,field_path(prefix,"contact"),"Range","a finite number in [0,1]",fmt.tprintf("%g",p.contact),"The contact strength is invalid");return {},false}
    goal:=anim.Modifier_Goal{rig=entity,kind=kind,slot=resolved,effector=effector,position=p.position}
    // By name: the operation is found again if the .character is read again.
    goal.name=p.name
    if kind==.Multi_IK {goal.effector_name=p.effector}
    if targeted {
        target,found:=spatial_target_value(call,world,p.target,field_path(prefix,"target"));if !found {return {},false}
        goal.target=target
    }
    definition,_:=program_modifier_definition(profile,kind,resolved)
    goal.weight=p.contact if supported else definition.weight
    goal.enabled=definition.enabled && (!supported || p.grounded)
    return goal,true
}


