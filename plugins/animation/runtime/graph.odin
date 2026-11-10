package anim

import "core:mem"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "base:runtime"

// An .agraph composes poses: clips, blends by a weight, layers over a branch or a mask, and
// additive poses, among them the aim offsets and additive spaces of a .blend. It has no states:
// locomotion is a .match, and what a character does on top of it are actions and match_play.
GRAPH_KIND :: asset.Fourcc(u32('A')|u32('G')<<8|u32('R')<<16|u32('F')<<24)
GRAPH_VERSION :: 3
GRAPH_NODES :: 64
GRAPH_PARAMETERS :: 16
PROGRAM_GROUPS :: GRAPH_NODES*2
PROGRAM_INSTRUCTIONS :: GRAPH_NODES*2+1
PROGRAM_LEAVES :: 16
GRAPH_MASKS :: 16
GRAPH_MASK_BONES :: 4096

Graph_Parameter :: struct {name:[32]u8 `mirai:"text"`,value,min,max:f32}
// Blend_Space: the .blend of blend_space, only as the right of an Additive node.
Graph_Node_Kind :: enum u8 {Clip,Blend_Space,Blend,Layer,Additive}
Sync_Mode :: enum u8 {Independent,Markers,Weighted,Fixed}
Graph_Mask :: struct {name:[64]u8 `mirai:"text"`,first,count:u16}
Graph_Mask_Bone :: struct {bone:Bone_Ref,weight:f32,branch:bool}
Graph_Node :: struct {
    name:[64]u8 `mirai:"text"`,
    kind:Graph_Node_Kind,
    left,right:u16,
    clip:[64]u8 `mirai:"text"`,
    blend_space:base.Asset_Id,
    x_param,y_param,weight_param:i16,
    position:mm.Vec2,
    weight,speed:f32,
    loop:bool,
    sync_mode:Sync_Mode,
    sync_duration:f32,
    sync_group:[32]u8 `mirai:"text"`,
    over:[asset.NODE_PATH_CAPACITY]u8 `mirai:"text"`,
    mask:[64]u8 `mirai:"text"`,
    reference:f32,
    curves:Curve_Blend,
    mirror:bool, // Clip and Blend_Space: left and right bones swap
    animation:base.Asset_Id,
}
GRAPH_NODE_DEFAULT :: Graph_Node{x_param=-1,y_param=-1,weight_param=-1,weight=.5,speed=1,loop=true,sync_mode=.Markers}
Graph_Info :: struct {animation:base.Asset_Id,output:u16}
Graph_Profile :: struct {info:Graph_Info,parameters:[]Graph_Parameter,nodes:[]Graph_Node,masks:[]Graph_Mask,mask_bones:[]Graph_Mask_Bone}

