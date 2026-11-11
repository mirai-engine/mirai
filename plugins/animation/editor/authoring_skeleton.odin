package animation_editor

import "core:fmt"
import aa "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"
import mm "mirai:std/math"

Authoring_Bone :: struct {
    name:[64]u8 `mirai:"text"`,
    path:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=Unique canonical path: the identity of the bone"`,
    parent:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=The canonical path of its parent; empty for a root; parents precede children"`,
    position:mm.Vec3 `mirai:"optional"`,
    rotation:[4]f32 `mirai:"optional,label=Normalized quaternion XYZW"`,
    scale:mm.Vec3 `mirai:"optional"`,
}
Skeleton_Create_Params :: struct {
    path:[1024]u8 `mirai:"text"`,
    bones:[256]Authoring_Bone,
    sockets:[128]aa.Skeleton_Socket `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Skeleton_Bone_Set_Params :: struct {
    asset:base.Asset_Id,
    path:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=The canonical path of the bone"`,
    bone:Authoring_Bone_Pose `mirai:"label=Its name and rest pose; an omitted transform is identity"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Authoring_Bone_Pose :: struct {
    name:[64]u8 `mirai:"text"`,
    position:mm.Vec3 `mirai:"optional"`,
    rotation:[4]f32 `mirai:"optional,label=Normalized quaternion XYZW"`,
    scale:mm.Vec3 `mirai:"optional"`,
}
Socket_Set_Params :: struct {
    asset:base.Asset_Id,
    name:[64]u8 `mirai:"text,label=Unique in the skeleton"`,
    bone:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,optional,label=A canonical bone path of the skeleton"`,
    offset:mm.Transform `mirai:"optional,label=Local to the bone"`,
    remove:bool `mirai:"optional,label=Removes the socket selected by name"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}

@(private)
authoring_skeleton_register :: proc(s:^editor.Session) {
    inspect:=Authoring_Inspect_Params{limit=128}
    create:=authoring_skeleton_create_defaults();if create==nil {return}
    bone:=Skeleton_Bone_Set_Params{bone={rotation={0,0,0,1},scale={1,1,1}}}
    socket:=Socket_Set_Params{offset=mm.TRANSFORM_IDENTITY}
    authoring_method_register(s,{name="skeleton.create",summary="Creates a .skeleton from its bones, parents before children, and its named sockets; an omitted transform of a bone is identity.",params=Skeleton_Create_Params,params_info=type_info_of(Skeleton_Create_Params),defaults=create,run=authoring_skeleton_create},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    authoring_method_register(s,{name="skeleton.bone.set",summary="Replaces the name and rest pose of a bone; its path and parent stay, since meshes and tracks refer to them.",params=Skeleton_Bone_Set_Params,params_info=type_info_of(Skeleton_Bone_Set_Params),defaults=&bone,run=authoring_bone_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    authoring_bone_add_register(s)
    authoring_method_register(s,{name="skeleton.socket.set",summary="Creates, replaces or removes a named socket of a .skeleton.",params=Socket_Set_Params,params_info=type_info_of(Socket_Set_Params),defaults=&socket,run=authoring_socket_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
}

@(private)
authoring_skeleton_create_defaults :: proc() -> ^Skeleton_Create_Params {
    result:=new(Skeleton_Create_Params,context.temp_allocator);if result==nil {return nil}
    for &bone in result.bones {bone.rotation={0,0,0,1};bone.scale={1,1,1}}
    return result
}

@(private)
authoring_bone :: proc(value:Authoring_Bone,parent:i32) -> aa.Skeleton_Bone {
    value:=value
    return {name=value.name,path=value.path,target=base.name_hash(base.text_get(value.path[:])),parent=parent,translation=value.position,rotation=quaternion(x=value.rotation.x,y=value.rotation.y,z=value.rotation.z,w=value.rotation.w),scale=value.scale}
}

@(private)
authoring_skeleton_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,result:^Authoring_File) -> (view:aa.Skeleton_View,ok:bool) {
    if !authoring_open(s,call,id,aa.KIND_SKELETON,result) {return}
    error:aa.Error
    view,error=aa.skeleton_view(&result.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .skeleton asset",fmt.tprintf("%v",error),"The skeleton asset is invalid");return}
    return view,true
}

@(private)
authoring_skeleton_save :: proc(s:^editor.Session,call:^api.Call,target:Authoring_File,id:base.Asset_Id,view:aa.Skeleton_View) {
    doc:aa.Document;defer aa.document_destroy(&doc)
    if error:=aa.skeleton_document(&doc,&s.app.assets.types,{id=id,bones=view.bones,sockets=view.sockets,body=view.body,body_parts=view.body_parts,source=view.source},s.app.allocator);error!=.None {authoring_failure(call,"bones","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","valid paths, hierarchy, rotations, scales and socket references",fmt.tprintf("%v",error),"The skeleton edit could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    _=authoring_publish(s,call,target,&doc)
}

@(private)
authoring_skeleton_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Authoring_Inspect_Params)
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_skeleton_open(s,call,p.asset,&file);if !ok {return}
    out:=call.out
    serial.text_write_raw(out,"{");authoring_result(call,p.asset,file.path)
    api.write_uint(out,"bones_total",u64(len(view.bones)));api.write_uint(out,"sockets_total",u64(len(view.sockets)))
    api.write_key(out,"bones");serial.text_write_raw(out,"[")
    start:=min(int(p.offset),len(view.bones));end:=min(start+int(p.limit),len(view.bones))
    for &bone,i in view.bones[start:end] {
        if i>0 {serial.text_write_raw(out,",")}
        value:=Authoring_Bone{name=bone.name,path=bone.path,position=bone.translation,rotation={bone.rotation.x,bone.rotation.y,bone.rotation.z,bone.rotation.w},scale=bone.scale}
        if bone.parent>=0 {value.parent=view.bones[bone.parent].path}
        authoring_write_value(call,&value,type_info_of(Authoring_Bone))
    }
    serial.text_write_raw(out,"]")
    api.write_key(out,"sockets");serial.text_write_raw(out,"[")
    start=min(int(p.offset),len(view.sockets));end=min(start+int(p.limit),len(view.sockets))
    for &socket,i in view.sockets[start:end] {if i>0 {serial.text_write_raw(out,",")};authoring_write_value(call,&socket,type_info_of(aa.Skeleton_Socket))}
    serial.text_write_raw(out,"]}")
}

@(private)
authoring_skeleton_create :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Skeleton_Create_Params)
    count,found:=api.params_array_count(call,"bones")
    sockets,_:=api.params_array_count(call,"sockets")
    if !found || count==0 || count>len(p.bones) || sockets>len(p.sockets) {authoring_failure(call,"bones","Capacity","1 to 256 bones and at most 128 sockets",fmt.tprintf("%d bones; %d sockets",count,sockets),"The skeleton definition exceeds its capacity");return}
    target,id,ok:=authoring_create_target(s,call,base.text_get(p.path[:]),".skeleton");if !ok {return}
    bones,error:=make([]aa.Skeleton_Bone,count,call.allocator)
    if error!=nil {authoring_failure(call,"bones","Out_Of_Memory","memory for bone rows","allocation failed","The bones could not be allocated",api.INTERNAL_ERROR);return}
    for &value,i in p.bones[:count] {
        parent,named:=authoring_bone_parent(call,bones[:i],base.text_get(value.parent[:]));if !named {return}
        bones[i]=authoring_bone(value,parent)
    }
    authoring_skeleton_save(s,call,target,id,{bones=bones,sockets=p.sockets[:sockets]})
}

// The index of the bone a path names among the bones before it; -1 for no parent.
@(private)
authoring_bone_parent :: proc(call:^api.Call,bones:[]aa.Skeleton_Bone,path:string) -> (parent:i32,ok:bool) {
    if path=="" {return -1,true}
    for &bone,i in bones {if base.text_get(bone.path[:])==path {return i32(i),true}}
    authoring_failure(call,"bones.parent","Missing_Bone","the canonical path of a bone before it",path,"A parent is not a bone that precedes the bone")
    return -1,false
}

@(private)
authoring_bone_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Skeleton_Bone_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_skeleton_open(s,call,p.asset,&file);if !ok {return}
    index:=-1
    for &bone,i in view.bones {if base.text_get(bone.path[:])==base.text_get(p.path[:]) {index=i;break}}
    if index<0 {authoring_failure(call,"path","Missing_Bone","the canonical path of a bone of the skeleton",base.text_get(p.path[:]),"The skeleton has no bone at that path",fix="animation.asset.inspect lists the bones with their paths");return}
    old:=view.bones[index]
    value:=authoring_bone({name=p.bone.name,path=old.path,position=p.bone.position,rotation=p.bone.rotation,scale=p.bone.scale},old.parent)
    bones,replaced:=authoring_replace_row(view.bones,index,value,false,aa.SKELETON_MAX_BONES,call.allocator)
    if !replaced {authoring_failure(call,"bone","Out_Of_Memory","memory for the bone edit","allocation failed","The bone edit could not be prepared",api.INTERNAL_ERROR);return}
    view.bones=bones
    authoring_skeleton_save(s,call,file,p.asset,view)
}

@(private)
authoring_socket_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Socket_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_skeleton_open(s,call,p.asset,&file);if !ok {return}
    at:=len(view.sockets)
    for value,i in view.sockets {if value.name==p.name {at=i;break}}
    sockets,replaced:=authoring_replace_row(view.sockets,at,aa.Skeleton_Socket{name=p.name,bone=p.bone,offset=p.offset},p.remove,aa.SKELETON_MAX_BONES,call.allocator)
    if !replaced {authoring_failure(call,"name","Invalid_Edit","an existing socket to remove or capacity to add",base.text_get(p.name[:]),"The socket edit cannot be prepared within capacity");return}
    view.sockets=sockets
    authoring_skeleton_save(s,call,file,p.asset,view)
}
