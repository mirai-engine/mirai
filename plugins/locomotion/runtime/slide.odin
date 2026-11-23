package locomotion

import cmath "core:math"
import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// A slide is a custom mode written on the extension point of locomotion: slide_step runs before
// locomotion_prepare, asks for MODE_SLIDING with set_mode and writes the Character_Move of every
// tick of it, and hands the character back to its walk with set_mode. Without Slide rows it costs
// nothing.
@(name_requires="Slide") MODE_SLIDING :: Locomotion_Mode(5)

@(component,replicated,description="The character can slide (mode sliding of its Character): crouching while it runs at start_speed or faster, or landing at land_speed with crouch pressed within buffer before (or held), it slides along the ground at its speed, at least min_speed and at most max_speed, which gravity changes on a slope and friction takes, steering toward its move a little. It stops after time unless the ground falls away along its course, when something stops it, or with a jump. It needs a Walk with a crouch_height, the height it slides at.")
Slide :: struct {
    start_speed:f32 `mirai:"min=0,unit=m/s"`, // across its up, from which crouch starts a slide
    land_speed:f32 `mirai:"min=0,unit=m/s"`,  // the same for crouch held when it lands
    max_speed:f32 `mirai:"min=0,unit=m/s"`,
    min_speed:f32 `mirai:"min=0,unit=m/s"`,   // its speed along its course while it slides is never under it
    buffer:f32 `mirai:"min=0,unit=s"`,        // a crouch pressed this long before landing slides on landing
    time:f32 `mirai:"min=0,unit=s"`,          // it slides at most this long, unless downhill
    friction:f32 `mirai:"min=0,unit=1/s"`,    // share of its speed lost every second
    downhill_angle:f32 `mirai:"angle,min=0"`, // ground that falls away along its course steeper than this keeps it sliding past time
    steer_angle:f32 `mirai:"angle,min=0"`,    // most its move turns its course from where it started
    steer_speed:f32 `mirai:"angle,min=0,unit=deg/s"`,
    cooldown:f32 `mirai:"min=0,unit=s"`,      // after a slide, before crouch starts another
}

SLIDE_DEFAULT :: Slide{start_speed=4.5,land_speed=1.5,max_speed=12,min_speed=4,buffer=1.5,time=1.25,friction=0,downhill_angle=10*mm.RAD_PER_DEG,steer_angle=20*mm.RAD_PER_DEG,steer_speed=15*mm.RAD_PER_DEG,cooldown=0.5}

@(component,derived,replicated,description="What the slide of a character carries between ticks.")
Slide_State :: struct {
    buffer:f32 `mirai:"transient,readonly,hidden,unit=s"`,   // left of a crouch pressed in the air, which slides on landing
    cooldown:f32 `mirai:"transient,readonly,hidden,unit=s"`, // left before crouch starts another slide
    time:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // it has slid
    course:[3]f32 `mirai:"transient,readonly,hidden"`,       // where it started sliding, across its up
    turn:f32 `mirai:"transient,readonly,hidden,angle"`,      // its move turned the course from there, left about its up
}

@(private) SLIDE_BLOCKED :: f32(0.5)     // share of the speed of the slide under which the body is held back
@(private) SLIDE_BLOCK_AFTER :: f32(0.1) // s into a slide before that is checked: it starts from the speed the body had

