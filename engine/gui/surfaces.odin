package gui

import "core:mem"
import "mirai:std/base"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import gpu "mirai:render"
import "mirai:ui"

// A UI context of the world: that of the window, or that of a local player,
// which covers the window and builds the screens of its player in its part,
// and the World_Widgets its player sees.
Surface :: struct {
    ctx:^ui.Context,
    open:bool,        // its frame is being built
    skipped:bool,     // this frame shows its last one again
    shown:bool,       // layer holds its last frame
    draws:[]gpu.Ui_Draw,
    panels:[]gpu.World_Panel,
    offscreen:[]host.Ui_Offscreen, // of the window: the runs of the widgets on meshes
    offscreen_draws:[]gpu.Ui_Draw,  // what those runs draw
    layer:gpu.Ui_Layer,
    draw_count,panel_count:int,
    pointer,keyboard:bool, // what its last frame consumed
    cursor:ui.Cursor,      // what its last frame asked of the pointer
    density:f32,           // of the window its atlas follows
    key:Surface_Key,  // what its last frame was built for
    input:ui.Input,   // of its last frame
    rect:[4]f32,      // the part of its player, in window points
    repeat:Pad_Repeat,
    family:ui.Prompt_Family,
    source:Source,
    viewed:bool,      // its last frame showed a camera or particles, which are drawn every frame
    animating:bool,   // a tree of its last frame said the next one differs
    nesting:u32,      // ui.Stats.dropped_nesting of its context when its last frame ended
}

// Reports what the frame a surface just ended nested deeper than a context holds.
@(private)
nesting_report :: proc(s:^Surface,problems:^core.Problems) {
    dropped:=s.ctx.stats.dropped_nesting
    if dropped>s.nesting {
        core.report(problems,core.NONE,"gui.nesting","%d id scopes, floating boxes or layers of the interfaces of a frame were nested deeper than a frame holds and were not applied: they share the ids, the layer or the clip of what holds them; nest fewer floating or layered boxes and Lists inside each other",dropped-s.nesting)
    }
    s.nesting=dropped
}

Surface_Key :: struct {
    size:[2]f32,
    scale,density:f32,
    font:[2]f32,        // height and density of the atlas its glyphs were placed in
    view:ui.World_View, // of its world panels
    ray:ui.World_Ray,   // that reaches them
    plan:u64,           // what it builds, in order, and how
    family:ui.Prompt_Family,
    prompts:u64,        // Gui.prompts: the pack and the images of the settings
}

PAD_REPEAT_DELAY :: f32(0.4) // seconds a direction is held before it repeats
PAD_REPEAT_RATE :: f32(0.1)
PAD_STICK :: f32(0.5)        // of the travel of the left stick that counts as its direction

// How long each direction (up, down, left, right) has been held.
Pad_Repeat :: struct {held:[4]f32,down:[4]bool}

@(private)
surface_create :: proc(gui:^Gui,app:^host.App,p:int) -> bool {
    gui.allocator=app.allocator
    ctx:=host.app_ui_context_create(app,WIDGET_CAPACITY)
    if ctx==nil {return false}
    ctx.navigation=true
    draws,e1:=make([]gpu.Ui_Draw,DRAW_CAPACITY,gui.allocator)
    panels,e2:=make([]gpu.World_Panel,PANEL_CAPACITY,gui.allocator)
    offscreen,e3:=make([]host.Ui_Offscreen,p==0?2*MESH_CAPACITY:0,gui.allocator)
    offscreen_draws,e4:=make([]gpu.Ui_Draw,p==0?DRAW_CAPACITY:0,gui.allocator)
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil {
        delete(draws,gui.allocator);delete(panels,gui.allocator);delete(offscreen,gui.allocator);delete(offscreen_draws,gui.allocator)
        host.app_ui_context_destroy(app,ctx)
        return false
    }
    s:=&gui.surfaces[p]
    s.ctx,s.draws,s.panels,s.offscreen,s.offscreen_draws,s.density=ctx,draws,panels,offscreen,offscreen_draws,app.density
    return true
}

