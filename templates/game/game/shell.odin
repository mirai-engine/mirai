package game

import "mirai:core"
import gui "mirai:engine/gui"
import render "mirai:engine/render"
import save "mirai:engine/save"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"

// The shell of the game: main menu, pause and graphics settings, with mouse
// and keyboard. assets/ui/shell.ui (tools/content writes it) is one screen with
// a page per Shell_Page; Shell.page says which shows, and shell_frame is the
// only code that changes it. Add a screen by adding a page there and a member
// of Shell_Page before Playing.
//
// Settings have one route: the player's choices are Shell_Options, kept in the
// profile (save.request_profile_save, read back on the first frame), and
// shell_apply turns them into Graphics_Settings and Display_Settings. Nothing
// else writes those two or saves them.

SHELL_START_SCENE :: "scenes/main.scene"  // what Quit to Menu loads, which puts the world as it started

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

// The pages of shell.ui, by the order of the nodes of its Switcher. While
// Playing, no page shows and the screen is hidden.
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

// One event of shell.ui; true when it changed an option.
@(private="file")
shell_event :: proc(event:gui.UI_Event,shell:^Shell,options:^Shell_Options,solo:bool,scenes:^scene.Scene_Requests,app:^host.App) -> (changed:bool) {
    #partial switch event.kind {
    case .Clicked:
        switch event.name {
        case base.name_hash("menu_play"),base.name_hash("pause_resume"): shell.page=.Playing
        case base.name_hash("menu_exit"):                                host.app_exit(app,0)
        case base.name_hash("pause_settings"):                           shell.page=.Settings
        case base.name_hash("settings_back"):                            shell.page=.Pause
        case base.name_hash("pause_quit"):
            // A network session has no menu to go back to: it leaves.
            if !solo {host.app_exit(app,0);return}
            scene.request_path(scenes,SHELL_START_SCENE)
            shell.page=.Menu
        }
    case .Changed:
        index:=i32(event.value)
        switch event.name {
        case base.name_hash("settings_preset"):
            shell_preset_take(options,Shell_Preset(index))
            return true
        case base.name_hash("settings_limit"):
            options.limit=index
            return true
        case base.name_hash("settings_fullscreen"):
            options.fullscreen=event.on
            return true
        case base.name_hash("settings_vsync"):
            options.vsync=event.on
            return true
        case base.name_hash("settings_scale"):       options.scale=index
        case base.name_hash("settings_shadows"):     options.shadows=index
        case base.name_hash("settings_aa"):          options.antialiasing=index
        case base.name_hash("settings_reflections"): options.reflections=render.Reflections(index)
        case: return false
        }
        // What a preset sets, changed by hand, is no longer that preset.
        options.preset=.Custom
        return true
    }
    return false
}

@(private="file")
shell_show :: proc(hidden:^core.Table(render.Hidden),e:core.Entity,shown:bool) {
    if core.has(core.read(hidden),e)!=shown {return}
    if shown {core.remove(hidden,e)} else {core.add(hidden,e,render.Hidden{})}
}

// Runs every frame, also while the clock is stopped: it is what Escape and the
// buttons reach. What the clock, the mouse and the screens do follows the page.
@(step="frame")
shell_frame :: proc(
    shell:^Shell,options:^Shell_Options,g:^gui.Gui,screens:core.Read(Shell_Screen),huds:core.Read(Shell_Hud),
    frame_input:core.Frame_Input,clock:core.Ref(core.Clock),clock_requests:^core.Clock_Requests,network:core.Ref(core.Network),
    saves:^save.Save_Requests,scenes:^scene.Scene_Requests,hidden:^core.Table(render.Hidden),
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

    screen:=core.count(screens)>0?core.entity_at(screens,0):core.NONE
    changed:=false
    for event in gui.events_this_frame(g) {
        if event.entity==screen && shell_event(event,shell,options,solo,scenes,app) {changed=true}
    }
    if changed {
        shell_apply(options^,graphics,display)
        save.request_profile_save(saves)
    }

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
    if screen!=core.NONE {shell_show(hidden,screen,shell.page!=.Playing)}
    if core.count(huds)>0 {shell_show(hidden,core.entity_at(huds,0),shell.page!=.Menu)}
}
