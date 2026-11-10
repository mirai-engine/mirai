package physics

import cmath "core:math"
import "core:math/linalg"
import input "mirai:engine/input"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// Crouch, slide and mantle, the modes of a character that walks beyond walking and falling, and the
// tactical sprint and the ledge jump, which change its walk and its jump.
// Crouching (the crouch action held while it stands, with a Walk whose crouch_height is not zero)
// makes its capsule that tall and walks at crouch_speed; it stands up again when the action is let go
// and what is over it lets it (Character_State.cramped meanwhile). A Slide turns a crouch at a run
// into a slide along the ground, and a Mantle turns a jump facing a ledge into a climb onto it. A
// Tactical_Sprint spends energy for a faster sprint and jump, and a Ledge_Jump turns a jump at speed
// where the ground falls away ahead into a longer one.

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

@(component,replicated,description="The character can mantle (mode mantling of its Character): with jump, looking at a wall within reach whose top is between min_height and max_height over its feet, with room to stand there and on the way, it climbs onto it in time. Standing, a top lower than ground_height is jumped onto instead; in the air, jump held climbs once delay has passed since it left the ground. Its Locomotion_State keeps the height of the ledge (mantle_height) for the animation of the climb. It needs a Walk.")
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

@(component,replicated,description="The sprint of the character spends energy for more speed (tactical sprint): sprinting on the ground with at least min_energy, its top speed ramps from the sprint_speed of its Walk to speed_multiplier times it over speed_ramp, growing by the same factor every instant, it accelerates acceleration_multiplier times faster and its jumps go up to jump_multiplier times faster (over jump_ramp). It spends cost_per_second while it runs (not in the air when pause_falling), cost_jump on a jump and cost_slide when it slides; it ends without energy, after going down in the air for fall_grace, once sprint is let go, or after the move points off forward for grace. Energy comes back at recharge per second recharge_delay after it was last spent. Without energy it sprints as its Walk says. It needs a Walk.")
Tactical_Sprint :: struct {
    speed_multiplier:f32 `mirai:"min=1"`,        // of the sprint_speed of its Walk, at the end of the ramp
    acceleration_multiplier:f32 `mirai:"min=0"`, // of the acceleration of its Walk on the ground while it lasts
    jump_multiplier:f32 `mirai:"min=1"`,         // of the speed of its jumps, at the end of the ramp
    speed_ramp:f32 `mirai:"min=0,unit=s"`,       // from the start of the sprint to speed_multiplier, exponentially; 0: whole at once
    jump_ramp:f32 `mirai:"min=0,unit=s"`,        // the same to jump_multiplier
    energy:f32 `mirai:"min=0"`,                  // most it holds
    min_energy:f32 `mirai:"min=0"`,              // it starts only with this much
    cost_per_second:f32 `mirai:"min=0,unit=1/s"`,
    cost_jump:f32 `mirai:"min=0"`,
    cost_slide:f32 `mirai:"min=0"`,
    recharge:f32 `mirai:"min=0,unit=1/s"`,
    recharge_delay:f32 `mirai:"min=0,unit=s"`,   // after energy was last spent
    fall_grace:f32 `mirai:"min=0,unit=s"`,       // going down in the air past this it ends
    grace:f32 `mirai:"min=0,unit=s"`,            // the move off forward this long, with sprint held, ends it; back within it, it goes on. Letting go of sprint ends it at once
    pause_falling:bool,                          // it spends nothing in the air
}

TACTICAL_SPRINT_DEFAULT :: Tactical_Sprint{speed_multiplier=1.4,acceleration_multiplier=3,jump_multiplier=1.2,speed_ramp=0.6224,jump_ramp=0.7265,energy=115,min_energy=10,cost_per_second=15,cost_jump=18,cost_slide=10,recharge=52,recharge_delay=2,fall_grace=0.5,grace=0.5,pause_falling=true}

