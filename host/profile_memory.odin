package host

import render "mirai:render"
import "mirai:platform"
import "mirai:rhi"

// The Memory track of a recording: what the process, the GPU and the pools of
// the renderer hold at the end of each frame, in bytes. A sample asks the
// system and the driver: it allocates nothing.

Profile_Memory_Frame :: struct {
    process:platform.Process_Memory,
    gpu_used,gpu_budget:u64, // of the device: what the process holds and what the system lets it hold; zeros when the driver does not say
    textures:u64,            // of the renderer: its textures
    geometry:u64,            // the pools of the geometry and the table of meshes
    geometry_free:u64,       // of those pools, the free ranges between meshes
    rays:u64,                // the acceleration structures
}

@(private)
profile_memory_sample :: proc(app:^App,m:^Profile_Memory_Frame) {
    m^={process=platform.process_memory()}
    if app.device!=nil {m.gpu_used,m.gpu_budget=rhi.device_memory(app.device)}
    if r:=app.renderer;r!=nil {
        stats:=render.renderer_stats(r)
        m.textures,m.geometry,m.geometry_free,m.rays=stats.texture_bytes,stats.geometry_bytes,stats.geometry_free,stats.ray_bytes
    }
}
