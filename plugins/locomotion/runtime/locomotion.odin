package locomotion

import cmath "core:math"
import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// The actions of a body a seat drives, with input.Move_Action and
// input.Look_Action: jump, sprint and crouch are Buttons.
@(actions)
Walk_Action :: enum u8 {Jump,Sprint,Crouch}

// Their bindings when Input_Settings does not name them.
walk_action_defaults :: proc "contextless" () -> [Walk_Action]input.Action_Bindings {
    return {
        .Jump=input.action_default(.Button,input.binding_key(.Space),input.binding_gamepad_button(.South)),
        .Sprint=input.action_default(.Button,input.binding_key(.Left_Shift),input.binding_gamepad_button(.Left_Stick)),
        .Crouch=input.action_default(.Button,input.binding_key(.Left_Control),input.binding_gamepad_button(.Right_Stick)),
    }
}

@(names="MODE_")
Locomotion_Mode :: distinct u16
@(name_requires="Walk") MODE_FALLING :: Locomotion_Mode(0)
@(name_requires="Walk") MODE_WALKING :: Locomotion_Mode(1)
@(name_requires="Fly") MODE_FLYING :: Locomotion_Mode(2)
@(name_requires="Swim") MODE_SWIMMING :: Locomotion_Mode(3)
@(name_requires="Walk") MODE_CROUCHING :: Locomotion_Mode(4)
// The last mode locomotion_step drives: those after it are custom modes, whose owner (slide.odin,
// mantle.odin, navigation or a game) claims it with its Character_Move every tick it drives
// (claim_mode). Locomotion then only adds its layered moves and its pace on top, and a tick nobody
// claims it the character goes back to the mode its components start it in.
MODE_ENGINE_LAST :: MODE_CROUCHING

LAYERED_MOVE_CAPACITY :: 4

Move_Mix :: enum u8 {
    Additive, // added to the velocity the locomotion drives toward
    Override, // replaces it on every axis, without gravity or ground, for as long as it lasts
}

// A velocity on top of locomotion for a number of ticks: dash, wind, conveyor, root motion.
Layered_Move :: struct {
    velocity:[3]f32 `mirai:"unit=m/s"`, // world axes
    turn:f32 `mirai:"angle,unit=deg/s"`, // of the yaw it faces, left about its up; while one turns it, its look does not
    ticks:u32,                          // left
    mix:Move_Mix,
    id:u32,                             // meaning given by the game
}

@(component,replicated,description="The character can walk, jump, fall and crouch (modes walking, falling and crouching of its Character).")
Walk :: struct {
    max_speed:f32 `mirai:"min=0,unit=m/s"`,
    sprint_speed:f32 `mirai:"min=0,unit=m/s"`,     // while the sprint action is held; at most max_speed: it does not sprint
    sprint_default:bool,                           // it sprints without the sprint action
    backward_slowdown:f32 `mirai:"min=0,max=1"`,   // share of the speed lost moving straight back from where it looks
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
    braking:f32 `mirai:"min=0,unit=m/s2"`,
    air_control:f32 `mirai:"min=0,max=1"`,  // share of the acceleration and of the traction left in the air
    jump_height:f32 `mirai:"min=0,unit=m"`,     // the highest a jump goes, held to its apex
    jump_rise:f32 `mirai:"min=0,unit=s"`,       // a jump held keeps the speed it starts with for up to this long, then falls as it would: let go earlier, it goes less high
    jump_cut:f32 `mirai:"min=0,max=1"`,         // share of its speed up a jump keeps when it is let go while it rises; 1 or 0: all of it
    coyote_time:f32 `mirai:"min=0,unit=s"`, // after walking off a ledge, in which a jump still starts
    crouch_speed:f32 `mirai:"min=0,unit=m/s"`,  // top speed while crouched
    crouch_height:f32 `mirai:"min=0,unit=m"`,   // of its capsule crouched or sliding, from the feet to the top of the head; 0: it does not crouch
    crouch_toggle:bool,                         // crouch turns crouching on and off; otherwise it crouches while crouch is held
    turn_speed:f32 `mirai:"angle,min=0,unit=deg/s"`, // its yaw toward the look its input.Move_Input asks, whoever drives it; 0: at once
}

WALK_DEFAULT :: Walk{max_speed=5,acceleration=30,braking=40,air_control=0.3,jump_height=1.2,jump_cut=1,coyote_time=0.1,crouch_speed=2.5,crouch_height=1.2,turn_speed=500*mm.RAD_PER_DEG}

@(component,replicated,description="The character can fly (mode flying of its Character): toward the move in the axes of the look, without gravity.")
Fly :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`,
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
    turn_speed:f32 `mirai:"angle,min=0,unit=deg/s"`, // its yaw toward its look while it flies; 0: at once
}

FLY_DEFAULT :: Fly{speed=8,acceleration=30,turn_speed=500*mm.RAD_PER_DEG}

@(component,replicated,description="The character can swim (mode swimming of its Character): in water deeper than depth, toward the move in the axes of the look, with its head out at the surface. Jump climbs out onto a ledge.")
Swim :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`,
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
    depth:f32 `mirai:"min=0,unit=m"`,          // of water over the ground from which it swims instead of walking
    surface_offset:f32 `mirai:"min=0,unit=m"`, // of the head over the surface while it swims on it
    turn_speed:f32 `mirai:"angle,min=0,unit=deg/s"`, // its yaw toward its look while it swims; 0: at once
}

SWIM_DEFAULT :: Swim{speed=2,acceleration=4,depth=1.2,surface_offset=0.25,turn_speed=500*mm.RAD_PER_DEG}

