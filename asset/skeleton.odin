package asset

import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

SKELETON_VERSION :: 3
SKELETON_OLDEST :: SKELETON_VERSION
SKELETON_MAX_BONES :: 65536

Skeleton_Info :: struct {bone_count:u32}

Skeleton_Socket :: struct {
    name:[64]u8 `mirai:"text"`,
    bone:[NODE_PATH_CAPACITY]u8 `mirai:"text"`,
    offset:mm.Transform,
}

Skeleton_Bone :: struct {
    name:[64]u8 `mirai:"text"`,
    path:[NODE_PATH_CAPACITY]u8 `mirai:"text"`,
    target:u64,
    parent:i32,
    translation:[3]f32,
    rotation:quaternion128,
    scale:[3]f32,
}

// The body of a skeleton (anim.Body_Map): its up at rest, across the -Z it
// faces, and in body_parts the bone of each part found, by path. confidence
// goes from 0 to 1; manual marks what a person set, which detection keeps.
Skeleton_Body :: struct {
    up:[3]f32,
    confidence:f32,
    manual:bool,
}
Skeleton_Body_Part :: struct {
    part:anim.Body_Part,
    bone:[NODE_PATH_CAPACITY]u8 `mirai:"text"`,
    confidence:f32,
    manual:bool,
}

Skeleton_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of: the prefab of the import that made it
    bones:[]Skeleton_Bone,
    sockets:[]Skeleton_Socket,
    body:^Skeleton_Body,
    body_parts:[]Skeleton_Body_Part,
    source:^Import_Info,
}

Skeleton_View :: struct {
    info:^Skeleton_Info,
    bones:[]Skeleton_Bone,
    sockets:[]Skeleton_Socket,
    body:^Skeleton_Body, // nil without a body
    body_parts:[]Skeleton_Body_Part,
    source:^Import_Info,
}

skeleton_check :: proc(view:Skeleton_View) -> bool {
    if view.info==nil || len(view.bones)==0 || len(view.bones)>SKELETON_MAX_BONES || int(view.info.bone_count)!=len(view.bones) {return false}
    for &bone,i in view.bones {
        if bone.parent< -1 || int(bone.parent)>=i || !text_valid(bone.name[:]) || !text_valid(bone.path[:]) {return false}
        path:=base.text_get(bone.path[:])
        if path=="" || bone.target!=base.name_hash(path) {return false}
        if !finite(bone.translation.x,bone.translation.y,bone.translation.z,bone.scale.x,bone.scale.y,bone.scale.z,bone.rotation.x,bone.rotation.y,bone.rotation.z,bone.rotation.w) {return false}
        q:=bone.rotation
        if bone.scale.x==0 || bone.scale.y==0 || bone.scale.z==0 || abs(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w-1)>1e-3 {return false}
        for other in view.bones[:i] {if other.target==bone.target {return false}}
    }
    for &socket,i in view.sockets {
        if !text_valid(socket.name[:]) || socket.name[0]==0 || !text_valid(socket.bone[:]) {return false}
        if skeleton_bone_index(view.bones,socket.bone)<0 {return false}
        for other in view.sockets[:i] {if other.name==socket.name {return false}}
        for value in socket.offset.position {if !finite(value) {return false}}
        for value in socket.offset.scale {if !finite(value) || value==0 {return false}}
        q:=socket.offset.rotation
        if !finite(q.x,q.y,q.z,q.w) || abs(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w-1)>1e-3 {return false}
    }
    return skeleton_body_check(view)
}

// A body with a unit up across its forward, and each part once on a bone of its
// own, all confidences between 0 and 1.
@(private="file")
skeleton_body_check :: proc(view:Skeleton_View) -> bool {
    if view.body==nil {return len(view.body_parts)==0}
    body:=view.body
    if !anim.body_up_valid(body.up) || !finite(body.confidence) || body.confidence<0 || body.confidence>1 {return false}
    if len(view.body_parts)>len(anim.Body_Part) {return false}
    for &row,i in view.body_parts {
        if row.part>max(anim.Body_Part) || !text_valid(row.bone[:]) || !finite(row.confidence) || row.confidence<0 || row.confidence>1 {return false}
        // A part without bone is one a person left without.
        if row.bone[0]==0 {if !row.manual {return false}} else if skeleton_bone_index(view.bones,row.bone)<0 {return false}
        for &other in view.body_parts[:i] {if other.part==row.part || row.bone[0]!=0 && other.bone==row.bone {return false}}
    }
    return true
}

// The bone with this path, or -1.
skeleton_bone_index :: proc(bones:[]Skeleton_Bone,path:[NODE_PATH_CAPACITY]u8) -> i32 {
    for &bone,i in bones {if bone.path==path {return i32(i)}}
    return -1
}

