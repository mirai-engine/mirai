package animation_editor

import "core:fmt"
import "core:mem"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

Graph_Node_Patch :: struct {
    name:[64]u8 `mirai:"text"`,kind:anim.Graph_Node_Kind `mirai:"optional"`,
    left,right,clip:[64]u8 `mirai:"text,optional"`,blend_space:base.Asset_Id `mirai:"optional"`,
    animation:base.Asset_Id `mirai:"optional"`,
    x_parameter,y_parameter,weight_parameter:[32]u8 `mirai:"text,optional"`,
    position:mm.Vec2 `mirai:"optional"`,weight:f32 `mirai:"optional,min=0,max=1"`,speed:f32 `mirai:"optional"`,loop:bool `mirai:"optional"`,
    sync_mode:anim.Sync_Mode `mirai:"optional"`,sync_duration:f32 `mirai:"optional,min=0,unit=s"`,sync_group:[32]u8 `mirai:"text,optional"`,
    over:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text,optional"`,mask:[64]u8 `mirai:"text,optional"`,reference:f32 `mirai:"optional,min=0,unit=s"`,curves:anim.Curve_Blend `mirai:"optional"`,
}
Graph_Parameter_Patch :: struct {name:[32]u8 `mirai:"text"`,value,min,max:f32 `mirai:"optional"`}
Graph_Patch_Params :: struct {
    asset:base.Asset_Id,animation:base.Asset_Id `mirai:"optional"`,
    output:[64]u8 `mirai:"text,optional"`,
    nodes:[anim.GRAPH_NODES]Graph_Node_Patch `mirai:"optional"`,parameters:[anim.GRAPH_PARAMETERS]Graph_Parameter_Patch `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
authoring_patch_register :: proc(s:^editor.Session) {
    authoring_method_register(s,{name="animation.graph.patch",summary="Edits only the given fields of the named nodes and parameters of an .agraph, and its source and output, all at once; animation.graph.set replaces its nodes and masks.",params=Graph_Patch_Params,params_info=type_info_of(Graph_Patch_Params),run=authoring_graph_patch},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
}
@(private)
graph_named_definition :: proc(call:^api.Call,profile:anim.Graph_Profile,p:^Graph_Write_Params) -> (counts:Graph_Counts,ok:bool) {
    counts={nodes=len(profile.nodes),parameters=len(profile.parameters),masks=len(profile.masks),mask_bones=len(profile.mask_bones)}
    if counts.mask_bones>len(p.mask_bones) {authoring_failure(call,"mask_bones","Capacity","at most 512 mask bones for graph patch",fmt.tprintf("%d",counts.mask_bones),"Use a full code-authored definition for this graph");return}
    p.animation=profile.info.animation
    p.output=profile.nodes[profile.info.output].name
    copy(p.parameters[:],profile.parameters)
    for &node,i in profile.nodes {
        value:=Program_Graph_Node{name=node.name,kind=node.kind,clip=node.clip,animation=node.animation,blend_space=node.blend_space,position=node.position,weight=node.weight,speed=node.speed,loop=node.loop,sync_mode=node.sync_mode,sync_duration=node.sync_duration,sync_group=node.sync_group,over=node.over,mask=node.mask,reference=node.reference,curves=node.curves,mirror=node.mirror}
        if node.kind!=.Clip && node.kind!=.Blend_Space {value.left,value.right=profile.nodes[node.left].name,profile.nodes[node.right].name}
        if node.x_param>=0 {value.x_parameter=profile.parameters[node.x_param].name};if node.y_param>=0 {value.y_parameter=profile.parameters[node.y_param].name};if node.weight_param>=0 {value.weight_parameter=profile.parameters[node.weight_param].name}
        p.nodes[i]=value
    }
    for mask,i in profile.masks {p.masks[i]={name=mask.name};for bone,j in profile.mask_bones[mask.first:][:mask.count] {p.mask_bones[int(mask.first)+j]={mask=mask.name,bone=bone.bone,weight=bone.weight,branch=bone.branch}}}
    return counts,true
}
@(private)
authoring_patch_value :: proc(call:^api.Call,text:string,value:^$T) -> bool {
    schema:serial.Schema;serial.schema_init(&schema,call.allocator);defer serial.schema_destroy(&schema)
    index,ok:=serial.schema_add_type_info(&schema,type_info_of(T));if !ok {authoring_failure(call,"patch","Out_Of_Memory","a schema for the patch","allocation failed","The patch could not be prepared",api.SERVER_ERROR);return false}
    reader:serial.Text_Reader;api.call_reader_init(call,&reader,text);defer serial.text_reader_destroy(&reader)
    if !serial.text_read(&reader,&schema,index,mem.ptr_to_bytes(value),true) || !serial.text_end(&reader) {authoring_failure(call,"patch","Invalid_Value","fields matching the target definition","invalid patch","The patch fields could not be read");return false}
    return true
}
authoring_graph_patch :: proc(s:^editor.Session,call:^api.Call) {
    patch:=api.call_params(call,Graph_Patch_Params);if !authoring_editable(s,call) {return}
    file:Authoring_File;defer asset.asset_close(&file.file);profile,loaded:=program_graph_open(s,call,patch.asset,&file);if !loaded {return}
    definition:=program_graph_defaults(call.allocator);if definition==nil {authoring_failure(call,"patch","Out_Of_Memory","memory for a graph definition","allocation failed","The patch could not be allocated",api.SERVER_ERROR);return}
    counts,ok:=graph_named_definition(call,profile,definition);if !ok {return}
    if authoring_field_present(call,"animation") {definition.animation=patch.animation};if authoring_field_present(call,"output") {definition.output=patch.output}
    nodes,_:=api.params_array_count(call,"nodes");parameters,_:=api.params_array_count(call,"parameters")
    if !graph_named_unique(call,patch.nodes[:nodes],"nodes") || !graph_named_unique(call,patch.parameters[:parameters],"parameters") {return}
    text,_:=authoring_json_field(call.raw,"nodes",call.allocator)
    for &node,i in patch.nodes[:nodes] {
        index,valid:=graph_named_reference(call,definition.nodes[:counts.nodes],base.text_get(node.name[:]),fmt.tprintf("nodes[%d].name",i));if !valid {return};if index<0 {authoring_failure(call,fmt.tprintf("nodes[%d].name",i),"Required","an existing node name","empty","A node patch needs a name");return}
        element,_:=authoring_json_element(text,i,call.allocator);if !authoring_patch_value(call,element,&definition.nodes[index]) || !graph_source_sync(call,definition.nodes[index],element,fmt.tprintf("nodes[%d]",i)) {return}
    }
    text,_=authoring_json_field(call.raw,"parameters",call.allocator)
    for &parameter,i in patch.parameters[:parameters] {
        index,valid:=graph_named_reference(call,definition.parameters[:counts.parameters],base.text_get(parameter.name[:]),fmt.tprintf("parameters[%d].name",i));if !valid {return};if index<0 {authoring_failure(call,fmt.tprintf("parameters[%d].name",i),"Required","an existing parameter name","empty","A parameter patch needs a name");return}
        element,_:=authoring_json_element(text,i,call.allocator);if !authoring_patch_value(call,element,&definition.parameters[index]) {return}
    }
    cooked,valid:=graph_named_prepare(s,call,definition,&counts);defer anim.graph_profile_free(&cooked,call.allocator);if !valid {return}
    doc:asset.Document;defer asset.document_destroy(&doc)
    if anim.graph_document(&doc,&s.app.assets.types,patch.asset,cooked,call.allocator)!=.None {authoring_failure(call,"patch","Invalid_Definition","a valid graph","invalid","The graph patch could not be serialized");return}
    _=authoring_publish(s,call,file,&doc)
}

