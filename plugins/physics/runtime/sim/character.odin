package mirai_physics

import cmath "core:math"
import "mirai:std/base"
import math "mirai:std/math"
import "mirai:std/spatial"

Character_Handle :: distinct base.Handle

Character_Desc :: struct {
    radius,height:f32,        // m; height from the feet to the top of the head
    mass:f32,                 // kg
    max_slope:f32,            // radians, steepest ground that can be walked
    step_height:f32,          // m, tallest obstacle that is walked over
    traction_force:f32,       // N, limit of the force that drives the character against the ground or the air
    adhesion_force:f32,       // N, limit of the force that keeps the feet on ground that falls away
    gravity_scale:f32,
    push_force:f32,           // N, limit of the traction passed to a dynamic body the capsule leans on; zero takes the traction force
    // kg/m3 of the body, whose volume in a fluid is its mass over this, as a capsule from the feet to the head:
    // the capsule it collides with is not the volume of a body. Zero gives it no buoyancy.
    density:f32,
    drag:f32,                 // Cd of the body in a fluid; zero takes CD_HUMAN
    up_speed:f32,             // radians per second its up turns toward the opposite of its gravity; zero keeps it
    filter:Filter,
    user_data:u64,
}
#assert(size_of(Character_Desc)==80)

CHARACTER_DESC_DEFAULT :: Character_Desc{
    radius=0.3,height=1.8,mass=80,max_slope=0.25*PI,step_height=0.3,
    traction_force=3200,adhesion_force=2400,gravity_scale=1,push_force=800,density=985,drag=CD_HUMAN,up_speed=PI,filter=FILTER_DEFAULT,
}

Move_Flag :: enum u32 {
    Airborne,       // does not stand on ground even where it could: a jump that starts, a flight
    Drive_Vertical, // the drive also controls the vertical velocity
    No_Gravity,
    Float,          // in a fluid, holds the head float_height over the surface, softly and with the adhesion force at most
}
Move_Flags :: bit_set[Move_Flag;u32]

// A velocity a character is driven toward by a bounded force.
Drive :: struct {
    velocity:Vec3, // m/s
    force:f32,     // N, limit of the force that drives toward it; zero leaves the velocity alone
}

// What drives a character from the next step on, until it is set again: the locomotion of whoever
// moves it decides it from its input and the ground the last step found. A character stands on walkable
// ground within its step height by itself: it lands when it comes down on it, and leaves it when the
// ground falls away, when it is launched upward or when its move is Airborne. The step takes the drive
// of what it finds, so a character that walks off a ledge already moves as in the air.
Character_Move :: struct {
    ground:Drive,    // while it stands: relative to the ground, along it
    air:Drive,       // otherwise: in the world, across the up of the character unless Drive_Vertical
    launch:Vec3,     // m/s added at once; a standing character pushes the ground back
    yaw:f32,         // radians of its heading (its look, -Z at 0), turning left about the up in its up_frame
    flags:Move_Flags,
    float_height:f32, // m of the head over the surface of a fluid, with Float
    // Its seconds per second of the world, a body that lives faster or slower (bullet time): its gravity,
    // adhesion and pushes scale by the square and its up turns by it; whoever moves it scales its drives
    // and launch by it. Zero: 1.
    pace:f32,
    gravity_scale:f32, // times the gravity_scale of its desc, the one a game asks for a while; zero: 1
}
#assert(size_of(Character_Move)==64)

@(private)
move_pace :: #force_inline proc "contextless" (m:Character_Move) -> f32 {return m.pace>0?m.pace:1}

Ground_Flag :: enum u32 {
    Hit,      // there is something under the character within reach
    Walkable,
    Standing, // the last step held the character on it: drove along it, kept the feet on it and pushed it back
    Stale,    // found before the character or the world changed: the next step looks again
}
Ground_Flags :: bit_set[Ground_Flag;u32]

@(private) Effect_Kind :: enum u32 {None,Add,Set}

Fluid_Flag :: enum u32 {
    In_Fluid,   // some of the body is under the surface of a fluid
    Underwater, // its head is
}
Fluid_Flags :: bit_set[Fluid_Flag;u32]

// What the last step left of a character. Its ground is found again at the end of every step, where the
// next one starts, so the locomotion that runs between two steps decides on it.
Character_State :: struct {
    ground:Ground_Flags,
    ground_turn:f32,        // radians the ground turned the character in the last step
    ground_body:Body_Handle,
    ground_point,ground_normal:Vec3,
    ground_velocity:Vec3,   // of the ground at the point, with its surface
    ground_surface:Vec3,    // of the surface itself along the ground, a conveyor: part of the velocity its body does not have
    ground_distance:f32,    // m of the feet above the ground found, negative when sunk; zero without ground
    effect_velocity:Vec3,
    effect:Effect_Kind,     // instant effect waiting for the next step
    fluid:Fluid_Flags,
    submersion:f32,         // 0 to 1: the share of the body, a capsule from the feet to the head, under the surface
    head_depth:f32,         // m of the top of the head under the surface; negative above it, -max(f32) without a fluid in its column
    fluid_velocity:Vec3,    // of the fluid it is in: its current
    depth:f32,              // m of fluid over the feet: head_depth plus the height
    // The wall the capsule leans on, found with the ground: of what it touches and cannot push (a
    // static or kinematic body), the normal across its up and out of the wall that its drive heads
    // into the most, and how fast the drive heads into it, m/s; zero without one.
    wall_normal:Vec3,
    wall_push:f32,
    // The frame of its vertical: its +Y is the up of the character, about which the yaw of the move turns. The
    // step turns it toward the opposite of the gravity it feels, without twisting it about the up.
    up_frame:Quat,
}
#assert(size_of(Character_State)==144)

@(private)
Character :: struct {
    desc:Character_Desc,
    state:Character_State,
    move:Character_Move,
    body:Body_Handle,
    shape:Shape_Handle,
    generation:u32, // odd while the slot is in use
    next_free:i32,
}
#assert(size_of(Character)==312)

@(private)
Ground :: struct {
    hit:bool,
    walkable:bool,
    body:Body_Handle,
    point,normal:Vec3,
    velocity:Vec3,
    surface:Vec3,
    distance:f32,
}

