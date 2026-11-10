package physics_cache

import "core:math"
import "core:math/linalg"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// A .physics_cache: the motion of bodies and pieces recorded over time.
CACHE_KIND :: asset.Fourcc(u32('P')|u32('C')<<8|u32('A')<<16|u32('C')<<24)
CACHE_EXTENSION :: ".physics_cache"
CACHE_VERSION :: 2
CACHE_MAX_TRACKS :: 4096

Cache_Error :: enum u8 {None,Invalid,Capacity,Out_Of_Memory,Geometry_Unavailable}

Cache_Info :: struct {duration:f32,origin:mm.Transform}

Cache_Track :: struct {
    object:u32,
    piece:i32,
    vertex_first,vertex_count:u32,
    index_first,index_count:u32,
    material_first:u32,
    materials:[32]base.Asset_Id,
}

Cache_Vertex :: struct {position,normal:[3]f32,uv:[2]f32,color:[4]f32}
Cache_Frame :: struct {time:f32,first,count:u32}
Cache_Sample :: struct {track:u32,pose:mm.Transform}

Cache_View :: struct {
    info:^Cache_Info,
    tracks:[]Cache_Track,
    vertices:[]Cache_Vertex,
    indices,materials:[]u32,
    frames:[]Cache_Frame,
    samples:[]Cache_Sample,
}

Playback_Piece :: struct {track:u32,pose:mm.Transform}

cache_view :: proc(file:^asset.Asset,types:^asset.Types) -> (view:Cache_View,error:asset.Error) {
    asset.kind_check(file,CACHE_KIND,CACHE_VERSION) or_return
    view.info=asset.asset_row(file,types,"cache",Cache_Info) or_return
    view.tracks=asset.asset_rows(file,types,"tracks","",Cache_Track) or_return
    view.vertices=asset.asset_rows(file,types,"vertices","",Cache_Vertex) or_return
    view.indices=asset.asset_rows(file,types,"indices","",u32) or_return
    view.materials=asset.asset_rows(file,types,"materials","",u32) or_return
    view.frames=asset.asset_rows(file,types,"frames","",Cache_Frame) or_return
    view.samples=asset.asset_rows(file,types,"samples","",Cache_Sample) or_return
    if !cache_check(view) {return {},.Corrupt}
    return view,.None
}

@(private)
finite :: proc "contextless" (v:f32) -> bool {return !math.is_nan(v) && !math.is_inf(v)}

@(private)
pose_valid :: proc "contextless" (pose:mm.Transform) -> bool {
    for n in pose.position {if !finite(n) {return false}}
    for n in pose.scale {if !finite(n) || abs(n)<1e-8 {return false}}
    for n in ([4]f32{pose.rotation.x,pose.rotation.y,pose.rotation.z,pose.rotation.w}) {if !finite(n) {return false}}
    return abs(linalg.dot(pose.rotation,pose.rotation)-1)<0.001
}

cache_check :: proc(view:Cache_View) -> bool {
    if view.info==nil || !finite(view.info.duration) || view.info.duration<0 || !pose_valid(view.info.origin) {return false}
    if len(view.frames)==0 || len(view.tracks)>CACHE_MAX_TRACKS {return false}
    for track in view.tracks {
        if u64(track.vertex_first)+u64(track.vertex_count)>u64(len(view.vertices)) || track.vertex_count==0 {return false}
        if u64(track.index_first)+u64(track.index_count)>u64(len(view.indices)) || track.index_count==0 || track.index_count%3!=0 {return false}
        if u64(track.material_first)+u64(track.index_count/3)>u64(len(view.materials)) {return false}
        for index in view.indices[track.index_first:][:track.index_count] {if index>=track.vertex_count {return false}}
        for material in view.materials[track.material_first:][:track.index_count/3] {if material>=u32(len(track.materials)) {return false}}
    }
    for v in view.vertices {
        for n in v.position {if !finite(n) {return false}}
        for n in v.normal {if !finite(n) {return false}}
        for n in v.uv {if !finite(n) {return false}}
        for n in v.color {if !finite(n) {return false}}
    }
    previous:f32=-1
    for frame in view.frames {
        if !finite(frame.time) || frame.time<0 || frame.time<=previous || u64(frame.first)+u64(frame.count)>u64(len(view.samples)) {return false}
        previous=frame.time
        last:u32
        for sample,i in view.samples[frame.first:][:frame.count] {
            if int(sample.track)>=len(view.tracks) || i>0 && sample.track<=last || !pose_valid(sample.pose) {return false}
            last=sample.track
        }
    }
    return view.frames[0].time==0 && view.frames[len(view.frames)-1].time==view.info.duration
}