// Starts a slide from a crouch at a run or a landing with crouch, slides along the ground, and
// ends it standing (crouched when crouch is held without a move, or with crouch_toggle on and no
// move), falling when the ground goes, or with a jump, which its walk then takes.
@(step="fixed",stage="simulate",before="locomotion_prepare")
slide_step :: proc(
    slides:^core.Table(Slide,.Read),states:^core.Table(Slide_State),locos:^core.Table(Locomotion_State,.Read),
    walks:^core.Table(Walk,.Read),characters:^core.Table(phys.Character,.Read),colliders:^core.Table(phys.Collider,.Read),
    found:^core.Table(phys.Character_State,.Read),motions:^core.Table(core.Motion,.Read),inputs:^core.Table(input.Move_Input,.Read),
    moves:^core.Table(phys.Character_Move),requests:^Locomotion_Requests,physics:core.Ref(phys.Physics_State),
    paces:^core.Table(core.Own_Pace,.Read),walk_actions:input.Input_Of(Walk_Action),time:core.Time,clock:core.Clock,
) {
    for e in states.entities {
        if !core.has(slides,e) || !core.has(locos,e) || !core.has(walks,e) || !phys.character_owner(characters,colliders,e) {core.remove(states,e)}
    }
    if !time.playing || time.dt<=0 {return}
    jump,crouch:=input.action_of(walk_actions,.Jump),input.action_of(walk_actions,.Crouch)
    for row in 0..<core.count(slides) {
        e:=core.entity_at(slides,row)
        slide:=core.at(slides,row)
        loco,moving:=core.get(locos,e)
        walk,walking:=core.get(walks,e)
        body,bodied:=core.get(characters,e)
        if !moving || !walking || !bodied || !phys.character_owner(characters,colliders,e) {continue}
        if !core.has(states,e) {core.add(states,e,Slide_State{})}
        s:=core.staged(states,e)
        if s==nil {continue}
        pace:=core.pace_of(clock,paces,e)
        dt:=time.dt*pace
        ground,_:=core.get(found,e)
        motion,_:=core.get(motions,e)
        asked,_:=core.get(inputs,e)
        capsule,made:=phys.character_capsule(physics,e)
        frame:=capsule.up_frame if made else mm.QUAT_IDENTITY
        up:=mm.quat_rotate(frame,{0,1,0})
        crouches:=walk.crouch_height>0
        crouch_down:=crouches && asked.buttons&input.action_bit(crouch)!=0
        crouch_pressed:=crouch_down && !loco.crouch_held
        if !ground.standing && crouch_pressed {s.buffer=slide.buffer} else {s.buffer=max(s.buffer-dt,0)}
        s.cooldown=max(s.cooldown-dt,0)
        sliding:=loco.mode==MODE_SLIDING
        if loco.suspended {
            if sliding {set_mode(requests,e,MODE_FALLING)}
            continue
        }
        // Its velocity in its own time, without what additive layered moves put in it.
        own:=loco.pace if loco.pace>0 else 1
        v:=motion.linear/own
        v-=additive_delivered(v,loco.added,loco.driven)
        ground_velocity:=ground.ground_velocity/pace
        n:=ground.ground_normal
        if linalg.dot(n,up)<=0 {n=up}
        relative:=v-ground_velocity
        current:=relative-n*linalg.dot(relative,n)
        given:=move_facing(asked,loco.yaw,frame)
        wish:=move_wish(given,frame,walk.max_speed)
        if sliding {
            jumped:=asked.buttons&input.action_bit(jump)!=0 && !loco.jump_held && walk.jump_height>0
            if jumped || !(crouches && ground.standing) {
                // Its walk takes the jump, or the fall, this tick.
                s.cooldown=slide.cooldown
                set_mode(requests,e,MODE_WALKING if ground.standing else MODE_FALLING)
                continue
            }
        } else {
            // Whether its walk crouches with this input: what slides at a run.
            on:=crouch_down && !loco.crouch_lock
            if walk.crouch_toggle {on=!loco.crouch_on if crouch_pressed else loco.crouch_on}
            landing:=loco.mode==MODE_FALLING && (s.buffer>0 || !walk.crouch_toggle && crouch_down)
            speed:=linalg.length(current)
            walks_now:=loco.mode==MODE_WALKING || loco.mode==MODE_CROUCHING || loco.mode==MODE_FALLING
            if !walks_now || !crouches || !ground.standing || s.cooldown>0 || loco.crouch_lock && crouch_down {continue}
            if !(crouch_pressed && on && speed>=slide.start_speed || landing && speed>=slide.land_speed) {continue}
            s.buffer=0
            slide_start(s,current,up)
            set_mode(requests,e,MODE_SLIDING)
        }
        gravity:=phys.gravity_of_entity(physics,e)*body.gravity_scale*locomotion_gravity(loco)
        velocity,ended:=slide_velocity(s,slide,n,up,current,wish,gravity,dt)
        if ended {
            // It stands up when it moves; without a move it stays crouched.
            s.cooldown=slide.cooldown
            set_mode(requests,e,MODE_WALKING if wish!={} else MODE_CROUCHING)
            continue
        }
        next:phys.Character_Move
        next.value.ground={velocity,body.traction_force}
        next.value.air={velocity=v-up*linalg.dot(v,up)}
        next.value.yaw=mm.angle_wrap(loco.yaw+ground.ground_turn)
        if walk.turn_speed>0 {
            next.value.yaw=mm.angle_wrap(mm.angle_approach(next.value.yaw,asked.look_yaw,walk.turn_speed*dt))
        } else {next.value.yaw=asked.look_yaw}
        next.value.flags={.Reach_Drive}
        next.value.gravity_scale=loco.gravity
        next.height=walk.crouch_height
        if move:=core.edit(moves,e);move!=nil {move^=next} else {core.add(moves,e,next)}
    }
}

// The velocity along the ground of a tick of a slide, and whether it ends: its speed, which gravity
// along its course changes and friction takes, along its course, which the move turns toward itself
// at most steer_angle from where it started at steer_speed. n is the normal of the ground, current
// its velocity along it relative to the ground.
@(private)
slide_velocity :: proc(s:^Slide_State,slide:Slide,n,up,current,wish,gravity:[3]f32,dt:f32) -> (velocity:[3]f32,ended:bool) {
    s.time+=dt
    if flat:=wish-up*linalg.dot(wish,up);linalg.dot(flat,flat)>1e-8 {
        start:=s.course
        want:=clamp(linalg.atan2(linalg.dot(linalg.cross(start,flat),up),linalg.dot(start,flat)),-slide.steer_angle,slide.steer_angle)
        s.turn=mm.angle_approach(s.turn,want,slide.steer_speed*dt)
    }
    course:=mm.quat_rotate(mm.quat_axis_angle(up,s.turn),s.course)
    along:=course-n*linalg.dot(course,n)
    if l:=linalg.length(along);l>1e-6 {along/=l} else {along=course}
    moving:=linalg.length(current)
    speed:=clamp(moving+(linalg.dot(gravity,along)-slide.friction*moving)*dt,slide.min_speed,max(slide.max_speed,slide.min_speed))
    downhill:=-linalg.dot(along,up)>cmath.sin(slide.downhill_angle)
    // Something in the way: the body goes at under half the speed the slide drives it at.
    blocked:=s.time>SLIDE_BLOCK_AFTER && moving<SLIDE_BLOCKED*speed
    ended=blocked || s.time>=slide.time && !downhill
    return along*speed,ended
}

@(private)
slide_start :: proc "contextless" (s:^Slide_State,current,up:[3]f32) {
    course:=current-up*linalg.dot(current,up)
    if l:=linalg.length(course);l>1e-6 {course/=l}
    s.course,s.turn,s.time=course,0,0
}
