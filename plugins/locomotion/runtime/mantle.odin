package locomotion

import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// A mantle is a custom mode written on the extension point of locomotion: mantle_step runs before
// locomotion_prepare, asks for MODE_MANTLING with set_mode when a jump faces a ledge (ledge_find),
// writes the Character_Move of every tick of the climb and gives the character back to its walk,
// falling onto what it climbed. Without Mantle rows it costs nothing.
@(name_requires="Mantle") MODE_MANTLING :: Locomotion_Mode(6)

@(component,replicated,description="The character can mantle (mode mantling of its Character): with jump, looking at a wall within reach whose top is between min_height and max_height over its feet, with room to stand there and on the way, it climbs onto it in time. Standing, a top lower than ground_height is jumped onto instead; in the air, jump held climbs once delay has passed since it left the ground. Its Mantle_State keeps the height of the ledge for the animation of the climb. It needs a Walk.")
Mantle :: struct {
    reach:f32 `mirai:"min=0,unit=m"`,         // from its axis, ahead, where it looks for the wall
    min_height:f32 `mirai:"min=0,unit=m"`,
    max_height:f32 `mirai:"min=0,unit=m"`,
    ground_height:f32 `mirai:"min=0,unit=m"`, // standing, ledges at most this high are jumped onto
    facing:f32 `mirai:"angle,min=0"`,         // most the wall is off where it looks
    time:f32 `mirai:"min=0,unit=s"`,          // of the climb
    delay:f32 `mirai:"min=0,unit=s"`,         // in the air since it left the ground before jump held climbs
}

MANTLE_DEFAULT :: Mantle{reach=1,min_height=0.5,max_height=2.5,ground_height=1.2,facing=45*mm.RAD_PER_DEG,time=0.6,delay=0.25}

@(component,derived,replicated,description="The climb of a character that mantles.")
Mantle_State :: struct {
    from,to:[3]f32 `mirai:"transient,readonly,unit=m"`, // where its feet start and end the climb, in the world: what warps a clip of it
    normal:[3]f32 `mirai:"transient,readonly"`,         // of the face of the wall it climbs, across its up and out of it: the climb faces -normal
    time:f32 `mirai:"transient,readonly,hidden,unit=s"`,       // of the climb
    height:f32 `mirai:"transient,readonly,unit=m"`,            // of the ledge of its last climb over its feet: the animation of the climb chooses by it
    air_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,   // since it last stood
}

// The id of the layered move that stops the body where a climb ends, on the tick its walk takes it
// back.
MANTLE_STOP :: u32(0x4d4e_5354)

@(private) MANTLE_TOLERANCE :: f32(0.4) // m off the way at which a climb is given up: something pushed it
@(private) MANTLE_RISE :: f32(0.6)     // share of the climb by which it has risen
@(private) MANTLE_ACROSS :: f32(0.4)   // and from which it moves across onto the top