// The body of a view resolved on bones, by path: those of the view, or the
// bones of a new import that keeps what a person set. Parts whose bone is
// missing stay without one. An empty map without a body.
skeleton_body_map :: proc(bones:[]Skeleton_Bone,body:^Skeleton_Body,parts:[]Skeleton_Body_Part) -> anim.Body_Map {
    map_:=anim.body_map_empty()
    if body==nil {return map_}
    map_.up,map_.axes_confidence=body.up,body.confidence
    for &row in parts {
        if row.part>max(anim.Body_Part) {continue}
        bone:=skeleton_bone_index(bones,row.bone)
        if bone<0 && !(row.manual && row.bone[0]==0) {continue}
        map_.bones[row.part],map_.confidence[row.part]=bone,row.confidence if bone>=0 else 0
        if row.manual {map_.manual+={row.part}}
    }
    return map_
}

// The rows of a body map on its bones, in part order: one per part found and
// one, without bone, per part a person left without. False, writing no rows,
// for a map with no part or not of these bones.
skeleton_body_rows :: proc(bones:[]Skeleton_Bone,map_:anim.Body_Map,body:^Skeleton_Body,parts:^[len(anim.Body_Part)]Skeleton_Body_Part) -> (count:int,ok:bool) {
    if !anim.body_map_valid(map_,len(bones)) {return 0,false}
    found:=false
    for bone,part in map_.bones {
        manual:=part in map_.manual
        if bone<0 && !manual {continue}
        parts[count]={part=part,confidence=map_.confidence[part] if bone>=0 else 0,manual=manual}
        if bone>=0 {parts[count].bone=bones[bone].path;found=true}
        count+=1
    }
    if !found {return 0,false}
    body^={up=map_.up,confidence=map_.axes_confidence}
    return count,true
}

// Finds the body of a skeleton (anim.body_detect), keeping what `previous`
// marks manual; facing, when given, receives where it was found facing. The
// work arrays come from the allocator.
skeleton_body_detect :: proc(bones:[]Skeleton_Bone,previous:anim.Body_Map,allocator:=context.temp_allocator,facing:^mm.Vec3=nil) -> (map_:anim.Body_Map,ok:bool) {
    n:=len(bones)
    if n==0 {return}
    parents,e1:=make([]i32,n,allocator)
    names,e2:=make([]string,n,allocator)
    rest,e3:=make([]mm.Transform,n,allocator)
    world,e4:=make([]mm.Transform,n,allocator)
    defer {delete(parents,allocator);delete(names,allocator);delete(rest,allocator);delete(world,allocator)}
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil {return}
    for &bone,i in bones {
        parents[i]=bone.parent
        names[i]=base.text_get(bone.name[:])
        rest[i]={bone.translation,bone.rotation,bone.scale}
    }
    map_=previous
    if !anim.body_detect(parents,names,rest,world,&map_,facing) {return {},false}
    return map_,true
}

skeleton_document :: proc(doc:^Document,types:^Types,desc:Skeleton_Desc,allocator:=context.allocator) -> Error {
    info:=Skeleton_Info{u32(len(desc.bones))}
    if !skeleton_check({info=&info,bones=desc.bones,sockets=desc.sockets,body=desc.body,body_parts=desc.body_parts}) {return .Invalid}
    document_init(doc,KIND_SKELETON,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=SKELETON_VERSION
    error:=skeleton_tables(doc,types,&info,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
skeleton_tables :: proc(doc:^Document,types:^Types,info:^Skeleton_Info,desc:Skeleton_Desc) -> Error {
    document_put_row(doc,types,"skeleton",info) or_return
    document_put(doc,types,"bones",desc.bones) or_return
    document_put(doc,types,"sockets",desc.sockets) or_return
    if desc.body!=nil {
        document_put_row(doc,types,"body",desc.body) or_return
        document_put(doc,types,"body_parts",desc.body_parts) or_return
    }
    import_put(doc,types,desc.source) or_return
    return .None
}

skeleton_save :: proc(path:string,types:^Types,desc:Skeleton_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    skeleton_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

skeleton_view :: proc(a:^Asset,types:^Types) -> (view:Skeleton_View,error:Error) {
    kind_check(a,KIND_SKELETON,SKELETON_OLDEST,SKELETON_VERSION) or_return
    view.info=asset_row(a,types,"skeleton",Skeleton_Info) or_return
    view.bones=asset_rows(a,types,"bones","",Skeleton_Bone) or_return
    view.sockets=table_rows(a,types,"sockets",Skeleton_Socket) or_return
    body:=table_rows(a,types,"body",Skeleton_Body) or_return
    if len(body)>1 {return {},.Corrupt}
    if len(body)==1 {view.body=&body[0]}
    view.body_parts=table_rows(a,types,"body_parts",Skeleton_Body_Part) or_return
    view.source=import_info(a,types) or_return
    if !skeleton_check(view) {return {},.Corrupt}
    return view,.None
}
