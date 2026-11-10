package portals_editor

import "core:math"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import erender "mirai:engine/render"
import "mirai:ui"
import mm "mirai:std/math"
import portals "plugins:portals/runtime"

GIZMO_VERTICES :: 1024
GIZMO_COLOR :: [4]f32{0.75,0.59,1,0.9}
MIRROR_COLOR :: [4]f32{0.62,0.86,1,0.9}

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
    cards.provider.count=2
    cards.provider.cards[0]={
        label="Portal",group="Logic",color={190,150,255,255},lift=1.5,scale={2,3,1},component=portals.Portal,make=portal_make,
        drawing=ui.icon_drawing(ui.icon_part(.Loop,rim[:],1.4),ui.icon_part(.Fill,inside[:],shade=60)),
    }
    // A glass that stands, with the glint of what it reflects.
    cards.provider.cards[1]={
        label="Mirror",group="Logic",color={160,220,255,255},lift=1.2,scale={1.6,2.4,1},make=mirror_make,
        drawing=ui.icon_drawing(
            ui.icon_part(.Loop,{{-4.6,-6.8},{4.6,-6.8},{4.6,6.8},{-4.6,6.8}},1.4),
            ui.icon_part(.Line,{{-2.4,1.2},{1.2,-4.2}}),
            ui.icon_part(.Line,{{-0.4,3.6},{2.6,-0.9}}),
        ),
    }
    return
}

@(private)
portal_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,portals.Portal);t!=nil {core.add(t,e,portals.Portal{})}
}

@(private)
mirror_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,portals.Portal);t!=nil {core.add(t,e,portals.Portal{mirror=true})}
}

@(storage)
Portals_Gizmo :: struct {vertices:[GIZMO_VERTICES]erender.Debug_Vertex}

// The opening of each selected portal, the side it shows (+Z), and the way to its exit.
@(step="frame")
portals_gizmo :: proc(s:^editor.Session,gizmo:^Portals_Gizmo,app:^host.App) {
    draw :: proc(lines:^erender.Debug_Lines,w:core.World_Ref,e:core.Entity,portal:portals.Portal) {
        SEGMENTS :: 32
        placed:=editor.entity_world(w,e)
        color:=portal.mirror?MIRROR_COLOR:GIZMO_COLOR
        if portal.ellipse {
            previous:=mm.transform_point(placed,{0.5,0,0})
            for i in 1..=SEGMENTS {
                angle:=f32(i)/SEGMENTS*2*math.PI
                point:=mm.transform_point(placed,{0.5*math.cos(angle),0.5*math.sin(angle),0})
                erender.debug_line(lines,previous,point,color)
                previous=point
            }
        } else {
            corners:=[4][3]f32{{-0.5,-0.5,0},{0.5,-0.5,0},{0.5,0.5,0},{-0.5,0.5,0}}
            for corner,i in corners {
                erender.debug_line(lines,mm.transform_point(placed,corner),mm.transform_point(placed,corners[(i+1)%4]),color)
            }
        }
        erender.debug_arrow(lines,placed.position,placed.position+mm.quat_rotate(placed.rotation,[3]f32{0,0,1})*0.75,color)
        if !portal.mirror && editor.entity_alive(w,portal.exit) {
            erender.debug_arrow(lines,placed.position,editor.entity_world(w,portal.exit).position,color,0.3)
        }
    }
    editor.selection_gizmo(s,app,gizmo.vertices[:],portals.Portal,draw)
}
