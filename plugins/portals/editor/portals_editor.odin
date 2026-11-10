package portals_editor

import "core:math"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import erender "mirai:engine/render"
import "mirai:ui"
import portals "plugins:portals/runtime"

GIZMO_VERTICES :: 1024
GIZMO_COLOR :: [4]f32{0.75,0.59,1,0.9}

@(storage)
Portals_Cards :: struct {provider:editor.Card_Provider}

portals_cards_default :: proc() -> (cards:Portals_Cards) {
    // An opening that stands, and the place behind it.
    rim,inside:[ui.ICON_POINT_CAPACITY][2]f32
    for i in 0..<len(rim) {
        angle:=f32(i)/f32(len(rim))*2*math.PI
        rim[i]={4.6*math.cos(angle),6.8*math.sin(angle)}
        inside[i]={2.3*math.cos(angle),4.4*math.sin(angle)}
    }
    cards.provider.count=1
    cards.provider.cards[0]={
        label="Portal",group="Logic",color={190,150,255,255},lift=1.5,scale={2,3,1},component=portals.Portal,make=portal_make,
        drawing=ui.icon_drawing(ui.icon_part(.Loop,rim[:],1.4),ui.icon_part(.Fill,inside[:],shade=60)),
    }
    return
}

@(private)
portal_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,portals.Portal);t!=nil {core.add(t,e,portals.Portal{})}
}

@(storage)
Portals_Gizmo :: struct {vertices:[GIZMO_VERTICES]erender.Debug_Vertex}

// The opening of each selected portal, its front, and the way to its exit.
@(step="frame")
portals_gizmo :: proc(s:^editor.Session,gizmo:^Portals_Gizmo,app:^host.App) {
    draw :: proc(lines:^erender.Debug_Lines,w:core.World_Ref,e:core.Entity,portal:portals.Portal) {
        placed:=editor.entity_world(w,e)
        editor.gizmo_face(lines,placed,portal.ellipse,GIZMO_COLOR)
        if editor.entity_alive(w,portal.exit) {
            erender.debug_arrow(lines,placed.position,editor.entity_world(w,portal.exit).position,GIZMO_COLOR,0.3)
        }
    }
    editor.selection_gizmo(s,app,gizmo.vertices[:],portals.Portal,draw)
}
