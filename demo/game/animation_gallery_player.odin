package game

import "core:math"
import "core:math/linalg"
import "mirai:core"
import cam "mirai:engine/camera"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
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

// deg/s the bodies of the gallery turn toward where they walk.
GALLERY_TURN_SPEED :: 500

// m from a station's origin within which its body stands at it.
GALLERY_REACH_DISTANCE :: 3.4

GALLERY_FOCUS_BLEND :: cam.Camera_Blend{seconds=.6,ease=.Cubic_In_Out}

gallery_move :: proc(input:^inp.Move_Input,rotation:mm.Quat,wish:mm.Vec3,dt:f32) {
    input.look_yaw=yaw_of(rotation)
    input.move={}
    if amount:=linalg.length(wish);amount>.001 {
        desired:=math.atan2(-wish.x,-wish.z)
        input.look_yaw=mm.angle_wrap(mm.angle_approach(input.look_yaw,desired,GALLERY_TURN_SPEED*mm.RAD_PER_DEG*dt))
        input.move=mm.quat_rotate(mm.quat_axis_angle({0,1,0},-input.look_yaw),wish/max(amount,1))
    }
}

gallery_player_input :: proc(input:^inp.Move_Input,rotation:mm.Quat,dt:f32,owner:inp.Drivable,walk_actions:inp.Input_Of(phys.Walk_Action),look_actions:inp.Input_Of(inp.Look_Action),follows:core.Read(cam.Camera_Follow)) {
    look:=inp.seat_vector(look_actions,owner.seat,.Look)
    move:=inp.seat_vector(walk_actions,owner.seat,.Move)
    follow,_:=core.get(follows,owner.camera)
    yaw:=follow.looking.x if follow.state.ready else follow.yaw
    yaw-=look.x*LOOK_SPEED
    wish:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},yaw),mm.Vec3{move.x,0,-move.y})
    gallery_move(input,rotation,wish,dt)
    if inp.seat_down(walk_actions,owner.seat,.Jump) {input.buttons|=inp.action_bit(inp.action_of(walk_actions,.Jump))}
}

// The body a gallery seat drives walks along the view of its camera; while it adjusts a panel it
// stands still. A body that fell goes back to where the gallery starts.
@(step="fixed",after="locomotion_seat")
gallery_player_move :: proc(players:core.Read(Gallery_Player),inputs:^core.Table(inp.Move_Input),worlds:core.Read(core.World_Transform),placer:core.Placer,seats:inp.Players,walk_actions:inp.Input_Of(phys.Walk_Action),look_actions:inp.Input_Of(inp.Look_Action),follows:core.Read(cam.Camera_Follow),time:core.Time) {
    for row in 0..<core.count(players) {
        player:=core.at(players,row)
        body:=inp.body_of(seats.drivables,core.entity_at(players,row))
        owner,driven:=core.get(seats.drivables,body)
        input:=core.get(inputs,body)
        placed,exists:=core.get(worlds,body)
        if !driven || input==nil || !exists {continue}
        input.move,input.buttons={},{}
        if player.focus!=core.NONE {input.look_yaw=yaw_of(placed.rotation);continue}
        gallery_player_input(input,placed.rotation,time.dt,owner,walk_actions,look_actions,follows)
        if placed.position.y< -3 {core.place(placer,body,GALLERY_START,at_rest=true)}
    }
}

// E at a station: frame its panel, or drive the spider; E again, or at the spider, gives the
// walk back to Mirai.
@(step="fixed",after="gallery_player_move")
gallery_interact :: proc(players:^core.Table(Gallery_Player),gallery:core.Read(Animation_Gallery),panels:core.Read(Gallery_Panel),worlds:core.Read(core.World_Transform),seats:inp.Players,actions:inp.Input_Of(Action),requests:^inp.Seat_Requests,cameras:^cam.Camera_Requests) {
    for row in 0..<core.count(players) {
        player:=core.at(core.read(players),row)
        seat:=core.entity_at(players,row)
        body:=inp.body_of(seats.drivables,seat)
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
            } else if near!=core.NONE {
                if near==player.spider {inp.drive(requests,seat,player.spider)}
                for at in 0..<core.count(panels) {
                    panel:=core.at(panels,at)
                    if panel.station!=near {continue}
                    entity:=core.entity_at(panels,at)
                    cam.camera_override(cameras,seat,seat,panel.camera,blend=GALLERY_FOCUS_BLEND)
                    next.focus=entity
                }
            }
        }
        if next!=player {core.at(players,row)^=next}
    }
}

GALLERY_PLAQUE_SIZE :: [2]f32{330,64}
GALLERY_PANEL_SIZE :: [2]f32{300,340}
GALLERY_PLAQUE_DISTANCE :: 10 // m from the body of the player within which the plaques show

// The plaques show near the body of the player and a panel only while its player adjusts it: a
// widget without size is not drawn.
@(step="fixed",after="gallery_interact")
gallery_widgets :: proc(players:core.Read(Gallery_Player),labels:core.Read(Gallery_Label),panels:core.Read(Gallery_Panel),widgets:^core.Table(gui.World_Widget),worlds:core.Read(core.World_Transform),drivables:core.Read(inp.Drivable)) {
    player,found:=core.first(players)
    if !found {return}
    focus:=core.at(players,0).focus
    body,_:=core.get(worlds,inp.body_of(drivables,player))
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
    current,exists:=core.get(core.read(widgets),e)
    if !exists || current.size==size && current.input==input {return}
    if widget:=core.get(widgets,e);widget!=nil {widget.size,widget.input=size,input}
}