// The part of the window of player p of count, in points: for the window, all
// of it right of what the editor keeps at the side of the view.
@(private)
surface_rect :: proc(app:^host.App,p,count:int) -> [4]f32 {
    size:=app.ui_input.size
    if p==0 {
        left:=host.app_scene_points(app).x
        return {left,0,size.x-left,size.y}
    }
    r:=host.app_player_rect(app,p-1,count)
    d:=max(app.density,0.01)
    return {f32(r.x),f32(r.y),f32(r.z),f32(r.w)}/d
}

// The input of a context: that of the window, with the pointer and the keys
// only for the player that has the keyboard, the navigation of the gamepads
// of its player (-1: all) and the scale of the settings.
@(private)
surface_input :: proc(repeat:^Pad_Repeat,app:^host.App,settings:UI_Settings,scale:f32,gamepads:[]core.Gamepad,rect:[4]f32,keyboard:bool,gamepad:int,window:bool) -> (input:ui.Input) {
    input=app.ui_input
    if app.platform!=nil && platform.window_relative_mouse(app.platform) {input.pointer_absent=true}
    if !keyboard {
        input.pointer_absent=true
        input.down,input.pressed,input.released,input.clicks,input.wheel={},{},{},0,{}
        input.keys_down,input.keys_pressed,input.keys_repeated,input.modifiers,input.text_count={},{},{},{},0
    }
    input.pad=pad_input(repeat,gamepads,gamepad,input.dt)
    input.scroll,input.aim=pad_sticks(gamepads,gamepad)
    input.scale=surface_scale(window?input.size:rect.zw,settings,scale)
    return
}

// Layout units to points: the reference fits the size, times the scale of the player.
surface_scale :: proc "contextless" (size:[2]f32,settings:UI_Settings,scale:f32) -> f32 {
    return ui.scale_to_fit(size,settings.reference)*(scale>0?scale:1)
}

// The navigation of the gamepads of a player (-1: every one): the buttons as
// host.ui_pad_buttons maps them, and the d-pad and the left stick, which
// repeat while held.
pad_input :: proc "contextless" (r:^Pad_Repeat,gamepads:[]core.Gamepad,gamepad:int,dt:f32) -> (pads:ui.Pads) {
    held:[4]bool
    DIRECTIONS :: [4]core.Gamepad_Button{.Dpad_Up,.Dpad_Down,.Dpad_Left,.Dpad_Right}
    for &g,i in gamepads {
        if !g.connected || gamepad>=0 && i!=gamepad {continue}
        x,y:=g.axes[.Left_X],g.axes[.Left_Y]
        stick:=[4]bool{y<=-PAD_STICK,y>=PAD_STICK,x<=-PAD_STICK,x>=PAD_STICK}
        for button,d in DIRECTIONS {held[d]||=button in g.down || button in g.pressed || stick[d]}
        pads+=host.ui_pad_buttons(g.pressed)-{.Up,.Down,.Left,.Right}
    }
    repeats :: proc "contextless" (t:f32) -> int {return t<PAD_REPEAT_DELAY?0:1+int((t-PAD_REPEAT_DELAY)/PAD_REPEAT_RATE)}
    pad:=[4]ui.Pad{.Up,.Down,.Left,.Right}
    for d in 0..<4 {
        switch {
        case !held[d]: r.down[d],r.held[d]=false,0
        case !r.down[d]:
            r.down[d],r.held[d]=true,0
            pads+={pad[d]}
        case:
            before:=r.held[d]
            r.held[d]+=dt
            if repeats(r.held[d])>repeats(before) {pads+={pad[d]}}
        }
    }
    return
}

