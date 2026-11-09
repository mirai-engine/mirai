package animation_editor

import "core:fmt"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/serial"
import "mirai:std/base"
import anim "plugins:animation/runtime"

Graph_Counts :: struct {nodes,parameters,masks,mask_bones:int}
Graph_Inspect_Result :: struct {
    asset:base.Asset_Id,path:[1024]u8 `mirai:"text"`,
    animation:base.Asset_Id,output:[64]u8 `mirai:"text"`,
    nodes_total,parameters_total,masks_total,mask_bones_total:u32,
    nodes:[64]Authoring_Page(Program_Graph_Node),
    parameters:[16]Authoring_Page(anim.Graph_Parameter),
    masks:[64]Authoring_Page(Program_Graph_Mask),
    mask_bones:[512]Authoring_Page(Program_Graph_Mask_Bone),
}

@(private)
graph_named_inspect :: proc(call:^api.Call,profile:anim.Graph_Profile,p:^Authoring_Inspect_Params) {
    api.write_key(call.out,"animation");serial.write_u8(call.out,'"');serial.text_write_asset_id(call.out,profile.info.animation);serial.write_u8(call.out,'"')
    api.write_text(call.out,"output",base.text_get(profile.nodes[profile.info.output].name[:]))
    nodes:[64]Program_Graph_Node
    for &node,i in profile.nodes {
        value:=Program_Graph_Node{name=node.name,kind=node.kind,clip=node.clip,animation=node.animation,blend_space=node.blend_space,position=node.position,weight=node.weight,speed=node.speed,loop=node.loop,sync_mode=node.sync_mode,sync_duration=node.sync_duration,sync_group=node.sync_group,over=node.over,mask=node.mask,reference=node.reference,curves=node.curves,mirror=node.mirror}
        if node.kind!=.Clip && node.kind!=.Blend_Space {value.left,value.right=profile.nodes[node.left].name,profile.nodes[node.right].name}
        if node.x_param>=0 {value.x_parameter=profile.parameters[node.x_param].name}
        if node.y_param>=0 {value.y_parameter=profile.parameters[node.y_param].name}
        if node.weight_param>=0 {value.weight_parameter=profile.parameters[node.weight_param].name}
        nodes[i]=value
    }
    masks:[anim.GRAPH_MASKS]Program_Graph_Mask;mask_bones:=make([]Program_Graph_Mask_Bone,len(profile.mask_bones),call.allocator)
    if len(profile.mask_bones)>0 && mask_bones==nil {authoring_failure(call,"mask_bones","Out_Of_Memory","memory for named mask rows","allocation failed","The masks could not be inspected",api.SERVER_ERROR);return}
    for mask,i in profile.masks {
        masks[i]={name=mask.name}
        for bone,j in profile.mask_bones[mask.first:][:mask.count] {mask_bones[int(mask.first)+j]={mask=mask.name,bone=bone.bone,weight=bone.weight,branch=bone.branch}}
    }
    api.write_uint(call.out,"nodes_total",u64(len(profile.nodes)));api.write_uint(call.out,"parameters_total",u64(len(profile.parameters)));api.write_uint(call.out,"masks_total",u64(len(profile.masks)));api.write_uint(call.out,"mask_bones_total",u64(len(profile.mask_bones)))
    graph_named_node_rows(call,nodes[:len(profile.nodes)],p.offset,p.limit);program_rows(call,"parameters",profile.parameters,p.offset,p.limit)
    program_rows(call,"masks",masks[:len(profile.masks)],p.offset,p.limit);program_rows(call,"mask_bones",mask_bones,p.offset,p.limit)
}
@(private)
graph_named_node_rows :: proc(call:^api.Call,rows:[]Program_Graph_Node,offset,limit:u32) {
    api.write_key(call.out,"nodes");serial.text_write_raw(call.out,"[");first:=min(int(offset),len(rows));last:=min(first+int(limit),len(rows));source_only:=[3]string{"sync_mode","sync_duration","sync_group"}
    for &row,i in rows[first:last] {if i>0 {serial.write_u8(call.out,',')};serial.text_write_raw(call.out,"{");api.write_uint(call.out,"index",u64(first+i),true);api.write_key(call.out,"value");authoring_write_arrays(call,&row,nil,source_only[:] if row.kind!=.Clip && row.kind!=.Blend_Space else nil);serial.text_write_raw(call.out,"}")}
    serial.text_write_raw(call.out,"]")
}
@(private)
graph_source_sync :: proc(call:^api.Call,node:Program_Graph_Node,text:string,path:string) -> bool {
    if node.kind==.Clip || node.kind==.Blend_Space {return true}
    nested:=api.Call{raw=text,allocator=call.allocator};fields:=[3]string{"sync_mode","sync_duration","sync_group"}
    for field in fields {if authoring_field_present(&nested,field) {authoring_failure(call,fmt.tprintf("%s.%s",path,field),"Source_Only","sync configuration on Clip or Blend_Space","composite node","Synchronization belongs to source nodes");return false}}
    return true
}

@(private)
graph_named_index :: proc(rows:[]$T,name:string) -> int {
    if name=="" {return -1}
    for &row,i in rows {if base.text_get(row.name[:])==name {return i}}
    return -1
}