@(component,replicated,description="The character jumps off a ledge farther (ledge jump): standing at min_speed or faster for min_time, with nothing in the way for reach ahead along where it goes and no ground there within min_drop under its feet, it is ready (Locomotion_State.ledge_ready) and a jump adds added_speed along where it goes, at most max_speed across its up, and up_speed up to the speed of its jump. It lasts until it lands (Locomotion_State.ledge_jumping), and meanwhile air control steers it without slowing it. It needs a Walk.")
Ledge_Jump :: struct {
    min_speed:f32 `mirai:"min=0,unit=m/s"`, // across its up, relative to the ground
    min_time:f32 `mirai:"min=0,unit=s"`,    // standing at min_speed or more
    reach:f32 `mirai:"min=0,unit=m"`,       // ahead of its feet, where the ground has to fall away
    min_drop:f32 `mirai:"min=0,unit=m"`,    // under its feet there
    added_speed:f32 `mirai:"min=0,unit=m/s"`,
    max_speed:f32 `mirai:"min=0,unit=m/s"`, // across its up after the launch
    up_speed:f32 `mirai:"min=0,unit=m/s"`,  // over that of its jump
}

LEDGE_JUMP_DEFAULT :: Ledge_Jump{min_speed=6,min_time=0.25,reach=1.5,min_drop=1.9,added_speed=8,max_speed=10.24,up_speed=0.8}

// The multipliers of speed and jump of a tactical sprint that has lasted sprint_time: each grows
// by the same factor every instant from 1 to its whole value over its ramp. 1 outside a tactical
// sprint.
tactical_boost :: proc "contextless" (loco:Locomotion_State,tactical:Tactical_Sprint) -> (speed,jump:f32) {
    if !loco.sprint_active {return 1,1}
    ramp :: proc "contextless" (whole,seconds,elapsed:f32) -> f32 {
        whole:=max(whole,1)
        if !(seconds>0) {return whole}
        return cmath.pow(whole,clamp(max(elapsed,0)/seconds,0,1))
    }
    return ramp(tactical.speed_multiplier,tactical.speed_ramp,loco.sprint_time),ramp(tactical.jump_multiplier,tactical.jump_ramp,loco.sprint_time)
}

// The energy left of the tactical sprint of a character.
tactical_energy :: proc "contextless" (loco:Locomotion_State,tactical:Tactical_Sprint) -> f32 {
    return clamp(tactical.energy-loco.sprint_spent,0,tactical.energy)
}

@(private)
tactical_spend :: proc "contextless" (loco:^Locomotion_State,tactical:Tactical_Sprint,amount:f32) {
    if !(amount>0) {return}
    loco.sprint_spent=min(loco.sprint_spent+amount,tactical.energy)
    loco.sprint_rest=0
    if loco.sprint_spent>=tactical.energy {loco.sprint_active=false}
}

// A tick of the energy and the state of a tactical sprint, before the speed of the walk is taken:
// sprinting says whether the input sprints (sprint held, the move forward), walking whether it
// runs standing (not crouched or sliding). It starts sprinting on the ground with min_energy; it
// ends without energy, falling past fall_grace, out of walking or falling, or past grace without
// sprinting. Energy comes back once it has rested recharge_delay.
@(private)
tactical_update :: proc "contextless" (loco:^Locomotion_State,tactical:Tactical_Sprint,sprinting,walking,standing:bool,dt:f32,held:=true) {
    loco.sprint_rest+=dt
    if loco.sprint_active {
        loco.sprint_off=0 if sprinting else loco.sprint_off+dt
        if !held || !walking || !standing && loco.fall_time>tactical.fall_grace || loco.sprint_off>=tactical.grace {loco.sprint_active=false}
    } else if sprinting && walking && standing && tactical_energy(loco^,tactical)>=tactical.min_energy && tactical.energy>0 {
        loco.sprint_active,loco.sprint_time,loco.sprint_off=true,0,0
    }
    if loco.sprint_active {
        loco.sprint_time+=dt
        if standing || !tactical.pause_falling {tactical_spend(loco,tactical,tactical.cost_per_second*dt)}
    }
    if !loco.sprint_active && loco.sprint_rest>=tactical.recharge_delay {
        loco.sprint_spent=max(loco.sprint_spent-tactical.recharge*dt,0)
    }
}