// What the locomotion of a character carries from one tick to the next: its
// mode, its layered moves, the gravity it was asked for and the state of each
// of its moves, and what its mode drove toward in the last tick for its
// animation (desired to turn_speed, in world axes and time). Only
// locomotion_step writes it and adds it, when the Character first moves by a
// mode; a scene never holds one.
@(component,derived,replicated,description="The mode a locomotion is in and what it carries between ticks.")
Locomotion_State :: struct {
    mode:Locomotion_Mode `mirai:"transient,readonly"`,
    gravity:f32 `mirai:"transient,readonly,hidden"`,           // times the gravity_scale of its Character, set_gravity_scale asked; 0: 1
    jumped:bool `mirai:"transient,readonly,hidden"`,           // in the air by a jump: no coyote time
    jump_held:bool `mirai:"transient,readonly,hidden"`,        // the jump button was down in the last tick
    ready:bool `mirai:"transient,local,hidden"`,               // its yaw was taken from where it stands
    yaw:f32 `mirai:"transient,readonly,hidden,angle"`,         // it faces, about its up
    coyote:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // left
    added:[3]f32 `mirai:"transient,readonly,hidden,unit=m/s"`, // what additive layered moves put in the last drive
    driven:[3]f32 `mirai:"transient,readonly,hidden,unit=m/s"`, // what the locomotion drove toward in the last tick without them, in the world
    pace:f32 `mirai:"transient,readonly,hidden"`,       // of its last move (core.Own_Pace): its velocity is that of its own time by it; 0: 1
    layer_time:f32 `mirai:"transient,readonly,hidden"`, // part of a tick of its own time its layered moves have not spent
    move_count:u32 `mirai:"transient,readonly,hidden"`,
    moves:[LAYERED_MOVE_CAPACITY]Layered_Move `mirai:"transient,readonly,hidden"`,
    overridden:bool `mirai:"transient,readonly,hidden"`, // an Override layered move drove its last tick
    claimed:bool `mirai:"transient,local,hidden"`,         // its custom mode was claimed this tick: only inside locomotion_prepare
    speed_scale:f32 `mirai:"transient,readonly"`,
    jump_scale:f32 `mirai:"transient,readonly"`,
    acceleration_scale:f32 `mirai:"transient,readonly"`,
    suspended:bool `mirai:"transient,readonly"`,
    placed,placed_at_rest:bool `mirai:"transient,local,hidden"`,
    crouched:bool `mirai:"transient,readonly,hidden"`,    // it asks for the crouch_height of its Walk
    crouch_held:bool `mirai:"transient,readonly,hidden"`, // the crouch button was down in the last tick
    crouch_on:bool `mirai:"transient,readonly,hidden"`,   // it asks to crouch: crouch held, or toggled on with crouch_toggle
    crouch_lock:bool `mirai:"transient,readonly,hidden"`, // asked to walk with crouch held: crouch does nothing until it is let go
    jump_speed:f32 `mirai:"transient,readonly,hidden,unit=m/s"`,   // up, of its last jump: a jump held keeps it (Walk.jump_rise)
    jump_rise:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // left in which its jump held keeps jump_speed
    desired:[3]f32 `mirai:"transient,readonly,hidden,unit=m/s"`,    // the velocity its mode heads to without layered moves, relative to the ground
    acceleration:f32 `mirai:"transient,readonly,hidden,unit=m/s2"`, // at which it heads there
    braking:f32 `mirai:"transient,readonly,hidden,unit=m/s2"`,      // at which it stops without a move
    facing:[3]f32 `mirai:"transient,readonly,hidden"`,              // where it turns to: the look of its input across its up
    turn_speed:f32 `mirai:"transient,readonly,hidden,angle,unit=deg/s"`, // at which it turns there; 0: at once
}

Locomotion_Request_Kind :: enum u8 {
    Add_Move,
    Remove_Moves, // those of the id of the move
    Set_Mode,   // of the engine
    Claim_Mode, // custom, with the move of this tick
    Set_Speed_Scale,
    Set_Jump_Scale,
    Set_Acceleration_Scale,
    Set_Suspended,
    Set_Gravity_Scale, // times the gravity_scale of its Character until asked again: low gravity while charging a dash
}

Locomotion_Request :: struct {
    entity:core.Entity,
    kind:Locomotion_Request_Kind,
    move:Layered_Move,
    mode:Locomotion_Mode,
    claim:phys.Character_Move,
    gravity_scale,speed_scale,jump_scale,acceleration_scale:f32,
    suspended:bool,
}

GRAVITY_SCALE_MAX :: f32(1000)
SPEED_SCALE_MAX :: f32(1000)
JUMP_SCALE_MAX :: f32(1000)
ACCELERATION_SCALE_MAX :: f32(1000)

// Runtime controls are applied by locomotion_prepare before the characters move.
@(storage,queue)
Locomotion_Requests :: struct {
    queue:core.Queue(Locomotion_Request),
}

add_move :: proc(requests:^Locomotion_Requests,e:core.Entity,move:Layered_Move) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Add_Move,move=move})
}
remove_moves :: proc(requests:^Locomotion_Requests,e:core.Entity,id:u32) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Remove_Moves,move={id=id}})
}
// Puts a Character in a mode of the engine (at most MODE_ENGINE_LAST).
set_mode :: proc(requests:^Locomotion_Requests,e:core.Entity,mode:Locomotion_Mode) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Mode,mode=mode})
}
// Drives a Character in a custom mode (after MODE_ENGINE_LAST) with move for this tick. Its owner
// asks every tick it drives it, before locomotion_prepare; a tick nobody claims it, the character
// goes back to the mode its components start it in (falling with a Walk).
claim_mode :: proc(requests:^Locomotion_Requests,e:core.Entity,mode:Locomotion_Mode,move:phys.Character_Move) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Claim_Mode,mode=mode,claim=move})
}
// Scales the gravity of a Character by scale times its gravity_scale until asked again: a game
// changes it for a while (low gravity while charging, a glide) through here, and the authored
// Character keeps its own.
set_gravity_scale :: proc(requests:^Locomotion_Requests,e:core.Entity,scale:f32) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Gravity_Scale,gravity_scale=scale})
}

set_speed_scale :: proc(requests:^Locomotion_Requests,e:core.Entity,scale:f32) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Speed_Scale,speed_scale=scale})
}
set_jump_scale :: proc(requests:^Locomotion_Requests,e:core.Entity,scale:f32) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Jump_Scale,jump_scale=scale})
}
set_acceleration_scale :: proc(requests:^Locomotion_Requests,e:core.Entity,scale:f32) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Acceleration_Scale,acceleration_scale=scale})
}
set_suspended :: proc(requests:^Locomotion_Requests,e:core.Entity,suspended:bool) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Suspended,suspended=suspended})
}