@(private) UP :: Vec3{0,1,0}
@(private) CHARACTER_SKIN :: 0.02  // m the ground probe is thinner than the capsule
@(private) LAND_DISTANCE :: 0.01   // m above the ground at which a fall ends
@(private) LAND_SPEED :: 0.1       // m/s upward above which a character does not land, and a launch takes it off the ground
@(private) FACE_PROBE :: 0.03      // m beside and above an edge where the face next to it is read
@(private) STEP_TOLERANCE :: LINEAR_SLOP // m above step_height that still is a step
@(private) FLATTEN_MIN :: 0.05     // vertical part of a contact normal below which it already is a wall
@(private) FLATTEN_MAX :: 0.95     // and above which the contact is under the capsule and holds it
@(private) FLATTEN_MIN_SCALE :: 0.25 // a nearly vertical contact made horizontal pushes at most four times its depth
@(private) CHARACTER_PUSHES :: 4 // directions of dynamic bodies a character leans on; more share the closest one
@(private) LINEAR_LOCKS :: Body_Flags{.Lock_Linear_X,.Lock_Linear_Y,.Lock_Linear_Z}
@(private) ANGULAR_LOCKS :: Body_Flags{.Lock_Angular_X,.Lock_Angular_Y,.Lock_Angular_Z}

@(private) character_half_segment :: #force_inline proc "contextless" (d:^Character_Desc) -> f32 {
    return 0.5*(d.height-d.step_height)-d.radius
}
@(private) character_center_height :: #force_inline proc "contextless" (d:^Character_Desc) -> f32 {
    return d.step_height+0.5*(d.height-d.step_height)
}

@(private)
character_read :: #force_inline proc "contextless" (w:^World,h:Character_Handle) -> (^Character,i32) {
    index:=base.handle_index(base.Handle(h))
    generation:=base.handle_generation(base.Handle(h))
    if index>=u32(w.character_high) || generation&1==0 || w.characters[index].generation!=generation {return nil,-1}
    return &w.characters[index],i32(index)
}
@(private)
character_get :: #force_inline proc "contextless" (w:^World,h:Character_Handle) -> (^Character,i32) {
    ch,index:=character_read(w,h)
    if ch!=nil {stamp(w,.Characters,index)}
    return ch,index
}

@(private)
character_mass_set :: proc(w:^World,body:Body_Handle,d:^Character_Desc) {
    length:=d.height-d.step_height
    side:=d.mass*(0.25*d.radius*d.radius+length*length/12)
    body_set_mass_properties(w,body,d.mass,{0,character_center_height(d),0},mat3_diagonal({side,0.5*d.mass*d.radius*d.radius,side}))
}

@(private)
character_desc_valid :: proc "contextless" (d:^Character_Desc) -> bool {
    return finite(d.radius,d.height,d.mass,d.max_slope,d.step_height,d.traction_force,d.adhesion_force,d.gravity_scale,d.push_force,d.density,d.drag,d.up_speed) &&
        d.max_slope>0 && d.max_slope<0.5*PI && d.push_force>=0 && d.density>=0 && d.drag>=0 && d.up_speed>=0
}

character_valid :: proc(w:^World,h:Character_Handle) -> bool {
    ch,_:=character_read(w,h)
    return ch!=nil
}

// A character standing with its feet at `position`, turned as `rotation`, whose +Y is its up: a dynamic body
// with a capsule along the up that floats one step height above the ground. It sleeps standing still with
// nothing to do, and a new move, a launch or a change of the world or of what it stands on wakes it. Its up_frame
// is `frame` turned to that up, and the yaw of its move that of the rotation in it. Null when the description
// is not usable or a capacity (characters, bodies, shapes) is exhausted.
character_create :: proc(w:^World,desc:Character_Desc,position:Vec3,rotation:=QUAT_IDENTITY,frame:=QUAT_IDENTITY) -> Character_Handle {
    d:=desc
    if !character_desc_valid(&d) || !finite(position) || !finite(rotation,frame) {return {}}
    if !(d.radius>0 && d.mass>0 && d.step_height>=0 && d.height>=2*d.radius+d.step_height) {return {}}
    if d.drag==0 {d.drag=CD_HUMAN}
    if w.character_free<0 && int(w.character_high)>=len(w.characters) {
        w.stats.character_capacity_exhausted+=1
        return {}
    }
    turned:=q_normalize(rotation)
    up_frame:=up_frame_turn(q_normalize(frame),q_rotate(turned,UP))
    yaw:=up_frame_yaw(up_frame,turned)
    body_desc:=BODY_DESC_DEFAULT
    body_desc.position=position
    body_desc.rotation=character_rotation(up_frame,yaw)
    body_desc.gravity_scale=d.gravity_scale
    body_desc.locks=ANGULAR_LOCKS
    body_desc.user_data=d.user_data
    body:=body_create(w,body_desc)
    half:=character_half_segment(&d)
    center:=Vec3{0,character_center_height(&d),0}
    shape_desc:=SHAPE_DESC_DEFAULT
    shape_desc.geometry=Capsule{d.radius,half}
    shape_desc.transform={center,QUAT_IDENTITY}
    shape_desc.friction=0
    shape_desc.filter=d.filter
    shape_desc.user_data=d.user_data
    shape:=shape_create(w,body,shape_desc)
    if shape=={} {
        body_destroy(w,body)
        return {}
    }
    character_mass_set(w,body,&d)
    stamp(w,.Bodies,i32(base.handle_index(base.Handle(body))))
    w.bodies[base.handle_index(base.Handle(body))].flags+={.Character}
    index:=w.character_free
    if index>=0 {
        w.character_free=w.characters[index].next_free
    } else {
        index=w.character_high
        w.character_high+=1
    }
    w.character_count+=1
    ch:=&w.characters[index]
    stamp(w,ch)
    ch^={desc=d,body=body,shape=shape,generation=ch.generation+1,next_free=-1}
    ch.move={ground={force=d.traction_force},yaw=yaw}
    ch.state.ground={.Stale}
    ch.state.head_depth,ch.state.depth=-max(f32),-max(f32)
    ch.state.up_frame=up_frame
    return Character_Handle(base.handle_make(u32(index),ch.generation))
}

character_destroy :: proc(w:^World,h:Character_Handle) {
    ch,index:=character_get(w,h)
    if ch==nil {return}
    body_destroy(w,ch.body)
    ch^={generation=ch.generation+1,next_free=w.character_free}
    w.character_free=index
    w.character_count-=1
}

