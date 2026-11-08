package game

import "mirai:core"
import gui "mirai:engine/gui"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"

// The shell of the game: main menu, pause and graphics settings, with mouse
// and keyboard. assets/ui/shell.ui (tools/content writes it) is one screen with
// a page per Shell_Page; Shell.page says which shows, and shell_frame is the
// only code that changes it. Add a screen by adding a member of Shell_Page and
// a page named like it there.
//
// Settings have one route: the player's choices are Shell_Options, which the
// profile keeps by itself (@(storage,persist)), and shell_apply turns them into
// Graphics_Settings and Display_Settings. Nothing else writes those two.

// The options of each selector of the settings page, in the order tools/content writes them.
SHELL_SCALES :: [3]f32{0.5,0.75,1}         // Render scale
SHELL_SHADOW_RAYS :: [4]u32{1,2,4,8}       // Shadows, Off to High; Off also takes the rays of the sun away
SHELL_FRAME_LIMITS :: [4]u32{30,60,120,0}  // Frame limit, 0: none

// What each quality preset sets of the options; Custom keeps what they hold.
Shell_Quality :: struct {scale,shadows,antialiasing:i32,reflections:render.Reflections}
SHELL_QUALITIES :: [Shell_Preset]Shell_Quality{
    .Low   ={scale=0,shadows=1,antialiasing=1,reflections=.Off},
    .Medium={scale=1,shadows=2,antialiasing=1,reflections=.Traced},
    .High  ={scale=2,shadows=3,antialiasing=1,reflections=.Detailed},
    .Custom={},
}

// The pages of shell.ui: its Switcher shows the page named like the member.
// While Playing there is none and the screen is hidden.
Shell_Page :: enum i32 {Menu,Pause,Settings,Playing}

Shell_Preset :: enum i32 {Low,Medium,High,Custom}

// On the entity that shows shell.ui.
@(component)
Shell_Screen :: struct {}

// On the HUD, which the main menu hides.
@(component)
Shell_Hud :: struct {}

// Quit to Menu loads a scene, and this stays for the next one.
@(storage,keep)
Shell :: struct {
    page:Shell_Page,
    captured:bool, // the mouse is held by the game
    applied:bool,  // Shell_Options reached the engine
}

// What the player chose: indices of the SHELL_ tables, and the fields the settings page binds.
@(storage,persist)
Shell_Options :: struct {
    chosen:bool,                 // false on a first run, which takes the preset the engine gives this machine
    preset:Shell_Preset,
    base:render.Graphics_Preset, // what the fields without a selector follow, under Custom too
    scale,shadows,antialiasing,limit:i32,
    reflections:render.Reflections,
    fullscreen,vsync:bool,
}

SHELL_OPTIONS_DEFAULT :: Shell_Options{preset=.High,base=.High,scale=2,shadows=3,antialiasing=1,limit=1,reflections=.Detailed,vsync=true}

@(private="file")
shell_preset_take :: proc(options:^Shell_Options,preset:Shell_Preset) {
    options.preset=preset
    if preset==.Custom {return}
    qualities:=SHELL_QUALITIES
    quality:=qualities[preset]
    options.base=render.Graphics_Preset(i32(preset))
    options.scale,options.shadows,options.antialiasing,options.reflections=quality.scale,quality.shadows,quality.antialiasing,quality.reflections
}

// Brings the engine to the options, at once.
@(private="file")
shell_apply :: proc(options:Shell_Options,graphics:^render.Graphics_Settings,display:^render.Display_Settings) {
    scales,rays,limits:=SHELL_SCALES,SHELL_SHADOW_RAYS,SHELL_FRAME_LIMITS
    g:=graphics^
    render.graphics_preset_apply(&g,options.base)
    g.render_scale,g.render_megapixels=scales[clamp(options.scale,0,len(scales)-1)],0 // no cap: the scale is what the player gets
    g.sun_shadows=options.shadows>0
    g.shadowed_lights=rays[clamp(options.shadows,0,len(rays)-1)]
    g.reflections=options.reflections
    g.frame_limit,g.vsync=limits[clamp(options.limit,0,len(limits)-1)],options.vsync
    base.text_set(g.antialiasing[:],options.antialiasing==0?render.ANTIALIASING_OFF:render.ANTIALIASING_TAA)
    graphics^=g
    display.mode=options.fullscreen?.Fullscreen:.Project
}

