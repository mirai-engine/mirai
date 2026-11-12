package render

import "mirai:core"
import "mirai:host"
import "mirai:platform"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:std/base"

// How the project is drawn: the quality of the renderer, the memory it takes
// and the pacing of the frames, a setting of the machine. The game draws with
// it and the editor too, whose Graphics popup changes it. Its default depends on the GPU
// (graphics_settings_for_device). A device that renders on the CPU keeps its
// reduced budgets and takes only the pacing.

Indirect_Light :: enum u8 {
    Off,
    Probes, // the probe volume, darkened at contact by short traced rays
}
Light_Probes :: enum u8 {Low,Medium,High}
// The largest side of a texture: GRAPHICS_TEXTURE_SIZES.
Textures :: enum u8 {Low,Medium,High,Ultra}
// How far meshes keep their detail (GRAPHICS_DETAIL_PIXELS), and how far and dense a
// plugin draws the scattered detail of a scene (foliage).
Detail :: enum u8 {Low,Medium,High,Ultra}

@(storage,shared,setting="machine")
Graphics_Settings :: struct {
    resolution:u32 `mirai:"min=1,max=16384,section=Resolution,graphics=Resolution,choices=720|900|1080|1440|2160"`, // the lines the views of the window aim for together, never above one pixel per point (gpu.Settings.resolution)
    antialiasing:[gpu.ANTIALIASING_NAME_BYTES]u8 `mirai:"text,graphics=Antialiasing"`, // the technique that resolves the image and upscales it: "off", "taa" or one a plugin offers (antialiasing_offer); one no plugin resolves is the TAA
    indirect_light:Indirect_Light `mirai:"section=Lighting,graphics=Indirect light"`,
    light_probes:Light_Probes `mirai:"graphics=Light probes"`,
    reflections:gpu.Reflections `mirai:"graphics=Reflections"`, // off unless chosen: no preset changes it
    sun_shadows:bool,                          // the sun casts shadows; off, it lights everything it faces
    light_samples:u32 `mirai:"min=1,max=31,graphics=Light samples,choices=7|15|31"`, // samples of the direct light of a pixel, spread over its lights by what each gives it (GRAPHICS_LIGHT_SAMPLES_MAX)
    light_half_resolution:bool `mirai:"graphics=Light resolution,choices=Full|Half"`, // the samples of the direct light are taken at one pixel of each 2x2, and the others take theirs by their surfaces
    glass_shadows:bool `mirai:"graphics=Glass shadows,choices=Off|Colored"`, // blended surfaces color the light that crosses them
    glass_layers:u32 `mirai:"min=1,max=2,graphics=Glass layers,choices=1|2"`,
    textures:Textures `mirai:"section=Detail,graphics=Textures,choices=1K|2K|4K|8K"`,
    detail:Detail `mirai:"graphics=Detail"`,
    frame_limit:u32 `mirai:"section=Frames,graphics=Frame limit,choices=30|60|120|144|240|Off:0"`, // frames per second; 0: none
    vsync:bool `mirai:"graphics=VSync"`,
    frame_generation:bool `mirai:"graphics=Frame generation"`, // a technique that generates frames (FSR 3.1) shows one between each two, with the memory of its passes and half a frame more of latency; frame_limit and vsync count the frames shown
    show_fps:bool `mirai:"graphics=Show FPS"`, // the frames per second in the editor and the game
    texture_memory:u32 `mirai:"min=0,max=65536,unit=MB,section=Memory,advanced"`, // GPU memory of textures, past which they load without their largest levels; 0: a share of the device's (GRAPHICS_TEXTURE_POOL_SHARE)
    geometry_memory:u32 `mirai:"min=0,max=4096,unit=MB,advanced"`, // GPU memory of the pages of streamed meshes, taken when the first one loads: a later change waits until the renderer starts again; 0: that of gpu.DEFAULT_SETTINGS
}

// Without a device: the High preset.
GRAPHICS_SETTINGS_DEFAULT :: Graphics_Settings{
    resolution=1080,antialiasing={0='t',1='a',2='a'},indirect_light=.Probes,light_probes=.High,
    sun_shadows=true,light_samples=15,light_half_resolution=true,glass_shadows=true,glass_layers=1,textures=.High,detail=.High,frame_limit=60,vsync=true,frame_generation=true,show_fps=true,
}

