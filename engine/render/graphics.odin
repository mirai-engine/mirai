package render

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
// How far meshes keep their detail: GRAPHICS_DETAIL_PIXELS.
Detail :: enum u8 {Low,Medium,High,Ultra}
Reflections :: enum u8 {
    Off,      // the probe volume reflects
    Traced,   // smooth surfaces trace their reflection; the rough ones take the light of what it meets from the probe volume
    Detailed, // and sharp ones show the glass and the gloss of what they reflect
}

@(storage,setting="machine")
Graphics_Settings :: struct {
    render_megapixels:f32 `mirai:"min=0,max=100,section=Resolution"`, // the most pixels of the 3D image, in millions, below one per point of the window; 0: one per point
    antialiasing:[gpu.ANTIALIASING_NAME_BYTES]u8 `mirai:"text"`, // the technique that resolves the image and upscales it: "off", "taa" or one a plugin offers (antialiasing_offer); one no plugin resolves is the TAA
    indirect_light:Indirect_Light `mirai:"section=Lighting"`,
    light_probes:Light_Probes,
    reflections:Reflections,
    light_samples:u32 `mirai:"min=1,max=31"`,   // samples of the direct light of a pixel, spread over its lights by what each gives it (GRAPHICS_LIGHT_SAMPLES_MAX)
    light_half_resolution:bool,               // the samples of the direct light are taken at one pixel of each 2x2, and the others take theirs by their surfaces
    glass_shadows:bool,                        // blended surfaces color the light that crosses them
    glass_layers:u32 `mirai:"min=1,max=2"`,
    textures:Textures `mirai:"section=Detail"`,
    detail:Detail,
    frame_limit:u32 `mirai:"section=Frames"`, // frames per second; 0: none
    vsync:bool,
    frame_generation:bool,                     // a technique that generates frames (FSR 3.1) shows one between each two, with the memory of its passes and half a frame more of latency; frame_limit and vsync count the frames shown
    show_fps:bool,                             // the frames per second in the editor and the game
    texture_memory:u32 `mirai:"min=0,max=65536,unit=MB,section=Memory,advanced"`, // GPU memory of textures, past which they load without their largest levels; 0: a share of the device's (GRAPHICS_TEXTURE_POOL_SHARE)
    geometry_memory:u32 `mirai:"min=0,max=4096,unit=MB,advanced"`, // GPU memory of the pages of streamed meshes, taken when the first one loads: a later change waits until the renderer starts again; 0: that of gpu.DEFAULT_SETTINGS
}

// Without a device: the High preset.
GRAPHICS_SETTINGS_DEFAULT :: Graphics_Settings{
    render_megapixels=2.0736,antialiasing={0='t',1='a',2='a'},indirect_light=.Probes,light_probes=.High,reflections=.Detailed,
    light_samples=15,light_half_resolution=true,glass_shadows=true,glass_layers=1,textures=.High,detail=.High,frame_limit=60,vsync=true,frame_generation=true,show_fps=true,
}

Graphics_Preset :: enum u8 {Low,Medium,High,Ultra}
// Of each preset only the fields of the quality count: graphics_preset_apply.
// The resolution and the technique of antialiasing are not of them: a preset
// leaves them as they are.
GRAPHICS_PRESETS :: [Graphics_Preset]Graphics_Settings{
    .Low   ={indirect_light=.Probes,light_probes=.Low,reflections=.Off,light_samples=7,light_half_resolution=true,glass_layers=1,textures=.Low,detail=.Low},
    .Medium={indirect_light=.Probes,light_probes=.Medium,reflections=.Traced,light_samples=15,light_half_resolution=true,glass_layers=1,textures=.Medium,detail=.Medium},
    .High  ={indirect_light=.Probes,light_probes=.High,reflections=.Detailed,light_samples=15,light_half_resolution=true,glass_shadows=true,glass_layers=1,textures=.High,detail=.High,frame_generation=true},
    .Ultra ={indirect_light=.Probes,light_probes=.High,reflections=.Detailed,light_samples=31,glass_shadows=true,glass_layers=2,textures=.Ultra,detail=.Ultra,frame_generation=true},
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

// Gives the fields of the quality the values of the preset; the others stay.
graphics_preset_apply :: proc(g:^Graphics_Settings,preset:Graphics_Preset) {
    presets:=GRAPHICS_PRESETS
    p:=presets[preset]
    g.indirect_light,g.light_probes,g.reflections=p.indirect_light,p.light_probes,p.reflections
    g.light_samples,g.glass_shadows,g.glass_layers=p.light_samples,p.glass_shadows,p.glass_layers
    g.light_half_resolution=p.light_half_resolution
    g.textures,g.detail=p.textures,p.detail
    g.frame_generation=p.frame_generation
}

// The resolution of the default of a small device: the pixels of a 16:9 image 900 tall.
GRAPHICS_SMALL_DEVICE_MEGAPIXELS :: f32(1.44)

// The default on a device: Medium at GRAPHICS_SMALL_DEVICE_MEGAPIXELS on a GPU
// without hardware ray tracing or an integrated one, High on the others.
graphics_settings_for_device :: proc(device:rhi.Device_Info) -> Graphics_Settings {
    g:=GRAPHICS_SETTINGS_DEFAULT
    if !device.features.ray_query || device.type==.Integrated {
        graphics_preset_apply(&g,.Medium)
        g.render_megapixels=GRAPHICS_SMALL_DEVICE_MEGAPIXELS
    }
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
    s.render_scale,s.render_megapixels=1,max(quality.render_megapixels,0)
    // A plugin that resolves the technique replaces the Resolve stage, where the TAA runs, in its pipeline.
    technique:=quality.antialiasing
    s.taa=base.text_get(technique[:])!=gpu.ANTIALIASING_OFF
    s.gi_enabled=quality.indirect_light!=.Off
    s.probe_budget,s.probe_rays=probes[quality.light_probes][0],probes[quality.light_probes][1]
    // The finest cascade reaches 15 m from the eye: what changes where it hands over to the next is far.
    if quality.light_probes==.High {s.probe_grid=32}
    s.reflections=quality.reflections!=.Off
    s.reflection_detail_roughness=quality.reflections==.Detailed?gpu.REFLECTION_SHARED_ROUGHNESS:0
    s.direct_samples=clamp(quality.light_samples,1,GRAPHICS_LIGHT_SAMPLES_MAX)
    s.direct_half_resolution=quality.light_half_resolution
    s.shadow_maps=true
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
graphics_apply :: proc(graphics:Graphics_Settings,sync:^Render_Sync,app:^host.App) {
    if sync.graphics_applied && sync.graphics==graphics {return}
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
    sync.graphics,sync.graphics_applied=graphics,true
}
