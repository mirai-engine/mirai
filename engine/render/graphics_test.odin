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
a_scale_set_by_hand_is_used_as_it_is_and_zero_follows_the_target_of_the_preset :: proc(t:^testing.T) {
    g:=GRAPHICS_SETTINGS_DEFAULT
    settings:=gpu.DEFAULT_SETTINGS
    settings.render_scale=0.5
    s:=graphics_render_settings(settings,g,{type=.Discrete})
    testing.expect(t,s.render_scale==1 && s.render_height==1080)
    g.render_scale=0.5
    s=graphics_render_settings(settings,g,{type=.Discrete})
    testing.expect(t,s.render_scale==0.5 && s.render_height==0)
    testing.expect(t,s.sun_shadows)
    g.sun_shadows=false
    testing.expect(t,!graphics_render_settings(settings,g,{type=.Discrete}).sun_shadows)
    presets:=GRAPHICS_PRESETS
    for preset in Graphics_Preset {
        if preset>.Low {testing.expect(t,presets[preset].preset_height>=presets[preset-Graphics_Preset(1)].preset_height)}
    }
}

@(test)
setting_a_preset_applies_it_and_a_field_changed_by_hand_reads_as_custom :: proc(t:^testing.T) {
    presets:=GRAPHICS_PRESETS
    g:=GRAPHICS_SETTINGS_DEFAULT
    testing.expect_value(t,graphics_quality_of(g),Graphics_Quality.High)
    // A preset named over a scale set by hand: it follows the target of the preset again.
    seen:=g.quality
    g.render_scale,g.quality=0.5,.Low
    graphics_quality_settle(&g,seen)
    testing.expect(t,g.quality==.Low && g.render_scale==0 && g.preset_height==presets[.Low].preset_height && g.reflections==.Off)
    // A field changed by hand reads as Custom, and the target stays for the scale that follows it.
    seen=g.quality
    g.reflections=.Traced
    graphics_quality_settle(&g,seen)
    testing.expect(t,g.quality==.Custom && g.preset_height==presets[.Low].preset_height)
    // Back at the values of the preset, it reads as the preset again.
    seen=g.quality
    g.reflections=.Off
    graphics_quality_settle(&g,seen)
    testing.expect_value(t,g.quality,Graphics_Quality.Low)
    // Custom named by hand reads as what the fields are.
    seen=g.quality
    g.quality=.Custom
    graphics_quality_settle(&g,seen)
    testing.expect_value(t,g.quality,Graphics_Quality.Low)
    // A file that names a preset its fields are not at: applied when first read.
    fresh:=GRAPHICS_SETTINGS_DEFAULT
    fresh.quality=.Low
    graphics_quality_settle(&fresh,.Custom)
    testing.expect(t,fresh.quality==.Low && fresh.reflections==.Off)
}

@(test)
the_first_read_keeps_the_fields_of_a_project_over_the_default_and_applies_a_preset_it_names :: proc(t:^testing.T) {
    app:=new(host.App)
    defer free(app)
    own:=GRAPHICS_SETTINGS_DEFAULT
    own.shadowed_lights,own.glass_shadows,own.glass_layers=16,true,2
    sync:=new(Render_Sync)
    defer free(sync)
    graphics_apply(&own,sync,app)
    testing.expect(t,own.shadowed_lights==16 && own.glass_shadows && own.glass_layers==2 && own.quality==.Custom)
    named:=GRAPHICS_SETTINGS_DEFAULT
    named.quality=.Low
    other:=new(Render_Sync)
    defer free(other)
    graphics_apply(&named,other,app)
    testing.expect(t,named.quality==.Low && named.reflections==.Off)
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

@(test)
a_preset_keeps_a_pixel_per_point_within_the_lines_of_its_target :: proc(t:^testing.T) {
    presets:=GRAPHICS_PRESETS
    // At the window of the render check the presets it runs draw every pixel, as before.
    for preset in ([]Graphics_Preset{.Medium,.High,.Ultra}) {
        testing.expect_value(t,gpu.views_render_scale(1,presets[preset].preset_height,900,1),f32(1))
    }
    testing.expect_value(t,gpu.views_render_scale(1,presets[.Low].preset_height,900,1),f32(0.8))
    testing.expect_value(t,gpu.views_render_scale(1,presets[.High].preset_height,2160,1),f32(0.5))
    testing.expect_value(t,gpu.views_render_scale(0.5,0,2160,1),f32(0.5))
}
