package editor

import "core:fmt"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:ui"

// While a game with several local players plays: the number of each view
// and the one with the input outlined. The click that gives the input back
// to the game gives it to the player under it.
@(step="ui",after="editor_panels")
play_players_overlay :: proc(s:^Session) {
    if !playing(s) || simulating(s) || !s.gui.begun {return}
    w:=shown_world(s)
    control:=core.world_storage_of(w,input.Seats)
    requests:=core.world_storage_of(w,input.Seat_Requests)
    if control==nil || requests==nil {return}
    n:=control.local_count
    if n<2 {return}
    ctx:=s.gui.ctx
    frame:=platform.input_frame(s.app.platform)
    point:=s.app.ui_input.pointer/(s.app.ui_input.scale>0?s.app.ui_input.scale:f32(1))
    clicked:=s.play_capture_click && .Left in frame.mouse_pressed
    for index in 0..<n {
        pixels:=host.app_player_rect(s.app,index,n)
        density:=max(s.app.density,0.01)
        tile:=[4]f32{f32(pixels.x),f32(pixels.y),f32(pixels.z),f32(pixels.w)}/density
        top:=max(tile.y,s.gui.rects.bar.h)
        rect:=ui.Rect{tile.x,top,tile.z,tile.y+tile.w-top}
        if clicked && ui.rect_contains(rect,point) {input.focus(requests,index)}
        focused:=index==control.focus
        if focused && !s.play_input_released {ui.draw_rect_lines(ctx,rect,2,ui.tone(ctx,"accent"))}
        if ui.box(ctx,{width=ui.FIT,height=ui.FIT,padding={7,4,7,4},float={to=.Surface,offset={rect.x+rect.w-38,rect.y+8},layer=ui.LAYER_PANEL},fill=ui.tone(ctx,"panel"),radius=ui.metric(ctx,"radius_control")}) {
            ui.label(ctx,fmt.tprintf("P%d",index+1),ui.metric(ctx,"font_small"),focused?ui.tone(ctx,"accent"):ui.tone(ctx,"text_muted"))
        }
    }
}
