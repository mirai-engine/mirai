package game

import "mirai:core"
import inp "mirai:engine/input"
import scene "mirai:engine/scene"

// The boat of the raft scene (the vehicles plugin): the swimmer climbs in
// through its hatch and steers it, or takes the seat of its turret and aims
// its gun, and gets off with the use action. What may be entered is this
// game's rule: an Interactable on a Mount, used to its end, seats the player
// whose body used it there.
@(step="fixed",server)
boat_seats :: proc(
    used:core.Ref(scene.Interaction_Events),mounts:^core.Table(inp.Mount,.Read),seat_state:core.Ref(inp.Seats),
    seats:^core.Table(inp.Seat,.Read),actions:inp.Input_Of(Action),requests:^inp.Seat_Requests,
) {
    if core.count(mounts)==0 {return}
    // Who rides gets off with use.
    for row in 0..<core.count(seats) {
        seat:=core.entity_at(seats,row)
        if mount,_:=inp.mount_of_driven(mounts,core.at(seats,row).body);mount!=core.NONE && inp.seat_pressed(actions,seat,.Use) {inp.dismount(requests,seat)}
    }
    for event in used.items {
        if event.kind!=.Completed || !core.has(mounts,event.target) {continue}
        if seat:=inp.driver_of(seat_state,event.actor);seat!=core.NONE {inp.mount(requests,seat,event.target)}
    }
}
