package animation_editor

import "mirai:asset"
import "core:fmt"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Program_Blend_Sample :: struct {position:mm.Vec2 `mirai:"label=In the units of the axes"`,clip:[64]u8 `mirai:"text,label=A clip of its animation"`,speed:f32 `mirai:"optional"`,animation:base.Asset_Id `mirai:"optional,label=Empty is that of info"`}
Program_Blend_Info :: struct {animation:base.Asset_Id,dimension:lib.Blend_Dimension,x:anim.Blend_Axis,y:anim.Blend_Axis `mirai:"optional"`}
Blend_Write_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .blend: what is there is replaced keeping its id"`,
    info:Program_Blend_Info,
    samples:[lib.BLEND_MAX_SAMPLES]Program_Blend_Sample `mirai:"label=1 to 256"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Blend_Sample_Params :: struct {asset:base.Asset_Id,position:mm.Vec2 `mirai:"label=Outside the hull it projects to the nearest edge"`}
Blend_Contribution :: struct {index:u32 `mirai:"label=The sample"`,clip:[64]u8 `mirai:"text"`,animation:base.Asset_Id,weight:f32}
Blend_Sample_Result :: struct {samples:[3]Blend_Contribution}
Program_Graph_Node :: struct {
    name:[64]u8 `mirai:"text"`,
    kind:anim.Graph_Node_Kind,
    left,right:[64]u8 `mirai:"text,optional,label=Child node name"`,
    clip:[64]u8 `mirai:"text,optional"`,
    animation:base.Asset_Id `mirai:"optional,label=Clip source; empty inherits the graph animation"`,
    blend_space:base.Asset_Id `mirai:"optional,label=Blend_Space: a .blend, an aim offset or additive space; only the right of an Additive node"`,
    x_parameter,y_parameter,weight_parameter:[32]u8 `mirai:"text,optional,label=Parameter name; empty uses the fixed value"`,
    position:mm.Vec2 `mirai:"optional"`,
    weight:f32 `mirai:"optional,min=0,max=1"`,
    speed:f32 `mirai:"optional"`,
    loop:bool `mirai:"optional"`,
    sync_mode:anim.Sync_Mode `mirai:"optional,label=Clip and Blend_Space only"`,
    sync_duration:f32 `mirai:"optional,min=0,unit=s,label=Clip and Blend_Space only"`,
    sync_group:[32]u8 `mirai:"text,optional,label=Clip and Blend_Space only"`,
    over:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=Bone branch path for Layer"`,
    mask:[64]u8 `mirai:"text,optional,label=Named bone mask"`,
    reference:f32 `mirai:"optional,min=0,unit=s,label=Reference time for an additive clip"`,
    curves:anim.Curve_Blend `mirai:"optional"`,
    mirror:bool `mirai:"optional,label=Clip or Blend_Space with left and right bones swapped"`,
}
Program_Graph_Mask :: struct {name:[64]u8 `mirai:"text"`}
Program_Graph_Mask_Bone :: struct {mask:[64]u8 `mirai:"text"`,bone:anim.Bone_Ref,weight:f32 `mirai:"optional,min=0,max=1"`,branch:bool `mirai:"optional"`}
Graph_Write_Params :: struct {
    path:[1024]u8 `mirai:"text,label=Ending in .agraph: what is there is replaced keeping its id"`,
    animation:base.Asset_Id,
    output:[64]u8 `mirai:"text,label=The node whose pose the graph gives"`,
    nodes:[anim.GRAPH_NODES]Program_Graph_Node,
    parameters:[anim.GRAPH_PARAMETERS]anim.Graph_Parameter `mirai:"optional"`,
    masks:[64]Program_Graph_Mask `mirai:"optional"`,
    mask_bones:[512]Program_Graph_Mask_Bone `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates the definition with its references and sources without writing"`,
}
Modifier_Inspect_Params :: struct {entity:editor.Api_Entity_Text `mirai:"text,entity"`,handle:core.Entity `mirai:"transient"`,offset:u32 `mirai:"optional"`,limit:u32 `mirai:"optional,min=1,max=256,clamp"`,diagnostics:bool `mirai:"optional"`}
Modifier_Goal_Kind :: enum u8 {IK,Look,Contact,Grounding,Chain_IK,Spring,Multi_IK,Spline_IK,Follow}
MODIFIER_GOAL_KINDS :: [Modifier_Goal_Kind]anim.Modifier_Kind{.IK=.IK,.Look=.Look,.Contact=.Contact,.Grounding=.Grounding,.Chain_IK=.Chain_IK,.Spring=.Spring,.Multi_IK=.Multi_IK,.Spline_IK=.Spline_IK,.Follow=.Follow}
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
program_graph_defaults :: proc(allocator:=context.temp_allocator) -> ^Graph_Write_Params {
    graph:=new(Graph_Write_Params,allocator)
    if graph==nil {return nil}
    for &node in graph.nodes {node.weight,node.speed,node.loop,node.sync_mode=.5,1,true,.Markers}
    for &bone in graph.mask_bones {bone.weight=1}
    return graph
}