// What drives the character from the next step on. Another move than the one it has wakes it.
character_set_move :: proc(w:^World,h:Character_Handle,move:Character_Move) -> bool {
    if !finite(move.ground.velocity,move.air.velocity,move.launch) || !finite(move.ground.force,move.air.force,move.yaw,move.float_height,move.pace,move.gravity_scale) {return false}
    ch,index:=character_read(w,h)
    if ch==nil {return false}
    if ch.move==move {return true}
    stamp(w,.Characters,index)
    ch.move=move
    character_wake(w,ch)
    return true
}

@(private)
character_wake :: proc(w:^World,ch:^Character) {
    if _,body:=body_read(w,ch.body);body>=0 {body_wake(w,body)}
}
character_move :: proc(w:^World,h:Character_Handle) -> Character_Move {
    ch,_:=character_read(w,h)
    return ch!=nil?ch.move:{}
}
character_state :: proc(w:^World,h:Character_Handle) -> Character_State {
    ch,_:=character_read(w,h)
    return ch!=nil?ch.state:{}
}
character_desc :: proc(w:^World,h:Character_Handle) -> Character_Desc {
    ch,_:=character_read(w,h)
    return ch!=nil?ch.desc:{}
}
// Changes how the capsule meets the ground. Its size, mass and filter stay as created.
character_set_desc :: proc(w:^World,h:Character_Handle,desc:Character_Desc) -> bool {
    d:=desc
    if !character_desc_valid(&d) {return false}
    ch,_:=character_get(w,h)
    if ch==nil {return false}
    if d.drag==0 {d.drag=CD_HUMAN}
    d.radius,d.height,d.mass,d.step_height,d.filter=ch.desc.radius,ch.desc.height,ch.desc.mass,ch.desc.step_height,ch.desc.filter
    ch.desc=d
    character_wake(w,ch)
    return true
}
// Changes what the capsule and the probes of the character meet, keeping everything else.
character_set_filter :: proc(w:^World,h:Character_Handle,filter:Filter) {
    ch,_:=character_get(w,h)
    if ch==nil {return}
    ch.desc.filter=filter
    shape_set_filter(w,ch.shape,filter)
}
// Changes the height of the capsule with the feet where they are: to crouch and to stand up again.
// Growing first checks the taller capsule, CHARACTER_SKIN thinner so a wall it leans on is not in the
// way, against the world with the filter of the character and fails, changing nothing, when something
// is in its way (a ceiling). False also for a capsule that does not fit.
character_set_height :: proc(w:^World,h:Character_Handle,height:f32) -> bool {
    if !finite(height) {return false}
    ch,_:=character_get(w,h)
    if ch==nil || !(height>=2*ch.desc.radius+ch.desc.step_height) {return false}
    body,body_index:=body_get(w,ch.body)
    shape,_:=shape_get(w,ch.shape)
    if body==nil || shape==nil {return false}
    d:=ch.desc
    d.height=height
    center:=Vec3{0,character_center_height(&d),0}
    capsule:=Capsule{d.radius,character_half_segment(&d)}
    if height>ch.desc.height {
        filter:=Query_Filter{filter=d.filter,ignore_body=ch.body}
        blocking:[1]Shape_Handle
        thin:=Capsule{max(capsule.radius-CHARACTER_SKIN,0.5*capsule.radius),capsule.half_height}
        if overlap_shape(w,thin,{body.position+q_rotate(body.rotation,center),body.rotation},blocking[:],filter)>0 {return false}
    }
    ch.desc.height=height
    shape.size.y=capsule.half_height
    shape.local.p=center
    character_mass_set(w,ch.body,&ch.desc)
    ch.state.ground+={.Stale}
    body_update_proxies(w,body_index)
    body_wake(w,body_index)
    return true
}

// Keeps the feet from moving along the world axes of its linear locks, as those of a body: nothing the step
// does moves them along one, and only a teleport puts them elsewhere on it. Its rotation stays locked, since
// its move turns it.
character_set_locks :: proc(w:^World,h:Character_Handle,locks:Body_Flags) {
    ch,_:=character_get(w,h)
    if ch==nil {return}
    body_set_locks(w,ch.body,ANGULAR_LOCKS+locks&LINEAR_LOCKS)
}

character_body :: proc(w:^World,h:Character_Handle) -> Body_Handle {
    ch,_:=character_read(w,h)
    return ch!=nil?ch.body:{}
}
// The capsule: shape_set_surface gives it the rules of its contacts, as its dominance.
character_shape :: proc(w:^World,h:Character_Handle) -> Shape_Handle {
    ch,_:=character_read(w,h)
    return ch!=nil?ch.shape:{}
}
// Feet of the character.
character_position :: proc(w:^World,h:Character_Handle) -> Vec3 {
    ch,_:=character_read(w,h)
    return ch!=nil?body_position(w,ch.body):{}
}
character_velocity :: proc(w:^World,h:Character_Handle) -> Vec3 {
    ch,_:=character_read(w,h)
    return ch!=nil?body_linear_velocity(w,ch.body):{}
}
// Teleports the feet; the velocity stays.
character_set_position :: proc(w:^World,h:Character_Handle,position:Vec3) -> bool {
    if !finite(position) {return false}
    ch,_:=character_get(w,h)
    if ch==nil {return false}
    body_set_transform(w,ch.body,position,body_rotation(w,ch.body))
    ch.state.ground+={.Stale}
    return true
}
// Turns the character as `rotation`, whose +Y is its up from now on: its up_frame turns to that up and the yaw
// of its move becomes that of the rotation in it.
character_set_rotation :: proc(w:^World,h:Character_Handle,rotation:Quat) -> bool {
    if !finite(rotation) {return false}
    ch,_:=character_get(w,h)
    if ch==nil {return false}
    turned:=q_normalize(rotation)
    ch.state.up_frame=up_frame_turn(ch.state.up_frame,q_rotate(turned,UP))
    ch.move.yaw=up_frame_yaw(ch.state.up_frame,turned)
    body_set_transform(w,ch.body,body_position(w,ch.body),character_rotation(ch.state.up_frame,ch.move.yaw))
    ch.state.ground+={.Stale}
    return true
}
// The up of a frame of the vertical: its +Y.
up_frame_up :: #force_inline proc "contextless" (frame:Quat) -> Vec3 {return q_rotate(frame,UP)}
// The frame of the vertical turned toward `up` by at most `angle` radians, by the shortest rotation: it turns
// with the up without twisting about it, so a yaw kept in it keeps heading the same way along the ground.
up_frame_turn :: proc "contextless" (frame:Quat,up:Vec3,angle:=max(f32)) -> Quat {
    to:=normalize(up)
    if to=={} {return frame}
    from:=up_frame_up(frame)
    axis:=cross(from,to)
    s,c:=length(axis),dot(from,to)
    if s==0 && c>0 {return frame}
    if s<1e-6 && c<0 {axis=perp(from)} else {axis/=s}
    return q_normalize(q_axis_angle(axis,min(cmath.atan2(s,c),angle))*frame)
}
// The yaw of a rotation in a frame of the vertical: where its -Z heads, about the up, as a camera looks.
up_frame_yaw :: proc "contextless" (frame,rotation:Quat) -> f32 {
    forward:=q_rotate(conj(frame)*rotation,math.FORWARD)
    return math.yaw_of_direction(forward)
}
// The body of a character faces its yaw with -Z, as a look does.
character_rotation :: #force_inline proc "contextless" (frame:Quat,yaw:f32) -> Quat {
    return frame*q_axis_angle(UP,yaw)
}