// The presets, in their order, and Custom: none. No setting stores one: a
// preset is the values graphics_preset_apply writes, and the one the fields
// are at is graphics_quality_of.
Graphics_Quality :: enum u8 {Low,Medium,High,Ultra,Custom}
// Of each preset only the fields of the quality count: graphics_preset_apply.
// The technique of antialiasing is not one of them: it is the same in all.
GRAPHICS_PRESETS :: #partial [Graphics_Quality]Graphics_Settings{
    .Low   ={resolution=720,sun_shadows=true,indirect_light=.Probes,light_probes=.Low,light_samples=7,light_half_resolution=true,glass_layers=1,textures=.Low,detail=.Low},
    .Medium={resolution=900,sun_shadows=true,indirect_light=.Probes,light_probes=.Medium,light_samples=15,light_half_resolution=true,glass_layers=1,textures=.Medium,detail=.Medium},
    .High  ={resolution=1080,sun_shadows=true,indirect_light=.Probes,light_probes=.High,light_samples=15,light_half_resolution=true,glass_shadows=true,glass_layers=1,textures=.High,detail=.High,frame_generation=true},
    .Ultra ={resolution=1440,sun_shadows=true,indirect_light=.Probes,light_probes=.High,light_samples=31,glass_shadows=true,glass_layers=2,textures=.Ultra,detail=.Ultra,frame_generation=true},
}

// The frames per second of its own a game needs under generated ones (AMD's
// minimum for FSR 3): fewer judder and lag behind the input.
FRAME_GENERATION_BASE_MIN :: f32(60)

// Whether a technique that generates frames should: the settings ask for it
// and the frames shown are not capped (by VSync on the refresh of the display,
// or by the frame limit) below twice FRAME_GENERATION_BASE_MIN, which would
// leave the game fewer of its own.
graphics_generates :: proc(graphics:Graphics_Settings,app:^host.App) -> bool {
    if !graphics.frame_generation {return false}
    if !app.paced || app.platform==nil {return true}
    shown:=f32(graphics.frame_limit)
    if refresh:=platform.window_refresh_rate(app.platform);graphics.vsync && refresh>0 && (shown==0 || refresh<shown) {shown=refresh}
    return shown==0 || shown>=2*FRAME_GENERATION_BASE_MIN-0.5
}

// What names a preset (a control, a layer of the settings, the code of a
// game): gives the fields of the quality its values; the others stay. Custom is none and changes nothing.
graphics_preset_apply :: proc(g:^Graphics_Settings,preset:Graphics_Quality) {
    if preset==.Custom {return}
    presets:=GRAPHICS_PRESETS
    p:=presets[preset]
    g.resolution=p.resolution
    g.sun_shadows=p.sun_shadows
    g.indirect_light,g.light_probes=p.indirect_light,p.light_probes
    g.light_samples,g.glass_shadows,g.glass_layers=p.light_samples,p.glass_shadows,p.glass_layers
    g.light_half_resolution=p.light_half_resolution
    g.textures,g.detail=p.textures,p.detail
    g.frame_generation=p.frame_generation
}

// The preset the fields of g are at, or Custom: what a control shows, computed
// when it is read.
graphics_quality_of :: proc(g:Graphics_Settings) -> Graphics_Quality {
    for preset in Graphics_Quality {
        at:=g
        graphics_preset_apply(&at,preset)
        if preset!=.Custom && at==g {return preset}
    }
    return .Custom
}

// The default on a device: Medium on a GPU without hardware ray tracing or an
// integrated one, High on the others.
graphics_settings_for_device :: proc(device:rhi.Device_Info) -> Graphics_Settings {
    g:=GRAPHICS_SETTINGS_DEFAULT
    if !device.features.ray_query || device.type==.Integrated {graphics_preset_apply(&g,.Medium)}
    return g
}

