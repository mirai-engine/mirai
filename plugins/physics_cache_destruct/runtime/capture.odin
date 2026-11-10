package physics_cache_destruct

import "mirai:core"
import cache "plugins:physics_cache/runtime"
import destruct "plugins:destruct/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

Capture_Source :: struct {entity:core.Entity,object:u32,materials:[32]base.Asset_Id}

// Records what destructibles are now into a physics cache: a frame at time with the pieces of the sources
// that are in the world, each a track with the geometry destruct draws it with, in the frame of the origin
// of the recorder. A transaction: it measures the pieces with temporary memory.
capture_destructible :: proc(
    r:^cache.Cache_Recorder,time:f32,sources:[]Capture_Source,
    view:destruct.Destruct_View,geometry:core.Ref(destruct.Destruct_Cache),
) -> cache.Cache_Error {
    if r==nil || r.allocator.procedure==nil {return .Invalid}
    mesh:geom.Mesh_Buffer
    geom.mesh_buffer_init(&mesh,r.allocator)
    defer geom.mesh_buffer_destroy(&mesh)
    count:=0
    for &source in sources {
        pieces,pieces_error:=make([]destruct.Piece_Info,destruct.pieces(view,source.entity,nil),context.temp_allocator)
        groups,groups_error:=make([]destruct.Group_Info,destruct.groups(view,source.entity,nil),context.temp_allocator)
        if pieces_error!=nil || groups_error!=nil {return .Out_Of_Memory}
        destruct.pieces(view,source.entity,pieces)
        destruct.groups(view,source.entity,groups)
        for piece in pieces {
            if piece.body==0 {continue}
            pose:mm.Transform
            found:=false
            for group in groups {if group.group==piece.group {pose={position=group.position,rotation=group.rotation,scale={1,1,1}};found=true;break}}
            if !found {continue}
            track:u32
            known:=false
            for old,index in r.tracks {if old.object==source.object && old.piece==piece.id {track=u32(index);known=true;break}}
            if !known {
                if !destruct.piece_geometry(geometry,source.entity,piece.id,&mesh) {return .Geometry_Unavailable}
                added,error:=cache.record_mesh(r,source.object,piece.id,geom.mesh_buffer_view(&mesh),source.materials[:])
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
    return cache.record_frame(r,time,r.scratch[:count])
}