@(step="fixed",stage="simulate",before="locomotion_step")
locomotion_prepare :: proc(
    characters:^core.Table(phys.Character,.Read),colliders:^core.Table(phys.Collider,.Read),states:^core.Table(Locomotion_State),
    moves:^core.Table(phys.Character_Move),remotes:^core.Table(core.Remote,.Read),
    walks:^core.Table(Walk,.Read),flights:^core.Table(Fly,.Read),swims:^core.Table(Swim,.Read),
    requests:^Locomotion_Requests,time:core.Time,problems:^core.Problems,
) {
    if time.playing && time.dt>0 {
        for row in 0..<core.count(characters) {
            e:=core.entity_at(characters,row)
            if core.has(states,e) || !phys.character_owner(characters,colliders,e) {continue}
            if mode,ok:=initial_mode(walks,flights,swims,e);ok {
                core.add(states,e,Locomotion_State{mode=mode,speed_scale=1,jump_scale=1,acceleration_scale=1})
            }
        }
    }
    for asked in core.take(&requests.queue) {
        start:Maybe(Locomotion_Mode)
        switch asked.kind {
        case .Set_Mode:
            if asked.mode>MODE_ENGINE_LAST {
                core.report(problems,asked.entity,"locomotion.request","the custom mode %d was asked with set_mode; its owner claims it with its move every tick it drives it (claim_mode)",asked.mode)
                continue
            }
            if missing:=mode_missing(asked.mode,asked.entity,walks,flights,swims);missing!="" {
                core.report(problems,asked.entity,"locomotion.mode_component","the mode %s was asked of an entity without %s; give it a %s, which holds the parameters of that mode",mode_label(asked.mode),missing,missing)
                continue
            }
            start=asked.mode
        case .Claim_Mode:
            if asked.mode<=MODE_ENGINE_LAST {
                core.report(problems,asked.entity,"locomotion.request","the mode %s of the engine was claimed; ask for it with set_mode, and claim only custom modes",mode_label(asked.mode))
                continue
            }
            start=asked.mode
        case .Add_Move,.Remove_Moves,.Set_Speed_Scale,.Set_Jump_Scale,.Set_Acceleration_Scale,.Set_Suspended,.Set_Gravity_Scale:
        }
        c:^Locomotion_State
        if phys.character_owner(characters,colliders,asked.entity) {
            c=locomotion_state_of(states,walks,flights,swims,asked.entity,start)
        }
        if c==nil {
            core.report(problems,asked.entity,"locomotion.request","the entity needs a Character, a capsule Collider and a locomotion mode to take locomotion requests")
            continue
        }
        switch asked.kind {
        case .Add_Move:
            if asked.move.ticks==0 || c.move_count>=LAYERED_MOVE_CAPACITY {
                core.report(problems,asked.entity,"locomotion.request",asked.move.ticks==0?"a layered move without ticks was asked; give it the ticks it lasts":"a layered move was asked of a Character that carries LAYERED_MOVE_CAPACITY of them; end some with remove_moves")
                continue
            }
            c.moves[c.move_count]=asked.move
            c.move_count+=1
        case .Remove_Moves:
            moves_remove(c,asked.move.id)
        case .Claim_Mode:
            if c.mode!=asked.mode {c.mode,c.jumped,c.coyote=asked.mode,false,0}
            c.claimed=true
            character_move_write(moves,asked.entity,asked.claim)
        case .Set_Mode:
            c.mode,c.jumped,c.coyote=asked.mode,false,0
            // Asked to walk it stands up, and a crouch held meanwhile waits to be let go; asked to
            // crouch it crouches.
            switch asked.mode {
            case MODE_WALKING: c.crouch_on,c.crouch_lock=false,true
            case MODE_CROUCHING: c.crouch_on=true
            }
        case .Set_Speed_Scale:
            if !(asked.speed_scale>=0 && asked.speed_scale<=SPEED_SCALE_MAX) {
                core.report(problems,asked.entity,"locomotion.request","speed scale must be finite and between zero and %v",SPEED_SCALE_MAX)
                continue
            }
            c.speed_scale=asked.speed_scale
        case .Set_Jump_Scale:
            if !(asked.jump_scale>=0 && asked.jump_scale<=JUMP_SCALE_MAX) {
                core.report(problems,asked.entity,"locomotion.request","jump scale must be finite and between zero and %v",JUMP_SCALE_MAX)
                continue
            }
            c.jump_scale=asked.jump_scale
        case .Set_Acceleration_Scale:
            if !(asked.acceleration_scale>=0 && asked.acceleration_scale<=ACCELERATION_SCALE_MAX) {
                core.report(problems,asked.entity,"locomotion.request","acceleration scale must be finite and between zero and %v",ACCELERATION_SCALE_MAX)
                continue
            }
            c.acceleration_scale=asked.acceleration_scale
        case .Set_Suspended:
            if c.suspended!=asked.suspended {
                c.suspended=asked.suspended
                c.jumped,c.coyote,c.jump_rise,c.added,c.driven=false,0,0,{},{}
            }
        case .Set_Gravity_Scale:
            if !(abs(asked.gravity_scale)<=GRAVITY_SCALE_MAX) {
                core.report(problems,asked.entity,"locomotion.request","a gravity scale of %v was asked; ask for a finite one of at most %v either way",asked.gravity_scale,GRAVITY_SCALE_MAX)
                continue
            }
            c.gravity=asked.gravity_scale
        }
    }
    // A custom mode lasts while its owner claims it; where this end decides the character, a tick
    // without a claim takes it back to the mode its components start it in. A replica keeps the
    // mode the network gives it.
    for row in 0..<core.count(states) {
        e:=core.entity_at(states,row)
        c:=core.at(states,row)
        start,starts:=initial_mode(walks,flights,swims,e)
        unclaimed:=c.mode>MODE_ENGINE_LAST && !c.claimed && core.owned(remotes,e)
        if !phys.character_owner(characters,colliders,e) || unclaimed && !starts || !starts && c.mode<=MODE_ENGINE_LAST {
            core.remove(states,e)
            core.remove(moves,e)
            continue
        }
        if unclaimed {
            edit:=core.edit_at(states,row)
            edit.mode,edit.jumped,edit.coyote=start,false,0
        } else if c.claimed {core.edit_at(states,row).claimed=false}
    }
}