// Whether the ground falls away ahead of a standing character along direction: a sphere almost as
// wide as it, from over its step, meets nothing for reach, and a ray down from there, from its
// step over its feet, meets no ground within min_drop under them. It is what makes it ready for a
// ledge jump.
ledge_drop_ahead :: proc(w:^sim.World,h:sim.Character_Handle,direction:[3]f32,ledge:Ledge_Jump) -> bool {
    if !sim.character_valid(w,h) || !(ledge.reach>0) || !(ledge.min_drop>0) {return false}
    desc:=sim.character_desc(w,h)
    up:=mm.quat_rotate(sim.character_state(w,h).up_frame,{0,1,0})
    ahead:=direction-up*linalg.dot(direction,up)
    if l:=linalg.length(ahead);l>1e-6 && l<=max(f32) {ahead/=l} else {return false}
    feet:=sim.character_position(w,h)
    filter:=sim.Query_Filter{filter=desc.filter,ignore_body=sim.character_body(w,h)}
    radius:=desc.radius*LEDGE_SWEEP
    if _,blocked:=sim.shape_cast_closest(w,sim.Sphere{radius},{feet+up*(desc.step_height+desc.radius),mm.QUAT_IDENTITY},ahead*ledge.reach,filter);blocked {return false}
    _,ground:=sim.ray_cast_closest(w,feet+ahead*ledge.reach+up*desc.step_height,-up*(desc.step_height+ledge.min_drop),filter)
    return !ground
}

// Whether a character with a Ledge_Jump is ready for one this tick: it has stood at min_speed for
// min_time, it walks and the ground falls away ahead along its velocity over the ground.
ledge_ready_update :: proc(loco:^Locomotion_State,ledge:Ledge_Jump,ground:Character_State,velocity:[3]f32,w:^sim.World,h:sim.Character_Handle) {
    loco.ledge_ready=false
    if loco.ledge_jumping || !ground.standing || loco.mode!=MODE_WALKING || loco.ledge_time<ledge.min_time || overriding(loco) {return}
    loco.ledge_ready=ledge_drop_ahead(w,h,velocity-ground.ground_velocity,ledge)
}

@(private) SLIDE_BLOCKED :: f32(0.5)     // share of the speed of the slide under which the body is held back
@(private) SLIDE_BLOCK_AFTER :: f32(0.1) // s into a slide before that is checked: it starts from the speed the body had
@(private) LEDGE_PROBE :: f32(0.5)     // share of its radius of the sphere that looks for the wall
@(private) LEDGE_WALL :: f32(0.7)      // least part of the normal of a wall across its up: within 45° of upright
@(private) LEDGE_INSET :: f32(0.05)    // m past the face, and over the top, the capsule is put
@(private) LEDGE_TOP_STEPS :: 6        // rays down from the face to a radius past it that find how far the top goes
@(private) LEDGE_TOP_STEP :: f32(0.05) // m off the height of the top at which a ray has left it
@(private) LEDGE_SWEEP :: f32(0.9)     // share of its radius the capsule swept along the way has
@(private) MANTLE_TOLERANCE :: f32(0.4) // m off the way at which a climb is given up: something pushed it
@(private) MANTLE_FORCE :: f32(10)     // times its traction force that drives the climb
@(private) MANTLE_RISE :: f32(0.6)     // share of the climb by which it has risen
@(private) MANTLE_ACROSS :: f32(0.4)   // and from which it moves across onto the top

// The top speed of a walk crouched: crouch_speed, which neither sprint nor moving back change.
@(private)
crouch_speed :: proc "contextless" (walk:Walk) -> f32 {return max(walk.crouch_speed,0)}

// The velocity along the ground of a tick of a slide, and whether it ends: its speed, which gravity
// along its course changes and friction takes, along its course, which the move turns toward itself
// at most steer_angle from where it started at steer_speed. n is the normal of the ground, current
// its velocity along it relative to the ground.
@(private)
slide_velocity :: proc(loco:^Locomotion_State,slide:Slide,n,up,current,wish,gravity:[3]f32,dt:f32) -> (velocity:[3]f32,ended:bool) {
    loco.slide_time+=dt
    if flat:=wish-up*linalg.dot(wish,up);linalg.dot(flat,flat)>1e-8 {
        start:=loco.slide_course
        want:=clamp(linalg.atan2(linalg.dot(linalg.cross(start,flat),up),linalg.dot(start,flat)),-slide.steer_angle,slide.steer_angle)
        loco.slide_turn=mm.angle_approach(loco.slide_turn,want,slide.steer_speed*dt)
    }
    course:=mm.quat_rotate(mm.quat_axis_angle(up,loco.slide_turn),loco.slide_course)
    along:=course-n*linalg.dot(course,n)
    if l:=linalg.length(along);l>1e-6 {along/=l} else {along=course}
    moving:=linalg.length(current)
    speed:=clamp(moving+(linalg.dot(gravity,along)-slide.friction*moving)*dt,slide.min_speed,max(slide.max_speed,slide.min_speed))
    downhill:=-linalg.dot(along,up)>cmath.sin(slide.downhill_angle)
    // Something in the way: the body goes at under half the speed the slide drives it at.
    blocked:=loco.slide_time>SLIDE_BLOCK_AFTER && moving<SLIDE_BLOCKED*speed
    ended=blocked || loco.slide_time>=slide.time && !downhill
    return along*speed,ended
}

