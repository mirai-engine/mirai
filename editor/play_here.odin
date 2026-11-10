package editor

import "core:fmt"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor/history"
import scene "mirai:engine/scene"
import mm "mirai:std/math"
import "mirai:ui"

// Play from here and Play from camera: the next Play puts player 1 there
// (scene.Play_Origin asked), before any Spawn_Point. The menu of a right
// click on the scene that did not turn the camera plays from where the ray
// under the pointer first meets a body, and lists what that ray goes
// through, nearest first, to select it.

VIEWPORT_MENU_ENTITIES :: 16

Viewport_Menu :: struct {
    entities:[VIEWPORT_MENU_ENTITIES]core.Entity,
    count:int,
    here:[3]f32, // where the ray first meets a body
    hit:bool,
}

// Where the camera of the editor is, facing level where it looks.
camera_origin :: proc(s:^Session) -> scene.Play_Origin {
    o:=s.viewport.orbit
    eye:=orbit_position(o)
    return {position=eye,rotation=level_facing(o.target-eye),set=true}
}

@(private)
level_facing :: proc(look:[3]f32) -> mm.Quat {
    look:=look
    look.y=0
    if linalg.length(look)<=1e-4 {return 1}
    return mm.quat_look(linalg.normalize(look),{0,1,0})
}

// Player 1 at a place, facing level where the camera looks.
point_origin :: proc(s:^Session,position:[3]f32) -> scene.Play_Origin {
    o:=s.viewport.orbit
    return {position=position,rotation=level_facing(o.target-orbit_position(o)),set=true,asked=true}
}

@(private)
viewport_menu_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"viewport_menu")}

viewport_menu_open :: proc(s:^Session,w:core.World_Ref,point:[2]f32) {
    g:=s.gui
    if g.ctx.popup.count>0 || g.modal!=.None {return}
    picks:[VIEWPORT_MENU_ENTITIES]Pick
    count:=pick_through(s,w,point,picks[:],ghosts_shown(s))
    m:=&g.viewport_menu
    m^={count=count}
    for p,i in picks[:count] {
        m.entities[i]=p.entity
        if !m.hit && !p.indicator {m.here,m.hit=p.position,true}
    }
    ui.popup_open(g.ctx,viewport_menu_popup(g),{point.x,point.y,0,0})
}

viewport_menu_build :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    popup:=viewport_menu_popup(g)
    if !ui.popup_is_open(ctx,popup) {return}
    if ui.popup(ctx,popup) {
        ui.id_push(ctx,popup)
        viewport_menu_items(s,&g.viewport_menu)
        ui.id_pop(ctx)
    }
}

@(private)
viewport_menu_items :: proc(s:^Session,m:^Viewport_Menu) {
    ctx:=s.gui.ctx
    if len(s.selection.entities)>0 {
        if ui.menu_item(ctx,ui.id(ctx,"ask"),"Ask agent",{icon=.Sparkle,disabled=!s.has_project}) {ai_ask(s)}
        ui.menu_separator(ctx)
    }
    if ui.menu_item(ctx,ui.id(ctx,"here"),"Play from here",{icon=.Play,disabled=!m.hit || command_state(s,"play").disabled}) {
        command_call(s,"play.start",fmt.tprintf(`{{"from":"Point","point":[%v,%v,%v]}}`,m.here.x,m.here.y,m.here.z))
    }
    command_menu_item(s,ui.id(ctx,"camera"),"play_from_camera")
    if m.count>0 {ui.menu_separator(ctx)}
    w:=shown_world(s)
    for e,i in m.entities[:m.count] {
        if !entity_alive(w,e) {continue}
        icon,color:=entity_icon(s,w,e)
        if ui.menu_item(ctx,ui.id(ctx,"entity",i+1),entity_label(w,e),{icon=icon,icon_color=color,checked=history.selection_has(s.selection,e)}) {
            history.selection_set(s.selection,{e})
            outliner_reveal(s.outliner,w,e)
        }
    }
}
