package decals_editor

import "mirai:core"
import "mirai:editor"
import "mirai:host"
import erender "mirai:engine/render"
import mm "mirai:std/math"
import "mirai:ui"
import decals "plugins:decals/runtime"

GIZMO_VERTICES :: 512
GIZMO_COLOR :: [4]f32{0.96,0.67,0.47,0.9}

@(storage)
Decals_Cards :: struct {provider:editor.Card_Provider}

decals_cards_default :: proc() -> (cards:Decals_Cards) {
    cards.provider.count=1
    cards.provider.cards[0]={
        label="Decal",group="Logic",color={245,170,120,255},scale={1,0.5,1},component=decals.Decal,make=decal_make,
        // A surface, and what comes down onto it.
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-6.5,2.5},{0,-1},{6.5,2.5},{0,6}}),
            ui.icon_part(.Fill,{{-2.8,2.5},{0,1},{2.8,2.5},{0,4}},shade=70),
            ui.icon_part(.Line,{{0,-7},{0,-2.8}}),
            ui.icon_part(.Line,{{-1.8,-4.5},{0,-2.7},{1.8,-4.5}}),
        ),
    }
    return
}

@(private)
decal_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,decals.Decal);t!=nil {core.add(t,e,decals.DECAL_DEFAULT)}
}

@(storage)
Decals_Gizmo :: struct {vertices:[GIZMO_VERTICES]erender.Debug_Vertex}

// The box of each selected decal, and the way its image goes onto what is inside.
@(step="frame")
decals_gizmo :: proc(s:^editor.Session,gizmo:^Decals_Gizmo,app:^host.App) {
    draw :: proc(lines:^erender.Debug_Lines,w:core.World_Ref,e:core.Entity,_:decals.Decal) {
        placed:=editor.entity_world(w,e)
        erender.debug_box_transformed(lines,mm.transform_matrix(placed),{-0.5,-0.5,-0.5},{0.5,0.5,0.5},GIZMO_COLOR)
        erender.debug_arrow(lines,mm.transform_point(placed,{0,0.5,0}),mm.transform_point(placed,{0,-0.5,0}),GIZMO_COLOR)
    }
    editor.selection_gizmo(s,app,gizmo.vertices[:],decals.Decal,draw)
}