cache_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,view:Cache_View,allocator:=context.allocator) -> asset.Error {
    if !cache_check(view) {return .Invalid}
    asset.document_init(doc,CACHE_KIND,id,allocator)
    doc.kind_version=CACHE_VERSION
    error:=cache_tables(doc,types,view)
    if error!=.None {asset.document_destroy(doc)}
    return error
}

@(private)
cache_tables :: proc(doc:^asset.Document,types:^asset.Types,v:Cache_View) -> asset.Error {
    asset.document_put_row(doc,types,"cache",v.info) or_return
    asset.document_put(doc,types,"tracks",v.tracks) or_return
    asset.document_put(doc,types,"frames",v.frames) or_return
    asset.document_put(doc,types,"samples",v.samples,{.Bulk},.LZ) or_return
    asset.document_put(doc,types,"vertices",v.vertices,{.Bulk},.LZ) or_return
    asset.document_put(doc,types,"indices",v.indices,{.Bulk},.LZ) or_return
    asset.document_put(doc,types,"materials",v.materials,{.Bulk},.LZ) or_return
    return .None
}

cache_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,view:Cache_View,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    cache_document(&doc,types,id,view,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}

cache_sample :: proc(view:Cache_View,time:f32,out:[]Playback_Piece) -> int {
    if view.info==nil || len(view.frames)==0 || !finite(time) {return 0}
    sample_time:=clamp(time,0,view.info.duration)
    lo,hi:=0,len(view.frames)
    for lo<hi {mid:=(lo+hi)/2;if view.frames[mid].time<=sample_time {lo=mid+1}else{hi=mid}}
    at:=max(lo-1,0)
    frame:=view.frames[at]
    if u64(frame.first)+u64(frame.count)>u64(len(view.samples)) {return 0}
    from:=view.samples[frame.first:][:frame.count]
    to:[]Cache_Sample
    alpha:f32
    if at+1<len(view.frames) {
        next:=view.frames[at+1]
        if u64(next.first)+u64(next.count)>u64(len(view.samples)) || next.time<=frame.time {return 0}
        to=view.samples[next.first:][:next.count];alpha=(sample_time-frame.time)/(next.time-frame.time)
    }
    next:=0
    for sample,index in from {
        if index>=len(out) {break}
        pose:=sample.pose
        for next<len(to) && to[next].track<sample.track {next+=1}
        if next<len(to) && to[next].track==sample.track {
            end:=to[next].pose
            pose.position=pose.position+(end.position-pose.position)*alpha
            pose.rotation=mm.quat_slerp(pose.rotation,end.rotation,alpha)
            pose.scale=pose.scale+(end.scale-pose.scale)*alpha
        }
        out[index]={sample.track,pose}
    }
    return len(from)
}

cache_mesh :: proc(view:Cache_View,track:u32,out:^geom.Mesh_Buffer) -> bool {
    if int(track)>=len(view.tracks) || out==nil {return false}
    t:=view.tracks[track]
    if u64(t.vertex_first)+u64(t.vertex_count)>u64(len(view.vertices)) || u64(t.index_first)+u64(t.index_count)>u64(len(view.indices)) || t.index_count%3!=0 || u64(t.material_first)+u64(t.index_count/3)>u64(len(view.materials)) {return false}
    if reserve(&out.positions,int(t.vertex_count))!=nil || reserve(&out.normals,int(t.vertex_count))!=nil || reserve(&out.uvs,int(t.vertex_count))!=nil || reserve(&out.colors,int(t.vertex_count))!=nil || reserve(&out.indices,int(t.index_count))!=nil || reserve(&out.materials,int(t.index_count/3))!=nil {return false}
    geom.mesh_buffer_clear(out)
    for v in view.vertices[t.vertex_first:][:t.vertex_count] {append(&out.positions,v.position);append(&out.normals,v.normal);append(&out.uvs,v.uv);append(&out.colors,v.color)}
    append(&out.indices,..view.indices[t.index_first:][:t.index_count])
    append(&out.materials,..view.materials[t.material_first:][:t.index_count/3])
    return true
}
