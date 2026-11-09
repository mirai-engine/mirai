package physics_cache

import "core:mem"
import "core:slice"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

Recorder_Desc :: struct {
    frames,tracks,samples,vertices,indices:int,
    origin:mm.Transform,
}

Cache_Recorder :: struct {
    info:Cache_Info,
    tracks:[dynamic]Cache_Track,
    vertices:[dynamic]Cache_Vertex,
    indices,materials:[dynamic]u32,
    frames:[dynamic]Cache_Frame,
    samples:[dynamic]Cache_Sample,
    scratch:[]Cache_Sample,
    pieces:[]destruct.Piece_Info,
    groups:[]destruct.Group_Info,
    geometry:geom.Mesh_Buffer,
    allocator:mem.Allocator,
}

Capture_Source :: struct {entity:core.Entity,object:u32,materials:[32]base.Asset_Id}

record_init :: proc(r:^Cache_Recorder,desc:Recorder_Desc,allocator:=context.allocator) -> Cache_Error {
    if r==nil || r.allocator.procedure!=nil || desc.frames<=0 || desc.tracks<=0 || desc.tracks>CACHE_MAX_TRACKS || desc.samples<=0 || desc.vertices<=0 || desc.indices<=0 || !pose_valid(desc.origin) {return .Invalid}
    if u64(desc.frames)>u64(max(u32)) || u64(desc.samples)>u64(max(u32)) || u64(desc.vertices)>u64(max(u32)) || u64(desc.indices)>u64(max(u32)) || desc.frames>max(int)/size_of(Cache_Frame) || desc.samples>max(int)/size_of(Cache_Sample) || desc.vertices>max(int)/size_of(Cache_Vertex) || desc.indices>max(int)/size_of(u32) {return .Invalid}
    r.allocator=allocator
    r.info.origin=desc.origin
    errors:[9]mem.Allocator_Error
    r.tracks,errors[0]=make([dynamic]Cache_Track,0,desc.tracks,allocator)
    r.vertices,errors[1]=make([dynamic]Cache_Vertex,0,desc.vertices,allocator)
    r.indices,errors[2]=make([dynamic]u32,0,desc.indices,allocator)
    r.materials,errors[3]=make([dynamic]u32,0,desc.indices/3,allocator)
    r.frames,errors[4]=make([dynamic]Cache_Frame,0,desc.frames,allocator)
    r.samples,errors[5]=make([dynamic]Cache_Sample,0,desc.samples,allocator)
    r.scratch,errors[6]=make([]Cache_Sample,desc.tracks,allocator)
    r.pieces,errors[7]=make([]destruct.Piece_Info,desc.tracks,allocator)
    r.groups,errors[8]=make([]destruct.Group_Info,desc.tracks,allocator)
    geom.mesh_buffer_init(&r.geometry,allocator)
    starved:=false
    for error in errors {starved||=error!=nil}
    if starved || cap(r.tracks)<desc.tracks || cap(r.vertices)<desc.vertices || cap(r.indices)<desc.indices || cap(r.materials)<desc.indices/3 || cap(r.frames)<desc.frames || cap(r.samples)<desc.samples || len(r.scratch)<desc.tracks || len(r.pieces)<desc.tracks || len(r.groups)<desc.tracks {
        record_destroy(r)
        return .Out_Of_Memory
    }
    return .None
}

record_destroy :: proc(r:^Cache_Recorder) {
    delete(r.tracks);delete(r.vertices);delete(r.indices);delete(r.materials);delete(r.frames);delete(r.samples)
    delete(r.scratch,r.allocator);delete(r.pieces,r.allocator);delete(r.groups,r.allocator)
    geom.mesh_buffer_destroy(&r.geometry)
    r^={}
}

record_view :: proc(r:^Cache_Recorder) -> Cache_View {
    return {&r.info,r.tracks[:],r.vertices[:],r.indices[:],r.materials[:],r.frames[:],r.samples[:]}
}

