package input

import "mirai:core"
import mm "mirai:std/math"

// Where the player who drives a body aims: the view of its seat for the tick
// (Seat_View), placed on the body. It is an input as the actions are, so the
// server, a client and a tick run again aim alike, whatever the cameras of
// each end did.

// What aim reads, for a step to receive in one parameter.
@(params)
Aims :: struct {
    seat_state:core.Ref(Seats),
    runtime:core.Ref(Seat_States),
    worlds:^core.Table(core.World_Transform,.Read),
    verticals:^core.Table(core.Vertical,.Read),
}

// The ray the player who drives body sees along: from where its camera was
// and as it looked, in any camera mode, on every end. False for a body no
// seat drives, without a World_Transform, or whose seat saw through no camera.
aim :: proc(aims:Aims,body:core.Entity) -> (origin,direction:[3]f32,rotation:mm.Quat,ok:bool) {
    seat:=seat_of(aims.seat_state,body)
    if seat==core.NONE {return}
    view:=seat_view(aims.runtime,seat)
    if view.kind==.None {return}
    placed:=core.get(aims.worlds,body) or_return
    origin,rotation=view_aim(view,placed.position,core.vertical_of(aims.verticals,body))
    return origin,mm.quat_forward(rotation),rotation,true
}

// The origin and rotation of a view of a body at position, in the frame of
// its vertical.
view_aim :: proc "contextless" (view:Seat_View,position:[3]f32,vertical:mm.Quat) -> (origin:[3]f32,rotation:mm.Quat) {
    rotation=vertical*mm.quat_axis_angle({0,1,0},view.yaw)*mm.quat_axis_angle({1,0,0},view.pitch)
    return position+mm.quat_rotate(vertical,view.eye),rotation
}
