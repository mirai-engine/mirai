package editor

import "mirai:platform"
import "mirai:ui"

play_paused :: proc "contextless" (s:^Session) -> bool {return s.mode==.Paused || s.mode==.Simulation_Paused}

// The game of the user is seen through its own camera: while it plays, and while play.step or
// play.record holds it paused, so that its interfaces take the pointer as the image shows them.
play_viewed :: proc "contextless" (s:^Session) -> bool {return s.mode==.Play || s.mode==.Paused && s.play_stepped}

// The editor shows the game of the user, playing or paused: the panels behave
// as in a game, and the chat opens only while it is paused.
play_shown :: proc "contextless" (s:^Session) -> bool {return s.mode==.Play || s.mode==.Paused}

play_release_input :: proc(s:^Session) {
    if s.mode!=.Play || s.play_input_released {return}
    s.play_input_released=true
    s.app.game_mouse_off=true
    platform.window_set_relative_mouse(s.app.platform,false)
}

play_chat_set :: proc(s:^Session,open:bool) {
    if s.ai==nil || !play_shown(s) {return}
    open:=open && s.mode==.Paused
    ai_chat_show(s.ai,open)
    if s.play_chat_open==open {return}
    s.play_chat_open=open
    if open {
        s.play_chat_input_released,s.play_input_released=s.play_input_released,true
        library_select(s,.Ai)
    } else {
        s.gui.layout.left_open=false
        ai_chat_focus(s.ai,false)
        if s.gui.ctx!=nil {s.gui.ctx.edit={};ui.popup_close(s.gui.ctx)}
        s.play_input_released=s.play_chat_input_released
        s.play_capture_click=false
    }
}

// The click that recaptures the scene never reaches the game; Tab toggles the chat while it is paused.
play_input_update :: proc(s:^Session) {
    app,g:=s.app,s.gui
    frame:=platform.input_frame(app.platform)
    app.game_mouse_off=true
    if simulating(s) || s.mode==.Watch {
        app.game_input_blocked=true
        if s.mode==.Watch {_=platform.input_tick_take(app.platform)}
        return
    }
    if s.mode==.Play || s.mode==.Paused {
        if s.mode==.Paused && .Tab in frame.keys_pressed && app.ui_input.modifiers=={} && s.gui.modal==.None && s.gui.ctx!=nil && !s.gui.ctx.modal_open && s.gui.ctx.popup.count==0 {
            play_chat_set(s,!s.play_chat_open)
            app.ui_input.keys_pressed-={.Tab}
            app.ui_input.keys_repeated-={.Tab}
        } else if s.ai!=nil && ai_chat_open(s.ai)!=s.play_chat_open {play_chat_set(s,ai_chat_open(s.ai))}
    }
    app.game_input_blocked=s.mode!=.Play && !s.viewport.hovered
    if s.mode!=.Play {
        app.game_input_blocked=app.game_input_blocked || s.play_chat_open
        // What the mouse and the keys do while the game is paused is for the
        // editor: a game that resumes does not get it all in its first tick.
        if s.mode==.Paused {_=platform.input_tick_take(app.platform)}
        return
    }
    if .F1 in frame.keys_pressed {play_release_input(s)}
    if s.play_capture_click && frame.mouse_down=={} {s.play_capture_click=false}
    if s.play_input_released && !s.play_chat_open && !player_processes_captured(s) && .F1 not_in frame.keys_pressed && .Left in frame.mouse_pressed && frame.mouse_inside && g.modal==.None && g.ctx!=nil && g.ctx.popup.count==0 && g.ctx.edit.id==0 {
        point:=app.ui_input.pointer/(app.ui_input.scale>0?app.ui_input.scale:f32(1))
        over_panel:=false
        panels:=[?]ui.Rect{g.rects.bar,g.rects.left,g.rects.right,g.rects.bottom}
        for rect in panels {
            if ui.rect_contains(rect,point) {over_panel=true;break}
        }
        if !over_panel && player_process_at(s,point)==0 {
            s.play_input_released=false
            s.play_capture_click=true
        }
    }
    app.game_input_blocked=s.play_input_released || s.play_capture_click
    app.game_mouse_off=s.play_input_released
    if app.game_input_blocked {_=platform.input_tick_take(app.platform)}
}

// Resuming plays on from the newest frame the game played; with here, from
// the frame its history went back to, dropping the frames after it. stepped:
// the pause is that of play.step, which keeps the view of the game; any other
// pause or resume gives the viewport back to the editor's camera.
play_pause :: proc(s:^Session,paused:bool,here:=false,stepped:=false) {
    s.play_stepped=paused && stepped
    if !playing(s) {return}
    r:=run_find(s,0)
    if paused && (s.mode==.Play || s.mode==.Simulate) {
        platform.window_set_relative_mouse(s.app.platform,false)
        s.mode=simulating(s)?.Simulation_Paused:.Paused
        if r!=nil && r.history!=nil {r.history.held=true}
    } else if !paused && play_paused(s) {
        play_chat_set(s,false)
        if r!=nil {history_resume(s,r,here)}
        s.mode=simulating(s)?.Simulate:.Play
    }
}
