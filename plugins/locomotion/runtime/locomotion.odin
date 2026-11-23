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
@(name_requires="Slide") MODE_SLIDING :: Locomotion_Mode(5)
@(name_requires="Mantle") MODE_MANTLING :: Locomotion_Mode(6)
// The last mode of the engine: those after it are of games, written by them.
MODE_ENGINE_LAST :: MODE_MANTLING

LAYERED_MOVE_CAPACITY :: 4

Move_Mix :: enum u8 {
    Additive, // added to the velocity the locomotion drives toward
    Override, // replaces it on every axis, without gravity or ground, for as long as it lasts
}

// A velocity on top of locomotion for a number of ticks: dash, wind, conveyor.
Layered_Move :: struct {
    velocity:[3]f32 `mirai:"unit=m/s"`, // world axes
    ticks:u32,                          // left
    mix:Move_Mix,
    id:u32,                             // meaning given by the game
}

@(component,replicated,description="The character can walk, jump, fall and crouch (modes walking, falling and crouching of its Character).")
Walk :: struct {
    max_speed:f32 `mirai:"min=0,unit=m/s"`,
    sprint_speed:f32 `mirai:"min=0,unit=m/s"`,     // while the sprint action is held; at most max_speed: it does not sprint
    sprint_default:bool,                           // it sprints without the sprint action, which then only asks for the tactical sprint of a Tactical_Sprint
    backward_slowdown:f32 `mirai:"min=0,max=1"`,   // share of the speed lost moving straight back from where it looks
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
    braking:f32 `mirai:"min=0,unit=m/s2"`,
    air_control:f32 `mirai:"min=0,max=1"`,  // share of the acceleration and of the traction left in the air
    jump_height:f32 `mirai:"min=0,unit=m"`,     // of a jump let go at once
    jump_rise:f32 `mirai:"min=0,unit=s"`,       // a jump held keeps rising at the speed it started with for up to this long, then falls as it would
    jump_cut:f32 `mirai:"min=0,max=1"`,         // share of its speed up a jump keeps when it is let go while it rises; 1 or 0: all of it
    coyote_time:f32 `mirai:"min=0,unit=s"`, // after walking off a ledge, in which a jump still starts
    crouch_speed:f32 `mirai:"min=0,unit=m/s"`,  // top speed while crouched
    crouch_height:f32 `mirai:"min=0,unit=m"`,   // of its capsule crouched or sliding, from the feet to the top of the head; 0: it does not crouch
    crouch_toggle:bool,                         // crouch turns crouching on and off; otherwise it crouches while crouch is held
}

WALK_DEFAULT :: Walk{max_speed=5,acceleration=30,braking=40,air_control=0.3,jump_height=1.2,jump_cut=1,coyote_time=0.1,crouch_speed=2.5,crouch_height=1.2}

@(component,replicated,description="The character can fly (mode flying of its Character): toward the move in the axes of the look, without gravity.")
Fly :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`,
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
}

FLY_DEFAULT :: Fly{speed=8,acceleration=30}

@(component,replicated,description="The character can swim (mode swimming of its Character): in water deeper than depth, toward the move in the axes of the look, with its head out at the surface. Jump climbs out onto a ledge.")
Swim :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`,
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
    depth:f32 `mirai:"min=0,unit=m"`,          // of water over the ground from which it swims instead of walking
    surface_offset:f32 `mirai:"min=0,unit=m"`, // of the head over the surface while it swims on it
}

SWIM_DEFAULT :: Swim{speed=2,acceleration=4,depth=1.2,surface_offset=0.25}

// What the locomotion of a character carries from one tick to the next: its
// mode, its layered moves, the gravity it was asked for and the state of each
// of its moves. Only locomotion_step writes it and adds it, when the Character
// first moves by a mode; a scene never holds one.
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
    speed_scale:f32 `mirai:"transient,readonly"`,
    suspended:bool `mirai:"transient,readonly"`,
    placed,placed_at_rest:bool `mirai:"transient,local,hidden"`,
    crouched:bool `mirai:"transient,readonly,hidden"`,    // it asks for the crouch_height of its Walk: crouching or sliding
    crouch_held:bool `mirai:"transient,readonly,hidden"`, // the crouch button was down in the last tick
    crouch_on:bool `mirai:"transient,readonly,hidden"`,   // it asks to crouch: crouch held, or toggled on with crouch_toggle
    jump_speed:f32 `mirai:"transient,readonly,hidden,unit=m/s"`,   // up, of its last jump: a jump held keeps it (Walk.jump_rise)
    jump_rise:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // left in which its jump held keeps jump_speed
}