GRAPHICS_PROBES :: [Light_Probes][2]u32{.Low={128,64},.Medium={256,96},.High={512,256}} // probes traced per frame, rays of each
GRAPHICS_REFLECTION_LIGHTS :: u32(8)
// The most samples of the direct light of a pixel: past it the image of a thousand lights does not change.
GRAPHICS_LIGHT_SAMPLES_MAX :: 31
GRAPHICS_TEXTURE_SIZES :: [Textures]u32{.Low=1024,.Medium=2048,.High=4096,.Ultra=8192}
GRAPHICS_DETAIL_PIXELS :: [Detail]f32{.Low=4,.Medium=2,.High=1,.Ultra=0.5} // of error on the screen before a mesh takes a simpler level
// Of the memory of the device, what textures take; the rest is for the targets, the scene and its structures.
GRAPHICS_TEXTURE_POOL_SHARE :: 0.4
GRAPHICS_TEXTURE_POOL_MIN :: u32(256)

// The settings of the renderer that quality stands for on a device, over the others it has.
graphics_render_settings :: proc(settings:gpu.Settings,quality:Graphics_Settings,device:rhi.Device_Info) -> gpu.Settings {
    s:=settings
    probes,sizes,pixels:=GRAPHICS_PROBES,GRAPHICS_TEXTURE_SIZES,GRAPHICS_DETAIL_PIXELS
    s.resolution=max(quality.resolution,1)
    // A plugin that resolves the technique replaces the Resolve stage, where the TAA runs, in its pipeline.
    technique:=quality.antialiasing
    s.taa=base.text_get(technique[:])!=gpu.ANTIALIASING_OFF
    s.gi_enabled=quality.indirect_light!=.Off
    s.probe_budget,s.probe_rays=probes[quality.light_probes][0],probes[quality.light_probes][1]
    // The finest cascade reaches 15 m from the eye: what changes where it hands over to the next is far.
    if quality.light_probes==.High {s.probe_grid=32}
    s.reflections=quality.reflections
    s.sun_shadows=quality.sun_shadows
    s.direct_samples=clamp(quality.light_samples,1,GRAPHICS_LIGHT_SAMPLES_MAX)
    s.direct_half_resolution=quality.light_half_resolution
    s.reflection_light_budget=min(s.light_budget,GRAPHICS_REFLECTION_LIGHTS)
    s.colored_shadows=quality.glass_shadows
    s.glass_layers=clamp(quality.glass_layers,1,gpu.GLASS_LAYERS_MAX)
    s.texture_max_size=sizes[quality.textures]
    s.lod_error_pixels=pixels[quality.detail]
    switch {
    case quality.texture_memory>0: s.texture_pool_megabytes=quality.texture_memory
    case device.memory>0:          s.texture_pool_megabytes=max(u32(f64(device.memory)*GRAPHICS_TEXTURE_POOL_SHARE/(1024*1024)),GRAPHICS_TEXTURE_POOL_MIN)
    case:                          s.texture_pool_megabytes=gpu.DEFAULT_SETTINGS.texture_pool_megabytes
    }
    s.page_pool_bytes=quality.geometry_memory>0?u64(quality.geometry_memory)<<20:gpu.DEFAULT_SETTINGS.page_pool_bytes
    return s
}

// Brings the renderer and the pacing to the graphics settings of the world when they change.
@(step="render",loops="game editor",before="render_sync")
graphics_apply :: proc(settings:core.Ref(Graphics_Settings),sync:^Render_Sync,app:^host.App) {
    graphics:=settings.ptr^
    if sync.graphics_applied && sync.graphics==graphics && sync.paced==app.paced {return}
    r:=app.renderer
    if r!=nil && rhi.device_info(r.device).type!=.CPU {
        before:=r.settings
        gpu.renderer_apply_settings(r,graphics_render_settings(r.settings,graphics,rhi.device_info(r.device)^))
        // Loaded textures keep the levels they were loaded with until they are loaded again.
        if app.assets!=nil && (r.settings.texture_max_size!=before.texture_max_size || r.settings.texture_pool_megabytes!=before.texture_pool_megabytes) {host.assets_textures_reload(app.assets,before)}
    }
    if app.paced {
        pacing:=platform.Frame_Pacing{limit=graphics.frame_limit,vsync=graphics.vsync}
        if app.device!=nil && pacing.vsync!=platform.pacing(app.platform).vsync {rhi.swapchain_set_vsync(app.device,pacing.vsync)}
        platform.set_pacing(app.platform,pacing)
    }
    sync.graphics,sync.paced=graphics,app.paced
    sync.graphics_applied=true
}