@(private)
program_register :: proc(s:^editor.Session) {
    inspect:=Authoring_Inspect_Params{limit=128}
    blend:=program_blend_defaults()
    graph:=program_graph_defaults()
    if blend==nil || graph==nil {return}
    modifiers:=Modifier_Inspect_Params{limit=128}
    authoring_method_register(s,{name="animation.blend_space.set",summary="Makes or replaces a .blend: clips placed on one or two axes, its segments or triangles prepared from the samples. It plays as an aim offset or additive space, the right of an Additive node of an .agraph. An invalid one changes nothing. In Edit.",params=Blend_Write_Params,params_info=type_info_of(Blend_Write_Params),defaults=blend,run=program_blend_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    authoring_method_register(s,{name="animation.blend_space.sample",summary="The samples of a blend space that contribute at a position and their weights, without advancing the world.",params=Blend_Sample_Params,params_info=type_info_of(Blend_Sample_Params),flags={.Read_Only},run=program_blend_sample},Blend_Sample_Result,type_info_of(Blend_Sample_Result))
    authoring_method_register(s,{name="animation.graph.set",summary="Makes or replaces an .agraph that composes poses: named nodes in any order (clips, blends, layers and additives) with its parameters and bone masks. Locomotion is a .match. An invalid one changes nothing. In Edit.",params=Graph_Write_Params,params_info=type_info_of(Graph_Write_Params),defaults=graph,run=program_graph_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
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
program_blend_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^Authoring_File) -> (anim.Blend_Profile,bool) {
    if !authoring_open(s,call,id,anim.BLEND_KIND,file) {return {},false}
    profile,error:=anim.blend_space_view(&file.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .blend asset",fmt.tprintf("%v",error),"The blend space is invalid");return {},false}
    return profile,true
}

@(private)
program_graph_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^Authoring_File) -> (anim.Graph_Profile,bool) {
    if !authoring_open(s,call,id,anim.GRAPH_KIND,file) {return {},false}
    profile,error:=anim.graph_view(&file.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .agraph asset",fmt.tprintf("%v",error),"The animation graph is invalid");return {},false}
    return profile,true
}

@(private)
program_match_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,file:^Authoring_File) -> (anim.Match_Profile,bool) {
    if !authoring_open(s,call,id,anim.MATCH_KIND,file) {return {},false}
    profile,error:=anim.match_view(&file.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .match asset",fmt.tprintf("%v",error),"The motion matching library is invalid");return {},false}
    return profile,true
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
program_blend_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Authoring_Inspect_Params)
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=program_blend_open(s,call,p.asset,&file);if !ok {return}
    serial.text_write_raw(call.out,"{");authoring_result(call,p.asset,file.path)
    api.write_key(call.out,"info");authoring_write_value(call,&profile.info,type_info_of(anim.Blend_Info))
    api.write_uint(call.out,"samples_total",u64(len(profile.samples)));api.write_uint(call.out,"segments_total",u64(len(profile.segments)));api.write_uint(call.out,"triangles_total",u64(len(profile.triangles)))
    program_rows(call,"samples",profile.samples,p.offset,p.limit);program_rows(call,"segments",profile.segments,p.offset,p.limit);program_rows(call,"triangles",profile.triangles,p.offset,p.limit)
    serial.text_write_raw(call.out,"}")
}

@(private)
program_blend_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Blend_Write_Params)
    if !authoring_editable(s,call) {return}
    target:Authoring_File;defer asset.asset_close(&target.file)
    id,ok:=authoring_set_target(s,call,base.text_get(p.path[:]),anim.BLEND_KIND,".blend",&target);if !ok {return}
    sample_count,_:=api.params_array_count(call,"samples")
    if sample_count==0 || sample_count>lib.BLEND_MAX_SAMPLES {authoring_failure(call,"samples","Capacity","1 to 256 samples",fmt.tprintf("%d",sample_count),"A blend space needs samples");return}
    source:Authoring_File;defer asset.asset_close(&source.file)
    animation,loaded:=program_animation_open(s,call,p.info.animation,&source);if !loaded {return}
    samples:[lib.BLEND_MAX_SAMPLES]anim.Blend_Sample
    for &value,i in p.samples[:sample_count] {
        if !program_clip_reference(s,call,animation,value.animation,value.clip[:],fmt.tprintf("samples[%d].clip",i)) {return}
        samples[i]={position=value.position,clip=value.clip,speed=value.speed,animation=value.animation}
    }
    if p.info.dimension==.Two && p.info.x.name==p.info.y.name {authoring_failure(call,"info.y.name","Duplicate_Name","an axis name distinct from x",base.text_get(p.info.y.name[:]),"Blend-space axis names must be distinct");return}
    profile:=anim.Blend_Profile{info={animation=p.info.animation,dimension=p.info.dimension,x=p.info.x,y=p.info.y},samples=samples[:sample_count]}
    defer delete(profile.segments,call.allocator);defer delete(profile.triangles,call.allocator)
    if error:=anim.blend_space_prepare(&profile,call.allocator);error!=.None {
        authoring_failure(call,"samples","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","valid axes, positions and distinct noncollinear samples",fmt.tprintf("%v",error),"The blend-space definition cannot be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS)
        return
    }
    doc:asset.Document;defer asset.document_destroy(&doc)
    if error:=anim.blend_space_document(&doc,&s.app.assets.types,id,profile,s.app.allocator);error!=.None {authoring_failure(call,"samples","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","a valid prepared blend space",fmt.tprintf("%v",error),"The prepared blend space could not be written",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    _=authoring_publish(s,call,target,&doc)
}

@(private)
program_blend_sample :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Blend_Sample_Params)
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=program_blend_open(s,call,p.asset,&file);if !ok {return}
    weights,sampled:=anim.blend_sample(profile,p.position)
    if !sampled {authoring_failure(call,"position","Invalid_Value","a finite position",fmt.tprintf("%v",p.position),"The blend-space position must be finite");return}
    serial.text_write_raw(call.out,`{"samples":[`)
    for weight,i in weights.weights[:weights.count] {
        if i>0 {serial.text_write_raw(call.out,",")}
        sample:=profile.samples[weights.samples[i]]
        serial.text_write_raw(call.out,"{");api.write_uint(call.out,"index",u64(weights.samples[i]),true);api.write_text(call.out,"clip",base.text_get(sample.clip[:]));api.write_key(call.out,"animation");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,sample.animation if sample.animation!={} else profile.info.animation);serial.write_u8(call.out,'"');api.write_key(call.out,"weight");api.write_number(call.out,weight);serial.text_write_raw(call.out,"}")
    }
    serial.text_write_raw(call.out,"]}")
}

@(private)
program_graph_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Authoring_Inspect_Params)
    file:Authoring_File;defer asset.asset_close(&file.file)
    profile,ok:=program_graph_open(s,call,p.asset,&file);if !ok {return}
    serial.text_write_raw(call.out,"{");authoring_result(call,p.asset,file.path)
    graph_named_inspect(call,profile,p)
    serial.text_write_raw(call.out,"}")
}