record_mesh :: proc(r:^Cache_Recorder,object:u32,piece:i32,mesh:geom.Mesh,materials:[]base.Asset_Id=nil) -> (track:u32,error:Cache_Error) {
    if r==nil || r.allocator.procedure==nil || !geom.mesh_is_valid(mesh) || len(mesh.indices)==0 || len(materials)>32 {return 0,.Invalid}
    for old,index in r.tracks {if old.object==object && old.piece==piece {return u32(index),.None}}
    if len(r.tracks)==cap(r.tracks) || len(mesh.positions)>cap(r.vertices)-len(r.vertices) || len(mesh.indices)>cap(r.indices)-len(r.indices) || len(mesh.indices)/3>cap(r.materials)-len(r.materials) {return 0,.Capacity}
    for m in mesh.materials {if m>=32 {return 0,.Invalid}}
    for p in mesh.positions {for n in p {if !finite(n) {return 0,.Invalid}}}
    t:=Cache_Track{object=object,piece=piece,vertex_first=u32(len(r.vertices)),vertex_count=u32(len(mesh.positions)),index_first=u32(len(r.indices)),index_count=u32(len(mesh.indices)),material_first=u32(len(r.materials))}
    copy(t.materials[:],materials)
    for p,index in mesh.positions {
        v:=Cache_Vertex{position=p,normal={0,1,0},color={1,1,1,1}}
        if len(mesh.normals)>0 {v.normal=mesh.normals[index]}
        if len(mesh.uvs)>0 {v.uv=mesh.uvs[index]}
        if len(mesh.colors)>0 {v.color=mesh.colors[index]}
        append(&r.vertices,v)
    }
    append(&r.indices,..mesh.indices)
    for triangle in 0..<len(mesh.indices)/3 {append(&r.materials,len(mesh.materials)>0?mesh.materials[triangle]:u32(0))}
    track=u32(len(r.tracks))
    append(&r.tracks,t)
    return track,.None
}

record_frame :: proc(r:^Cache_Recorder,time:f32,samples:[]Cache_Sample) -> Cache_Error {
    if r==nil || r.allocator.procedure==nil || !finite(time) || time<0 || len(r.frames)==0 && time!=0 || len(r.frames)>0 && time<=r.info.duration {return .Invalid}
    if len(r.frames)==cap(r.frames) || len(samples)>cap(r.samples)-len(r.samples) || len(samples)>len(r.scratch) {return .Capacity}
    for sample in samples {if int(sample.track)>=len(r.tracks) || !pose_valid(sample.pose) {return .Invalid}}
    scratch:=r.scratch[:len(samples)]
    copy(scratch,samples)
    slice.sort_by(scratch,proc(a,b:Cache_Sample)->bool{return a.track<b.track})
    for sample,index in scratch {if index>0 && sample.track==scratch[index-1].track {return .Invalid}}
    first:=len(r.samples)
    append(&r.samples,..scratch)
    append(&r.frames,Cache_Frame{time=time,first=u32(first),count=u32(len(samples))})
    r.info.duration=time
    return .None
}

capture_destructible :: proc(
    r:^Cache_Recorder,time:f32,sources:[]Capture_Source,
    view:destruct.Destruct_View,geometry:core.Ref(destruct.Destruct_Cache),
) -> Cache_Error {
    if r==nil || r.allocator.procedure==nil {return .Invalid}
    count:=0
    for &source in sources {
        pieces:=destruct.pieces(view,source.entity,r.pieces)
        bodies:=destruct.groups(view,source.entity,r.groups)
        if pieces>len(r.pieces) || bodies>len(r.groups) {return .Capacity}
        for piece in r.pieces[:pieces] {
            if piece.body==0 {continue}
            pose:mm.Transform
            found:=false
            for group in r.groups[:bodies] {if group.group==piece.group {pose={position=group.position,rotation=group.rotation,scale={1,1,1}};found=true;break}}
            if !found {continue}
            track:u32
            known:=false
            for old,index in r.tracks {if old.object==source.object && old.piece==piece.id {track=u32(index);known=true;break}}
            if !known {
                if !destruct.piece_geometry(geometry,source.entity,piece.id,&r.geometry) {return .Geometry_Unavailable}
                added,error:=record_mesh(r,source.object,piece.id,geom.mesh_buffer_view(&r.geometry),source.materials[:])
                if error!=.None {return error}
                track=added
            }
            if count==len(r.scratch) {return .Capacity}
            local,ok:=mm.transform_relative(pose,r.info.origin)
            if !ok {return .Invalid}
            r.scratch[count]={track,local}
            count+=1
        }
    }
    return record_frame(r,time,r.scratch[:count])
}