@(step="fixed",stage="simulate",before="physics_prepare")
locomotion_step :: proc(
    characters:^core.Table(phys.Character,.Read),states:^core.Table(Locomotion_State),
    moves:^core.Table(phys.Character_Move),inputs:^core.Table(input.Move_Input),
    walks:^core.Table(Walk,.Read),flights:^core.Table(Fly,.Read),swims:^core.Table(Swim,.Read),
    found:^core.Table(phys.Character_State,.Read),motions:^core.Table(core.Motion,.Read),
    locals:^core.Table(core.Transform,.Read),parents:^core.Table(core.Parent,.Read),remotes:^core.Table(core.Remote,.Read),physics:core.Ref(phys.Physics_State),places:core.Ref(core.Places),
    paces:^core.Table(core.Own_Pace,.Read),walk_actions:input.Input_Of(Walk_Action),time:core.Time,clock:core.Clock,problems:^core.Problems,
) {
    if places.ptr!=nil {
        for placed in places.queue.items {
            e:=placed.entity
            c:=core.edit(states,e)
            if c==nil {continue}
            capsule,made:=phys.character_capsule(physics,e)
            rotation:=placed.rotation if placed.rotation!=0 else mm.QUAT_IDENTITY
            frame:=capsule.up_frame if made else mm.QUAT_IDENTITY
            if placed.at_rest {
                mode:=MODE_FALLING if core.has(walks,e) else c.mode
                c^={mode=mode,speed_scale=c.speed_scale,jump_scale=c.jump_scale,acceleration_scale=c.acceleration_scale,suspended=c.suspended,gravity=c.gravity}
            }
            c.placed,c.placed_at_rest,c.ready=true,placed.at_rest || c.placed_at_rest,true
            c.yaw=phys.look_yaw_of(frame,rotation)
            if core.owned(remotes,e) {
                if seat:=core.edit(inputs,e);seat!=nil {seat.look_yaw=c.yaw}
            }
        }
    }
    if !time.playing || time.dt<=0 {return}
    jump,sprint,crouch:=input.action_of(walk_actions,.Jump),input.action_of(walk_actions,.Sprint),input.action_of(walk_actions,.Crouch)
    for row in 0..<core.count(states) {
        e:=core.entity_at(states,row)
        c:=core.edit_at(states,row)
        body,_:=core.get(characters,e)
        capsule,made:=phys.character_capsule(physics,e)
        frame:=capsule.up_frame if made else mm.QUAT_IDENTITY
        if !c.ready {
            if placed,ok:=core.world_of(locals,parents,e);ok {c.yaw=phys.look_yaw_of(frame,placed.rotation)}
            c.ready=true
        }
        ground,_:=core.get(found,e)
        motion,_:=core.get(motions,e)
        if c.placed {ground={}}
        if c.placed_at_rest {motion={}}
        asked,asked_any:=core.get(inputs,e)
        if c.placed || !asked_any {asked.look_yaw=c.yaw}
        c.placed,c.placed_at_rest=false,false
        next:phys.Character_Move
        pace:=core.pace_of(clock,paces,e)
        walk:Maybe(Walk)
        if found_walk,has:=core.get(walks,e);has {walk=found_walk}
        fly:Maybe(Fly)
        if found_fly,has:=core.get(flights,e);has {fly=found_fly}
        swim:Maybe(Swim)
        if found_swim,has:=core.get(swims,e);has {swim=found_swim}
        turn_speed:=mode_turn_speed(c.mode,walk,fly,swim)
        turned:=layered_turn(c)
        c.yaw=mm.angle_wrap(c.yaw+ground.ground_turn+turned*time.dt*pace)
        if turned==0 {
            c.yaw=mm.angle_wrap(mm.angle_approach(c.yaw,asked.look_yaw,turn_speed*time.dt*pace)) if turn_speed>0 else asked.look_yaw
        }
        c.facing=mm.quat_forward(frame*mm.quat_axis_angle({0,1,0},asked.look_yaw))
        c.turn_speed=turn_speed
        given:=move_facing(asked,c.yaw,frame)
        if c.suspended {
            next.value.flags={.Ghosted}
            character_move_write(moves,e,next)
            continue
        }
        if missing:=mode_missing(c.mode,e,walks,flights,swims);missing!="" {
            core.report(problems,e,"locomotion.mode_component","its Character is in the mode %s and it has no %s; give it a %s, which holds the parameters of that mode, or ask for another mode",mode_label(c.mode),missing,missing)
            // It falls when it can, and otherwise stands.
            if core.has(walks,e) {c.mode=MODE_FALLING}
        }
        if c.mode>MODE_ENGINE_LAST {
            // A custom mode owns its move: the yaw, flags, gravity and height its owner wrote stay,
            // and only the layered moves and the pace go on top. The edges of jump and crouch follow
            // the input meanwhile, so a press its owner took is not taken again after it.
            if written,has_written:=core.get(moves,e);has_written {next=written}
            c.jump_held=asked.buttons&input.action_bit(jump)!=0
            c.crouch_held=asked.buttons&input.action_bit(crouch)!=0
            own:=ground.standing && .Airborne not_in next.value.flags
            c.driven=next.value.ground.velocity+ground.ground_velocity if own else next.value.air.velocity
            up:=mm.quat_rotate(frame,{0,1,0})
            relative:=c.driven-ground.ground_velocity if own else c.driven
            c.desired=relative-up*linalg.dot(relative,up)
            c.acceleration,c.braking=mode_rates(walk,fly,swim)
            layers_apply(c,&next.value,body.traction_force,pace)
            move_paced(&next.value,c,body,pace,motion.linear,ground,frame)
        } else {
            if mode_missing(c.mode,e,walks,flights,swims)!="" {
                next.value={}
                c.desired,c.acceleration,c.braking={},0,0
            } else {
                gravity:=phys.gravity_of_entity(physics,e)*body.gravity_scale*locomotion_gravity(c^)
                next.value=locomotion_move_paced(c,body,walk,fly.? or_else {},swim,ground,frame,given,jump,sprint,crouch,motion.linear,gravity,time.dt,pace)
            }
            next.value.flags+={.Reach_Drive}
            next.value.gravity_scale=c.gravity
            if walking,ok:=walk.?;ok && c.crouched {next.height=walking.crouch_height}
        }
        // What it heads to in the time of the world: velocities by its pace, accelerations by its square.
        c.desired*=pace
        c.acceleration*=pace*pace
        c.braking*=pace*pace
        character_move_write(moves,e,next)
    }
}

@(private)
character_move_write :: proc(moves:^core.Table(phys.Character_Move),e:core.Entity,next:phys.Character_Move) {
    if move:=core.edit(moves,e);move!=nil {move^=next} else {core.add(moves,e,next)}
}

// The Locomotion_State of a Character, added the first time in start or, without it, in the mode its
// components start it in: walking (falling until it stands) with a Walk, else swimming with a Swim, else
// flying with a Fly. nil for a Character without those components
// and no start, and without memory.
@(private)
locomotion_state_of :: proc(states:^core.Table(Locomotion_State),walks:^core.Table(Walk,.Read),flights:^core.Table(Fly,.Read),swims:^core.Table(Swim,.Read),e:core.Entity,start:Maybe(Locomotion_Mode)=nil) -> ^Locomotion_State {
    if c:=core.staged(states,e);c!=nil {return c}
    mode,given:=start.?
    if !given {
        if first,ok:=initial_mode(walks,flights,swims,e);ok {mode=first} else {return nil}
    }
    core.add(states,e,Locomotion_State{mode=mode,speed_scale=1,jump_scale=1,acceleration_scale=1})
    return core.staged(states,e)
}

@(private)
initial_mode :: proc "contextless" (walks:^core.Table(Walk,.Read),flights:^core.Table(Fly,.Read),swims:^core.Table(Swim,.Read),e:core.Entity) -> (Locomotion_Mode,bool) {
    switch {
    case core.has(walks,e): return MODE_FALLING,true
    case core.has(swims,e): return MODE_SWIMMING,true
    case core.has(flights,e): return MODE_FLYING,true
    }
    return 0,false
}

// What set_gravity_scale asked to scale the gravity of a character by.
locomotion_gravity :: proc "contextless" (loco:Locomotion_State) -> f32 {return loco.gravity!=0?loco.gravity:1}

// A Move_Input in the axes of the yaw a character faces, in the frame of its
// vertical: what its modes read.
move_facing :: proc "contextless" (asked:input.Move_Input,yaw:f32,frame:mm.Quat) -> input.Move_Input {
    facing:=asked
    facing.look_yaw=yaw
    facing.move=mm.quat_rotate(conj(frame*mm.quat_axis_angle({0,1,0},yaw)),asked.move)
    return facing
}