@(component,derived,replicated,description="The transient state of a character with parkour capabilities.")
Parkour_State :: struct {
    crouch_lock:bool `mirai:"transient,readonly,hidden"`, // a slide ended with it standing up: crouch held does nothing until it is let go
    crouch_buffer:f32 `mirai:"transient,readonly,hidden,unit=s"`, // left of a crouch pressed in the air, which slides on landing
    air_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,       // since it last stood
    fall_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // going down in the air without a stop: what a long fall is
    slide_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // it has slid
    slide_cooldown:f32 `mirai:"transient,readonly,hidden,unit=s"`, // left before crouch starts another slide
    slide_course:[3]f32 `mirai:"transient,readonly,hidden"`,       // where it started sliding, across its up
    slide_turn:f32 `mirai:"transient,readonly,hidden"`,            // radians its move turned the course from there, left about its up
    mantle_from,mantle_to:[3]f32 `mirai:"transient,readonly,hidden,unit=m"`, // where its feet start and end a mantle, in the world
    mantle_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // of the mantle it climbs
    mantle_height:f32 `mirai:"transient,readonly,unit=m"`,          // of the ledge of its last mantle over its feet: the animation of the climb chooses by it
    sprint_active:bool `mirai:"transient,readonly"`,                // in a tactical sprint (Tactical_Sprint): the camera and the animation choose by it
    sprint_spent:f32 `mirai:"transient,readonly"`,                  // energy of its Tactical_Sprint used: 0 is full (tactical_energy)
    sprint_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // in the tactical sprint: its ramp (tactical_boost)
    sprint_rest:f32 `mirai:"transient,readonly,hidden,unit=s"`,     // since energy was last spent
    sprint_off:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // without sprinting in the tactical sprint
    ledge_time:f32 `mirai:"transient,readonly,hidden,unit=s"`,      // standing at the min_speed of its Ledge_Jump or more
    ledge_ready:bool `mirai:"transient,readonly"`,                  // a jump now is a ledge jump: the prompt of a game
    ledge_jumping:bool `mirai:"transient,readonly"`,                // in the air by a ledge jump, until it lands
}

Locomotion_Request_Kind :: enum u8 {
    Add_Move,
    Remove_Moves, // those of the id of the move
    Set_Mode,
    Set_Speed_Scale,
    Set_Suspended,
    Set_Gravity_Scale, // times the gravity_scale of its Character until asked again: low gravity while charging a dash
}

Locomotion_Request :: struct {
    entity:core.Entity,
    kind:Locomotion_Request_Kind,
    move:Layered_Move,
    mode:Locomotion_Mode,
    gravity_scale,speed_scale:f32,
    suspended:bool,
}

GRAVITY_SCALE_MAX :: f32(1000)
SPEED_SCALE_MAX :: f32(1000)

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
set_mode :: proc(requests:^Locomotion_Requests,e:core.Entity,mode:Locomotion_Mode) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Mode,mode=mode})
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
set_suspended :: proc(requests:^Locomotion_Requests,e:core.Entity,suspended:bool) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Suspended,suspended=suspended})
}

