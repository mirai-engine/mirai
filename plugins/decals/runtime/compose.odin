package decals

import "core:math"
import "core:math/linalg"
import render "mirai:engine/render"

@(private)
Decal_Region :: struct {
    rect:[4]i32,
    count:u32,
    pad:[3]u32,
}

@(private)
decal_screen_rect :: proc(pass:^render.Pass,item:Gpu_Decal) -> [4]i32 {
    size:=[2]f32{f32(pass.width),f32(pass.height)}
    lo,hi:[2]f32=max(f32),-max(f32)
    front,behind:=false,false
    for corner in 0..<8 {
        local:=[4]f32{f32(corner&1)-0.5,f32((corner>>1)&1)-0.5,f32(corner>>2)-0.5,1}
        world:=[3]f32{linalg.dot(item.to_world[0],local),linalg.dot(item.to_world[1],local),
                      linalg.dot(item.to_world[2],local)}-pass.camera.position
        clip:=pass.view_projection*[4]f32{world.x,world.y,world.z,1}
        if !(clip.w>0) {behind=true;continue}
        front=true
        pixel:=([2]f32{clip.x,-clip.y}/clip.w*0.5+0.5)*size+pass.jitter
        lo,hi=linalg.min(lo,pixel),linalg.max(hi,pixel)
    }
    if !front {return {}}
    // A box crossing the eye plane can cover any part of the view.
    if behind {return {0,0,i32(pass.width),i32(pass.height)}}
    return {i32(clamp(math.floor(lo.x)-1,0,size.x)),i32(clamp(math.floor(lo.y)-1,0,size.y)),
            i32(clamp(math.ceil(hi.x)+1,0,size.x)),i32(clamp(math.ceil(hi.y)+1,0,size.y))}
}

@(private)
decals_compose :: proc(
    pass:^render.Pass,compose:render.Pipeline,rows:render.Pass_Rows,placed:[]Gpu_Decal,
) {
    region:=Decal_Region{rect={i32(pass.width),i32(pass.height),0,0}}
    for &item in placed {
        item.rect=decal_screen_rect(pass,item)
        if item.rect.x>=item.rect.z || item.rect.y>=item.rect.w {continue}
        region.rect.xy=linalg.min(region.rect.xy,item.rect.xy)
        region.rect.zw=linalg.max(region.rect.zw,item.rect.zw)
        placed[region.count]=item
        region.count+=1
    }
    if region.count==0 {return}
    targets:=render.pass_surface_targets(pass)
    if targets=={} {return}
    reflectance:=.Reflectance in targets
    resolve:=render.pass_stage_pipeline(pass,{
        stage=.Surface,shader="decal_resolve",targets=targets,name="write decals",
        fragment="decal_resolve_reflectance" if reflectance else "",
    })
    if resolve==0 || !render.pass_params(pass,&region,size_of(region)) {return}
    scratch:=render.Pass_Texture_Desc{
        name="decal surface",format=.RGBA16_Float,width=pass.width,height=pass.height,
        layers=4,
    }
    if ok,_:=render.pass_texture(pass,5,scratch);!ok {return}
    render.pass_timestamp(pass,"compose decals")
    render.pass_pipeline(pass,compose)
    render.pass_rows(pass,0,rows)
    render.pass_surface_read(pass,1,.Linear_Depth)
    render.pass_surface_read(pass,2,.Normal)
    render.pass_surface_read(pass,3,.Albedo)
    render.pass_surface_read(pass,4,.Emission)
    extent:=region.rect.zw-region.rect.xy
    render.pass_dispatch(pass,u32((extent.x+DECAL_TILE-1)/DECAL_TILE),
                              u32((extent.y+DECAL_TILE-1)/DECAL_TILE))

    if !render.pass_texture_sample(pass,5,scratch) {return}
    render.pass_surface_begin(pass,targets,"write decals")
    render.pass_pipeline(pass,resolve)
    render.pass_scissor(pass,{region.rect.x,region.rect.y,extent.x,extent.y})
    render.pass_draw(pass,3)
    render.pass_end(pass)
}