graph_check :: proc(profile:Graph_Profile) -> bool {
    if profile.info.animation=={} || len(profile.nodes)==0 || len(profile.nodes)>GRAPH_NODES || int(profile.info.output)>=len(profile.nodes) || len(profile.parameters)>GRAPH_PARAMETERS {return false}
    for &parameter,i in profile.parameters {
        if !blend_text_valid(parameter.name[:],false) || !finite(parameter.value) || !finite(parameter.min) || !finite(parameter.max) || parameter.min>parameter.max || parameter.value<parameter.min || parameter.value>parameter.max {return false}
        for other in profile.parameters[:i] {if other.name==parameter.name {return false}}
    }
    if len(profile.masks)>GRAPH_MASKS || len(profile.mask_bones)>GRAPH_MASK_BONES {return false}
    for &mask,i in profile.masks {
        if !blend_text_valid(mask.name[:],false) || int(mask.first)>len(profile.mask_bones) || int(mask.count)>len(profile.mask_bones)-int(mask.first) {return false}
        for other in profile.masks[:i] {if other.name==mask.name {return false}}
    }
    for &bone in profile.mask_bones {if !profile_bone(bone.bone) || bone.bone.path[0]==0 || !finite(bone.weight) || bone.weight<0 || bone.weight>1 {return false}}
    for &node,i in profile.nodes {
        if !blend_text_valid(node.name[:],false) || !blend_text_valid(node.clip[:],true) || !blend_text_valid(node.over[:],true) || !blend_text_valid(node.mask[:],true) || !blend_text_valid(node.sync_group[:],true) || node.kind>max(Graph_Node_Kind) || !finite(node.speed) || !finite(node.weight) || node.weight<0 || node.weight>1 || !finite(node.position.x) || !finite(node.position.y) || node.sync_mode>max(Sync_Mode) || !finite(node.sync_duration) || node.sync_duration<0 || node.sync_mode==.Fixed && node.sync_duration<=0 || !finite(node.reference) || node.reference<0 || node.curves>max(Curve_Blend) {return false}
        source:=node.kind==.Clip || node.kind==.Blend_Space
        if node.animation!={} && node.kind!=.Clip {return false}
        if node.mirror && !source {return false}
        if source {
            if node.curves==.Additive {return false}
            if node.sync_mode!=.Fixed && node.sync_duration!=0 || node.sync_mode==.Independent && node.sync_group[0]!=0 {return false}
            if node.sync_group[0]!=0 {for previous in profile.nodes[:i] {if previous.kind!=.Clip && previous.kind!=.Blend_Space || previous.sync_group!=node.sync_group {continue};if previous.sync_mode!=node.sync_mode || node.sync_mode==.Fixed && previous.sync_duration!=node.sync_duration {return false}}}
        } else if node.sync_group[0]!=0 || node.sync_duration!=0 || node.sync_mode==.Weighted || node.sync_mode==.Fixed {return false}
        if node.mask[0]!=0 {found:=false;for mask in profile.masks {if mask.name==node.mask {found=true;break}};if !found {return false}}
        for other in profile.nodes[:i] {if other.name==node.name {return false}}
        for parameter in ([3]i16{node.x_param,node.y_param,node.weight_param}) {if parameter< -1 || int(parameter)>=len(profile.parameters) {return false}}
        switch node.kind {
        case .Clip:
            if node.clip[0]==0 {return false}
        case .Blend_Space:
            if node.blend_space=={} {return false}
        case .Blend,.Layer,.Additive:
            if int(node.left)>=i || int(node.right)>=i {return false}
        }
    }
    return graph_spaces_additive(profile)
}
// Whether each Blend_Space node is the right of an Additive node and of nothing else.
graph_spaces_additive :: proc(profile:Graph_Profile) -> bool {
    for &node,i in profile.nodes {
        if node.kind!=.Blend_Space {continue}
        additive:=false
        for &other in profile.nodes[i+1:] {
            if other.kind!=.Blend && other.kind!=.Layer && other.kind!=.Additive {continue}
            if int(other.left)==i || int(other.right)==i && other.kind!=.Additive {return false}
            if int(other.right)==i {additive=true}
        }
        if !additive || int(profile.info.output)==i {return false}
    }
    return true
}

graph_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,profile:Graph_Profile,allocator:=context.allocator) -> asset.Error {
    if !graph_check(profile) {return .Invalid}
    asset.document_init(doc,GRAPH_KIND,id,allocator);doc.kind_version=GRAPH_VERSION
    error:=graph_tables(doc,types,profile)
    if error!=.None {asset.document_destroy(doc)}
    return error
}
@(private)
graph_tables :: proc(doc:^asset.Document,types:^asset.Types,profile:Graph_Profile) -> asset.Error {
    info:=profile.info
    asset.document_put_row(doc,types,"graph",&info) or_return
    asset.document_put(doc,types,"parameters",profile.parameters) or_return
    asset.document_put(doc,types,"nodes",profile.nodes) or_return
    asset.document_put(doc,types,"masks",profile.masks) or_return
    asset.document_put(doc,types,"mask_bones",profile.mask_bones) or_return
    return .None
}
graph_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,profile:Graph_Profile,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    graph_document(&doc,types,id,profile,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}
graph_view :: proc(file:^asset.Asset,types:^asset.Types) -> (profile:Graph_Profile,error:asset.Error) {
    asset.kind_check(file,GRAPH_KIND,GRAPH_VERSION) or_return
    info:=asset.asset_row(file,types,"graph",Graph_Info) or_return
    profile.info=info^
    profile.parameters=asset.asset_rows(file,types,"parameters","",Graph_Parameter) or_return
    profile.nodes=asset.asset_rows(file,types,"nodes","",Graph_Node) or_return
    profile.masks=asset.asset_rows(file,types,"masks","",Graph_Mask) or_return
    profile.mask_bones=asset.asset_rows(file,types,"mask_bones","",Graph_Mask_Bone) or_return
    if !graph_check(profile) {return {},.Corrupt}
    return profile,.None
}
graph_profile_free :: proc(profile:^Graph_Profile,allocator:=context.allocator) {
    delete(profile.parameters,allocator);delete(profile.nodes,allocator);delete(profile.masks,allocator);delete(profile.mask_bones,allocator);profile^={}
}
graph_parameter_index :: proc(profile:Graph_Profile,name:string) -> int {
    for &parameter,i in profile.parameters {if base.text_get(parameter.name[:])==name {return i}}
    return -1
}