// The sticks of the gamepads of a player (-1: every one), the one pushed
// farthest of each: the right one scrolls, the left one aims in a Radial.
pad_sticks :: proc "contextless" (gamepads:[]core.Gamepad,gamepad:int) -> (scroll,aim:[2]f32) {
    for &g,i in gamepads {
        if !g.connected || gamepad>=0 && i!=gamepad {continue}
        right,left:=host.ui_stick(g.axes[.Right_X],g.axes[.Right_Y]),host.ui_stick(g.axes[.Left_X],g.axes[.Left_Y])
        if right.x*right.x+right.y*right.y>scroll.x*scroll.x+scroll.y*scroll.y {scroll=right}
        if left.x*left.x+left.y*left.y>aim.x*aim.x+aim.y*aim.y {aim=left}
    }
    return
}

// The family of the prompts of a player follows the device used last when it
// is one of the player's: the keyboard when it has it, or its gamepad (-1: any).
family_update :: proc "contextless" (family:^ui.Prompt_Family,device:core.Device,gamepads:[]core.Gamepad,keyboard:bool,gamepad:int) {
    if !device.gamepad {
        if keyboard {family^=.Keyboard}
        return
    }
    if int(device.slot)>=len(gamepads) || gamepad>=0 && int(device.slot)!=gamepad {return}
    family^=ui.Prompt_Family(int(gamepads[device.slot].family)+1)
}

// What the frame of context p is built for.
@(private)
surface_key :: proc(gui:^Gui,app:^host.App,p:int,input:ui.Input,family:ui.Prompt_Family) -> Surface_Key {
    key:=Surface_Key{size=input.size,scale=input.scale,density=app.density,font={f32(app.ui_font.height),app.ui_font.density},family=family,prompts=gui.prompts}
    world:=false
    plan:u64
    for &entry in gui.plan {
        if entry.player!=p {continue}
        world||=entry.world
        flags:=u64(entry.passive)|u64(entry.hiding)<<1|u64(entry.top)<<2|u64(entry.world)<<3
        mark:=[5]u64{u64(entry.entity),u64(entry.content.generation),u64(i64(entry.order)),entry.variant,flags}
        plan=base.hash64(mem.slice_to_bytes(mark[:]),plan)
    }
    key.plan=plan
    if world {key.view,key.ray=input.view,input.ray}
    return key
}

// Whether an interface of context p changed or plays.
@(private)
surface_changed :: proc(gui:^Gui,p:int) -> bool {
    for entry in gui.plan {
        if entry.player!=p {continue}
        instance:=&gui.instances[entry.instance]
        if instance.changed || instance.animating {return true}
    }
    return false
}

// Whether a context shows its last frame again: it has one, nobody draws in
// it with code, none of its interfaces changed or plays, it shows no camera
// or particles, it is built for the same and no input reached it.
surface_skips :: proc "contextless" (s:^Surface,wanted:bool,input:ui.Input,key:Surface_Key,device:core.Input,changed:bool) -> bool {
    if !s.shown || wanted || changed || s.viewed || s.animating || key!=s.key {return false}
    return !input_moved(input,s.input) && !device_moved(device)
}

// Whether the input of a frame does anything to a context after that of its last frame.
input_moved :: proc "contextless" (now,last:ui.Input) -> bool {
    return now.pointer!=last.pointer && !now.pointer_absent || now.pointer_absent!=last.pointer_absent || now.down!=last.down ||
        now.pressed!={} || now.released!={} || now.wheel!={} || now.keys_down!=last.keys_down || now.keys_pressed!={} ||
        now.keys_repeated!={} || now.modifiers!=last.modifiers || now.pad!={} || now.text_count>0 || now.scroll!={} || now.aim!=last.aim
}

// Whether a key, a button or the wheel changed: the actions buttons take may follow.
device_moved :: proc "contextless" (d:core.Input) -> bool {
    if d.keys_pressed!={} || d.keys_released!={} || d.mouse_pressed!={} || d.mouse_released!={} || d.wheel!={} {return true}
    for g in d.gamepads {
        if g.pressed!={} || g.released!={} {return true}
    }
    return false
}