@(private)
slide_start :: proc "contextless" (loco:^Locomotion_State,current,up:[3]f32) {
    course:=current-up*linalg.dot(current,up)
    if l:=linalg.length(course);l>1e-6 {course/=l}
    loco.slide_course,loco.slide_turn,loco.slide_time=course,0,0
}

// Whether a character asks to mantle this tick, before its locomotion takes the jump: jump pressed
// while it stands (from_ground), or jump held once it has been delay in the air.
mantle_wanted :: proc "contextless" (loco:^Locomotion_State,mantle:Mantle,ground:Character_State,move_input:input.Move_Input,jump:input.Action) -> (wanted,from_ground:bool) {
    held:=move_input.buttons&input.action_bit(jump)!=0
    switch loco.mode {
    case MODE_WALKING,MODE_CROUCHING:
        if ground.standing && held && !loco.jump_held {return true,true}
    case MODE_FALLING:
        if !ground.standing && held && loco.air_time>=mantle.delay {return true,false}
    }
    return false,false
}

// Where a character can mantle onto ahead of it toward facing: its feet on the top of a ledge, height
// over its feet. A sphere half its radius from just over its step finds the wall within reach, which is
// within 45° of upright and within facing of where it looks; a ray down from max_height over its feet,
// just past the face, finds the top, walkable for it, between min_height and max_height (over
// ground_height from_ground). The feet go a radius past the face, or onto the middle of a top
// narrower than that (the top of a thin wall). Its capsule fits standing there, and a thinner one
// goes up along the wall and across onto it without hitting anything.
ledge_find :: proc(w:^sim.World,h:sim.Character_Handle,facing:[3]f32,mantle:Mantle,from_ground:bool) -> (to:[3]f32,height:f32,found:bool) {
    if !sim.character_valid(w,h) || !(mantle.reach>0) || !(mantle.max_height>mantle.min_height) {return}
    desc:=sim.character_desc(w,h)
    frame:=sim.character_state(w,h).up_frame
    up:=mm.quat_rotate(frame,{0,1,0})
    ahead:=facing-up*linalg.dot(facing,up)
    if l:=linalg.length(ahead);l>1e-6 {ahead/=l} else {return}
    feet:=sim.character_position(w,h)
    filter:=sim.Query_Filter{filter=desc.filter,ignore_body=sim.character_body(w,h)}
    probe:=desc.radius*LEDGE_PROBE
    wall,hit:=sim.shape_cast_closest(w,sim.Sphere{probe},{feet+up*(desc.step_height+probe),mm.QUAT_IDENTITY},ahead*mantle.reach,filter)
    if !hit || !(wall.fraction>0) {return}
    across:=wall.normal-up*linalg.dot(wall.normal,up)
    span:=linalg.length(across)
    if span<LEDGE_WALL {return}
    into:=-across/span
    if linalg.dot(into,ahead)<cmath.cos(mantle.facing) {return}
    face:=wall.point-up*linalg.dot(wall.point-feet,up)
    drop:=mantle.max_height+LEDGE_INSET-mantle.min_height
    top_at :: proc(w:^sim.World,face,into,up:[3]f32,depth,over,drop:f32,filter:sim.Query_Filter) -> (sim.Ray_Hit,bool) {
        return sim.ray_cast_closest(w,face+into*depth+up*over,-up*drop,filter)
    }
    top,landed:=top_at(w,face,into,up,LEDGE_INSET,mantle.max_height+LEDGE_INSET,drop,filter)
    if !landed || !(top.fraction>0) || linalg.dot(top.normal,up)<cmath.cos(desc.max_slope) {return}
    height=linalg.dot(top.point-feet,up)
    if height<mantle.min_height || height>mantle.max_height || from_ground && height<=mantle.ground_height {return}
    // As far onto the top as a radius past the face, while it goes on at that height.
    stand:=desc.radius+LEDGE_INSET
    reached:=f32(LEDGE_INSET)
    for step in 1..=LEDGE_TOP_STEPS {
        depth:=LEDGE_INSET+(stand-LEDGE_INSET)*f32(step)/LEDGE_TOP_STEPS
        hit,ok:=top_at(w,face,into,up,depth,mantle.max_height+LEDGE_INSET,drop,filter)
        if !ok || abs(linalg.dot(hit.point-top.point,up))>LEDGE_TOP_STEP {break}
        reached=depth
    }
    if reached<stand {stand=0.5*(reached+LEDGE_INSET)}
    top.point=face+into*stand+up*linalg.dot(top.point-face,up)
    center:=desc.step_height+0.5*(desc.height-desc.step_height)
    capsule:=sim.Capsule{desc.radius,0.5*(desc.height-desc.step_height)-desc.radius}
    blocking:[1]sim.Shape_Handle
    if sim.overlap_shape(w,capsule,{top.point+up*(center+LEDGE_INSET),frame},blocking[:],filter)>0 {return}
    thin:=sim.Capsule{capsule.radius*LEDGE_SWEEP,capsule.half_height}
    start:=feet+up*center
    raised:=start+up*(height+LEDGE_INSET)
    if _,blocked:=sim.shape_cast_closest(w,thin,{start,frame},raised-start,filter);blocked {return}
    if _,blocked:=sim.shape_cast_closest(w,thin,{raised,frame},top.point+up*(center+LEDGE_INSET)-raised,filter);blocked {return}
    return top.point,height,true
}