@(step="fixed",stage="simulate",before="locomotion_prepare")
mantle_step :: proc(
    mantles:^core.Table(Mantle,.Read),states:^core.Table(Mantle_State),locos:^core.Table(Locomotion_State,.Read),
    walks:^core.Table(Walk,.Read),characters:^core.Table(phys.Character,.Read),colliders:^core.Table(phys.Collider,.Read),
    found:^core.Table(phys.Character_State,.Read),inputs:^core.Table(input.Move_Input,.Read),
    locals:^core.Table(core.Transform,.Read),parents:^core.Table(core.Parent,.Read),
    moves:^core.Table(phys.Character_Move),requests:^Locomotion_Requests,physics:core.Ref(phys.Physics_State),
    paces:^core.Table(core.Own_Pace,.Read),walk_actions:input.Input_Of(Walk_Action),time:core.Time,clock:core.Clock,
) {
    for e in states.entities {
        if !core.has(mantles,e) || !core.has(locos,e) || !core.has(walks,e) || !phys.character_owner(characters,colliders,e) {core.remove(states,e)}
    }
    if !time.playing || time.dt<=0 {return}
    jump:=input.action_of(walk_actions,.Jump)
    for row in 0..<core.count(mantles) {
        e:=core.entity_at(mantles,row)
        mantle:=core.at(mantles,row)
        loco,moving:=core.get(locos,e)
        body,bodied:=core.get(characters,e)
        if !moving || !bodied || !core.has(walks,e) || !phys.character_owner(characters,colliders,e) {continue}
        if !core.has(states,e) {core.add(states,e,Mantle_State{})}
        s:=core.staged(states,e)
        if s==nil {continue}
        dt:=time.dt*core.pace_of(clock,paces,e)
        ground,_:=core.get(found,e)
        asked,_:=core.get(inputs,e)
        capsule,made:=phys.character_capsule(physics,e)
        placed,ok:=core.world_of(locals,parents,e)
        if ground.standing {s.air_time=0} else {s.air_time+=dt}
        climbing:=loco.mode==MODE_MANTLING
        if loco.suspended || !made || !ok {
            if climbing {set_mode(requests,e,MODE_FALLING)}
            continue
        }
        frame:=capsule.up_frame
        if !climbing {
            wanted,from_ground:=mantle_wanted(loco,s^,mantle,ground,asked.buttons&input.action_bit(jump)!=0)
            if !wanted || layered_override(loco) {continue}
            facing:=mm.quat_forward(frame*mm.quat_axis_angle({0,1,0},loco.yaw))
            to,height,normal,found_ledge:=ledge_find(physics,capsule,facing,{mantle.reach,mantle.min_height,mantle.max_height,mantle.facing})
            if !found_ledge || from_ground && height<=mantle.ground_height {continue}
            s.from,s.to,s.normal,s.time,s.height=placed.position,to,normal,0,height
            set_mode(requests,e,MODE_MANTLING)
        }
        // Driven by root motion in the last tick (an Override layered move: the animation of the
        // climb, warped onto the ledge), it goes where that takes it and only its time runs.
        next:phys.Character_Move
        ended:bool
        next.value,ended=mantle_move(s,body,mantle,frame,placed.position,dt,loco.overridden)
        if ended {
            // It stops where the climb left it, up and across, and falls from there.
            s.air_time=0
            set_mode(requests,e,MODE_FALLING)
            add_move(requests,e,{ticks=1,mix=.Override,id=MANTLE_STOP})
            continue
        }
        next.value.yaw=loco.yaw
        next.value.gravity_scale=loco.gravity
        if move:=core.edit(moves,e);move!=nil {move^=next} else {core.add(moves,e,next)}
    }
}

// Whether a character asks to mantle this tick: jump pressed while it stands (from_ground), or
// jump held once it has been delay in the air.
mantle_wanted :: proc "contextless" (loco:Locomotion_State,s:Mantle_State,mantle:Mantle,ground:phys.Character_State,held:bool) -> (wanted,from_ground:bool) {
    switch loco.mode {
    case MODE_WALKING,MODE_CROUCHING:
        if ground.standing && held && !loco.jump_held {return true,true}
    case MODE_FALLING:
        if !ground.standing && held && s.air_time>=mantle.delay {return true,false}
    }
    return false,false
}

// Where the feet are a share u of the way of a climb: up along the wall first, then across onto the
// top, the two overlapping (MANTLE_RISE, MANTLE_ACROSS) and each easing in and out.
mantle_point :: proc "contextless" (from,to,up:[3]f32,u:f32) -> [3]f32 {
    rise:=linalg.dot(to-from,up)
    flat:=to-from-up*rise
    return from+up*(rise*mm.smoothstep(0,MANTLE_RISE,u))+flat*mm.smoothstep(MANTLE_ACROSS,1,u)
}

// The drive of a tick of a climb, from where its feet are: one that overrides gravity and the ground
// and takes the feet where the way puts them at the end of the tick. It ends at the end of the way,
// or when something holds it off the way unless driven.
mantle_move :: proc(s:^Mantle_State,body:phys.Character,mantle:Mantle,frame:mm.Quat,position:[3]f32,dt:f32,driven:=false) -> (move:phys.Character_Drive,ended:bool) {
    up:=mm.quat_rotate(frame,{0,1,0})
    length:=max(mantle.time,dt)
    now:=mantle_point(s.from,s.to,up,min(s.time/length,1))
    off:=position-now
    if s.time>=length || !driven && linalg.dot(off,off)>MANTLE_TOLERANCE*MANTLE_TOLERANCE {return {},true}
    s.time+=dt
    next:=mantle_point(s.from,s.to,up,min(s.time/length,1))
    drive:=phys.Drive{(next-position)/dt,body.traction_force}
    move.ground,move.air=drive,drive
    move.flags={.Airborne,.Drive_Vertical,.No_Gravity,.Reach_Drive}
    return
}
