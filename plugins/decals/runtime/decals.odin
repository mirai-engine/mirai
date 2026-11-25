package decals

import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// The box is that of the entity: its sides are its scale. The image lies
// across the local Y axis, facing up it. It changes the surface under it as a
// material of Alpha_Mode.Decal does, before the surface is lit: what it
// writes, by its coverage (the alpha of its color and image, by its fade).
@(component,description="Projects a material along local Y inside the entity's box.")
Decal :: struct {
    color:[4]f32 `mirai:"color"`,    // multiplies the image; its alpha is the opacity
    texture:base.Asset_Id,           // a color image with alpha; none: the plain color
    emission:[3]f32 `mirai:"color"`, // what the surface emits under it, with Emission in writes: a luminance, nits
    fade:f32 `mirai:"min=0,max=1"`,  // facing below which the decal fades; 0 disables the fade
    order:i32,                       // of two decals over each other, the higher one is on top
    normal_map:base.Asset_Id,        // with Normal in writes: turns the normal of the surface, x along local X and y along local Z
    writes:asset.Decal_Writes,       // what it changes of the surface: Surface gives it roughness, metallic and an occlusion of 1
    roughness:f32 `mirai:"min=0,max=1"`,
    metallic:f32 `mirai:"min=0,max=1"`,
}

DECAL_DEFAULT :: Decal{color={1,1,1,1},fade=0.35,writes={.Color,.Normal}}

// decal_box.slang
@(private)
Gpu_Decal :: struct {
    to_box:[3][4]f32,   // from the world to its box
    to_world:[3][4]f32, // from its box to the world
    color:[4]f32,
    emission:[4]f32,    // rgb nits, a the fade
    texture:u32,
    normal_map:u32,
    density:f32,
    normal_density:f32,
    roughness,metallic:f32,
    writes:u32,         // asset.Decal_Writes; Normal only with a normal map
    pad:u32,
}
#assert(size_of(Gpu_Decal)==160)

@(private)
Sorted :: struct {order:i32,entity:core.Entity,row:int}

// What the renderer draws the decals of the frame with: as many as the world
// has, the lower ones first.
@(storage,host,free="decals_gpu_free")
Decals_Gpu :: struct {
    items:[dynamic]Gpu_Decal,
    sorted:[dynamic]Sorted,
    emission:bool, // one of them writes emission
}

decals_gpu_free :: proc(state:^Decals_Gpu) {
    if state==nil {return}
    delete(state.items)
    delete(state.sorted)
    state^={}
}

// The decals of the world into the frame, the lower ones first.
@(step="render",loops="game editor",after="render_sync")
decals_render :: proc(
    state:^Decals_Gpu,decals:^core.Table(Decal,.Read),
    worlds:^core.Table(core.World_Transform,.Read),hidden:^core.Table(render.Hidden,.Read),
    parents:^core.Table(core.Parent,.Read),assets:^host.Assets,renderer:^render.Renderer,
) {
    clear(&state.items)
    clear(&state.sorted)
    state.emission=false
    if assets==nil || core.count(decals)==0 {return}
    for row in 0..<core.count(decals) {
        e:=core.entity_at(decals,row)
        if !core.has(worlds,e) || render.is_hidden(hidden,parents,e) {continue}
        if _,error:=append(&state.sorted,Sorted{core.at(decals,row).order,e,row});error!=nil {break}
    }
    slice.sort_by(state.sorted[:],proc(a,b:Sorted) -> bool {
        return a.order<b.order || (a.order==b.order &&
            core.entity_index(a.entity)<core.entity_index(b.entity))
    })
    for item in state.sorted {
        decal:=core.at(decals,item.row)
        world,_:=core.get(worlds,item.entity)
        if !(abs(world.scale.x*world.scale.y*world.scale.z)>=1e-12) || decal.writes=={} {continue}
        to_world:=mm.transform_matrix(world.transform)
        entry:=Gpu_Decal{
            to_box=mm.mat4_rows(linalg.inverse(to_world)),to_world=mm.mat4_rows(to_world),
            color=decal.color,
            emission={decal.emission.x,decal.emission.y,decal.emission.z,decal.fade},
            texture=max(u32),normal_map=max(u32),
            roughness=clamp(decal.roughness,0,1),metallic=clamp(decal.metallic,0,1),
        }
        entry.texture,entry.density=decal_texture(assets,decal.texture,world.scale)
        entry.normal_map,entry.normal_density=decal_texture(assets,decal.normal_map,world.scale)
        writes:=decal.writes&asset.DECAL_WRITES_ALL
        if entry.normal_map==max(u32) {writes-={.Normal}}
        if writes=={} {continue}
        entry.writes=u32(transmute(u8)writes)
        state.emission||=.Emission in writes
        if _,error:=append(&state.items,entry);error!=nil {break}
    }
    host.assets_commit(assets)
    decals_submit(state,renderer)
}

// The Decal stage of the next frame draws the decals of state.
@(private)
decals_submit :: proc(state:^Decals_Gpu,renderer:^render.Renderer) {
    if len(state.items)==0 {return}
    if state.emission {render.frame_decal_emission(renderer)}
    render.frame_pass(renderer,.Decal,decals_record,state)
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

// The box of each decal into the decal targets of the view, after the decals
// of the scene: the pixels it covers find the surface under them from the
// depth of the view.
@(private)
decals_record :: proc(pass:^render.Pass,user:rawptr) {
    state:=cast(^Decals_Gpu)user
    count:=len(state.items)
    targets:=render.pass_decal_targets(pass)
    pipeline:=render.pass_stage_pipeline(pass,{
        stage=.Decal,shader="decal_box",fragment="decal_box_emissive" if .Emission in targets else "",
        targets=targets,blend=.Premultiplied,name="projected decals",
    })
    if pipeline==0 || count==0 {return}
    rows,ok:=render.pass_rows_upload(pass,raw_data(state.items),count*size_of(Gpu_Decal))
    if !ok {return}
    placed:=([^]Gpu_Decal)(rows.ptr)[:count]
    for item,i in state.items {placed[i]=decal_relative(item,pass.origin)}
    render.pass_decal_begin(pass,"projected decals")
    render.pass_pipeline(pass,pipeline)
    render.pass_surface_read(pass,1,.Depth)
    render.pass_rows(pass,0,rows)
    render.pass_draw(pass,36,u32(count))
    render.pass_end(pass)
}
