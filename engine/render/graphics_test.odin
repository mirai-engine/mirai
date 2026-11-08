package render

import "core:testing"
import gpu "mirai:render"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:rhi"

@(test)
graphics_default_is_medium_on_a_gpu_without_hardware_ray_tracing_or_integrated :: proc(t:^testing.T) {
    medium:=GRAPHICS_SETTINGS_DEFAULT
    graphics_preset_apply(&medium,.Medium)
    testing.expect_value(t,graphics_settings_for_device({type=.Discrete,features={ray_query=true}}),GRAPHICS_SETTINGS_DEFAULT)
    for device in ([]rhi.Device_Info{{type=.Discrete},{type=.Integrated,features={ray_query=true}},{type=.Integrated}}) {
        testing.expect_value(t,graphics_settings_for_device(device),medium)
    }
    testing.expect_value(t,medium.frame_limit,GRAPHICS_SETTINGS_DEFAULT.frame_limit)
    // Frame generation takes memory the low presets do not give it.
    presets:=GRAPHICS_PRESETS
    for preset in Graphics_Preset {testing.expect_value(t,presets[preset].frame_generation,preset>=.High)}
    testing.expect(t,!medium.frame_generation && GRAPHICS_SETTINGS_DEFAULT.frame_generation)
}

@(test)
frame_generation_waits_for_a_cap_that_leaves_sixty_frames_of_the_game :: proc(t:^testing.T) {
    cases:=[?]struct{vsync:bool,limit:u32,refresh:f32,generates:bool}{
        {vsync=true,refresh=60,generates=false},
        {vsync=true,refresh=144,generates=true},
        {vsync=true,limit=60,refresh=144,generates=false},
        {vsync=false,limit=60,refresh=60,generates=false},
        {vsync=false,refresh=60,generates=true},
        {vsync=true,limit=240,refresh=119.88,generates=true},
    }
    for c in cases {
        p:platform.Platform
        p.window.refresh_hz=c.refresh
        app:=host.App{paced=true,platform=&p}
        g:=GRAPHICS_SETTINGS_DEFAULT
        g.vsync,g.frame_limit=c.vsync,c.limit
        testing.expectf(t,graphics_generates(g,&app)==c.generates,"%v",c)
        g.frame_generation=false
        testing.expect(t,!graphics_generates(g,&app))
    }
}

@(test)
graphics_default_without_a_device_is_the_high_preset :: proc(t:^testing.T) {
    high:=GRAPHICS_SETTINGS_DEFAULT
    graphics_preset_apply(&high,.High)
    testing.expect_value(t,high,GRAPHICS_SETTINGS_DEFAULT)
}

@(test)
resolution_is_a_budget_of_pixels_under_one_per_point :: proc(t:^testing.T) {
    g:=GRAPHICS_SETTINGS_DEFAULT
    settings:=gpu.DEFAULT_SETTINGS
    settings.render_scale=0.5
    s:=graphics_render_settings(settings,g,{type=.Discrete})
    testing.expect(t,s.render_scale==1 && s.render_megapixels==2.0736)
    g.render_megapixels=0
    testing.expect_value(t,graphics_render_settings(settings,g,{type=.Discrete}).render_megapixels,f32(0))
    g.render_scale=0.5
    testing.expect_value(t,graphics_render_settings(settings,g,{type=.Discrete}).render_scale,f32(0.5))
    g.render_scale=0
    testing.expect_value(t,graphics_render_settings(settings,g,{type=.Discrete}).render_scale,f32(1))
    testing.expect(t,graphics_render_settings(settings,g,{type=.Discrete}).sun_shadows)
    g.sun_shadows=false
    testing.expect(t,!graphics_render_settings(settings,g,{type=.Discrete}).sun_shadows)
    presets:=GRAPHICS_PRESETS
    for preset in Graphics_Preset {
        if preset>.Low {testing.expect(t,presets[preset].render_megapixels>=presets[preset-Graphics_Preset(1)].render_megapixels)}
    }
}

@(test)
textures_and_detail_set_the_limits_of_the_renderer_and_the_pool_follows_the_memory :: proc(t:^testing.T) {
    g:=GRAPHICS_SETTINGS_DEFAULT
    g.textures,g.detail=.Low,.Ultra
    s:=graphics_render_settings(gpu.DEFAULT_SETTINGS,g,{type=.Discrete,memory=8<<30})
    testing.expect_value(t,s.texture_max_size,u32(1024))
    testing.expect_value(t,s.lod_error_pixels,f32(0.5))
    testing.expect_value(t,s.texture_pool_megabytes,u32(3276))
    small:=graphics_render_settings(gpu.DEFAULT_SETTINGS,g,{type=.Integrated,memory=256<<20})
    testing.expect_value(t,small.texture_pool_megabytes,GRAPHICS_TEXTURE_POOL_MIN)
    unknown:=graphics_render_settings(gpu.DEFAULT_SETTINGS,g,{type=.Discrete})
    testing.expect_value(t,unknown.texture_pool_megabytes,gpu.DEFAULT_SETTINGS.texture_pool_megabytes)
}

@(test)
memory_chosen_in_megabytes_replaces_the_automatic_pools_and_no_preset_touches_it :: proc(t:^testing.T) {
    g:=GRAPHICS_SETTINGS_DEFAULT
    g.texture_memory,g.geometry_memory=1500,512
    settings:=gpu.DEFAULT_SETTINGS
    settings.page_pool_bytes=64<<20
    s:=graphics_render_settings(settings,g,{type=.Discrete,memory=8<<30})
    testing.expect_value(t,s.texture_pool_megabytes,u32(1500))
    testing.expect_value(t,s.page_pool_bytes,u64(512)<<20)
    // Back to 0, the pools are automatic again, whatever the renderer had.
    g.texture_memory,g.geometry_memory=0,0
    s=graphics_render_settings(s,g,{type=.Discrete,memory=8<<30})
    testing.expect_value(t,s.texture_pool_megabytes,u32(3276))
    testing.expect_value(t,s.page_pool_bytes,gpu.DEFAULT_SETTINGS.page_pool_bytes)
    s=graphics_render_settings(settings,g,{type=.Discrete})
    testing.expect_value(t,s.texture_pool_megabytes,gpu.DEFAULT_SETTINGS.texture_pool_megabytes)
    g.texture_memory,g.geometry_memory=1500,512
    for preset in Graphics_Preset {
        graphics_preset_apply(&g,preset)
        testing.expect(t,g.texture_memory==1500 && g.geometry_memory==512)
    }
}

@(test)
display_settings_left_at_zero_are_the_window_the_project_opened :: proc(t:^testing.T) {
    opened:=platform.Window_Desc{size={1280,720},maximized=true}
    mode,size:=display_target({},opened)
    testing.expect(t,mode==.Maximized && size==[2]i32{1280,720})
    mode,size=display_target({mode=.Windowed,width=1600},opened)
    testing.expect(t,mode==.Windowed && size==[2]i32{1600,720})
    mode,size=display_target({mode=.Fullscreen,width=100000,height=900},opened)
    testing.expect(t,mode==.Fullscreen && size==[2]i32{project.MAX_WINDOW_SIDE,900})
    mode,size=display_target({},{fullscreen=true})
    testing.expect(t,mode==.Fullscreen && size==platform.WINDOW_SIZE_DEFAULT)
    mode,_=display_target({},{})
    testing.expect_value(t,mode,Display_Mode.Windowed)
}
