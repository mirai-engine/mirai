package render

import "mirai:core"
import "mirai:host"
import "mirai:platform"
import "mirai:project"

// The window of the game as its player chose it, a setting of the machine:
// what it leaves at zero is as project.mirai says. Only the window the
// player opens takes it (host.App.game_window), never the editor's, where
// its Play draws.

Display_Mode :: enum u8 {
    Project,    // as project.mirai says
    Windowed,
    Maximized,
    Fullscreen, // the whole display, without the frame of the window
}

@(storage,setting="machine")
Display_Settings :: struct {
    mode:Display_Mode `mirai:"section=Window"`,
    width:i32 `mirai:"min=0,max=16384"`,  // points, while it is neither maximized nor in full screen; 0: as the project says
    height:i32 `mirai:"min=0,max=16384"`, // points; 0: as the project says
    display:u32 `mirai:"min=0,max=64"`,   // the one it goes to, 1 the first the system lists (platform.display_names); 0: the one the system opens it on
}

// The display settings the window was last brought to: one per application, as the window.
@(storage,host)
Display_Sync :: struct {
    applied:Display_Settings,
    done:bool,
}

// The mode and the size of the window display stands for, over the window
// it opened as: never .Project.
display_target :: proc(display:Display_Settings,opened:platform.Window_Desc) -> (mode:Display_Mode,size:[2]i32) {
    mode=display.mode
    if mode==.Project {mode=opened.fullscreen?.Fullscreen:(opened.maximized?.Maximized:.Windowed)}
    chosen,fallback:=[2]i32{display.width,display.height},platform.WINDOW_SIZE_DEFAULT
    for &side,i in size {
        side=opened.size[i]>0?opened.size[i]:fallback[i]
        if chosen[i]>0 {side=min(chosen[i],project.MAX_WINDOW_SIDE)}
    }
    return
}

// Brings the window of the game to the display settings when they change:
// what changed since the last time, or since it opened.
@(step="render",loops="game")
display_apply :: proc(display:Display_Settings,sync:^Display_Sync,app:^host.App,problems:^core.Problems) {
    if !app.game_window || sync.done && sync.applied==display {return}
    was:=sync.done?sync.applied:Display_Settings{}
    sync.applied,sync.done=display,true
    p:=app.platform
    if display.display>0 && display.display!=was.display && !platform.window_set_display(p,int(display.display)-1) {
        count:=len(platform.display_names(p,context.temp_allocator))
        core.report(problems,core.NONE,"render.display","Display_Settings.display %d is not a display of this machine, which has %d; give it one from 1 to %d, or 0 for the one the system opens the window on",display.display,count,count)
    }
    before_mode,before_size:=display_target(was,app.window)
    mode,size:=display_target(display,app.window)
    if mode==before_mode && size==before_size {return}
    switch mode {
    case .Windowed:
        platform.window_set_fullscreen(p,false)
        platform.window_set_maximized(p,false)
        platform.window_set_size(p,size)
    case .Maximized:
        platform.window_set_fullscreen(p,false)
        platform.window_set_maximized(p,true)
    case .Fullscreen:
        platform.window_set_fullscreen(p,true)
    case .Project:
    }
}