// The move of an input in the axes of its yaw (move_facing) in the world,
// across the up of the frame of the vertical, as a share of the top speed of
// a mode, at most 1 long: a velocity input asks for top speed at most.
move_wish :: proc "contextless" (move_input:input.Move_Input,frame:mm.Quat,top:f32) -> [3]f32 {
    s,c:=cmath.sincos(move_input.look_yaw)
    m:=move_share(move_input,top)
    wish:=[3]f32{c*m.x+s*m.z,0,c*m.z-s*m.x}
    if l:=linalg.length(wish);l>1 {wish/=l}
    return mm.quat_rotate(frame,wish)
}

// The move of an input as a share of the top speed of a mode, at most 1 long.
move_share :: proc "contextless" (move_input:input.Move_Input,top:f32) -> [3]f32 {
    m:=move_input.move
    if move_input.world_velocity {m=m/top if top>0 else {}}
    if l:=linalg.length(m);!(l<=1) {m=m/l if l<=max(f32) else {}}
    return m
}

// Within this angle of where it looks a move may sprint: cos 60°.
SPRINT_FORWARD :: f32(0.5)

// The top speed of walking for this input: sprint_speed while sprinting
// forward (within 60° of the look, with the sprint action or sprint_default)
// when it is faster, less backward_slowdown by how straight back from the look
// the move points (-Z of the move is forward); crouched, crouch_speed, which
// sprint does not change.
walk_speed :: proc "contextless" (walk:Walk,move_input:input.Move_Input,sprinting:bool,crouched:=false) -> f32 {
    speed:=max(walk.crouch_speed,0) if crouched else walk.max_speed
    if !crouched && sprint_forward(move_input,sprinting || walk.sprint_default) && walk.sprint_speed>speed {speed=walk.sprint_speed}
    l:=linalg.length(move_input.move.xz)
    if l>0 && walk.backward_slowdown>0 {
        speed*=1-clamp(walk.backward_slowdown,0,1)*max(move_input.move.z/l,0)
    }
    return speed
}

// Whether an input sprints: the sprint action held with a move within 60° of
// where it looks.
sprint_forward :: proc "contextless" (move_input:input.Move_Input,sprinting:bool) -> bool {
    l:=linalg.length(move_input.move.xz)
    return sprinting && l>0 && -move_input.move.z/l>=SPRINT_FORWARD
}

