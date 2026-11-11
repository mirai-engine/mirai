package camera

import "mirai:core"
import input "mirai:engine/input"
import render "mirai:engine/render"
import volume "mirai:engine/volume"

// The sky and the sun a player sees change as its body crosses an
// Environment_Trigger: entering the Volume of its entity turns on the ones it
// names, the sky over its seconds. It goes by the body and not by the camera,
// which would cross first; and it is of each end of a session, as what the
// sky shows. A body has to go TRIGGER_MARGIN into the volume to turn it on
// and as far out of it to leave it, so standing on its edge does not
// alternate.

TRIGGER_MARGIN :: f32(0.25) // m

@(component,description="Turns on the sky and the sun it names when the body of the player of this machine goes into the Volume of its entity; the sky blends over its seconds. Put it in a narrow passage, where the geometry hides the change.")
Environment_Trigger :: struct {
    sky,sun:core.Entity,
    seconds:f32 `mirai:"min=0,unit=s"`,    // of the blend of the sky; 0: at once
    inside:bool `mirai:"local,transient,hidden"`, // the body is in it, since it went past the margin
}

ENVIRONMENT_TRIGGER_DEFAULT :: Environment_Trigger{seconds=1}

@(step="frame")
environment_triggers :: proc(
    triggers:^core.Table(Environment_Trigger),volumes:core.Read(volume.Volume),worlds:core.Read(core.World_Transform),
    seat_state:core.Ref(input.Seats),seats:core.Read(input.Seat),
    requests:^render.Environment_Requests,
) {
    if core.count(triggers)==0 {return}
    body:=input.body_of(seats,input.focused(seat_state.ptr,seats))
    at,placed:=core.get(worlds,body)
    for row in 0..<core.count(triggers) {
        e:=core.entity_at(triggers,row)
        trigger:=core.at(triggers,row)
        zone,pose,rules:=volume.placed(volumes,worlds,e)
        inside:=trigger.inside
        if placed && rules {
            depth:=volume.depth(zone,pose,at.position)
            if !inside && depth>=TRIGGER_MARGIN {inside=true} else if inside && depth< -TRIGGER_MARGIN {inside=false}
        } else {
            inside=false
        }
        if inside==trigger.inside {continue}
        core.edit(triggers,e).inside=inside
        if inside {render.activate(requests,trigger.sky,trigger.sun,trigger.seconds)}
    }
}
