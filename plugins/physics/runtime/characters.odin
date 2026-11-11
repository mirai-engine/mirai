package physics

import cmath "core:math"
import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// What a Character is now in the simulation, for what looks around it with the queries of physics (a
// locomotion that climbs a ledge): its feet, the frame of its vertical, the capsule it stands on (height
// that of now, crouched or not) and what it collides with, its own body left out.
Character_Capsule :: struct {
    feet:[3]f32,
    up_frame:mm.Quat,
    radius,height,step_height,max_slope:f32,
    mass:f32, // kg, also when its Character takes it from the density of the capsule
    filter:Query_Filter,
}

// The capsule of the Character of e as the last step left it; not ok without one the simulation made.
character_capsule :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> (capsule:Character_Capsule,ok:bool) {
    if physics.ptr==nil || !physics.ready {return}
    l:=link_find(physics.ptr,e)
    if l==nil || l.kind!=.Character || !sim.character_valid(&physics.world,l.character) {return}
    w:=&physics.world
    desc:=sim.character_desc(w,l.character)
    return {
        feet=sim.character_position(w,l.character),up_frame=sim.character_state(w,l.character).up_frame,
        radius=desc.radius,height=desc.height,step_height=desc.step_height,max_slope=desc.max_slope,mass=desc.mass,
        filter={filter=desc.filter,ignore_body=sim.character_body(w,l.character)},
    },true
}

LANDING_REACH :: 20 // m below its feet, along its up, down to which a falling arc is swept
LANDING_SEGMENTS :: 8 // straight sweeps along the arc

// When a falling character lands and how fast its feet then move down along its up (seconds, m/s;
// negative when what it hits is on its way up). A sphere a little narrower than its capsule, so a
// wall it brushes is not where it lands, sweeps the ballistic arc of its velocity under its
// gravity (that of its body times Character.gravity_scale) until it is LANDING_REACH below its
// feet; time is along the arc to the first hit. Not found without a character made by the
// simulation, with no gravity along its up or with nothing on the arc. Queried on demand: the
// simulation does not keep it.
character_landing :: proc(physics:core.Ref(Physics_State),e:core.Entity) -> (time,speed:f32,ok:bool) {
    if physics.ptr==nil || !physics.ready {return}
    l:=link_find(physics.ptr,e)
    if l==nil || l.kind!=.Character {return}
    return landing_on_arc(&physics.world,l.character)
}

@(private)
landing_on_arc :: proc(w:^sim.World,h:sim.Character_Handle) -> (time,speed:f32,ok:bool) {
    if !sim.character_valid(w,h) {return}
    desc:=sim.character_desc(w,h)
    body:=sim.character_body(w,h)
    gravity:=sim.body_gravity(w,body)*desc.gravity_scale
    up:=mm.quat_rotate(sim.character_state(w,h).up_frame,{0,1,0})
    pull:=-linalg.dot(gravity,up)
    velocity:=sim.character_velocity(w,h)
    if !(pull>1e-4) || pull>max(f32) || !(linalg.dot(gravity,gravity)<=max(f32)) || !(linalg.dot(velocity,velocity)<=max(f32)) {return}
    rising:=linalg.dot(velocity,up)
    end:=(rising+cmath.sqrt(rising*rising+2*pull*LANDING_REACH))/pull
    if !(end>0) || end>max(f32) {return}
    radius:=desc.radius*.9
    start:=sim.character_position(w,h)+up*desc.radius
    filter:=sim.Query_Filter{filter=desc.filter,ignore_body=body}
    from:=start
    for i in 1..=LANDING_SEGMENTS {
        at:=end*f32(i)/LANDING_SEGMENTS
        to:=start+velocity*at+gravity*(.5*at*at)
        if !(linalg.dot(to-from,to-from)<=max(f32)) {return}
        hit,found:=sim.shape_cast_closest(w,sim.Sphere{radius},{from,mm.QUAT_IDENTITY},to-from,filter)
        if !found {
            from=to
            continue
        }
        along:=end*(f32(i-1)+hit.fraction)/LANDING_SEGMENTS
        if rising-pull*along>0 {
            time,speed=along,pull*along-rising
        } else {
            // On its way down the time comes from the height it falls, exact on a straight drop.
            contact:=from+(to-from)*hit.fraction
            height:=max(-linalg.dot(contact-start,up)-(desc.radius-radius),0)
            speed=cmath.sqrt(rising*rising+2*pull*height)
            time=(rising+speed)/pull
        }
        if !(time>0) || time>max(f32) {return 0,0,false}
        return time,speed,true
    }
    return
}