@(step="fixed",stage="simulate",before="locomotion_step")
locomotion_prepare :: proc(
    characters:^core.Table(phys.Character,.Read),colliders:^core.Table(phys.Collider,.Read),states:^core.Table(Locomotion_State),parkours:^core.Table(Parkour_State),
    moves:^core.Table(phys.Character_Move),inputs:^core.Table(input.Move_Input),
    walks:^core.Table(Walk,.Read),flights:^core.Table(Fly,.Read),swims:^core.Table(Swim,.Read),slides:^core.Table(Slide,.Read),mantles:^core.Table(Mantle,.Read),
    requests:^Locomotion_Requests,time:core.Time,problems:^core.Problems,
) {
    if time.playing && time.dt>0 {
        for row in 0..<core.count(characters) {
            e:=core.entity_at(characters,row)
            if core.has(states,e) || !phys.character_owner(characters,colliders,e) {continue}
            if mode,ok:=initial_mode(walks,flights,swims,e);ok {
                core.add(states,e,Locomotion_State{mode=mode,speed_scale=1})
            }
        }
    }
    for asked in core.take(&requests.queue) {
        start:Maybe(Locomotion_Mode)
        if asked.kind==.Set_Mode {
            if missing:=mode_missing(asked.mode,asked.entity,walks,flights,swims,slides,mantles);missing!="" {
                core.report(problems,asked.entity,"locomotion.mode_component","the mode %s was asked of an entity without %s; give it a %s, which holds the parameters of that mode",mode_label(asked.mode),missing,missing)
                continue
            }
            start=asked.mode
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
        case .Set_Mode:
            c.mode,c.jumped,c.coyote=asked.mode,false,0
        case .Set_Speed_Scale:
            if !(asked.speed_scale>=0 && asked.speed_scale<=SPEED_SCALE_MAX) {
                core.report(problems,asked.entity,"locomotion.request","speed scale must be finite and between zero and %v",SPEED_SCALE_MAX)
                continue
            }
            c.speed_scale=asked.speed_scale
        case .Set_Suspended:
            if c.suspended!=asked.suspended {
                c.suspended=asked.suspended
                c.jumped,c.coyote,c.jump_rise,c.added,c.driven=false,0,0,{},{}
                if c.mode==MODE_SLIDING || c.mode==MODE_MANTLING {c.mode=MODE_FALLING}
                if p:=core.edit(parkours,asked.entity);p!=nil {p^={}}
            }
        case .Set_Gravity_Scale:
            if !(abs(asked.gravity_scale)<=GRAVITY_SCALE_MAX) {
                core.report(problems,asked.entity,"locomotion.request","a gravity scale of %v was asked; ask for a finite one of at most %v either way",asked.gravity_scale,GRAVITY_SCALE_MAX)
                continue
            }
            c.gravity=asked.gravity_scale
        }
    }
    for row in 0..<core.count(states) {
        e:=core.entity_at(states,row)
        if phys.character_owner(characters,colliders,e) &&
            (core.at(states,row).mode>MODE_ENGINE_LAST || core.has(walks,e) || core.has(flights,e) || core.has(swims,e)) {continue}
        core.remove(states,e)
        core.remove(parkours,e)
        core.remove(moves,e)
        core.remove(inputs,e)
    }
}

