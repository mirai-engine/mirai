package decals

import "core:math/linalg"
import "core:slice"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

DECAL_CAPACITY :: 256
DECAL_TILE :: 8
#assert(DECAL_CAPACITY<=32*DECAL_TILE*DECAL_TILE)

Decal_Property :: enum u8 {Roughness, Metallic}
Decal_Properties :: bit_set[Decal_Property;u8]

// The box is that of the entity: its sides are its scale. The image lies
// across the local Y axis, facing up it.
@(component,description="Projects a material along local Y inside the entity's box.")
Decal :: struct {
    color:[4]f32 `mirai:"color"`,    // multiplies the image; its alpha is the opacity
    texture:base.Asset_Id,           // a color image with alpha; none: the plain color
    emission:[3]f32 `mirai:"color"`, // what the surface emits under it: a luminance, nits
    fade:f32 `mirai:"min=0,max=1"`,  // facing below which the decal fades; 0 disables the fade
    order:i32,                       // of two decals over each other, the higher one is on top
    normal_map:base.Asset_Id,
    overrides:Decal_Properties,
    roughness:f32 `mirai:"min=0,max=1"`,
    metallic:f32 `mirai:"min=0,max=1"`,
}

DECAL_DEFAULT :: Decal{color={1,1,1,1},fade=0.35}

// decal.slang
@(private)
Gpu_Decal :: struct {
    to_box:[3][4]f32,   // from the world to its box
    to_world:[3][4]f32, // from its box to the world
    color:[4]f32,
    emission:[4]f32,
    texture:u32,
    normal_map:u32,
    density:f32,
    normal_density:f32,
    roughness,metallic:f32, // negative leaves the receiver's property alone
    pad:[2]u32,
    rect:[4]i32,           // pixel min and exclusive max
}
#assert(size_of(Gpu_Decal)==176)

@(private)
Sorted :: struct {order:i32,entity:core.Entity,row:int}

// What the renderer draws the decals of the frame with.
@(storage,host)
Decals_Gpu :: struct {
    pipeline:render.Pipeline,
    material:bool,
    items:[DECAL_CAPACITY]Gpu_Decal,
    sorted:[DECAL_CAPACITY]Sorted,
    count:int,
}

// The decals of the world into the frame, the lower ones first.
@(step="render",loops="game editor",after="render_sync")
decals_render :: proc(
    state:^Decals_Gpu,decals:^core.Table(Decal,.Read),
    worlds:^core.Table(core.World_Transform,.Read),hidden:^core.Table(render.Hidden,.Read),
    parents:^core.Table(core.Parent,.Read),assets:^host.Assets,renderer:^render.Renderer,
) {
    state.count=0
    if assets==nil || core.count(decals)==0 {return}
    n:=0
    for row in 0..<core.count(decals) {
        e:=core.entity_at(decals,row)
        if n>=DECAL_CAPACITY || !core.has(worlds,e) || render.is_hidden(hidden,parents,e) {continue}
        state.sorted[n]={core.at(decals,row).order,e,row}
        n+=1
    }
    slice.sort_by(state.sorted[:n],proc(a,b:Sorted) -> bool {
        return a.order<b.order || (a.order==b.order &&
            core.entity_index(a.entity)<core.entity_index(b.entity))
    })
    material:=false
    for item in state.sorted[:n] {
        decal:=core.at(decals,item.row)
        world,_:=core.get(worlds,item.entity)
        if !(abs(world.scale.x*world.scale.y*world.scale.z)>=1e-12) {continue}
        to_world:=mm.transform_matrix(world.transform)
        entry:=Gpu_Decal{
            to_box=mm.mat4_rows(linalg.inverse(to_world)),to_world=mm.mat4_rows(to_world),
            color=decal.color,
            emission={decal.emission.x,decal.emission.y,decal.emission.z,decal.fade},
            texture=max(u32),normal_map=max(u32),
            roughness=clamp(decal.roughness,0,1) if .Roughness in decal.overrides else -1,
            metallic=clamp(decal.metallic,0,1) if .Metallic in decal.overrides else -1,
        }
        entry.texture,entry.density=decal_texture(assets,decal.texture,world.scale)
        entry.normal_map,entry.normal_density=decal_texture(assets,decal.normal_map,world.scale)
        material = material || entry.normal_map!=max(u32) || decal.overrides!={}
        state.items[state.count]=entry
        state.count+=1
    }
    host.assets_commit(assets)
    decals_submit(state,renderer,material)
}

@(private)
decal_texture :: proc(assets:^host.Assets,id:base.Asset_Id,scale:[3]f32) -> (u32,f32) {
    if id=={} {return max(u32),0}
    texture:=host.assets_texture_image(assets,id)
    if texture==nil || texture.handle==0 || texture.failed {return max(u32),0}
    return render.texture_index(texture.handle),
           max(f32(texture.width)/max(abs(scale.x),1e-4),
               f32(texture.height)/max(abs(scale.z),1e-4))
}

@(private)
decals_submit :: proc(state:^Decals_Gpu,renderer:^render.Renderer,material:bool) {
    if state.count==0 {return}
    state.material=material
    if material {
        state.pipeline=render.stage_pipeline(renderer,{
            stage=.Surface,shader="decal_compose",compute=true,name="compose decals",
        })
    } else {
        state.pipeline=render.stage_pipeline(renderer,{
            stage=.Surface,shader="decal",targets={.Albedo,.Emission},
            blend=.Alpha_Color,name="decals",
        })
    }
    if state.pipeline!=0 {render.frame_pass(renderer,.Surface,decals_record,state)}
}

// A decal for shaders whose places are relative to origin (the origin the
// renderer draws from): its place moves by it, and its box is found from there.
@(private)
decal_relative :: proc "contextless" (d:Gpu_Decal,origin:[3]f32) -> Gpu_Decal {
    d:=d
    place:=[3]f32{d.to_world[0].w,d.to_world[1].w,d.to_world[2].w}
    d.to_box=render.origin_from_place(d.to_box,place,origin)
    d.to_world=render.origin_to_world(d.to_world,origin)
    return d
}

@(private)
decals_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Decals_Gpu)user
    rows,ok:=render.pass_rows_upload(pass,&state.items,state.count*size_of(Gpu_Decal))
    if !ok {return}
    placed:=([^]Gpu_Decal)(rows.ptr)[:state.count]
    for item,i in state.items[:state.count] {placed[i]=decal_relative(item,pass.origin)}
    if state.material {decals_compose(pass,state.pipeline,rows,placed);return}
    render.pass_surface_begin(pass,{.Albedo,.Emission},"decals")
    render.pass_pipeline(pass,state.pipeline)
    render.pass_surface_read(pass,1,.Linear_Depth)
    render.pass_surface_read(pass,2,.Normal)
    render.pass_rows(pass,0,rows)
    render.pass_draw(pass,36,u32(state.count))
    render.pass_end(pass)
}