@(private)
graph_named_unique :: proc(call:^api.Call,rows:[]$T,field:string) -> bool {
    for &row,i in rows {
        name:=base.text_get(row.name[:])
        if name=="" {authoring_failure(call,fmt.tprintf("%s[%d].name",field,i),"Required","a nonempty unique name","","A graph name is empty");return false}
        if graph_named_index(rows[:i],name)>=0 {authoring_failure(call,fmt.tprintf("%s[%d].name",field,i),"Duplicate_Name","a unique name",name,"A graph name is repeated");return false}
    }
    return true
}

@(private)
graph_named_reference :: proc(call:^api.Call,rows:[]$T,name,path:string,empty:int=-1) -> (int,bool) {
    if name=="" {return empty,true}
    index:=graph_named_index(rows,name)
    if index<0 {authoring_failure(call,path,"Unknown_Reference","a declared name",name,"A graph reference is not declared");return -1,false}
    return index,true
}

// A Blend_Space node is an aim offset or additive space: the right of Additive nodes and nothing else.
@(private)
graph_spaces_check :: proc(call:^api.Call,nodes:[]Program_Graph_Node,output:int) -> bool {
    for &node,i in nodes {
        if node.kind!=.Blend_Space {continue}
        name:=base.text_get(node.name[:]);under:=""
        if i==output {under="the output of the graph"}
        for &other in nodes {
            if other.kind==.Clip || other.kind==.Blend_Space || under!="" {continue}
            if base.text_get(other.left[:])==name {under=fmt.tprintf("the left of %v node %s",other.kind,base.text_get(other.name[:]))}
            if base.text_get(other.right[:])==name && other.kind!=.Additive {under=fmt.tprintf("the right of %v node %s",other.kind,base.text_get(other.name[:]))}
        }
        if under=="" {found:=false;for &other in nodes {if other.kind==.Additive && base.text_get(other.right[:])==name {found=true}};if !found {under="the child of no node"}}
        if under!="" {authoring_failure(call,fmt.tprintf("nodes[%d]",i),"Additive_Only","a Blend_Space only as the right of Additive nodes",under,"A .blend in a graph is an aim offset or an additive space that adds to a pose",fix="Make it the right of an Additive node whose left is the pose it adds to; locomotion by speed is a .match (animation.character.setup writes one)");return false}
    }
    return true
}

