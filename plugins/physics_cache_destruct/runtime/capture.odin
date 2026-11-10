package physics_cache_destruct

import "core:mem"
import "mirai:core"
import cache "plugins:physics_cache/runtime"
import destruct "plugins:destruct/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// Records what destructibles become into a physics cache: every piece is a track with the geometry
// destruct draws it with, and each frame holds the pose of the body the piece is on.

Capture_Source :: struct {entity:core.Entity,object:u32,materials:[32]base.Asset_Id}

// The scratch of capture_destructible, for the tracks its recorder holds.
Capture :: struct {
    pieces:[]destruct.Piece_Info,
    groups:[]destruct.Group_Info,
    samples:[]cache.Cache_Sample,
    geometry:geom.Mesh_Buffer,
    allocator:mem.Allocator,
}

capture_init :: proc(c:^Capture,tracks:int,allocator:=context.allocator) -> cache.Cache_Error {
    if c==nil || c.allocator.procedure!=nil || tracks<=0 || tracks>cache.CACHE_MAX_TRACKS {return .Invalid}
    c.allocator=allocator
    errors:[3]mem.Allocator_Error
    c.pieces,errors[0]=make([]destruct.Piece_Info,tracks,allocator)
    c.groups,errors[1]=make([]destruct.Group_Info,tracks,allocator)
    c.samples,errors[2]=make([]cache.Cache_Sample,tracks,allocator)
    geom.mesh_buffer_init(&c.geometry,allocator)
    if errors!={} {
        capture_destroy(c)
        return .Out_Of_Memory
    }
    return .None
}

capture_destroy :: proc(c:^Capture) {
    if c==nil || c.allocator.procedure==nil {return}
    delete(c.pieces,c.allocator);delete(c.groups,c.allocator);delete(c.samples,c.allocator)
    geom.mesh_buffer_destroy(&c.geometry)
    c^={}
}

// Adds a frame at time with the pieces of the sources that are in the world, each in the frame of the
// origin of the recorder; a piece seen for the first time adds its track.
capture_destructible :: proc(
    c:^Capture,r:^cache.Cache_Recorder,time:f32,sources:[]Capture_Source,
    view:destruct.Destruct_View,geometry:core.Ref(destruct.Destruct_Cache),
) -> cache.Cache_Error {
    if c==nil || c.allocator.procedure==nil || r==nil || r.allocator.procedure==nil {return .Invalid}
    count:=0
    for &source in sources {
        pieces:=destruct.pieces(view,source.entity,c.pieces)
        bodies:=destruct.groups(view,source.entity,c.groups)
        if pieces>len(c.pieces) || bodies>len(c.groups) {return .Capacity}
        for piece in c.pieces[:pieces] {
            if piece.body==0 {continue}
            pose:mm.Transform
            found:=false
            for group in c.groups[:bodies] {if group.group==piece.group {pose={position=group.position,rotation=group.rotation,scale={1,1,1}};found=true;break}}
            if !found {continue}
            track:u32
            known:=false
            for old,index in r.tracks {if old.object==source.object && old.piece==piece.id {track=u32(index);known=true;break}}
            if !known {
                if !destruct.piece_geometry(geometry,source.entity,piece.id,&c.geometry) {return .Geometry_Unavailable}
                added,error:=cache.record_mesh(r,source.object,piece.id,geom.mesh_buffer_view(&c.geometry),source.materials[:])
                if error!=.None {return error}
                track=added
            }
            if count==len(c.samples) {return .Capacity}
            local,ok:=mm.transform_relative(pose,r.info.origin)
            if !ok {return .Invalid}
            c.samples[count]={track,local}
            count+=1
        }
    }
    return cache.record_frame(r,time,c.samples[:count])
}