// Instant effect, applied at the next step: adds to the velocity of the character or replaces it. An
// upward launch takes a walking character off the ground.
character_launch :: proc(w:^World,h:Character_Handle,velocity:Vec3,override:=false) -> bool {
    if !finite(velocity) {return false}
    ch,_:=character_get(w,h)
    if ch==nil {return false}
    state:=&ch.state
    if override {
        state.effect_velocity,state.effect=velocity,.Set
    } else {
        state.effect_velocity+=velocity
        if state.effect==.None {state.effect=.Add}
    }
    character_wake(w,ch)
    return true
}


// The move of a character in one step and its constraint against the ground or the air.
@(private)
Character_Solver :: struct {
    character,body,ground:i32, // slots; ground is -1 without a body under the feet
    next:Character_State,
    move:Character_Move,
    drive:Drive,               // of the move, for standing or for the air
    found:Ground,              // what is under the feet at the start of the step
    standing:bool,             // on found
    velocity:Vec3,             // of the body once instant effects and the launch of the move are in
    up:Vec3,                   // of the character in the step
    free:Vec3,                 // 1 along the world axes its linear locks leave free, 0 along the locked ones
    c,g:i32,                   // solver bodies; g is -1 for ground that does not move
    normal,tangent1,tangent2:Vec3,
    anchor:Vec3,               // ground point relative to the center of mass of the ground body
    target:Vec3,
    inv_inertia_g:Mat3,
    inv_mass_c,inv_mass_g:f32,
    normal_mass:f32,
    tangent_mass:[3]f32,       // inverse of the symmetric 2x2: xx, xy, yy
    separation:f32,            // along the normal, of the feet above the ground at the start of the step
    drive_limit,adhesion_limit:f32, // N s per substep
    normal_impulse:f32,
    drive_impulse:Vec3,
    pushes:[CHARACTER_PUSHES]Vec3,  // into the dynamic bodies the capsule touches, in the plane of the drive
    push_count:i32,
    push_limit:f32,                 // N s per substep of drive along each of them
    floating:bool,                  // Float holds the head over the surface of a fluid
    float_separation:f32,           // m of the feet above where Float holds them, at the start of the step
    float_limit:f32,                // N s per substep
    wedge:Vec3,                     // the ground normal of the faces that hold it (character_wedged); zero without
    wedge_body:i32,
}

// Finds what is under the feet, along its up. A sphere a little thinner than the capsule is swept down from
// its lower end; when it touches an edge or a steep face, a ray reads the face beside the touch, and a ray
// down the axis finds the floor when that face is too high to step on or too steep.
@(private)
character_probe :: proc(w:^World,ch:^Character,body:^Body,up:Vec3,fall:f32) -> (ground:Ground,ground_index:i32) {
    d:=&ch.desc
    r:=d.radius
    rc:=r-min(CHARACTER_SKIN,0.25*r)
    rest:=d.step_height+r-rc
    reach:=rest+d.step_height+fall
    low:=body.position+up*(d.step_height+r)
    filter:=Query_Filter{filter=d.filter,ignore_body=ch.body}
    cos_max:=cmath.cos(d.max_slope)
    ground_index=-1
    hit,found:=shape_cast_closest(w,Sphere{rc},{low,QUAT_IDENTITY},-up*reach,filter)
    if !found {return}
    ground={hit=true,body=hit.body,point=hit.point,normal=hit.normal,distance=hit.fraction*reach-rest}
    under_shape:=hit.shape
    // Only what the feet reach in one step up is ground; the rest is an obstacle in front of the capsule.
    feet:=dot(low,up)-r-d.step_height
    if hit.normal!={} && dot(hit.point,up)-feet<=d.step_height+STEP_TOLERANCE {
        if dot(hit.normal,up)>=cos_max {
            ground.walkable=true
        } else {
            side:=hit.point-low
            side-=up*dot(side,up)
            face,face_found:=ray_cast_closest(w,hit.point+normalize(side)*FACE_PROBE+up*FACE_PROBE,-up*(3*FACE_PROBE),filter)
            if face_found && dot(face.normal,up)>=cos_max {
                ground.walkable=true
                ground.normal=face.normal
            }
        }
    }
    if !ground.walkable {
        if floor,floor_found:=ray_cast_closest(w,low,-up*(rc+reach),filter);floor_found && dot(floor.normal,up)>=cos_max && dot(floor.point,up)-feet<=d.step_height+STEP_TOLERANCE {
            ground={hit=true,walkable=true,body=floor.body,point=floor.point,normal=floor.normal,distance=floor.fraction*(rc+reach)-r-d.step_height}
            under_shape=floor.shape
        }
    }
    if ground.normal=={} {return {},-1}
    if under,index:=body_read(w,ground.body);under!=nil {
        ground_index=index
        if under.type!=.Static {ground.velocity=under.linear_velocity+cross(under.angular_velocity,ground.point-under.center)}
    }
    // The surface of a conveyor carries the feet along it.
    if surface,_:=shape_read(w,under_shape);surface!=nil && surface.surface_speed!={} {
        moving:=q_rotate(shape_transform_of(w,surface).q,surface.surface_speed)
        ground.surface=moving-ground.normal*dot(moving,ground.normal)
        ground.velocity+=ground.surface
    }
    return
}