@(step="fixed",stage="simulate",before="physics_prepare")
locomotion_step :: proc(
    characters:^core.Table(phys.Character,.Read),states:^core.Table(Locomotion_State),parkours:^core.Table(Parkour_State),
    moves:^core.Table(phys.Character_Move),inputs:^core.Table(input.Move_Input),
    walks:^core.Table(Walk,.Read),flights:^core.Table(Fly,.Read),swims:^core.Table(Swim,.Read),slides:^core.Table(Slide,.Read),mantles:^core.Table(Mantle,.Read),tacticals:^core.Table(Tactical_Sprint,.Read),ledges:^core.Table(Ledge_Jump,.Read),
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
                c^={mode=mode,speed_scale=c.speed_scale,suspended=c.suspended,gravity=c.gravity}
                if p:=core.edit(parkours,e);p!=nil {p^={}}
            }
            c.placed,c.placed_at_rest,c.ready=true,placed.at_rest || c.placed_at_rest,true
            c.yaw=phys.look_yaw_of(frame,rotation)
            if core.owned(remotes,e) {
                if seat:=core.edit(inputs,e);seat!=nil {seat.look_yaw=c.yaw}
            }
        }
    }
    if !time.playing || time.dt<=0 {return}
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
        c.yaw=mm.angle_wrap(c.yaw+ground.ground_turn)
        if body.turn_speed>0 {
            c.yaw=mm.angle_wrap(mm.angle_approach(c.yaw,asked.look_yaw,body.turn_speed*time.dt*pace))
        } else {c.yaw=asked.look_yaw}
        given:=move_facing(asked,c.yaw,frame)
        walk:Maybe(Walk)
        if found_walk,has:=core.get(walks,e);has {walk=found_walk}
        fly,_:=core.get(flights,e)
        swim:Maybe(Swim)
        if found_swim,has:=core.get(swims,e);has {swim=found_swim}
        extra:Walk_Moves
        if found_slide,has:=core.get(slides,e);has {extra.slide=found_slide}
        if tactical,has:=core.get(tacticals,e);has {extra.tactical=tactical}
        if ledge,has:=core.get(ledges,e);has {extra.ledge=ledge}
        mantle,mantles_too:=core.get(mantles,e)
        parkour:Parkour_State
        p:=&parkour
        if walk!=nil && (mantles_too || extra.slide!=nil || extra.tactical!=nil || extra.ledge!=nil) {
            if !core.has(parkours,e) {core.add(parkours,e,Parkour_State{})}
            if row:=core.staged(parkours,e);row!=nil {p=row}
        } else if core.has(parkours,e) {core.remove(parkours,e)}
        if c.suspended {
            next.value.flags={.Ghosted}
            character_move_write(moves,e,next)
            continue
        }
        jump:=input.action_of(walk_actions,.Jump)
        // A jump facing a ledge climbs it instead, before the locomotion takes the jump.
        if mantles_too && walk!=nil && made && (c.mode==MODE_WALKING || c.mode==MODE_FALLING || c.mode==MODE_CROUCHING) && !overriding(c) {
            if wanted,from_ground:=mantle_wanted(c,p,mantle,ground,given,jump);wanted {
                if placed,ok:=core.world_of(locals,parents,e);ok {
                    facing:=mm.quat_forward(frame*mm.quat_axis_angle({0,1,0},given.look_yaw))
                    if to,height,found_ledge:=ledge_find(physics,capsule,facing,mantle,from_ground);found_ledge {mantle_start(c,p,placed.position,to,height)}
                }
            }
        }
        // Ready for a ledge jump where the ground falls away ahead, before the locomotion takes the jump.
        p.ledge_ready=false
        if ledge,has:=extra.ledge.?;has && walk!=nil && made {ledge_ready_update(c,p,ledge,ground,motion.linear,physics,capsule)}
        if missing:=mode_missing(c.mode,e,walks,flights,swims,slides,mantles);missing!="" {
            core.report(problems,e,"locomotion.mode_component","its Character is in the mode %s and it has no %s; give it a %s, which holds the parameters of that mode, or ask for another mode",mode_label(c.mode),missing,missing)
            // It falls when it can, and otherwise stands.
            if core.has(walks,e) {c.mode=MODE_FALLING}
        }
        if mode_missing(c.mode,e,walks,flights,swims,slides,mantles)!="" {
            next.value={}
        } else if c.mode==MODE_MANTLING {
            placed,_:=core.world_of(locals,parents,e)
            next.value=mantle_move(c,p,body,mantle,frame,placed.position,given,jump,time.dt*pace,overriding(c))
            // The layered moves of the tick drive the climb; the tick it ends they are spent, so it
            // stops on what it climbed instead of carrying the last one on.
            spent:=next.value
            layers_apply(c,&next.value if c.mode==MODE_MANTLING else &spent,body.traction_force,pace)
            move_paced(&next.value,c,body,pace,motion.linear,ground,frame)
        } else if c.mode>MODE_ENGINE_LAST {
            if written,has_written:=core.get(moves,e);has_written {next=written}
            layers_apply(c,&next.value,body.traction_force,pace)
            move_paced(&next.value,c,body,pace,motion.linear,ground,frame)
        } else {
            next.value=locomotion_move_paced(c,p,body,walk,fly,swim,extra,ground,frame,given,jump,input.action_of(walk_actions,.Sprint),input.action_of(walk_actions,.Crouch),motion.linear,phys.gravity_of_entity(physics,e)*body.gravity_scale*locomotion_gravity(c^),time.dt,pace)
        }
        next.value.flags+={.Reach_Drive}
        next.value.gravity_scale=c.gravity
        next.height=0
        if walking,ok:=walk.?;ok && c.crouched {next.height=walking.crouch_height}
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
    core.add(states,e,Locomotion_State{mode=mode,speed_scale=1})
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