@(private)
program_graph_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Graph_Write_Params)
    if !authoring_editable(s,call) {return}
    target:Authoring_File;defer asset.asset_close(&target.file)
    id,ok:=authoring_set_target(s,call,base.text_get(p.path[:]),anim.GRAPH_KIND,".agraph",&target);if !ok {return}
    profile,prepared:=graph_named_prepare(s,call,p);defer anim.graph_profile_free(&profile,call.allocator)
    if !prepared {return}
    doc:asset.Document;defer asset.document_destroy(&doc)
    if error:=anim.graph_document(&doc,&s.app.assets.types,id,profile,s.app.allocator);error!=.None {authoring_failure(call,"graph","Publication","a valid prepared graph",fmt.tprintf("%v",error),"The animation graph could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    _=authoring_publish(s,call,target,&doc)
}

// Checks that the graph of the Animation declares a parameter with this name and range.
@(private)
program_parameter_check :: proc(s:^editor.Session,call:^api.Call,animation:anim.Animation,name:string,value:f32) -> bool {
    if name=="" {authoring_failure(call,"name","Required","a declared parameter name","empty","The parameter name is required");return false}
    if !finite(value) {authoring_failure(call,"value","Invalid_Value","a finite parameter value",fmt.tprintf("%v",value),"The parameter value must be finite");return false}
    if s.app==nil || s.app.assets==nil {authoring_failure(call,"assets","Unavailable","an asset registry","missing registry","Assets are unavailable",api.SERVER_ERROR);return false}
    if !host.assets_scan(s.app.assets) {authoring_failure(call,"assets","Read_Failed","a refreshed asset registry","scan failed","The asset registry could not be refreshed",api.SERVER_ERROR);return false}
    record,found:=asset.registry_find(&s.app.assets.registry,animation.asset)
    if !found {authoring_failure(call,"asset","Missing_Asset","an animation program in the registry",fmt.tprintf("%v",animation.asset),"The animation program is missing");return false}
    file:Authoring_File;defer asset.asset_close(&file.file)
    index:=-1
    switch record.kind {
    case anim.GRAPH_KIND:
        profile,loaded:=program_graph_open(s,call,animation.asset,&file);if !loaded {return false}
        index=anim.graph_parameter_index(profile,name)
        if index<0 || index>=len(profile.parameters) {authoring_failure(call,"name","Unknown_Reference","a declared parameter name",name,"The graph parameter is missing");return false}
        if value<profile.parameters[index].min || value>profile.parameters[index].max {authoring_failure(call,"value","Out_Of_Range",fmt.tprintf("%v to %v",profile.parameters[index].min,profile.parameters[index].max),fmt.tprintf("%v",value),"The parameter is outside its declared range");return false}
    case:
        authoring_failure(call,"asset","Invalid_Kind","an .agraph asset",fmt.tprintf("%v",record.kind),"Only an .agraph has parameters",fix="Parameters drive the blends of an .agraph; a .match follows the body, and animation.request plays tells it what to play");return false
    }
    return true
}


@(private)
program_runtime_mode :: proc(s:^editor.Session,call:^api.Call) -> bool {
    if s.mode==.Edit {authoring_failure(call,"mode","Runtime_Required","Play or Simulation","Edit","Transient animation controls require Play or Simulation");return false}
    return true
}



@(private)
program_modifier_count :: proc(profile:anim.Pose_Profile,kind:anim.Modifier_Kind) -> int {
    switch kind {
    case .IK: return len(profile.ik)
    case .Look: return len(profile.look)
    case .Contact: return len(profile.contacts)
    case .Grounding: return len(profile.grounding)
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
    case .Contact:name=anim.modifier_operation_name(&profile.contacts[slot]);result.weight,result.enabled=profile.contacts[slot].weight,profile.contacts[slot].enabled
    case .Grounding:name=anim.modifier_operation_name(&profile.grounding[slot]);result.weight,result.enabled=profile.grounding[slot].weight,profile.grounding[slot].enabled
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
@(private)
program_modifier_profile :: proc(s:^editor.Session,call:^api.Call,world:core.World_Ref,entity:core.Entity,kind:anim.Modifier_Kind,file:^Authoring_File) -> (anim.Pose_Profile,bool) {
    id:base.Asset_Id
    if kind==.Chain_Retarget {
        value,present:=editor.entity_get(world,entity,anim.Animation)
        if present {id=value.retarget}
    } else {
        config,present:=editor.entity_get(world,entity,anim.Pose_Modifiers)
        if present {id=config.profile}
    }
    if id=={} {authoring_failure(call,"entity","Missing_Profile","Animation.retarget for Chain_Retarget or Pose_Modifiers.profile for other kinds","unassigned","The rig operation has no assigned profile");return {},false}
    return authoring_profile_open(s,call,id,file)
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
    config,present:=editor.entity_get(world,entity,anim.Pose_Modifiers)
    file:Authoring_File;defer asset.asset_close(&file.file)
    retarget_file:Authoring_File;defer asset.asset_close(&retarget_file.file)
    profile:anim.Pose_Profile
    if present && config.profile!={} {loaded:bool;profile,loaded=authoring_profile_open(s,call,config.profile,&file);if !loaded {return}}
    profile.retarget_chains=nil
    animation,animated:=editor.entity_get(world,entity,anim.Animation)
    if animated && animation.retarget!={} {retarget,loaded:=authoring_profile_open(s,call,animation.retarget,&retarget_file);if !loaded {return};profile.retarget_chains=retarget.retarget_chains}
    if !present && (!animated || animation.retarget=={}) {authoring_failure(call,"entity","Missing_Profile","Pose_Modifiers or Animation.retarget","none","The entity has no rig operation profile");return}
    runtime:=core.world_storage_of(world,anim.Modifier_Runtime)
    total:=0;for kind in anim.Modifier_Kind {total+=program_modifier_count(profile,kind)}
    serial.text_write_raw(call.out,"{");api.write_key(call.out,"id",true);api.write_id(call.out,editor.api_entity_id(world,entity))
    api.write_key(call.out,"profile");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,config.profile);serial.write_u8(call.out,'"')
    api.write_key(call.out,"retarget_profile");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,animation.retarget);serial.write_u8(call.out,'"')
    api.write_uint(call.out,"total",u64(total));api.write_key(call.out,"last_request_error");request_error:=anim.modifier_request_error(runtime,entity);authoring_write_value(call,&request_error,type_info_of(anim.Modifier_Request_Error));api.write_key(call.out,"modifiers");serial.text_write_raw(call.out,"[")
    offset,written:=0,0
    for kind in anim.Modifier_Kind {
        for slot in 0..<program_modifier_count(profile,kind) {
            index:=offset;offset+=1
            if index<int(p.offset) || written>=int(p.limit) {continue}
            definition,_:=program_modifier_definition(profile,kind,u16(slot));weight,enabled:=definition.weight,definition.enabled
            if kind!=.Chain_Retarget {weight*=config.weight;enabled &&=config.enabled}
            alpha,target:f32=1,1;requested:=true;remaining:f32
            if state:=anim.modifier_control_state(runtime,entity,kind,u16(slot));state!=nil {
                weight,enabled=state.base_weight*state.weight,state.base_enabled && (state.enabled || state.weight>0)
                alpha,target,requested,remaining=state.weight,state.target,state.enabled,max(0,state.duration-state.elapsed)
            }
            if written>0 {serial.text_write_raw(call.out,",")};written+=1
            tag:=kind
            serial.text_write_raw(call.out,"{");api.write_key(call.out,"kind",true);authoring_write_value(call,&tag,type_info_of(anim.Modifier_Kind))
            api.write_text(call.out,"name",base.text_get(definition.name[:]))
            selected:=&retarget_file if kind==.Chain_Retarget else &file
            api.write_key(call.out,"profile");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,selected.file.blob.header.id);serial.write_u8(call.out,'"')
            api.write_key(call.out,"weight");api.write_number(call.out,weight);api.write_bool(call.out,"enabled",enabled)
            if p.diagnostics {
                api.write_key(call.out,"alpha");api.write_number(call.out,alpha);api.write_key(call.out,"target_alpha");api.write_number(call.out,target);api.write_bool(call.out,"requested_enabled",requested);api.write_key(call.out,"fade_remaining");api.write_number(call.out,remaining)
                diagnostic,_:=anim.animation_rig_diagnostic(runtime,entity,kind,u16(slot),core.world_storage_of(world,anim.Animation_Constraints))
                result:=Modifier_Diagnostic_Result{valid=diagnostic.valid,reached=diagnostic.reached,residual=diagnostic.residual,angular_error=diagnostic.angular_error,iterations=diagnostic.iterations}
                if kind==.Grounding {result=program_grounding_diagnostic(world,entity,u16(slot),profile.grounding[slot])}
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
    supported:=kind==.Contact || kind==.Grounding
    for field in ([6]string{"target","position","normal","contact","grounded","effector"}) {
        present:=api.json_member(raw,field)!=""
        allowed:bool
        switch field {
        case "target":allowed=targeted
        case "position":allowed=kind==.Contact || kind==.Spring
        case "normal":allowed=kind==.Contact
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
    for number,i in p.normal {if !finite(number) {authoring_failure(call,field_path(prefix,fmt.tprintf("normal[%d]",i)),"Non_Finite","a finite number",fmt.tprintf("%g",number),"The modifier goal normal is invalid");return {},false}}
    if supported && (!finite(p.contact) || p.contact<0 || p.contact>1) {authoring_failure(call,field_path(prefix,"contact"),"Range","a finite number in [0,1]",fmt.tprintf("%g",p.contact),"The contact strength is invalid");return {},false}
    goal:=anim.Modifier_Goal{rig=entity,kind=kind,slot=resolved,effector=effector,position=p.position,normal=p.normal}
    // By name: the operation is found again if the profile is read again.
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


