package paint_editor

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "mirai:asset"
import erender "mirai:engine/render"
import "mirai:host"
import paint "plugins:paint/runtime"
import "mirai:std/base"
import "mirai:std/geom"

// The vertices of the mesh an entity shows as the renderer numbers them, by
// index in the mesh (those of its clusters, every level of detail), with the
// colors the entity shows now.
Canvas :: struct {
    allocator:runtime.Allocator,
    positions:[][3]f32, // in the space of the mesh
    colors:[]u32,
}

canvas_destroy :: proc(c:^Canvas) {
    delete(c.positions,c.allocator);delete(c.colors,c.allocator)
    c^={}
}

// Reads the mesh or primitive a Mesh_Renderer shows, and the colors of
// painted when they are of as many vertices. False, with the canvas empty,
// when it is not a mesh that can be drawn.
canvas_load :: proc(c:^Canvas,a:^host.Assets,shown:erender.Mesh_Renderer,painted:base.Asset_Id,allocator:=context.allocator) -> bool {
    c.allocator=allocator
    if shown.mesh!={} {
        file:asset.Asset
        if host.assets_file(a,shown.mesh,asset.KIND_MESH,&file)!=.None {return false}
        defer asset.asset_close(&file)
        view,error:=asset.mesh_view(&file,&a.types)
        if error!=.None || !canvas_take(c,view.geometry) {return false}
    } else {
        // A primitive is drawn as its mesh is made at run time (host.assets_shape).
        buffer:geom.Mesh_Buffer
        geom.mesh_buffer_init(&buffer,context.temp_allocator)
        defer geom.mesh_buffer_destroy(&buffer)
        if !host.assets_geometry(a,{},shown.shape,&buffer,true) {return false}
        made:host.Mesh_Render_Geometry
        host.assets_render_geometry_init(&made,context.temp_allocator)
        defer host.assets_render_geometry_destroy(&made)
        mesh:=geom.mesh_buffer_view(&buffer)
        mesh.colors,mesh.materials=nil,nil
        if !host.assets_render_geometry_make(mesh,nil,0,&made,host.assets_limits(a)) || !canvas_take(c,made.geometry) {return false}
    }
    if painted=={} {return true}
    file:asset.Asset
    if host.assets_file(a,painted,paint.KIND,&file)!=.None {return true}
    defer asset.asset_close(&file)
    if colors,error:=paint.colors_view(&file,&a.types);error==.None && len(colors)==len(c.colors) {copy(c.colors,colors)}
    return true
}

@(private)
canvas_take :: proc(c:^Canvas,g:asset.Mesh_Geometry) -> bool {
    count:=len(g.vertices)
    if count==0 {return false}
    c.positions=make([][3]f32,count,c.allocator)
    c.colors=make([]u32,count,c.allocator)
    for cluster in g.clusters {
        for local in 0..<asset.cluster_vertex_count(cluster) {
            at:=int(cluster.vertex_first+local)
            if at>=count {
                canvas_destroy(c)
                return false
            }
            c.positions[at]=asset.cluster_position(g,cluster,local)
            c.colors[at]=len(g.colors)>0?g.colors[at]:0xffffffff
        }
    }
    return true
}

// How much of the brush a point takes at a distance from its center, as a fraction of its radius: all of it at the center, none at the edge.
falloff :: proc "contextless" (t:f32) -> f32 {
    if t>=1 {return 0}
    return 1-t*t*(3-2*t)
}

// One stamp of the brush: raises the weight of every position within radius
// of center to the falloff there. A stroke keeps the most of its stamps, so
// going twice over a place within a stroke paints it once.
stamp :: proc(positions:[][3]f32,weights:[]f32,center:[3]f32,radius:f32) -> (changed:bool) {
    if radius<=0 {return false}
    limit:=radius*radius
    for position,at in positions {
        offset:=position-center
        squared:=linalg.dot(offset,offset)
        if squared>=limit {continue}
        weight:=falloff(math.sqrt(squared)/radius)
        if weight>weights[at] {
            weights[at]=weight
            changed=true
        }
    }
    return
}

// The stamps between two points of a stroke, spaced a quarter of the radius, the second point included.
stamp_segment :: proc(positions:[][3]f32,weights:[]f32,from,to:[3]f32,radius:f32) -> (changed:bool) {
    steps:=max(int(math.ceil(linalg.distance(from,to)/max(radius*0.25,1e-4))),1)
    for step in 1..=steps {
        if stamp(positions,weights,linalg.lerp(from,to,f32(step)/f32(steps)),radius) {changed=true}
    }
    return
}

// The colors of a stroke: each vertex goes from the color it had toward the
// color of the brush by strength times its weight. Alpha is kept.
colors_blend :: proc(colors:[]u32,before:[]u32,weights:[]f32,color:[3]f32,strength:f32) {
    target:=[3]f32{clamp(color.r,0,1),clamp(color.g,0,1),clamp(color.b,0,1)}*255
    for &out,at in colors {
        amount:=clamp(strength*weights[at],0,1)
        packed:=before[at]
        if amount>0 {
            mixed:=packed&0xff000000
            for channel in 0..<3 {
                shift:=u32(channel)*8
                old:=f32((packed>>shift)&0xff)
                mixed|=u32(math.round(old+(target[channel]-old)*amount))<<shift
            }
            packed=mixed
        }
        out=packed
    }
}