// The Character_Move of one tick of a mode of the locomotion: from the input
// (jump is the action of Walk_Action.Jump among its buttons), the ground and
// the fluid the last step left, the frame of its vertical, the velocity of
// the body and its gravity, all in its own time, which runs pace times the
// time of the world (dt is that of its own time). walking and swim are nil
// for a character that cannot walk or swim: one that only swims stays in the
// mode out of the water. It also leaves in loco what the mode heads to
// (desired, acceleration and braking), in its own time.
locomotion_move :: proc(loco:^Locomotion_State,body:phys.Character,walking:Maybe(Walk),fly:Fly,swim:Maybe(Swim),ground:phys.Character_State,frame:mm.Quat,move_input:input.Move_Input,jump,sprint,crouch:input.Action,velocity,gravity:[3]f32,dt:f32,pace:f32=1,scale:f32=1,jump_scale:f32=1,acceleration_scale:f32=1) -> (move:phys.Character_Drive) {
    up:=mm.quat_rotate(frame,{0,1,0})
    across :: proc "contextless" (v,up:[3]f32) -> [3]f32 {return v-up*linalg.dot(v,up)}
    look:=frame*mm.quat_axis_angle({0,1,0},move_input.look_yaw)
    if !move_input.world_velocity {look*=mm.quat_axis_angle({1,0,0},move_input.look_pitch)}
    walk,walks:=walking.?
    walk.max_speed*=scale
    walk.sprint_speed*=scale
    walk.crouch_speed*=scale
    walk.acceleration*=acceleration_scale
    walk.braking*=acceleration_scale
    move.yaw=move_input.look_yaw
    traction:=body.traction_force
    held:=move_input.buttons&input.action_bit(jump)!=0
    pressed:=held && !loco.jump_held && walk.jump_height>0 && jump_scale>0
    released:=!held && loco.jump_held
    loco.jump_held=held
    v:=velocity-additive_delivered(velocity,loco.added,loco.driven)
    // Its direction; how far it asks is a share of the top speed of each mode.
    wish:=move_wish(move_input,frame,walk.max_speed)
    // Into the water and out of it by the depth of the water over the ground, the same both ways; never in
    // the middle of a move that overrides the locomotion, as climbing out.
    if swim,swims:=swim.?;swims && loco.mode!=MODE_FLYING && !layered_override(loco^) {
        within:=ground.walkable && ground.ground_distance<=body.step_height
        deep:=water_depth(body,ground)>swim.depth
        if loco.mode==MODE_SWIMMING {
            if walks && .In_Fluid not_in ground.fluid {
                loco.mode=MODE_FALLING
            } else if walks && within && !deep {loco.mode=MODE_WALKING}
        } else if .In_Fluid in ground.fluid && deep {loco.mode=MODE_SWIMMING}
    }
    if swim,swims:=swim.?;swims && loco.mode==MODE_SWIMMING {
        loco.jumped,loco.coyote,loco.crouched=false,0,false
        swim:=swim
        swim.speed*=scale
        swim.acceleration*=acceleration_scale
        current:=ground.fluid_velocity
        relative:=v-current
        aim:=mm.quat_rotate(look,move_share(move_input,swim.speed))
        // On the surface, or under it, only in a fluid its state says it is in: that of a character just
        // made or placed says none yet, and a float then would pull it up from the deep.
        wet:=.In_Fluid in ground.fluid
        surfaced:=wet && ground.head_depth<=0 && linalg.dot(aim,up)>=0
        dives:=wet && !surfaced && aim!={}
        flat:=across(relative,up)
        drift:=across(current,up)
        loco.desired=(aim if dives else across(aim,up))*swim.speed
        loco.acceleration,loco.braking=swim.acceleration,swim.acceleration
        if surfaced {
            move.air={mm.approach_point(flat,across(aim,up)*swim.speed,swim.acceleration*dt)+drift,traction}
            move.flags={.Airborne,.Float}
            move.float_height=swim.surface_offset
            // Out onto a ledge or a raft: a climb, for a jump against the drag of the water takes no one out.
            // It takes the feet to the surface at the speed of a jump, which then takes them jump_height over it.
            if speed:=cmath.sqrt(2*linalg.length(gravity)*walk.jump_height)*jump_scale;pressed && speed*dt>0 && loco.move_count<LAYERED_MOVE_CAPACITY {
                loco.moves[loco.move_count]={velocity=up*speed+move_wish(move_input,frame,swim.speed)*swim.speed,ticks=max(u32(cmath.ceil(max(ground.depth,0)/(speed*dt))),1),mix=.Override}
                loco.move_count+=1
                loco.mode,loco.jumped=MODE_FALLING,true
            }
        } else if dives {
            move.air={mm.approach_point(relative,aim*swim.speed,swim.acceleration*dt)+current,traction}
            move.flags={.Airborne,.Drive_Vertical}
        } else {
            // Still, what the buoyancy has over the weight, or the weight over it, takes it up or down slowly.
            // Out of a fluid it is driven across alone, and falls.
            move.air={mm.approach_point(flat,across(aim,up)*swim.speed,swim.acceleration*dt)+drift,traction}
            move.flags={.Airborne}
        }
    } else if loco.mode==MODE_FLYING {
        loco.jumped,loco.coyote,loco.crouched=false,0,false
        speed:=fly.speed*scale
        fly_accel:=fly.acceleration*acceleration_scale
        aim:=mm.quat_rotate(look,move_share(move_input,speed))
        move.air={mm.approach_point(v,aim*speed,fly_accel*dt),traction}
        move.flags={.Airborne,.Drive_Vertical,.No_Gravity}
        loco.desired,loco.acceleration,loco.braking=aim*speed,fly_accel,fly_accel
    } else {
        sprint_held:=move_input.buttons&input.action_bit(sprint)!=0
        crouches:=walk.crouch_height>0
        crouch_down:=crouches && move_input.buttons&input.action_bit(crouch)!=0
        crouch_pressed:=crouch_down && !loco.crouch_held
        loco.crouch_held=crouch_down
        if !crouch_down {loco.crouch_lock=false}
        if walk.crouch_toggle {
            if crouch_pressed {loco.crouch_on=!loco.crouch_on}
        } else {
            loco.crouch_on=crouch_down && !loco.crouch_lock
        }
        was:=loco.mode
        if ground.standing {
            loco.jumped,loco.coyote,loco.jump_rise=false,0,0
        } else {
            // A jump held keeps its speed up for up to jump_rise, until it is let go or something stops the rise.
            if loco.jump_rise>0 {
                rising:=linalg.dot(v,up)
                if held && rising>=loco.jump_speed-2*linalg.length(gravity)*dt {
                    move.launch+=up*(loco.jump_speed-rising)
                    jump_hold(loco,&move,up,linalg.length(gravity),dt)
                } else {loco.jump_rise=0}
            }
            if released && loco.jumped && walk.jump_cut>0 && walk.jump_cut<1 {
                if rising:=linalg.dot(v,up);rising>0 {move.launch-=up*rising*(1-walk.jump_cut)}
            }
            if (was==MODE_WALKING || was==MODE_CROUCHING) && !loco.jumped {
                loco.coyote=walk.coyote_time
            } else {loco.coyote=max(loco.coyote-dt,0)}
        }

        n:=ground.ground_normal
        if linalg.dot(n,up)<=0 {n=up}
        relative:=v-ground.ground_velocity
        current:=relative-n*linalg.dot(relative,n)
        crouching:=ground.standing && (loco.crouch_on || ground.cramped)
        loco.mode=ground.standing?(crouching?MODE_CROUCHING:MODE_WALKING):MODE_FALLING
        speed:=walk_speed(walk,move_input,sprint_held,loco.mode==MODE_CROUCHING)
        desired:[3]f32
        if share:=move_wish(move_input,frame,speed);share!={} {
            along:=share-up*(linalg.dot(share,n)/linalg.dot(n,up))
            desired=along*(speed*linalg.length(share)/linalg.length(along))
        }
        move.ground={mm.approach_point(current,desired,(desired=={}?walk.braking:walk.acceleration)*dt),traction}
        loco.crouched=ground.standing && loco.crouch_on
        loco.desired,loco.acceleration,loco.braking=desired,walk.acceleration,walk.braking

        move.air={velocity=across(v,up)}
        air:=walk.air_control*walk.acceleration
        if !ground.standing {loco.desired,loco.acceleration,loco.braking=move.air.velocity,air,air}
        if wish!={} && walk.air_control>0 {
            speed:=walk_speed(walk,move_input,sprint_held,false)
            share:=move_wish(move_input,frame,speed)
            move.air={mm.approach_point(move.air.velocity,share*speed,air*dt),walk.air_control*traction}
            if !ground.standing {loco.desired=share*speed}
            // Ground too steep to walk is not climbed from the air either.
            if ground.ground_normal!={} && !ground.walkable && ground.ground_distance<=body.step_height {
                flat:=across(ground.ground_normal,up)
                if into:=linalg.dot(move.air.velocity,flat);into<0 && flat!={} {move.air.velocity-=flat*(into/linalg.dot(flat,flat))}
            }
        }

        if pressed && (ground.standing || loco.coyote>0 && !loco.jumped) {
            base:=linalg.dot(ground.standing?v-ground.ground_velocity:v,up)
            rise:=walk_jump_speed(walk,linalg.length(gravity))*jump_scale
            move.launch+=up*(rise-base)
            if ground.standing {move.air={velocity=across(v,up)+across(move.launch,up)}}
            loco.mode,loco.jumped,loco.coyote,loco.crouched,loco.crouch_on=MODE_FALLING,true,0,false,false
            loco.jump_speed,loco.jump_rise=rise,walk.jump_rise
            jump_hold(loco,&move,up,linalg.length(gravity),dt)
        }
    }
    loco.driven=move.ground.velocity+ground.ground_velocity if ground.standing && .Airborne not_in move.flags else move.air.velocity
    layers_apply(loco,&move,traction,pace)
    return
}

// The speed up a jump of a walk starts with under a gravity (m/s2): held for jump_rise and then
// falling, it reaches jump_height, h=v*r+v*v/(2*g); without jump_rise, sqrt(2*g*h). In the form
// 2*h/(r+sqrt(r*r+2*h/g)), which loses no digits to a long rise.
walk_jump_speed :: proc "contextless" (walk:Walk,gravity:f32) -> f32 {
    h,r:=walk.jump_height,max(walk.jump_rise,0)
    if !(h>0) || !(gravity>0) {return 0}
    return 2*h/(r+cmath.sqrt(r*r+2*h/gravity))
}

// A tick of a jump held, from the tick it starts: it keeps jump_speed while jump_rise lasts, whole
// ticks of it without gravity and the part of a tick left with as much more speed as the gravity
// takes from it then, so that it rises what walk_jump_speed counts on whatever the tick.
@(private)
jump_hold :: proc "contextless" (loco:^Locomotion_State,move:^phys.Character_Drive,up:[3]f32,gravity,dt:f32) {
    if loco.jump_rise>=dt {
        move.flags+={.No_Gravity}
        loco.jump_rise-=dt
    } else {
        move.launch+=up*(loco.jump_rise*gravity)
        loco.jump_rise=0
    }
}