// The ground each character stands on at the start of the step and the move it applies. Writes only to
// its own scratch.
@(private)
characters_move_task :: proc(data:rawptr,first,last,worker:int) {
    w:=(^World)(data)
    st:=&w.step
    dt:=st.dt
    for &cs in st.characters[first:last] {
        ch:=&w.characters[cs.character]
        body:=&w.bodies[cs.body]
        state:=ch.state
        move:=ch.move
        velocity:=body.linear_velocity
        #partial switch state.effect {
        case .Add: velocity+=state.effect_velocity
        case .Set: velocity=state.effect_velocity
        }
        cs.free=lock_free(body.flags)
        velocity*=cs.free
        move.launch*=cs.free
        // The up turns toward the opposite of the gravity the character feels, at most up_speed.
        if ch.desc.up_speed>0 {state.up_frame=up_frame_turn(state.up_frame,-ch.desc.gravity_scale*body_gravity_of(w,body),ch.desc.up_speed*move_pace(move)*dt)}
        up:=up_frame_up(state.up_frame)
        cs.up=up
        lift:=dot(velocity,up)
        launched:=state.effect!=.None && lift>dot(body.linear_velocity,up) && lift>LAND_SPEED
        was_standing:=.Standing in state.ground
        if state.effect!=.None || w.grounds_stale || .Stale in state.ground {
            cs.found,cs.ground=character_probe(w,ch,body,up,max(-lift*dt,0))
            character_ground_keep(&state,cs.found)
        } else {cs.found,cs.ground=character_ground_now(w,&state)}
        state.effect,state.effect_velocity=.None,{}
        ground:=cs.found
        cs.standing=false
        if .Airborne not_in move.flags && !launched && dot(move.launch,up)<=LAND_SPEED && ground.walkable && ground.distance<=ch.desc.step_height {
            rising:=lift-dot(ground.velocity,up)
            cs.standing=was_standing || rising<=LAND_SPEED && ground.distance<=min(max(LAND_DISTANCE,-rising*dt),ch.desc.step_height)
        }
        state.ground-={.Standing}
        if cs.standing {state.ground+={.Standing}}
        cs.drive=cs.standing?move.ground:move.air
        cs.floating=false
        if .Float in move.flags && !cs.standing && w.fluid_count>0 {
            if sample,ok:=fluid_sample(w,body.position+UP*ch.desc.height);ok && sample.normal.y>0 {
                cs.floating=true
                cs.float_separation=body.position.y-(sample.height+move.float_height-ch.desc.height)
            }
        }
        state.ground_turn=0
        if cs.standing && cs.ground>=0 {state.ground_turn=dot(w.bodies[cs.ground].angular_velocity,up)*dt}
        cs.next=state
        cs.move=move
        cs.velocity=velocity+move.launch
    }
}

// 1 along the world axes the linear locks of a body leave free, 0 along the locked ones.
@(private)
lock_free :: #force_inline proc "contextless" (flags:Body_Flags) -> Vec3 {
    return {.Lock_Linear_X in flags?0:1,.Lock_Linear_Y in flags?0:1,.Lock_Linear_Z in flags?0:1}
}

// The ground a character found, kept in its state.
@(private)
character_ground_keep :: proc "contextless" (state:^Character_State,ground:Ground) {
    state.ground&={.Standing}
    if ground.hit {state.ground+={.Hit}}
    if ground.walkable {state.ground+={.Walkable}}
    state.ground_body=ground.body
    state.ground_point,state.ground_normal,state.ground_velocity,state.ground_surface=ground.point,ground.normal,ground.velocity,ground.surface
    state.ground_distance=ground.distance
}

// The ground the end of the last step found, with the velocity its body has now: what moves it was
// asked for between the two steps.
@(private)
character_ground_now :: proc(w:^World,state:^Character_State) -> (ground:Ground,ground_index:i32) {
    ground_index=-1
    if .Hit not_in state.ground {return}
    ground={
        hit=true,walkable=.Walkable in state.ground,body=state.ground_body,point=state.ground_point,normal=state.ground_normal,
        surface=state.ground_surface,velocity=state.ground_surface,distance=state.ground_distance,
    }
    if under,index:=body_read(w,ground.body);under!=nil {
        ground_index=index
        if under.type!=.Static {ground.velocity+=under.linear_velocity+cross(under.angular_velocity,ground.point-under.center)}
    }
    state.ground_velocity=ground.velocity
    return
}

// The moves of the step: found in parallel, then their consequences on shared state are applied in slot
// order. Runs before the broad phase, so a body woken here has its contacts in this same step.
@(private)
characters_update :: proc(w:^World) {
    st:=&w.step
    count:=0
    for i in 0..<w.character_high {
        ch:=&w.characters[i]
        if ch.generation&1==0 {continue}
        body,index:=body_read(w,ch.body)
        if body==nil || body.type!=.Dynamic {continue}
        if .Awake not_in body.flags {
            // Asleep, it wakes when its ground may be gone or moves.
            ground,_:=body_read(w,ch.state.ground_body)
            if !w.grounds_stale && .Stale not_in ch.state.ground && (ground==nil || .Awake not_in ground.flags) {continue}
            body_wake(w,index)
        }
        st.characters[count]={character=i,body=index,ground=-1}
        count+=1
    }
    st.character_count=count
    world_parallel(w,count,8,w,characters_move_task)
    w.grounds_stale=false
    for &cs in st.characters[:count] {
        ch:=&w.characters[cs.character]
        body:=&w.bodies[cs.body]
        stamp(w,ch)
        stamp(w,body)
        was_standing:=.Standing in ch.state.ground
        turned:=ch.state.up_frame!=cs.next.up_frame
        ch.state=cs.next
        pace:=move_pace(cs.move)
        body.gravity_scale=.No_Gravity in cs.move.flags?0:ch.desc.gravity_scale*(cs.move.gravity_scale!=0?cs.move.gravity_scale:1)*pace*pace
        body.rotation=character_rotation(cs.next.up_frame,cs.move.yaw)
        body.linear_velocity=cs.velocity
        // A turning up turns the capsule about the feet.
        if turned {
            body.center=body.position+q_rotate(body.rotation,body.local_center)
            character_turned_proxies(w,body)
        }
        // At rest it leaves what it stands on and touches to sleep, and stands on a sleeping body as on a
        // static one; moving, it wakes them.
        moving:=length(cs.velocity-cs.found.velocity)>body.sleep_threshold || length(cs.drive.velocity)>body.sleep_threshold || cs.move.launch!={}
        if moving {body_wake_touching(w,cs.body)}
        // Only standing still on what rests, out of fluids, may it fall asleep.
        if moving || !cs.standing || cs.floating || .In_Fluid in cs.next.fluid || cs.ground>=0 && .Awake in w.bodies[cs.ground].flags {body.sleep_time=0}
        if cs.ground<0 {continue}
        under:=&w.bodies[cs.ground]
        if under.type!=.Dynamic {continue}
        if cs.move.launch!={} && was_standing {
            body_apply_impulse_at(w,cs.found.body,-ch.desc.mass*cs.move.launch,cs.found.point)
        } else if cs.standing && moving {
            body_wake(w,cs.ground)
        }
    }
}

