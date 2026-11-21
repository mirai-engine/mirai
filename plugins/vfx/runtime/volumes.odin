package vfx

import "core:math/linalg"
import "core:slice"
import erender "mirai:engine/render"
import mm "mirai:std/math"

// The volumes of a world (Particle_Volume): the light of their cells once a
// frame, after the steps, and in each view their media over the lit scene,
// before the sprites, on the side of glass of the pass.

// The light each cell of each volume receives, kept over frames: a local
// light a frame by turns adds up to all of them.
@(private)
volumes_light :: proc(sync:^Particle_Sync,pass:^erender.Pass,params:^Simulate_Params) {
    pool:=&sync.pool
    if pool.volume_count==0 {return}
    erender.pass_pipeline(pass,sync.pipelines.volume_light)
    params.mode,params.count,params.stage=0,pool.volume_cells,pool.volumes_at
    erender.pass_params(pass,params,size_of(params^))
    erender.pass_dispatch(pass,groups(pool.volume_cells,64),pool.volume_count)
    params.stage=0
}

// The media of the volumes, marched from the camera to the scene behind them.
@(private)
particles_volumes :: proc(pass:^erender.Pass,user:rawptr) {
    sync:=cast(^Particle_Sync)user
    pool:=&sync.pool
    if pass.world!=sync.world || pool.volume_count==0 || !pool_drawable(pass,sync) {return}
    draws:[GRID_CAPACITY]Pool_Draw
    count,index:=0,u32(0)
    frustum:=mm.frustum_from_matrix(pass.view_projection)
    for &entry in sync.grids.entries {
        if !entry.has_volume {continue}
        at:=pool.volumes_at+index*size_of(Gpu_Volume)
        index+=1
        low:=erender.origin_cell(entry.first,f64(entry.cell_size),pass.origin)
        high:=low+[3]f32{f32(entry.cells.x),f32(entry.cells.y),f32(entry.cells.z)}*entry.cell_size
        low-=pass.camera.position
        high-=pass.camera.position
        if !mm.frustum_overlaps_aabb(frustum,{low,high}) {continue}
        draws[count]={at,linalg.dot((low+high)*0.5,pass.camera.forward)}
        count+=1
    }
    if count==0 {return}
    slice.sort_by(draws[:count],proc(a,b:Pool_Draw) -> bool {return a.distance>b.distance})
    media:=erender.pass_media(pass,MEDIA_SLOT)
    erender.pass_blend_begin(pass,"particle volumes")
    pool_bind_frame(pass,sync)
    erender.pass_surface_read(pass,7,.Linear_Depth)
    erender.pass_surface_read(pass,8,.Glass_Depth)
    erender.pass_pipeline(pass,sync.pipelines.volume)
    Params :: struct {volume,pass:u32,pad:[2]u32,media:erender.Media_Grid}
    for draw in draws[:count] {
        params:=Params{volume=draw.slot,pass=u32(pass.glass),media=media}
        erender.pass_params(pass,&params,size_of(params))
        erender.pass_draw(pass,36)
    }
    erender.pass_end(pass)
}