// The part of the velocity of a body that the additive layered moves of the last tick put in it: of
// the added velocity, as much as the body went past what the locomotion drove toward (driven), so
// that the locomotion counts the rest as its own. A body that falls short of an added velocity,
// blocked by a wall or by the force that drives it, did not take that part, and the locomotion does
// not take it as its own going the other way.
additive_delivered :: proc "contextless" (velocity,added,driven:[3]f32) -> [3]f32 {
    speed:=linalg.length(added)
    if !(speed>0) {return {}}
    along:=added/speed
    return along*clamp(linalg.dot(velocity-driven,along),0,speed)
}

// The layered moves of a locomotion on top of a move, each for pace more
// ticks of its own time. locomotion_step applies them to the move of a mode of
// the game.
layers_apply :: proc(loco:^Locomotion_State,move:^phys.Character_Drive,traction:f32,pace:f32=1) {
    added:[3]f32
    kept:u32
    loco.overridden=false
    loco.layer_time+=pace
    spent:=u32(loco.layer_time)
    loco.layer_time-=f32(spent)
    for i in 0..<loco.move_count {
        layered:=loco.moves[i]
        switch layered.mix {
        case .Additive:
            added+=layered.velocity
            if move.ground.force==0 {move.ground.force=traction}
            if move.air.force==0 {move.air.force=traction}
        case .Override:
            added={}
            loco.overridden=true
            drive:=phys.Drive{layered.velocity,traction}
            move.ground,move.air=drive,drive
            move.flags+={.Airborne,.Drive_Vertical,.No_Gravity}
            move.flags-={.Float}
        }
        layered.ticks-=min(spent,layered.ticks)
        if layered.ticks>0 {
            loco.moves[kept]=layered
            kept+=1
        }
    }
    for i in kept..<loco.move_count {loco.moves[i]={}}
    loco.move_count=kept
    loco.added=added
    move.ground.velocity+=added
    move.air.velocity+=added
}

// A move of the time of a character in the time of the world, at its pace:
// velocities by it and forces by its square. When its pace changes, a launch
// keeps the velocity it had in its own time (across its up while it stands,
// relative to the ground).
move_paced :: proc "contextless" (move:^phys.Character_Drive,loco:^Locomotion_State,body:phys.Character,pace:f32,velocity:[3]f32,ground:phys.Character_State,frame:mm.Quat) {
    before:=loco.pace>0?loco.pace:1
    loco.pace=pace
    if pace==1 && before==1 {return}
    felt:=pace*pace
    move.ground.velocity*=pace
    move.ground.force*=felt
    move.air.velocity*=pace
    move.air.force*=felt
    move.launch*=pace
    if pace!=before {
        kept:=(ground.standing?velocity-ground.ground_velocity:velocity)*(pace/before-1)
        if ground.standing {
            up:=mm.quat_rotate(frame,{0,1,0})
            kept-=up*linalg.dot(kept,up)
        }
        move.launch+=kept
    }
    move.pace=pace
}

// The Character_Move of one tick of the world for a character whose time runs
// pace times it (core.pace_of): locomotion_move in its own time, from the
// ground, the velocity and the dt of the world.
locomotion_move_paced :: proc(loco:^Locomotion_State,body:phys.Character,walking:Maybe(Walk),fly:Fly,swim:Maybe(Swim),ground:phys.Character_State,frame:mm.Quat,move_input:input.Move_Input,jump,sprint,crouch:input.Action,velocity,gravity:[3]f32,dt,pace:f32) -> (move:phys.Character_Drive) {
    own:=ground
    own.ground_velocity/=pace
    own.fluid_velocity/=pace
    move=locomotion_move(loco,body,walking,fly,swim,own,frame,move_input,jump,sprint,crouch,velocity/(loco.pace>0?loco.pace:1),gravity,dt*pace,pace,loco.speed_scale,loco.jump_scale,loco.acceleration_scale)
    move_paced(&move,loco,body,pace,velocity,ground,frame)
    return
}

// Whether a layered move overrides the locomotion now.
layered_override :: proc "contextless" (loco:Locomotion_State) -> bool {
    for i in 0..<min(loco.move_count,LAYERED_MOVE_CAPACITY) {if loco.moves[i].mix==.Override {return true}}
    return false
}

// The turn of the yaw its layered moves ask now, rad/s left about its up.
layered_turn :: proc "contextless" (loco:^Locomotion_State) -> (turn:f32) {
    for layered in loco.moves[:min(loco.move_count,LAYERED_MOVE_CAPACITY)] {turn+=layered.turn}
    return
}

// The speed at which a character in mode turns toward its look: that of the component of the mode,
// and in a custom mode that of its Walk, else its Swim, else its Fly.
mode_turn_speed :: proc "contextless" (mode:Locomotion_Mode,walk:Maybe(Walk),fly:Maybe(Fly),swim:Maybe(Swim)) -> f32 {
    if f,ok:=fly.?;ok && mode==MODE_FLYING {return f.turn_speed}
    if s,ok:=swim.?;ok && mode==MODE_SWIMMING {return s.turn_speed}
    if w,ok:=walk.?;ok {return w.turn_speed}
    if s,ok:=swim.?;ok {return s.turn_speed}
    if f,ok:=fly.?;ok {return f.turn_speed}
    return 0
}

// The rates at which a custom mode is told to head to its velocity and to stop, for its animation:
// those of its Walk, else its Swim, else its Fly.
@(private)
mode_rates :: proc "contextless" (walk:Maybe(Walk),fly:Maybe(Fly),swim:Maybe(Swim)) -> (acceleration,braking:f32) {
    if w,ok:=walk.?;ok {return w.acceleration,w.braking}
    if s,ok:=swim.?;ok {return s.acceleration,s.acceleration}
    if f,ok:=fly.?;ok {return f.acceleration,f.acceleration}
    return
}

// m of water over the walkable ground in reach of the feet, else over the feet.
@(private)
water_depth :: proc "contextless" (body:phys.Character,ground:phys.Character_State) -> f32 {
    if ground.walkable && ground.ground_distance<=body.step_height {return ground.depth+ground.ground_distance}
    return ground.depth
}

// The component a mode of the engine needs that the entity lacks; "" when it has it or the mode is custom.
@(private)
mode_missing :: proc(mode:Locomotion_Mode,e:core.Entity,walks:^core.Table(Walk,$A),flights:^core.Table(Fly,$B),swims:^core.Table(Swim,$C)) -> string {
    switch mode {
    case MODE_FALLING,MODE_WALKING,MODE_CROUCHING: if !core.has(walks,e) {return "Walk"}
    case MODE_FLYING:               if !core.has(flights,e) {return "Fly"}
    case MODE_SWIMMING:             if !core.has(swims,e) {return "Swim"}
    }
    return ""
}