// Finds again the ground of every character the step moved, where the next step starts.
@(private)
characters_ground_task :: proc(data:rawptr,first,last,worker:int) {
    w:=(^World)(data)
    st:=&w.step
    for cs in st.characters[first:last] {
        ch:=&w.characters[cs.character]
        body:=&w.bodies[cs.body]
        stamp(w,ch)
        ground,_:=character_probe(w,ch,body,cs.up,max(-dot(body.linear_velocity,cs.up)*st.dt,0))
        if !ground.walkable && cs.wedge!={} && dot(body.linear_velocity-ground.velocity,cs.up)<=LAND_SPEED {
            ground={hit=true,walkable=true,body=body_handle(w,cs.wedge_body),point=body.position,normal=cs.wedge}
            if under:=&w.bodies[cs.wedge_body];under.type!=.Static {ground.velocity=under.linear_velocity+cross(under.angular_velocity,ground.point-under.center)}
        }
        character_ground_keep(&ch.state,ground)
        ch.state.wall_normal,ch.state.wall_push=character_wall(w,body,cs.up,cs.drive.velocity)
        character_fluid_keep(w,ch,body)
    }
}

// The ground of a capsule held by faces too steep to stand on, as in a V or between two rocks: the
// normals of what it touches, when two differ and they add up to walkable ground (the floor of Godot's
// CharacterBody3D from several walls). It cannot slide off them, so it is no fall. Read before the
// contacts of a standing character are flattened. Zero without one; held, the body whose face lifts it
// the most.
@(private)
character_wedged :: proc(w:^World,ch:^Character,body:^Body,up:Vec3) -> (normal:Vec3,held:i32) #no_bounds_check {
    sum,first:Vec3
    apart:=false
    highest:=-max(f32)
    for key:=body.contact_list;key>=0; {
        index:=key>>1
        contact:=&w.contacts[index]
        side:=key&1
        key=contact.edges[side].next
        if contact.flags&{.Touching,.Overlap}!={.Touching} {continue}
        for i in 0..<contact.manifold_count {
            manifold:=i==0?&w.manifolds[index]:&w.extra_manifolds[contact.extra][i-1]
            touching:=false
            for point in manifold.points[:manifold.count] {touching=touching || point.separation<=CHARACTER_SKIN}
            if !touching {continue}
            out:=side==0?-manifold.normal:manifold.normal
            if sum=={} {first=out} else {apart=apart || dot(out,first)<1-1e-4}
            sum+=out
            if lift:=dot(out,up);lift>highest {highest,held=lift,side==0?contact.body_b:contact.body_a}
        }
    }
    l:=length(sum)
    if !apart || !(l>0) || dot(sum,up)<l*cmath.cos(ch.desc.max_slope) {return {},-1}
    return sum/l,held
}

// The boxes of a character whose up turned: a shape that left its fat box grows it to hold the new pose.
@(private)
character_turned_proxies :: proc(w:^World,body:^Body) {
    xf:=body_transform_of(body)
    for s:=body.shape_list;s>=0;s=w.shapes[s].next {
        shape:=&w.shapes[s]
        stamp(w,shape)
        shape.aabb=shape_aabb(w,shape,xf)
        if math.aabb_contains(shape.fat,shape.aabb) {continue}
        shape.fat=math.aabb_merge(shape.fat,shape_fat(shape.aabb))
        shape_moved(w,s)
        if shape.proxy>=0 {spatial.dynamic_tree_move(&w.trees[DYNAMIC_TREE],shape.proxy,shape.fat)}
    }
}

// How deep in a fluid the body of a character is, where the next step starts.
@(private)
character_fluid_keep :: proc(w:^World,ch:^Character,body:^Body) #no_bounds_check {
    state:=&ch.state
    state.fluid,state.submersion,state.head_depth,state.fluid_velocity,state.depth={},0,-max(f32),{},-max(f32)
    if w.fluid_count==0 {return}
    d:=&ch.desc
    head:=body.position+UP*d.height
    sample,ok:=fluid_sample(w,head)
    if !ok {return}
    state.head_depth=sample.normal.y>0?sample.height-head.y:head.y-sample.height
    state.depth=state.head_depth+d.height
    fluid,spot:=fluid_find(w,body.position)
    if fluid<0 {return}
    column:[FLUID_COLUMN_DRY+1]Fluid_Interval
    count:=fluid_column(w,fluid,spot,body.position,&column)
    state.submersion=body_submersion(d,body.position.y,column[:count])
    if state.submersion>0 {
        state.fluid+={.In_Fluid}
        state.fluid_velocity=spot.current
    }
    if state.head_depth>0 {state.fluid+={.Underwater}}
}

// The share of the body of a character, an upright capsule from the feet to the head, in stretches of
// fluid.
@(private)
body_submersion :: proc "contextless" (d:^Character_Desc,feet:f32,column:[]Fluid_Interval) -> f32 {
    r:=d.radius
    half:=0.5*d.height-r
    middle:=feet+0.5*d.height
    total,_:=revolution_slab(r,half,true,-max(f32),max(f32))
    share:f32
    for stretch in column {
        part,_:=revolution_slab(r,half,true,stretch.bottom-middle,stretch.top-middle)
        share+=part
    }
    return clamp(share/total,0,1)
}

@(private)
characters_ground :: proc(w:^World) {
    world_parallel(w,w.step.character_count,8,w,characters_ground_task)
    w.grounds_stale=false
}

