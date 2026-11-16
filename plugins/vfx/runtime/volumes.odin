package vfx

import erender "mirai:engine/render"

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
    media:=erender.pass_media(pass,MEDIA_SLOT)
    erender.pass_blend_begin(pass,"particle volumes")
    pool_bind_frame(pass,sync)
    erender.pass_surface_read(pass,7,.Linear_Depth)
    erender.pass_surface_read(pass,8,.Glass_Depth)
    erender.pass_pipeline(pass,sync.pipelines.volume)
    Params :: struct {volumes,count,pass,pad:u32,media:erender.Media_Grid}
    params:=Params{pool.volumes_at,pool.volume_count,u32(pass.glass),0,media}
    erender.pass_params(pass,&params,size_of(params))
    erender.pass_draw(pass,3)
    erender.pass_end(pass)
}