@(private)
mode_label :: proc(mode:Locomotion_Mode) -> string {
    switch mode {
    case MODE_FALLING: return "falling"
    case MODE_WALKING: return "walking"
    case MODE_FLYING:  return "flying"
    case MODE_SWIMMING: return "swimming"
    case MODE_CROUCHING: return "crouching"
    }
    return "custom"
}

@(private)
moves_remove :: proc(loco:^Locomotion_State,id:u32) {
    kept:u32
    for i in 0..<loco.move_count {
        if loco.moves[i].id==id {continue}
        loco.moves[kept]=loco.moves[i]
        kept+=1
    }
    for i in kept..<loco.move_count {loco.moves[i]={}}
    loco.move_count=kept
}

@(private) LEDGE_PROBE :: f32(0.5)     // share of its radius of the sphere that looks for the wall
@(private) LEDGE_WALL :: f32(0.7)      // least part of the normal of a wall across its up: within 45° of upright
@(private) LEDGE_INSET :: f32(0.05)    // m past the face, and over the top, the capsule is put
@(private) LEDGE_TOP_STEPS :: 6        // rays down from the face to a radius past it that find how far the top goes
@(private) LEDGE_TOP_STEP :: f32(0.05) // m off the height of the top at which a ray has left it
@(private) LEDGE_SWEEP :: f32(0.9)     // share of its radius the capsule swept along the way has

// What ledge_find looks for: a wall within reach ahead, at most facing off where the character
// looks, whose top is between min_height and max_height over its feet.
Ledge_Query :: struct {
    reach:f32 `mirai:"unit=m"`,
    min_height,max_height:f32 `mirai:"unit=m"`,
    facing:f32 `mirai:"angle"`,
}

// Where a character can climb onto ahead of it toward facing: its feet on the top of a ledge, height
// over its feet. A sphere half its radius from just over its step finds the wall within reach, which is
// within 45° of upright and within query.facing of where it looks; a ray down from max_height over its
// feet, just past the face, finds the top, walkable for it, between min_height and max_height. The feet
// go a radius past the face, or onto the middle of a top narrower than that (the top of a thin wall).
// Its capsule fits standing there, and a thinner one goes up along the wall and across onto it without
// hitting anything.
ledge_find :: proc(physics:core.Ref(phys.Physics_State),capsule:phys.Character_Capsule,facing:[3]f32,query:Ledge_Query) -> (to:[3]f32,height:f32,found:bool) {
    if !(query.reach>0) || !(query.max_height>query.min_height) {return}
    frame:=capsule.up_frame
    up:=mm.quat_rotate(frame,{0,1,0})
    ahead:=facing-up*linalg.dot(facing,up)
    if l:=linalg.length(ahead);l>1e-6 {ahead/=l} else {return}
    feet,filter:=capsule.feet,capsule.filter
    probe:=capsule.radius*LEDGE_PROBE
    wall,hit:=phys.sweep(physics,phys.Sphere{probe},feet+up*(capsule.step_height+probe),1,ahead,query.reach,filter=filter)
    if !hit || !(wall.distance>0) {return}
    across:=wall.normal-up*linalg.dot(wall.normal,up)
    span:=linalg.length(across)
    if span<LEDGE_WALL {return}
    into:=-across/span
    if linalg.dot(into,ahead)<cmath.cos(query.facing) {return}
    face:=wall.point-up*linalg.dot(wall.point-feet,up)
    drop:=query.max_height+LEDGE_INSET-query.min_height
    top_at :: proc(physics:core.Ref(phys.Physics_State),face,into,up:[3]f32,depth,over,drop:f32,filter:phys.Query_Filter) -> (phys.Hit,bool) {
        return phys.raycast(physics,face+into*depth+up*over,-up,drop,filter=filter)
    }
    top,landed:=top_at(physics,face,into,up,LEDGE_INSET,query.max_height+LEDGE_INSET,drop,filter)
    if !landed || !(top.distance>0) || linalg.dot(top.normal,up)<cmath.cos(capsule.max_slope) {return}
    height=linalg.dot(top.point-feet,up)
    if height<query.min_height || height>query.max_height {return}
    // As far onto the top as a radius past the face, while it goes on at that height.
    stand:=capsule.radius+LEDGE_INSET
    reached:=f32(LEDGE_INSET)
    for step in 1..=LEDGE_TOP_STEPS {
        depth:=LEDGE_INSET+(stand-LEDGE_INSET)*f32(step)/LEDGE_TOP_STEPS
        hit,ok:=top_at(physics,face,into,up,depth,query.max_height+LEDGE_INSET,drop,filter)
        if !ok || abs(linalg.dot(hit.point-top.point,up))>LEDGE_TOP_STEP {break}
        reached=depth
    }
    if reached<stand {stand=0.5*(reached+LEDGE_INSET)}
    top.point=face+into*stand+up*linalg.dot(top.point-face,up)
    center:=capsule.step_height+0.5*(capsule.height-capsule.step_height)
    half:=0.5*(capsule.height-capsule.step_height)-capsule.radius
    blocking:[1]core.Entity
    if count,_:=phys.overlap_capsule(physics,top.point+up*(center+LEDGE_INSET),capsule.radius,half,frame,blocking[:],filter);count>0 {return}
    thin:=phys.Capsule{capsule.radius*LEDGE_SWEEP,half}
    start:=feet+up*center
    raised:=start+up*(height+LEDGE_INSET)
    if _,blocked:=phys.sweep(physics,thin,start,frame,raised-start,linalg.length(raised-start),filter=filter);blocked {return}
    across_to:=top.point+up*(center+LEDGE_INSET)-raised
    if _,blocked:=phys.sweep(physics,thin,raised,frame,across_to,linalg.length(across_to),filter=filter);blocked {return}
    return top.point,height,true
}

// Whether the ground falls away ahead of a standing character along direction: a sphere almost as
// wide as it, from over its step, meets nothing for reach, and a ray down from there, from its step
// over its feet, meets no ground within min_drop under them. What a jump off a ledge asks.
ledge_ahead :: proc(physics:core.Ref(phys.Physics_State),capsule:phys.Character_Capsule,direction:[3]f32,reach,min_drop:f32) -> bool {
    if !(reach>0) || !(min_drop>0) {return false}
    up:=mm.quat_rotate(capsule.up_frame,{0,1,0})
    ahead:=direction-up*linalg.dot(direction,up)
    if l:=linalg.length(ahead);l>1e-6 && l<=max(f32) {ahead/=l} else {return false}
    feet:=capsule.feet
    if _,blocked:=phys.sweep(physics,phys.Sphere{capsule.radius*LEDGE_SWEEP},feet+up*(capsule.step_height+capsule.radius),1,ahead,reach,filter=capsule.filter);blocked {return false}
    _,ground:=phys.raycast(physics,feet+ahead*reach+up*capsule.step_height,-up,capsule.step_height+min_drop,filter=capsule.filter)
    return !ground
}