// A walking character treats what touches its capsule as a wall: the capsule floats above everything it
// can step on, so a contact that would lift it becomes horizontal, as if the capsule were a cylinder.
@(private)
// What touches the floating capsule of a grounded character is an obstacle, not ground: a contact whose
// normal would lift it becomes horizontal. That includes one under the capsule, nearly vertical, on an
// edge higher than `step` above the ground at `floor`, which would otherwise carry it onto that edge. Heights
// and lifting are along its up.
character_flatten_contacts :: proc(w:^World,body:^Body,up:Vec3,floor,step:f32) #no_bounds_check {
    for key:=body.contact_list;key>=0; {
        index:=key>>1
        contact:=&w.contacts[index]
        sign:f32=key&1==0?-1:1
        key=contact.edges[key&1].next
        if contact.flags&{.Touching,.Overlap}!={.Touching} {continue}
        for i in 0..<contact.manifold_count {
            manifold:=i==0?&w.manifolds[index]:&w.extra_manifolds[contact.extra][i-1]
            along:=dot(manifold.normal,up)
            lift:=sign*along
            if lift<=FLATTEN_MIN {continue}
            flat:=manifold.normal-up*along
            scale:=length(flat)
            if lift>=FLATTEN_MAX {
                highest:=-max(f32)
                for point in manifold.points[:manifold.count] {highest=max(highest,dot(point.point,up))}
                if highest-floor<=step+STEP_TOLERANCE || scale<1e-3 {continue}
            }
            manifold.normal=flat/scale
            for &point in manifold.points[:manifold.count] {point.separation/=max(scale,FLATTEN_MIN_SCALE)}
        }
    }
}

// The wall of Character_State: of the touching contacts of the capsule with bodies it does not
// push, the normal across up and out of the wall that drive heads into the most; one that lifts the
// capsule is ground.
@(private)
character_wall :: proc(w:^World,body:^Body,up,drive:Vec3) -> (normal:Vec3,push:f32) #no_bounds_check {
    least:=max(f32)
    for key:=body.contact_list;key>=0; {
        index:=key>>1
        contact:=&w.contacts[index]
        side:=key&1
        key=contact.edges[side].next
        if contact.flags&{.Touching,.Overlap}!={.Touching} || w.bodies[side==0?contact.body_b:contact.body_a].type==.Dynamic {continue}
        for i in 0..<contact.manifold_count {
            manifold:=i==0?&w.manifolds[index]:&w.extra_manifolds[contact.extra][i-1]
            touching:=false
            for point in manifold.points[:manifold.count] {touching=touching || point.separation<=LINEAR_SLOP}
            if !touching {continue}
            out:=side==0?-manifold.normal:manifold.normal
            if dot(out,up)>FLATTEN_MIN {continue}
            flat:=out-up*dot(out,up)
            if length2(flat)<1e-6 {continue}
            flat=normalize(flat)
            if along:=dot(drive,flat);along<least {least,normal=along,flat}
        }
    }
    if normal!={} {push=max(-least,0)}
    return
}

// The directions in which the capsule leans on dynamic bodies, in the plane of the drive (all of space when
// `plane` is zero): the drive along each of them is capped by the push force.
@(private)
character_pushes :: proc(w:^World,cs:^Character_Solver,body:^Body,plane:Vec3) #no_bounds_check {
    for key:=body.contact_list;key>=0; {
        index:=key>>1
        contact:=&w.contacts[index]
        side:=key&1
        key=contact.edges[side].next
        if contact.flags&{.Touching,.Overlap}!={.Touching} || w.bodies[side==0?contact.body_b:contact.body_a].type!=.Dynamic {continue}
        for i in 0..<contact.manifold_count {
            manifold:=i==0?&w.manifolds[index]:&w.extra_manifolds[contact.extra][i-1]
            touching:=false
            for point in manifold.points[:manifold.count] {touching=touching || point.separation<=LINEAR_SLOP}
            if !touching {continue}
            into:=side==0?manifold.normal:-manifold.normal
            into-=plane*dot(into,plane)
            if length2(into)<1e-6 {continue}
            into=normalize(into)
            if cs.push_count<CHARACTER_PUSHES {
                cs.pushes[cs.push_count]=into
                cs.push_count+=1
                continue
            }
            closest:=0
            for push,k in cs.pushes {if dot(push,into)>dot(cs.pushes[closest],into) {closest=k}}
            cs.pushes[closest]=normalize(cs.pushes[closest]+into)
        }
    }
}

// The drive impulse with its part along each push direction cut down to the push limit.
@(private)
character_push_cap :: #force_inline proc "contextless" (cs:^Character_Solver,impulse:Vec3) -> Vec3 #no_bounds_check {
    p:=impulse
    for push in cs.pushes[:cs.push_count] {
        if along:=dot(p,push);along>cs.push_limit {p-=(along-cs.push_limit)*push}
    }
    return p
}

// Constraints of the step, once the awake bodies have their solver slots.
@(private)
characters_prepare :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    for &cs in st.characters[:st.character_count] {
        ch:=&w.characters[cs.character]
        body:=&w.bodies[cs.body]
        cs.c,cs.g=body.solver_index,-1
        cs.inv_mass_c=body.inv_mass
        cs.drive_limit=cs.drive.force*st.h
        cs.target=cs.drive.velocity
        cs.push_count=0
        felt:=move_pace(cs.move)*move_pace(cs.move)
        cs.float_limit=ch.desc.adhesion_force*felt*st.h
        push:=(ch.desc.push_force>0?ch.desc.push_force:ch.desc.traction_force)*felt
        cs.push_limit=push*st.h
        pushes:=push<cs.drive.force
        cs.wedge,cs.wedge_body=character_wedged(w,ch,body,cs.up)
        if !cs.standing {
            if pushes {character_pushes(w,&cs,body,.Drive_Vertical in cs.move.flags?Vec3{}:cs.up)}
            continue
        }
        ground:=cs.found
        character_flatten_contacts(w,body,cs.up,dot(ground.point,cs.up),ch.desc.step_height)
        if pushes {character_pushes(w,&cs,body,ground.normal)}
        n:=ground.normal
        locked:=cs.free!={1,1,1}
        cs.normal=n
        cs.tangent1=locked?character_free_tangent(n,cs.free):perp(n)
        cs.tangent2=cross(cs.tangent1,n)
        cs.separation=ground.distance*dot(n,cs.up)
        cs.adhesion_limit=ch.desc.adhesion_force*felt*st.h
        cs.inv_mass_g,cs.inv_inertia_g=0,{}
        cs.anchor={}
        cs.target+=ground.surface
        if cs.ground>=0 {
            under:=&w.bodies[cs.ground]
            cs.anchor=ground.point-under.center
            if under.solver_index>=0 {
                cs.g=under.solver_index
                cs.inv_mass_g,cs.inv_inertia_g=st.params[cs.g].inv_mass,st.params[cs.g].inv_inertia
                // The ground point moves on a circle: aim at its velocity half a step ahead.
                spin:=under.angular_velocity
                cs.target+=0.5*st.dt*cross(spin,cross(spin,cs.anchor))
            }
        }
        cs.target-=n*dot(cs.target,n)
        ma,mg,ig:=cs.inv_mass_c,cs.inv_mass_g,cs.inv_inertia_g
        rn:=cross(cs.anchor,n)
        r1,r2:=cross(cs.anchor,cs.tangent1),cross(cs.anchor,cs.tangent2)
        if locked {
            // The locks take away the mobility of the feet along the locked axes. Along the ground they leave
            // at most the line of tangent1: it alone is driven.
            k:=ma*dot(n,cs.free*n)+mg+dot(rn,ig*rn)
            cs.normal_mass=k>0?1/k:0
            kxx:=ma*dot(cs.tangent1,cs.free*cs.tangent1)+mg+dot(r1,ig*r1)
            cs.tangent_mass={kxx>0?1/kxx:0,0,0}
            continue
        }
        cs.normal_mass=1/(ma+mg+dot(rn,ig*rn))
        kxx:=ma+mg+dot(r1,ig*r1)
        kyy:=ma+mg+dot(r2,ig*r2)
        kxy:=dot(r1,ig*r2)
        det:=kxx*kyy-kxy*kxy
        cs.tangent_mass=det!=0?[3]f32{kyy/det,-kxy/det,kxx/det}:{}
    }
}