// What shell.ui asked for in this frame; true when it changed an option.
@(private="file")
shell_events :: proc(events:[]gui.UI_Event,screen:core.Entity,shell:^Shell,options:^Shell_Options,solo:bool,scenes:^scene.Scene_Requests,app:^host.App) -> (changed:bool) {
    if gui.clicked(events,screen,"menu_play") || gui.clicked(events,screen,"pause_resume") {shell.page=.Playing}
    if gui.clicked(events,screen,"pause_settings") {shell.page=.Settings}
    if gui.clicked(events,screen,"settings_back") {shell.page=.Pause}
    if gui.clicked(events,screen,"menu_exit") {host.app_exit(app,0)}
    if gui.clicked(events,screen,"pause_quit") {
        // A network session has no menu to go back to: it leaves.
        if !solo {host.app_exit(app,0);return}
        scene.request_restart(scenes)
        shell.page=.Menu
    }
    if value,ok:=gui.changed_value(events,screen,"settings_preset");ok {
        shell_preset_take(options,Shell_Preset(i32(value)))
        changed=true
    }
    if value,ok:=gui.changed_value(events,screen,"settings_limit");ok {options.limit=i32(value);changed=true}
    if on,ok:=gui.changed(events,screen,"settings_fullscreen");ok {options.fullscreen=on;changed=true}
    if on,ok:=gui.changed(events,screen,"settings_vsync");ok {options.vsync=on;changed=true}
    // What a preset sets, changed by hand, is no longer that preset.
    custom:=false
    if value,ok:=gui.changed_value(events,screen,"settings_scale");ok {options.scale=i32(value);custom=true}
    if value,ok:=gui.changed_value(events,screen,"settings_shadows");ok {options.shadows=i32(value);custom=true}
    if value,ok:=gui.changed_value(events,screen,"settings_aa");ok {options.antialiasing=i32(value);custom=true}
    if value,ok:=gui.changed_value(events,screen,"settings_reflections");ok {options.reflections=render.Reflections(i32(value));custom=true}
    if custom {options.preset=.Custom}
    return changed || custom
}

// Runs every frame, also while the clock is stopped: it is what Escape and the
// buttons reach. What the clock, the mouse and the screens do follows the page.
@(step="frame")
shell_frame :: proc(
    shell:^Shell,options:^Shell_Options,g:^gui.Gui,screens:core.Read(Shell_Screen),huds:core.Read(Shell_Hud),
    frame_input:core.Frame_Input,clock:core.Ref(core.Clock),clock_requests:^core.Clock_Requests,network:core.Ref(core.Network),
    scenes:^scene.Scene_Requests,hidden:^core.Table(render.Hidden),
    display:^render.Display_Settings,graphics:^render.Graphics_Settings,app:^host.App,
) {
    if !shell.applied {
        shell.applied=true
        if !options.chosen {
            options.chosen=true
            switch graphics.textures {
            case .Low:         shell_preset_take(options,.Low)
            case .Medium:      shell_preset_take(options,.Medium)
            case .High,.Ultra: shell_preset_take(options,.High)
            }
        }
        shell_apply(options^,graphics,display)
    }
    solo:=network.role==.Standalone
    if !solo && shell.page==.Menu {shell.page=.Playing}

    screen,_:=core.sole(screens)
    if shell_events(gui.events_this_frame(g),screen,shell,options,solo,scenes,app) {shell_apply(options^,graphics,display)}

    if core.key_pressed(frame_input.input,.Escape) {
        #partial switch shell.page {
        case .Playing:  shell.page=.Pause
        case .Pause:    shell.page=.Playing
        case .Settings: shell.page=.Pause
        }
    }

    // A network session cannot stop the clock of the others.
    frozen:=shell.page==.Pause || shell.page==.Settings
    if solo && frozen!=clock.paused {
        if frozen {core.pause(clock_requests)} else {core.resume(clock_requests)}
    }
    captured:=shell.page==.Playing
    if captured!=shell.captured && app.platform!=nil && app.renderer!=nil {
        shell.captured=captured
        platform.window_set_relative_mouse(app.platform,captured)
    }
    render.set_hidden(hidden,screen,shell.page==.Playing)
    if hud,found:=core.sole(huds);found {render.set_hidden(hidden,hud,shell.page==.Menu)}
}
