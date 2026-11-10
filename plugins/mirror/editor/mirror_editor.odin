package mirror_editor

import "mirai:core"
import "mirai:editor"
import "mirai:host"
import erender "mirai:engine/render"
import "mirai:ui"
import mirror "plugins:mirror/runtime"

GIZMO_VERTICES :: 512
GIZMO_COLOR :: [4]f32{0.62,0.86,1,0.9}

@(storage)
Mirror_Cards :: struct {provider:editor.Card_Provider}

mirror_cards_default :: proc() -> (cards:Mirror_Cards) {
    // A glass that stands, with the glint of what it reflects.
    cards.provider.count=1
    cards.provider.cards[0]={
        label="Mirror",group="Logic",color={160,220,255,255},lift=1.2,scale={1.6,2.4,1},component=mirror.Mirror,make=mirror_make,
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-4.6,-6.8},{4.6,-6.8},{4.6,6.8},{-4.6,6.8}},1.4),
            ui.icon_part(.Line,{{-2.4,1.2},{1.2,-4.2}}),
            ui.icon_part(.Line,{{-0.4,3.6},{2.6,-0.9}}),
        ),
    }
    return
}

@(private)
mirror_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,mirror.Mirror);t!=nil {core.add(t,e,mirror.Mirror{})}
}

@(storage)
Mirror_Gizmo :: struct {vertices:[GIZMO_VERTICES]erender.Debug_Vertex}

// The face of each selected mirror and its front.
@(step="frame")
mirror_gizmo :: proc(s:^editor.Session,gizmo:^Mirror_Gizmo,app:^host.App) {
    draw :: proc(lines:^erender.Debug_Lines,w:core.World_Ref,e:core.Entity,face:mirror.Mirror) {
        editor.gizmo_face(lines,editor.entity_world(w,e),face.ellipse,GIZMO_COLOR)
    }
    editor.selection_gizmo(s,app,gizmo.vertices[:],mirror.Mirror,draw)
}