// The direction along the ground of normal n that the linear locks of `free` leave the feet, or the one
// nearest to it when none is free.
@(private)
character_free_tangent :: proc "contextless" (n,free:Vec3) -> Vec3 {
    locked:=Vec3{1,1,1}-free
    t:Vec3
    switch locked.x+locked.y+locked.z {
    case 1: t=cross(n,locked)
    case 2: t=free-n*dot(n,free)
    }
    return length2(t)>1e-6?normalize(t):perp(n)
}

// One pass over the characters, before joints and contacts so that those have the last word. A character
// in the air is driven toward its target by a bounded force. A grounded one is held at its height above
// the ground point, softly from below and by the adhesion from above, and driven along the ground by the
// traction; both act on the ground body with the opposite impulse.
@(private)
characters_solve :: proc(w:^World) #no_bounds_check {
    st:=&w.step
    use_bias:=st.use_bias
    inv_h:=st.inv_h
    soft:=st.static_softness
    float_soft:=st.contact_softness
    push_speed:=w.desc.contact_speed
    for &cs in st.characters[:st.character_count] {
        if cs.c<0 {continue}
        if use_bias {cs.normal_impulse,cs.drive_impulse=0,{}}
        body:=&st.bodies[cs.c]
        v:=body.v
        if !cs.standing {
            if cs.floating && use_bias {
                // A spring toward the height of the waterline, implicit, with the softness of the contacts: it has
                // no rigid part for the relaxation to take back.
                s:=cs.float_separation+body.dp.y
                bias:=clamp(float_soft.mass_scale*float_soft.bias_rate*s,-push_speed,push_speed)
                impulse:=clamp(-(float_soft.mass_scale*v.y+bias)/cs.inv_mass_c,-cs.float_limit,cs.float_limit)
                v.y+=cs.inv_mass_c*cs.free.y*impulse
                body.v=v
            }
            if cs.drive_limit<=0 {continue}
            delta:=cs.target-v
            if .Drive_Vertical not_in cs.move.flags {delta-=cs.up*dot(delta,cs.up)}
            impulse:=cs.drive_impulse+cs.free*delta/cs.inv_mass_c
            if l:=length(impulse);l>cs.drive_limit {impulse*=cs.drive_limit/l}
            if cs.push_count>0 {impulse=character_push_cap(&cs,impulse)*cs.free}
            body.v=v+cs.inv_mass_c*cs.free*(impulse-cs.drive_impulse)
            cs.drive_impulse=impulse
            continue
        }
        ground:=cs.g>=0?st.bodies[cs.g]:SOLVER_BODY_REST
        vg,og:=ground.v,ground.w
        ma,mg,ig:=cs.inv_mass_c,cs.inv_mass_g,cs.inv_inertia_g
        n,r:=cs.normal,cs.anchor
        {
            s:=cs.separation+dot(body.dp-ground.dp-q_rotate(ground.dq,r)+r,n)
            bias:f32
            mass_scale:f32=1
            impulse_scale:f32
            if s>0 {
                bias=s*inv_h
            } else if use_bias {
                bias=max(soft.mass_scale*soft.bias_rate*s,-push_speed)
                mass_scale,impulse_scale=soft.mass_scale,soft.impulse_scale
            }
            vn:=dot(v-vg-cross(og,r),n)
            total:=max(cs.normal_impulse-cs.normal_mass*(mass_scale*vn+bias)-impulse_scale*cs.normal_impulse,-cs.adhesion_limit)
            p:=(total-cs.normal_impulse)*n
            cs.normal_impulse=total
            v+=ma*cs.free*p
            vg-=mg*p
            og-=ig*cross(r,p)
        }
        if cs.drive_limit>0 {
            vr:=v-vg-cross(og,r)-cs.target
            vt:=[2]f32{dot(vr,cs.tangent1),dot(vr,cs.tangent2)}
            impulse:=[2]f32{
                cs.drive_impulse[0]-(cs.tangent_mass[0]*vt[0]+cs.tangent_mass[1]*vt[1]),
                cs.drive_impulse[1]-(cs.tangent_mass[1]*vt[0]+cs.tangent_mass[2]*vt[1]),
            }
            if l2:=impulse[0]*impulse[0]+impulse[1]*impulse[1];l2>cs.drive_limit*cs.drive_limit {impulse*=cs.drive_limit/cmath.sqrt(l2)}
            if cs.push_count>0 {
                capped:=character_push_cap(&cs,impulse[0]*cs.tangent1+impulse[1]*cs.tangent2)
                impulse={dot(capped,cs.tangent1),dot(capped,cs.tangent2)}
            }
            p:=(impulse[0]-cs.drive_impulse[0])*cs.tangent1+(impulse[1]-cs.drive_impulse[1])*cs.tangent2
            cs.drive_impulse={impulse[0],impulse[1],0}
            v+=ma*cs.free*p
            vg-=mg*p
            og-=ig*cross(r,p)
        }
        body.v=v
        if cs.g>=0 {st.bodies[cs.g].v,st.bodies[cs.g].w=vg,og}
    }
}