Graph_Plan :: struct {nodes:[GRAPH_NODES]u8,count:u8}

@(private)
graph_plan :: proc(profile:Graph_Profile,root:int) -> (plan:Graph_Plan,ok:bool) {
    if root<0 || root>=len(profile.nodes) {return}
    wanted:[GRAPH_NODES]bool;wanted[root]=true
    #reverse for node,i in profile.nodes[:root+1] {if wanted[i] && (node.kind==.Blend || node.kind==.Layer || node.kind==.Additive) {if int(node.left)>=i || int(node.right)>=i {return};wanted[node.left],wanted[node.right]=true,true}}
    for needed,i in wanted[:root+1] {if needed {plan.nodes[plan.count]=u8(i);plan.count+=1}}
    return plan,true
}

Graph_Content :: struct {
    plans:[GRAPH_NODES]Graph_Plan,
    parameter_names:[GRAPH_PARAMETERS]u64, // base.name_hash of the name of each parameter
    id:base.Asset_Id,checked,revision:u64,stamp:[2]i64,profile:Graph_Profile,valid:bool,error:asset.Error,
}
@(storage,host,free="graph_assets_free")
Graph_Assets :: struct {allocator:mem.Allocator,contents:[dynamic]Graph_Content,matches:[dynamic]Match_Content}
graph_assets_free :: proc(cache:^Graph_Assets) {
    if cache.allocator.procedure!=nil {context.allocator=cache.allocator}
    for &content in cache.contents {graph_profile_free(&content.profile)}
    for &content in cache.matches {match_content_free(&content)}
    delete(cache.contents);delete(cache.matches);cache^={}
}
@(private)
graph_clone :: proc(source:[]$T,allocator:mem.Allocator) -> ([]T,bool) {
    out,error:=make([]T,len(source),allocator);if error!=nil {return nil,false};copy(out,source);return out,true
}
@(private)
graph_read :: proc(assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> (profile:Graph_Profile,error:asset.Error) {
    file:asset.Asset
    if error:=host.assets_file(assets,id,GRAPH_KIND,&file);error!=.None {return {},error};defer asset.asset_close(&file)
    view,read:=graph_view(&file,&assets.types);if read!=.None {return {},read}
    profile.info=view.info
    ok:bool
    defer if !ok {graph_profile_free(&profile,allocator)}
    profile.parameters,ok=graph_clone(view.parameters,allocator);if !ok {return profile,.Out_Of_Memory}
    profile.nodes,ok=graph_clone(view.nodes,allocator);if !ok {return profile,.Out_Of_Memory}
    profile.masks,ok=graph_clone(view.masks,allocator);if !ok {return profile,.Out_Of_Memory}
    profile.mask_bones,ok=graph_clone(view.mask_bones,allocator);if !ok {return profile,.Out_Of_Memory}
    return profile,.None
}
graph_content :: proc(cache:^Graph_Assets,app:^host.App,id:base.Asset_Id) -> ^Graph_Content {
    if cache==nil || app==nil || app.assets==nil || id=={} {return nil}
    context.allocator=app.allocator;cache.allocator=app.allocator
    row:=-1
    for content,i in cache.contents {if content.id==id {row=i;break}}
    if row<0 {row=len(cache.contents);if append(&cache.contents,Graph_Content{id=id})!=1 {return nil}}
    content:=&cache.contents[row]
    if content.checked==assets_stamp(app.assets) {return content if content.valid else nil}
    record,found:=asset.registry_find(&app.assets.registry,id)
    stamp:=[2]i64{}
    if found {stamp={record.size,record.time}}
    if content.checked!=0 && stamp==content.stamp {content.checked=assets_stamp(app.assets);return content if content.valid else nil}
    profile:Graph_Profile;error:=asset.Error.Not_Found
    if found {profile,error=graph_read(app.assets,app.allocator,id)}
    if error==.Out_Of_Memory {content.error=error;content.checked=0;return nil}
    graph_profile_free(&content.profile)
    content.profile,content.valid,content.error=profile,error==.None,error
    if content.valid {
        for _,i in profile.nodes {content.plans[i],_=graph_plan(profile,i)}
        for &parameter,i in profile.parameters {content.parameter_names[i]=base.name_hash(base.text_get(parameter.name[:]))}
    }
    content.stamp,content.checked=stamp,assets_stamp(app.assets);content.revision+=1
    return content if content.valid else nil
}
