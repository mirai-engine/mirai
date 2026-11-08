package decals

import "core:math/linalg"
import "core:slice"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// Decals: a color or an image laid over whatever surfaces are inside a box,
// without geometry of their own. They are drawn over the G-buffer of each
// view before it is lit, so they take the light, the shadows and the
// reflections of the surface they are on.

CAPACITY :: 256

// The box is that of the entity: its sides are its scale. The image lies
// across the local Y axis, facing up it.
@(component,description="Lays a color or an image over the surfaces inside its box, across its local Y axis.")
Decal :: struct {
    color:[4]f32 `mirai:"color"`,    // multiplies the image; its alpha is the opacity
    texture:base.Asset_Id,           // a color image with alpha; none: the plain color
    emission:[3]f32 `mirai:"color"`, // what the surface emits under it: a luminance, nits
    fade:f32 `mirai:"min=0,max=1"`,  // how far a surface turns away from the axis before the decal fades on it; 0: it never fades
    order:i32,                       // of two decals over each other, the higher one is on top
}

DECAL_DEFAULT :: Decal{color={1,1,1,1},fade=0.35}

// decal.slang
@(private)
Gpu_Decal :: struct {
    to_box:[3][4]f32,   // from the world to its box
    to_world:[3][4]f32, // and back: in the world, which each view takes relative to its origin (decal_relative)
    color:[4]f32,
    emission:[4]f32,
    texture:u32,
    density:f32,
    pad:[2]u32,
}
#assert(size_of(Gpu_Decal)==144)

@(private)
Sorted :: struct {order:i32,entity:core.Entity,row:int}

// What the renderer draws the decals of the frame with.
@(storage,host)
Decals_Gpu :: struct {
    pipeline:render.Pipeline, // of this frame
    items:[CAPACITY]Gpu_Decal,
    sorted:[CAPACITY]Sorted,
    count:int,
}

// The decals of the world into the frame, the lower ones first.
@(step="render",loops="game editor",after="render_sync")
decals_render :: proc(
    state:^Decals_Gpu,decals:core.Read(Decal),worlds:core.Read(core.World_Transform),
    hidden:core.Read(render.Hidden),parents:core.Read(core.Parent),app:^host.App,
) {
    state.count=0
    if app.assets==nil || core.count(decals)==0 {return}
    // 0 while the shaders in use have no decals: a generation made without the plugin.
    state.pipeline=render.stage_pipeline(app,{stage=.Surface,shader="decal",targets={.Albedo,.Emission},blend=.Alpha_Color,name="decals"})
    if state.pipeline==0 {return}
    n:=0
    for row in 0..<core.count(decals) {
        e:=core.entity_at(decals,row)
        if n>=CAPACITY || !core.has(worlds,e) || render.is_hidden(hidden,parents,e) {continue}
        state.sorted[n]={core.at(decals,row).order,e,row}
        n+=1
    }
    slice.sort_by(state.sorted[:n],proc(a,b:Sorted) -> bool {return a.order<b.order || (a.order==b.order && core.entity_index(a.entity)<core.entity_index(b.entity))})
    for item in state.sorted[:n] {
        decal:=core.at(decals,item.row)
        world,_:=core.get(worlds,item.entity)
        if abs(world.scale.x*world.scale.y*world.scale.z)<1e-12 {continue}
        to_world:=mm.transform_matrix(world.transform)
        entry:=Gpu_Decal{
            to_box=mm.mat4_rows(linalg.inverse(to_world)),to_world=mm.mat4_rows(to_world),
            color=decal.color,emission={decal.emission.x,decal.emission.y,decal.emission.z,decal.fade},
            texture=max(u32),
        }
        if decal.texture!={} {
            if texture:=host.assets_texture_image(app.assets,decal.texture);texture!=nil && texture.handle!=0 && !texture.failed {
                entry.texture=render.texture_index(texture.handle)
                entry.density=f32(texture.width)/max(abs(world.scale.x),1e-4)
            }
        }
        state.items[state.count]=entry
        state.count+=1
    }
    host.assets_commit(app.assets)
    if state.count>0 {render.frame_pass(app,.Surface,decals_record,state)}
}

// A decal for shaders whose places are relative to origin (the origin the
// renderer draws from): its place moves by it, and its box is found from there.
@(private)
decal_relative :: proc "contextless" (d:Gpu_Decal,origin:[3]f32) -> Gpu_Decal {
    d:=d
    d.to_box=render.origin_from_place(d.to_box,{d.to_world[0].w,d.to_world[1].w,d.to_world[2].w},origin)
    d.to_world=render.origin_to_world(d.to_world,origin)
    return d
}

@(private)
decals_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Decals_Gpu)user
    render.pass_surface_begin(pass,{.Albedo,.Emission},"decals")
    render.pass_pipeline(pass,state.pipeline)
    render.pass_surface_read(pass,1,.Linear_Depth)
    render.pass_surface_read(pass,2,.Normal)
    if rows,ok:=render.pass_rows_upload(pass,&state.items,state.count*size_of(Gpu_Decal));ok {
        placed:=([^]Gpu_Decal)(rows.ptr)[:state.count]
        for item,i in state.items[:state.count] {placed[i]=decal_relative(item,pass.origin)}
        render.pass_rows(pass,0,rows)
        render.pass_draw(pass,36,u32(state.count))
    }
    render.pass_end(pass)
}
