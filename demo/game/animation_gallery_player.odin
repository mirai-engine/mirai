package game

import "core:math"
import "core:math/linalg"
import "mirai:core"
import cam "mirai:engine/camera"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import locomotion "plugins:locomotion/runtime"
import mm "mirai:std/math"

// The seat of the animation gallery. It walks Mirai through the hall; E at a station with a panel
// frames the panel and frees the pointer for it, and E at the spider drives the spider.
@(component,description="The player of the animation gallery: it walks Mirai, adjusts the panel of the station it stands at and can drive the procedural spider.")
Gallery_Player :: struct {
    mirai,spider:core.Entity,
    focus:core.Entity `mirai:"hidden,readonly,transient"`, // the panel it adjusts
    near:core.Entity `mirai:"hidden,readonly,transient"`,  // the station its body stands at
}

MIRAI_WALK_SPEED :: 2.9154 // m/s the walk clip covers

// m from a station's origin within which its body stands at it.
GALLERY_REACH_DISTANCE :: 3.4

GALLERY_FOCUS_BLEND :: cam.Camera_Blend{seconds=.6,ease=.Cubic_In_Out}

// A body of the gallery walks along wish, in the world, and faces where it walks.
gallery_move :: proc(input:^inp.Move_Input,wish:mm.Vec3) {
    input.move={}
    if amount:=linalg.length(wish);amount>.001 {
        input.look_yaw=mm.yaw_of_direction(wish)
        input.move=wish/max(amount,1)
    }
}

// A body of the gallery player that fell goes back to where the gallery starts.
@(step="fixed")
gallery_player_fall :: proc(players:core.Read(Gallery_Player),worlds:core.Read(core.World_Transform),placer:core.Placer) {
    for player in players.table.values[:core.count(players)] {
        if placed,exists:=core.get(worlds,player.mirai);exists && placed.position.y< -3 {core.place(placer,player.mirai,GALLERY_START,at_rest=true)}
    }
}

// E at a station: frame its panel, or drive the spider; E again, or at the spider, gives the
// walk back to Mirai.
@(step="fixed")
gallery_interact :: proc(players:^core.Table(Gallery_Player),gallery:core.Read(Animation_Gallery),panels:core.Read(Gallery_Panel),worlds:core.Read(core.World_Transform),seats:core.Read(inp.Seat),actions:inp.Input_Of(Action),requests:^inp.Seat_Requests,cameras:^cam.Camera_Requests) {
    for row in 0..<core.count(players) {
        player:=core.at(players,row)
        seat:=core.entity_at(players,row)
        body:=inp.body_of(seats,seat)
        near:=core.NONE
        if placed,exists:=core.get(worlds,body);exists && body==player.mirai {
            closest:=f32(GALLERY_REACH_DISTANCE)
            for at in 0..<core.count(gallery) {
                distance:=linalg.length((core.at(gallery,at).origin-placed.position).xz)
                if distance<closest {closest,near=distance,core.entity_at(gallery,at)}
            }
        }
        next:=player
        next.near=near
        if inp.seat_pressed(actions,seat,.Use) {
            if body!=player.mirai && body!=core.NONE {
                inp.drive(requests,seat,player.mirai)
            } else if player.focus!=core.NONE {
                cam.camera_override_remove(cameras,seat)
                next.focus=core.NONE
                inp.drive(requests,seat,player.mirai)
            } else if near!=core.NONE {
                if near==player.spider {inp.drive(requests,seat,player.spider)}
                for at in 0..<core.count(panels) {
                    panel:=core.at(panels,at)
                    if panel.station!=near {continue}
                    entity:=core.entity_at(panels,at)
                    cam.camera_override(cameras,seat,seat,panel.camera,blend=GALLERY_FOCUS_BLEND)
                    next.focus=entity
                    inp.release(requests,seat)
                }
            }
        }
        if next!=player {core.edit_at(players,row)^=next}
    }
}

GALLERY_PLAQUE_SIZE :: [2]f32{330,64}
GALLERY_PANEL_SIZE :: [2]f32{300,340}
GALLERY_PLAQUE_DISTANCE :: 10 // m from the body of the player within which the plaques show

// The plaques show near the body of the player and a panel only while its player adjusts it: a
// widget without size is not drawn.
@(step="fixed")
gallery_widgets :: proc(players:core.Read(Gallery_Player),labels:core.Read(Gallery_Label),panels:core.Read(Gallery_Panel),widgets:^core.Table(gui.World_Widget),worlds:core.Read(core.World_Transform),seats:core.Read(inp.Seat)) {
    player,found:=core.first(players)
    if !found {return}
    focus:=core.at(players,0).focus
    body,_:=core.get(worlds,inp.body_of(seats,player) if focus==core.NONE else core.at(players,0).mirai)
    for row in 0..<core.count(labels) {
        e:=core.entity_at(labels,row)
        placed,exists:=core.get(worlds,e)
        near:=exists && linalg.length((placed.position-body.position).xz)<GALLERY_PLAQUE_DISTANCE
        gallery_widget_set(widgets,e,GALLERY_PLAQUE_SIZE if near else {},.Passive)
    }
    for row in 0..<core.count(panels) {
        e:=core.entity_at(panels,row)
        gallery_widget_set(widgets,e,GALLERY_PANEL_SIZE if e==focus else {},.Interactive if e==focus else .Passive)
    }
}

gallery_widget_set :: proc(widgets:^core.Table(gui.World_Widget),e:core.Entity,size:[2]f32,input:gui.World_Input) {
    current,exists:=core.get(widgets,e)
    if !exists || current.size==size && current.input==input {return}
    if widget:=core.edit(widgets,e);widget!=nil {widget.size,widget.input=size,input}
}