// The top speed of walking for this input: sprint_speed (times boost, that of
// a tactical sprint) while sprinting forward (within 60° of the look, with the
// sprint action or sprint_default) when it is faster, less backward_slowdown by how straight back from the look the
// move points (-Z of the move is forward); crouched, crouch_speed, which
// sprint does not change.
walk_speed :: proc "contextless" (walk:Walk,move_input:input.Move_Input,sprinting:bool,crouched:=false,boost:f32=1) -> f32 {
    speed:=crouch_speed(walk) if crouched else walk.max_speed
    if !crouched && sprint_forward(move_input,sprinting || walk.sprint_default) && walk.sprint_speed*boost>speed {speed=walk.sprint_speed*boost}
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

// The components an entity has that change how its Walk slides, sprints and
// jumps.
Walk_Moves :: struct {
    slide:Maybe(Slide),
    tactical:Maybe(Tactical_Sprint),
    ledge:Maybe(Ledge_Jump),
}

// The Character_Move of one tick of a mode of the locomotion: from the input
// (jump is the action of Walk_Action.Jump among its buttons), the ground and
// the fluid the last step left, the frame of its vertical, the velocity of
// the body and its gravity, all in its own time, which runs pace times the
// time of the world (dt is that of its own time). walking and swim are nil
// for a character that cannot walk or swim: one that only swims stays in the
// mode out of the water; extra holds what else changes its walk.
locomotion_move :: proc(loco:^Locomotion_State,p:^Parkour_State,body:phys.Character,walking:Maybe(Walk),fly:Fly,swim:Maybe(Swim),extra:Walk_Moves,ground:phys.Character_State,frame:mm.Quat,move_input:input.Move_Input,jump,sprint,crouch:input.Action,velocity,gravity:[3]f32,dt:f32,pace:f32=1,scale:f32=1) -> (move:phys.Character_Drive) {
    up:=mm.quat_rotate(frame,{0,1,0})
    across :: proc "contextless" (v,up:[3]f32) -> [3]f32 {return v-up*linalg.dot(v,up)}
    look:=frame*mm.quat_axis_angle({0,1,0},move_input.look_yaw)
    if !move_input.world_velocity {look*=mm.quat_axis_angle({1,0,0},move_input.look_pitch)}
    walk,walks:=walking.?
    walk.max_speed*=scale
    walk.sprint_speed*=scale
    walk.crouch_speed*=scale
    move.yaw=move_input.look_yaw
    traction:=body.traction_force
    held:=move_input.buttons&input.action_bit(jump)!=0
    pressed:=held && !loco.jump_held && walk.jump_height>0
    released:=!held && loco.jump_held
    loco.jump_held=held
    v:=velocity-additive_delivered(velocity,loco.added,loco.driven)
    // Its direction; how far it asks is a share of the top speed of each mode.
    wish:=move_wish(move_input,frame,walk.max_speed)
    // Into the water and out of it by the depth of the water over the ground, the same both ways; never in
    // the middle of a move that overrides the locomotion, as climbing out.
    if swim,swims:=swim.?;swims && loco.mode!=MODE_FLYING && !overriding(loco) {
        within:=ground.walkable && ground.ground_distance<=body.step_height
        deep:=water_depth(body,ground)>swim.depth
        if loco.mode==MODE_SWIMMING {
            if walks && .In_Fluid not_in ground.fluid {
                loco.mode=MODE_FALLING
            } else if walks && within && !deep {loco.mode=MODE_WALKING}
        } else if .In_Fluid in ground.fluid && deep {loco.mode=MODE_SWIMMING}
    }
    if swim,swims:=swim.?;swims && loco.mode==MODE_SWIMMING {
        loco.jumped,loco.coyote,loco.crouched,p.sprint_active,p.ledge_jumping=false,0,false,false,false
        swim:=swim
        swim.speed*=scale
        current:=ground.fluid_velocity
        relative:=v-current
        aim:=mm.quat_rotate(look,move_share(move_input,swim.speed))
        surfaced:=ground.head_depth<=0 && linalg.dot(aim,up)>=0
        flat:=across(relative,up)
        drift:=across(current,up)
        if surfaced {
            move.air={mm.approach_point(flat,across(aim,up)*swim.speed,swim.acceleration*dt)+drift,traction}
            move.flags={.Airborne,.Float}
            move.float_height=swim.surface_offset
            // Out onto a ledge or a raft: a climb, for a jump against the drag of the water takes no one out.
            // It takes the feet to the surface at the speed of a jump, which then takes them jump_height over it.
            if speed:=cmath.sqrt(2*linalg.length(gravity)*walk.jump_height);pressed && speed*dt>0 && loco.move_count<LAYERED_MOVE_CAPACITY {
                loco.moves[loco.move_count]={velocity=up*speed+move_wish(move_input,frame,swim.speed)*swim.speed,ticks=max(u32(cmath.ceil(max(ground.depth,0)/(speed*dt))),1),mix=.Override}
                loco.move_count+=1
                loco.mode,loco.jumped=MODE_FALLING,true
            }
        } else if aim!={} {
            move.air={mm.approach_point(relative,aim*swim.speed,swim.acceleration*dt)+current,traction}
            move.flags={.Airborne,.Drive_Vertical}
        } else {
            // Still, what the buoyancy has over the weight, or the weight over it, takes it up or down slowly.
            move.air={mm.approach_point(flat,{},swim.acceleration*dt)+drift,traction}
            move.flags={.Airborne}
        }
    } else if loco.mode==MODE_FLYING {
        loco.jumped,loco.coyote,loco.crouched,p.sprint_active,p.ledge_jumping=false,0,false,false,false
        speed:=fly.speed*scale
        aim:=mm.quat_rotate(look,move_share(move_input,speed))
        move.air={mm.approach_point(v,aim*speed,fly.acceleration*dt),traction}
        move.flags={.Airborne,.Drive_Vertical,.No_Gravity}
    } else {
        slide,slides:=extra.slide.?
        tactical,tacticals:=extra.tactical.?
        ledge,ledges:=extra.ledge.?
        sprint_held:=move_input.buttons&input.action_bit(sprint)!=0
        crouches:=walk.crouch_height>0
        crouch_down:=crouches && move_input.buttons&input.action_bit(crouch)!=0
        crouch_pressed:=crouch_down && !loco.crouch_held
        loco.crouch_held=crouch_down
        if walk.crouch_toggle {
            if crouch_pressed {loco.crouch_on=!loco.crouch_on}
        } else {
            if !crouch_down {p.crouch_lock=false}
            loco.crouch_on=crouch_down && !p.crouch_lock
        }
        // A crouch pressed in the air waits for the landing, where it slides.
        if slides && !ground.standing && crouch_pressed {p.crouch_buffer=slide.buffer} else {p.crouch_buffer=max(p.crouch_buffer-dt,0)}
        p.slide_cooldown=max(p.slide_cooldown-dt,0)
        was:=loco.mode
        if ground.standing {
            loco.jumped,loco.coyote,p.air_time,p.ledge_jumping=false,0,0,false
            p.fall_time,loco.jump_rise=0,0
        } else {
            p.air_time+=dt
            p.fall_time=p.fall_time+dt if linalg.dot(v,up)<0 else 0
            // A jump held keeps its speed up for up to jump_rise, until it is let go or something stops the rise.
            if loco.jump_rise>0 {
                rising:=linalg.dot(v,up)
                if held && rising>=loco.jump_speed-2*linalg.length(gravity)*dt {
                    move.launch+=up*(loco.jump_speed-rising)
                    loco.jump_rise=max(loco.jump_rise-dt,0)
                } else {loco.jump_rise=0}
            }
            if released && loco.jumped && !p.ledge_jumping && walk.jump_cut>0 && walk.jump_cut<1 {
                if rising:=linalg.dot(v,up);rising>0 {move.launch-=up*rising*(1-walk.jump_cut)}
            }
            if (was==MODE_WALKING || was==MODE_CROUCHING || was==MODE_SLIDING) && !loco.jumped {
                loco.coyote=walk.coyote_time
            } else {loco.coyote=max(loco.coyote-dt,0)}
        }

        n:=ground.ground_normal
        if linalg.dot(n,up)<=0 {n=up}
        relative:=v-ground.ground_velocity
        current:=relative-n*linalg.dot(relative,n)
        // A slide starts from a crouch at a run or a landing with crouch held, goes on along the
        // ground and ends standing, or crouched when crouch is held without a move.
        slide_end :: proc "contextless" (loco:^Locomotion_State,p:^Parkour_State,walk:Walk,slide:Slide,crouch_down,moving:bool) {
            loco.mode,p.slide_cooldown=MODE_WALKING,slide.cooldown
            if !moving {return}
            if walk.crouch_toggle {loco.crouch_on=false} else if crouch_down {p.crouch_lock,loco.crouch_on=true,false}
        }
        if was==MODE_SLIDING && !(slides && crouches && ground.standing) {
            slide_end(loco,p,walk,slide,crouch_down,wish!={})
            if !ground.standing {loco.mode=MODE_FALLING}
        }
        if slides && crouches && ground.standing && loco.mode!=MODE_SLIDING && p.slide_cooldown<=0 && !p.crouch_lock {
            speed:=linalg.length(current)
            landing:=was==MODE_FALLING && (p.crouch_buffer>0 || !walk.crouch_toggle && crouch_down)
            if crouch_pressed && loco.crouch_on && speed>=slide.start_speed || landing && speed>=slide.land_speed {
                p.crouch_buffer=0
                if walk.crouch_toggle {loco.crouch_on=true}
                slide_start(p,current,up)
                loco.mode=MODE_SLIDING
                if tacticals && p.sprint_active {tactical_spend(p,tactical,tactical.cost_slide)}
            }
        }
        // The tactical sprint runs while it sprints walking or falling, before the walk takes its speed.
        boost,jump_boost:f32=1,1
        if tacticals {
            running:=loco.mode!=MODE_SLIDING && !(ground.standing && (loco.crouch_on || ground.cramped))
            tactical_update(p,tactical,sprint_forward(move_input,sprint_held) && walk.sprint_speed>0,running,ground.standing,dt,sprint_held)
            boost,jump_boost=tactical_boost(p^,tactical)
        } else {p.sprint_active=false}
        // At min_speed or faster on the ground, toward a ledge jump.
        if ledges && ground.standing && was==MODE_WALKING && linalg.length(current)>=ledge.min_speed {
            p.ledge_time+=dt
        } else {p.ledge_time=0}
        if loco.mode==MODE_SLIDING {
            velocity,ended:=slide_velocity(p,slide,n,up,current,wish,gravity,dt)
            move.ground={velocity,traction}
            if ended {slide_end(loco,p,walk,slide,crouch_down,wish!={})}
        }
        if loco.mode!=MODE_SLIDING {
            crouching:=ground.standing && (loco.crouch_on || ground.cramped)
            loco.mode=ground.standing?(crouching?MODE_CROUCHING:MODE_WALKING):MODE_FALLING
            if move.ground.force==0 {
                speed:=walk_speed(walk,move_input,sprint_held,loco.mode==MODE_CROUCHING,boost)
                desired:[3]f32
                if share:=move_wish(move_input,frame,speed);share!={} {
                    along:=share-up*(linalg.dot(share,n)/linalg.dot(n,up))
                    desired=along*(speed*linalg.length(share)/linalg.length(along))
                }
                rate:=desired=={}?walk.braking:walk.acceleration
                if desired!={} && p.sprint_active && tactical.acceleration_multiplier>0 {rate*=tactical.acceleration_multiplier}
                move.ground={mm.approach_point(current,desired,rate*dt),traction}
            }
        }
        loco.crouched=loco.mode==MODE_SLIDING || ground.standing && loco.crouch_on

        move.air={velocity=across(v,up)}
        if wish!={} && walk.air_control>0 {
            speed:=walk_speed(walk,move_input,sprint_held,false,boost)
            share:=move_wish(move_input,frame,speed)
            // A ledge jump is steered, not slowed.
            if p.ledge_jumping {speed=max(speed,linalg.length(move.air.velocity))}
            move.air={mm.approach_point(move.air.velocity,share*speed,walk.air_control*walk.acceleration*dt),walk.air_control*traction}
            // Ground too steep to walk is not climbed from the air either.
            if ground.ground_normal!={} && !ground.walkable && ground.ground_distance<=body.step_height {
                flat:=across(ground.ground_normal,up)
                if into:=linalg.dot(move.air.velocity,flat);into<0 && flat!={} {move.air.velocity-=flat*(into/linalg.dot(flat,flat))}
            }
        }

        if pressed && (ground.standing || loco.coyote>0 && !loco.jumped) {
            base:=linalg.dot(ground.standing?v-ground.ground_velocity:v,up)
            rise:=cmath.sqrt(2*linalg.length(gravity)*walk.jump_height)*jump_boost
            if ledges && p.ledge_ready && ground.standing {
                // A ledge jump: added_speed along where it goes over the ground, at most max_speed across
                // its up, and up_speed over the rise of its jump.
                flat:=across(v-ground.ground_velocity,up)
                moving:=linalg.length(flat)
                along:=flat/moving if moving>1e-4 else wish
                launched:=flat+along*ledge.added_speed
                if l:=linalg.length(launched);l>ledge.max_speed && l>0 {launched*=ledge.max_speed/l}
                move.launch=launched-flat
                rise+=ledge.up_speed
                p.ledge_jumping=true
            }
            move.launch+=up*(rise-base)
            if ground.standing {move.air={velocity=across(v,up)+across(move.launch,up)}}
            if loco.mode==MODE_SLIDING {p.slide_cooldown=slide.cooldown}
            if tacticals && p.sprint_active && !p.ledge_jumping {tactical_spend(p,tactical,tactical.cost_jump)}
            loco.mode,loco.jumped,loco.coyote,loco.crouched,loco.crouch_on=MODE_FALLING,true,0,false,false
            p.ledge_ready,p.ledge_time=false,0
            // A ledge jump is a launch of its own, which holding the jump does not lengthen.
            loco.jump_speed,loco.jump_rise=rise,0 if p.ledge_jumping else walk.jump_rise
        }
    }
    loco.driven=move.ground.velocity+ground.ground_velocity if ground.standing && .Airborne not_in move.flags else move.air.velocity
    layers_apply(loco,&move,traction,pace)
    return
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
locomotion_move_paced :: proc(loco:^Locomotion_State,p:^Parkour_State,body:phys.Character,walking:Maybe(Walk),fly:Fly,swim:Maybe(Swim),extra:Walk_Moves,ground:phys.Character_State,frame:mm.Quat,move_input:input.Move_Input,jump,sprint,crouch:input.Action,velocity,gravity:[3]f32,dt,pace:f32) -> (move:phys.Character_Drive) {
    own:=ground
    own.ground_velocity/=pace
    own.fluid_velocity/=pace
    move=locomotion_move(loco,p,body,walking,fly,swim,extra,own,frame,move_input,jump,sprint,crouch,velocity/(loco.pace>0?loco.pace:1),gravity,dt*pace,pace,loco.speed_scale)
    move_paced(&move,loco,body,pace,velocity,ground,frame)
    return
}

// Whether a layered move overrides the locomotion now.
@(private)
overriding :: proc "contextless" (loco:^Locomotion_State) -> bool {
    for layered in loco.moves[:loco.move_count] {if layered.mix==.Override {return true}}
    return false
}

// m of water over the walkable ground in reach of the feet, else over the feet.
@(private)
water_depth :: proc "contextless" (body:phys.Character,ground:phys.Character_State) -> f32 {
    if ground.walkable && ground.ground_distance<=body.step_height {return ground.depth+ground.ground_distance}
    return ground.depth
}

// The component a mode of the engine needs that the entity lacks; "" when it has it or the mode is of a game.
@(private)
mode_missing :: proc(mode:Locomotion_Mode,e:core.Entity,walks:^core.Table(Walk,$A),flights:^core.Table(Fly,$B),swims:^core.Table(Swim,$C),slides:^core.Table(Slide,$D),mantles:^core.Table(Mantle,$E)) -> string {
    switch mode {
    case MODE_FALLING,MODE_WALKING,MODE_CROUCHING: if !core.has(walks,e) {return "Walk"}
    case MODE_FLYING:               if !core.has(flights,e) {return "Fly"}
    case MODE_SWIMMING:             if !core.has(swims,e) {return "Swim"}
    case MODE_SLIDING:
        if !core.has(walks,e) {return "Walk"}
        if !core.has(slides,e) {return "Slide"}
    case MODE_MANTLING:
        if !core.has(walks,e) {return "Walk"}
        if !core.has(mantles,e) {return "Mantle"}
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
    case MODE_SLIDING: return "sliding"
    case MODE_MANTLING: return "mantling"
    }
    return "of the game"
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
