package monitors_editor

import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:ui"
import monitors "plugins:monitors/runtime"

GIZMO_VERTICES :: 256
GIZMO_COLOR :: [4]f32{0.59,0.78,1,0.9}

@(storage)
Monitors_Cards :: struct {provider:editor.Card_Provider}

monitors_cards_default :: proc() -> (cards:Monitors_Cards) {
    cards.provider.count=1
    cards.provider.cards[0]={
        label="Screen",group="Logic",color={150,200,255,255},body=.Cube,scale={1.6,0.9,0.04},component=monitors.Screen,make=screen_make,
        // A monitor on its stand, with something playing.
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-6.5,-5.5},{6.5,-5.5},{6.5,3},{-6.5,3}}),
            ui.icon_part(.Fill,{{-1.6,-3.6},{2.4,-1.25},{-1.6,1.1}},shade=70),
            ui.icon_part(.Line,{{0,3},{0,6}}),
            ui.icon_part(.Line,{{-3.5,6},{3.5,6}}),
        ),
    }
    return
}

@(private)
screen_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,erender.Mesh_Renderer);t!=nil {core.add(t,e,erender.Mesh_Renderer{shape=.Cube})}
    if t:=core.world_table_of(w,monitors.Screen);t!=nil {core.add(t,e,monitors.SCREEN_DEFAULT)}
}

@(storage)
Monitors_Gizmo :: struct {vertices:[GIZMO_VERTICES]erender.Debug_Vertex}

// From each selected screen to the camera it shows.
@(step="frame")
monitors_gizmo :: proc(s:^editor.Session,gizmo:^Monitors_Gizmo,app:^host.App) {
    draw :: proc(lines:^erender.Debug_Lines,w:core.World_Ref,e:core.Entity,screen:monitors.Screen) {
        if !editor.entity_alive(w,screen.camera) {return}
        erender.debug_arrow(lines,editor.entity_world(w,screen.camera).position,editor.entity_world(w,e).position,GIZMO_COLOR,0.3)
    }
    editor.selection_gizmo(s,app,gizmo.vertices[:],monitors.Screen,draw)
}