// Starts a climb from where the feet are to the top a ledge_find gave.
mantle_start :: proc "contextless" (loco:^Locomotion_State,from,to:[3]f32,height:f32) {
    loco.mode,loco.jumped,loco.coyote,loco.crouched=MODE_MANTLING,false,0,false
    loco.mantle_from,loco.mantle_to,loco.mantle_time,loco.mantle_height=from,to,0,height
}

// Where the feet are a share u of the way of a climb: up along the wall first, then across onto the
// top, the two overlapping (MANTLE_RISE, MANTLE_ACROSS) and each easing in and out.
mantle_point :: proc "contextless" (from,to,up:[3]f32,u:f32) -> [3]f32 {
    rise:=linalg.dot(to-from,up)
    flat:=to-from-up*rise
    return from+up*(rise*mm.smoothstep(0,MANTLE_RISE,u))+flat*mm.smoothstep(MANTLE_ACROSS,1,u)
}

// The Character_Move of a tick of a climb, from where its feet are: a drive that overrides gravity and
// the ground and takes the feet where the way puts them at the end of the tick. At the end of the way,
// or when something holds it off the way, it falls (and stands on what it climbed). driven: an
// Override layered move takes the climb this tick (the root motion of the animation of the climb,
// warped onto the ledge), so it goes where that move takes it and only its time runs.
mantle_move :: proc(loco:^Locomotion_State,body:Character,mantle:Mantle,frame:mm.Quat,position:[3]f32,move_input:input.Move_Input,jump:input.Action,dt:f32,driven:=false) -> (move:Character_Drive) {
    up:=mm.quat_rotate(frame,{0,1,0})
    move.yaw=move_input.look_yaw
    loco.jump_held=move_input.buttons&input.action_bit(jump)!=0
    loco.crouched=false
    length:=max(mantle.time,dt)
    now:=mantle_point(loco.mantle_from,loco.mantle_to,up,min(loco.mantle_time/length,1))
    off:=position-now
    if loco.mantle_time>=length || !driven && linalg.dot(off,off)>MANTLE_TOLERANCE*MANTLE_TOLERANCE {
        // It stops where the climb left it, up and across, and falls from there.
        loco.mode,loco.air_time=MODE_FALLING,0
        move.air={{},max(body.traction_force,1)*MANTLE_FORCE}
        move.flags={.Airborne,.Drive_Vertical}
        return
    }
    loco.mantle_time+=dt
    next:=mantle_point(loco.mantle_from,loco.mantle_to,up,min(loco.mantle_time/length,1))
    drive:=sim.Drive{(next-position)/dt,max(body.traction_force,1)*MANTLE_FORCE}
    move.ground,move.air=drive,drive
    move.flags={.Airborne,.Drive_Vertical,.No_Gravity}
    return
}