@(private)
graph_named_prepare :: proc(s:^editor.Session,call:^api.Call,p:^Graph_Write_Params,counts:^Graph_Counts=nil) -> (profile:anim.Graph_Profile,ok:bool) {
    node_count,_:=api.params_array_count(call,"nodes")
    parameter_count,_:=api.params_array_count(call,"parameters")
    mask_count,_:=api.params_array_count(call,"masks")
    bone_count,_:=api.params_array_count(call,"mask_bones")
    if counts!=nil {node_count,parameter_count,mask_count,bone_count=counts.nodes,counts.parameters,counts.masks,counts.mask_bones}
    if node_count<=0 || node_count>len(p.nodes) {authoring_failure(call,"nodes","Capacity","1 to 64 nodes",fmt.tprintf("%d",node_count),"An animation graph needs nodes");return}
    if parameter_count>len(p.parameters) || mask_count>anim.GRAPH_MASKS || bone_count>len(p.mask_bones) {authoring_failure(call,"graph","Capacity","the published graph limits","too many rows","The graph exceeds authoring capacity");return}
    if !graph_named_unique(call,p.nodes[:node_count],"nodes") || !graph_named_unique(call,p.parameters[:parameter_count],"parameters") || !graph_named_unique(call,p.masks[:mask_count],"masks") {return}
    for node,i in p.nodes[:node_count] {if node.mirror && node.kind!=.Clip && node.kind!=.Blend_Space {authoring_failure(call,fmt.tprintf("nodes[%d].mirror",i),"Unsupported_Policy","a Clip or Blend_Space node",fmt.tprintf("%v",node.kind),"Only source nodes mirror; mirror their sources instead");return}}
    for node,i in p.nodes[:node_count] {if (node.kind==.Clip || node.kind==.Blend_Space) && node.curves==.Additive {authoring_failure(call,fmt.tprintf("nodes[%d].curves",i),"Unsupported_Policy","Override or Ignore on a source node","Additive","Additive curves require a composed node with a reference source");return}}
    if counts==nil {text:=api.json_member(call.raw,"nodes");for node,i in p.nodes[:node_count] {element,_:=authoring_json_element(text,i,call.allocator);if !graph_source_sync(call,node,element,fmt.tprintf("nodes[%d]",i)) {return}}}
    profile.info.animation=p.animation
    profile.nodes=make([]anim.Graph_Node,node_count,call.allocator)
    profile.parameters=make([]anim.Graph_Parameter,parameter_count,call.allocator)
    profile.masks=make([]anim.Graph_Mask,mask_count,call.allocator)
    profile.mask_bones=make([]anim.Graph_Mask_Bone,bone_count,call.allocator)
    if len(profile.nodes)!=node_count || len(profile.parameters)!=parameter_count || len(profile.masks)!=mask_count || len(profile.mask_bones)!=bone_count {authoring_failure(call,"graph","Out_Of_Memory","memory for the graph","allocation failed","The graph cannot be prepared",api.INTERNAL_ERROR);return}
    copy(profile.parameters,p.parameters[:parameter_count])
    remap:[anim.GRAPH_NODES]int;for &index in remap {index=-1}
    for sorted in 0..<node_count {
        selected:=-1
        for &node,i in p.nodes[:node_count] {
            if remap[i]>=0 {continue}
            if node.kind==.Clip || node.kind==.Blend_Space {selected=i;break}
            left,a:=graph_named_reference(call,p.nodes[:node_count],base.text_get(node.left[:]),fmt.tprintf("nodes[%d].left",i))
            right,b:=graph_named_reference(call,p.nodes[:node_count],base.text_get(node.right[:]),fmt.tprintf("nodes[%d].right",i))
            if !a || !b {return}
            if left<0 || right<0 {authoring_failure(call,fmt.tprintf("nodes[%d]",i),"Required","two child node names","empty child","A composed node needs both children");return}
            if remap[left]>=0 && remap[right]>=0 {selected=i;break}
        }
        if selected<0 {authoring_failure(call,"nodes","Cycle","an acyclic graph","cyclic dependencies","The graph contains a dependency cycle");return}
        node:=p.nodes[selected]
        value:=anim.GRAPH_NODE_DEFAULT
        value.name,value.kind,value.clip,value.blend_space,value.animation=node.name,node.kind,node.clip,node.blend_space,node.animation
        value.position,value.weight,value.speed,value.loop=node.position,node.weight,node.speed,node.loop
        value.over,value.mask,value.reference,value.curves,value.mirror=node.over,node.mask,node.reference,node.curves,node.mirror
        value.sync_mode,value.sync_duration,value.sync_group=node.sync_mode,node.sync_duration,node.sync_group
        parameter_names:=[3][32]u8{node.x_parameter,node.y_parameter,node.weight_parameter}
        parameter_fields:=[3]string{"x_parameter","y_parameter","weight_parameter"}
        for &name,j in parameter_names {
            index,valid:=graph_named_reference(call,p.parameters[:parameter_count],base.text_get(name[:]),fmt.tprintf("nodes[%d].%s",selected,parameter_fields[j]))
            if !valid {return}
            switch j {case 0:value.x_param=i16(index);case 1:value.y_param=i16(index);case 2:value.weight_param=i16(index)}
        }
        if node.kind!=.Clip && node.kind!=.Blend_Space {
            left:=graph_named_index(p.nodes[:node_count],base.text_get(node.left[:]))
            right:=graph_named_index(p.nodes[:node_count],base.text_get(node.right[:]))
            value.left,value.right=u16(remap[left]),u16(remap[right])
        }
        if _,valid:=graph_named_reference(call,p.masks[:mask_count],base.text_get(node.mask[:]),fmt.tprintf("nodes[%d].mask",selected));!valid {return}
        remap[selected]=sorted;profile.nodes[sorted]=value
    }
    output,named:=graph_named_reference(call,p.nodes[:node_count],base.text_get(p.output[:]),"output")
    if !named {return}
    if output<0 {authoring_failure(call,"output","Required","an output node name","empty","A graph needs an output node");return}
    profile.info.output=u16(remap[output])
    if !graph_spaces_check(call,p.nodes[:node_count],output) {return}
    at:=0
    for mask,i in p.masks[:mask_count] {
        profile.masks[i]={name=mask.name,first=u16(at)}
        for bone in p.mask_bones[:bone_count] {
            if bone.mask!=mask.name {continue}
            profile.mask_bones[at]={bone=bone.bone,weight=bone.weight,branch=bone.branch};at+=1;profile.masks[i].count+=1
        }
    }
    for &bone,i in p.mask_bones[:bone_count] {if _,valid:=graph_named_reference(call,p.masks[:mask_count],base.text_get(bone.mask[:]),fmt.tprintf("mask_bones[%d].mask",i));!valid {return}}
    if at!=bone_count {authoring_failure(call,"mask_bones","Required","a declared mask name","empty mask reference","Every mask bone needs a mask name");return}
    if !anim.graph_check(profile) {authoring_failure(call,"graph","Invalid_Definition","valid ranges, policies and masks","invalid definition","The graph violates its runtime contract");return}
    source:Authoring_File;defer asset.asset_close(&source.file)
    animation,loaded:=program_animation_open(s,call,p.animation,&source);if !loaded {return}
    for &node,i in profile.nodes {
        switch node.kind {
        case .Clip:
            if !program_clip_reference(s,call,animation,node.animation,node.clip[:],fmt.tprintf("nodes.%s.clip",base.text_get(node.name[:]))) {return}
        case .Blend_Space:
            file:Authoring_File
            blend,valid:=program_blend_open(s,call,node.blend_space,&file)
            asset.asset_close(&file.file)
            if !valid {return}
        case .Blend,.Layer,.Additive:
        }
    }
    return profile,true
}

