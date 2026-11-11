package vfx

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

// The particles of a world live on the GPU, in buffers the renderer keeps for
// the world (erender.pass_buffer): those of a world that is not drawn wait,
// still, and go when the world goes (particles_release). Each emitter holds a
// range of the pool, found again every frame by the id of its emitter; a
// range that is new, changes size or comes with another generation starts
// empty. The births of an emitter come in groups: how many, how many at once,
// how old the first ones are at the end of the frame and how far apart the
// next ones were born, so a burst starts at one instant and a rate spreads
// over the frame. A frame longer than STEP is simulated in several steps,
// each one starting the births that fall in it. In the Simulate stage, every
// step:
//
//   begin      a thread per emitter: its counters, and the dispatch that
//              takes the events of the step before
//   emit       the births of the step, and those the events start in the
//              emitters they name
//   simulate   a thread per slot the emitters of each program hold: its Vfx program, forces,
//              noise, collision against the depth of the frame or the traced
//              scene, deaths into the free list and events; in the last step
//              the light of the particle (sun with its shadow, local lights,
//              probes) and the list that is drawn
//
// and once a frame, finish: a group per emitter, its indirect draw and the
// list sorted back to front (or by age for a ribbon) where it asks. Before
// the steps, the areas of the surfaces the world reads for the first time
// (resources.odin).
//
// Sprites and ribbons are drawn in the Blend stage, over the lit scene before
// TAA, behind and in front of glass. Mesh particles are drawn in the Gbuffer
// stage and lit like the scene, but for those whose material blends: they
// are drawn with the sprites, with their fragment. Nothing a frame does allocates: the tables of
// a pool are made when its world gives its first emitters, and again when it
// asks another capacity.

CAPACITY :: 262144
EMITTER_CAPACITY :: 1024 // of a world
EVENT_CAPACITY :: 16384
SORT_MAX :: 2048 // particles of a sorted emitter or a ribbon
EVENT_SPAWN_MAX :: 64
SPAWNS :: 8 // groups of births an emitter gives in a frame
STEP :: f32(1.0/30) // the longest step a simulation takes
STEPS :: 8
FRAME_MAX :: f32(0.25) // seconds a frame simulates at most

// Births of an emitter: count particles, per of them at each instant. The
// first ones are age seconds old at the end of the frame, and each next
// instant spacing seconds younger. Older than the frame, they start where and
// how old their life took them (a prewarm). birth: the index of the first,
// which picks the random values of each particle.
Particle_Spawn :: struct {
    count,per:u32,
    birth:u32,
    age,spacing:f32,
}

// A Vfx program for an emitter: its id (0: none), its parameters, laid out
// as the program reflects them, the bytes of the Attributes it keeps of each
// particle, and whether it moves and ages its particles itself (the forces,
// collisions and aging of the effect do not run).
Program :: struct {
    id:u32,
    parameters:[16][4]f32,
    attributes:u32,
    moves:bool,
    births:bool, // it gives how many particles its emitter starts each frame, on the GPU
    prepare:bool, // it prepares each frame what its emitter keeps (STATE_BYTES of it)
    name:[effect.PARTICLE_NAME_BYTES]u8, // its stages are compiled for it alone: particle_<stage>__<name>
}

// The slots the live emitters of a program hold: [first, end) of the pool and
// [emitter_first, emitter_end) of the table of emitters, which its passes go
// over. events: some emitter starts particles in one of them.
Program_Span :: struct {
    first,end,emitter_first,emitter_end:u32,
    events:bool,
}

// The stages of a program that runs in the frame: a pipeline of its own each.
Program_Pipelines :: struct {
    id:u32,
    emit,simulate,stage:erender.Pipeline,
    sprite:[effect.PARTICLE_NAME_BYTES+32]u8, // the vertex stage of its sprites
    mesh:[effect.PARTICLE_NAME_BYTES+32]u8, // the vertex stage of its mesh particles, for the G-buffer pipeline of the view
    mesh_blend:[effect.PARTICLE_NAME_BYTES+32]u8, // that of its mesh particles whose material blends, drawn with the sprites
    using span:Program_Span,
}

PROGRAMS_IN_USE :: 128 // distinct programs of the emitters of a world
MESH_PROGRAMS :: 8 // Surface programs of the materials of the mesh of an emitter it draws

// Bytes of the Attributes of the pool for each of its particles: an emitter takes those
// of its range from them, its capacity times those of its program.
ATTRIBUTE_SHARE :: 32

// An emitter of a frame. Ranges are [min, max]; the shape faces +Y of the
// transform, where a cone opens.
Emitter_Desc :: struct {
    id:u64,              // stable while the emitter lives
    generation:u32,      // another one starts its range empty
    capacity:u32,        // particles alive at once
    transform:matrix[4,4]f32, // where the emitter is this frame
    previous:matrix[4,4]f32,  // and was the last one: births spread between both
    spawns:[SPAWNS]Particle_Spawn, // since the last list, in the order of their births
    seed:u32,
    paused:bool,         // its particles stay as they are
    local:bool,          // particles move with the emitter
    lit:bool,            // sun, lights and probes light them; else they show their color
    lights:u32,          // of its particles that light the scene, at most
    light:[3]f32,        // their intensity (cd), range (m) and radius (m; 0: half their size)
    shadows:bool,        // they cast shadows; else they light all in their range, with no rays
    relative:bool,       // unlit: the color is what the exposed image shows, not nits
    sort:bool,           // drawn back to front (SORT_MAX particles at most)
    shape:effect.Particle_Shape,
    shape_size:[3]f32,   // radius in x, or half extents of a box, or half length of a line
    shape_angle:f32,     // half-angle of a cone, radians
    shell:f32,           // 0: from the volume of the shape, 1: from its surface
    lifetime,speed,size,rotation,spin:[2]f32, // seconds, m/s, m, radians, radians/s
    velocity:[2][3]f32,  // m/s in the space of the emitter, between both, besides speed
    color:[2][4]f32,     // linear rgba; each particle takes a mix
    inherit:f32,         // share of the velocity of the emitter a particle starts with
    acceleration:[3]f32, // its own, m/s²: the gravity and the wind of where each particle is come on the GPU (fields.odin)
    gravity:f32,         // share of the gravity of where each particle is
    drag:f32,            // 1/s
    noise_strength,noise_frequency,noise_speed:f32, // curl noise: m/s², 1/m, 1/s
    attractor:[3]f32,    // a point of the emitter that pulls with attractor_strength (m/s²)
    attractor_strength:f32,
    collision:effect.Particle_Collision,
    // Share of the normal speed kept per hit, tangent speed lost per normal speed
    // stopped, share of the life lost per hit.
    bounce,friction,collision_life:f32,
    render:effect.Particle_Render,
    blend:effect.Particle_Blend,
    material:erender.Material_Handle, // its Surface program, or its base color (its texture is the flipbook), opacity and emission
    mesh:[3]u32,              // of Mesh particles: the vertices of a draw of its clusters (erender.mesh_draw_range) and the mesh of the scene
    blended:bool,             // of Mesh particles: its material blends (alpha mode Blend), so they are drawn over the lit scene with the sprites
    stretch:f32,              // Velocity: seconds of motion the sprite spans
    soft:f32,                 // metres over which a sprite fades into the surface behind it
    intensity:f32,            // multiplies the color
    flipbook:[2]u32,          // columns and rows of the texture
    flipbook_speed:f32,       // frames per second; 0: the whole flipbook over the life
    size_curve:effect.Particle_Curve,
    color_curve:effect.Particle_Gradient,
    view:erender.Texture_Handle, // drawn only into the effect view of this texture (gui.UI_Effects); 0: in the views of the world
    event:effect.Particle_Event, // what starts particles of event_target
    event_target:u64,         // id of another emitter
    event_count:u32,          // particles it starts per event
    program:Program,          // a Vfx program and its parameters; id 0: none
    resources:u32,                          // its RESOURCE_ROWS rows in Particle_Sync.resources from this one, + 1: the surface or bones of its shape, then the resources of its program; 0: it reads none
    stages:u32,                             // its PROGRAM_STAGES rows in Particle_Sync.stage_rows from this one, + 1; 0: none
    births:[2]u32,                          // of its channel: the first among those of the frame, and how many
    age:f32,                                // seconds since it started, at the end of the frame
    born:u32,                               // particles it started before this frame
    report:effect.Particle_Event,           // what of its particles the game hears of
    owner:core.Entity,                      // whose reports they are
    revision:u64,                           // of what is not given each frame (all but transform, previous, spawns, paused, resources, stages, births, age and born): another builds its row again; 0: every frame
}

FLAG_ACTIVE :: 1
FLAG_RESET :: 2
FLAG_LOCAL :: 4
FLAG_LIT :: 8
FLAG_SORT :: 16
FLAG_PAUSED :: 32
FLAG_ADDITIVE :: 64
FLAG_RELATIVE :: 128
FLAG_MOVED :: 256 // its program moves and ages its particles
FLAG_BIRTHS :: 512 // its program gives its births
FLAG_PREPARE :: 1024 // its program prepares what it keeps each frame
FLAG_VIEW :: 2048 // drawn into an effect view: its places are of that view, not of the world, and the origin does not move them
STATE_BYTES :: 512 // what a program keeps of each emitter between its prepare and the rest of the frame
// The data buffer: the parameters of each emitter, what their programs keep, then the Attributes.
STATES_AT :: EMITTER_CAPACITY*erender.PROGRAM_PARAMETER_BYTES
ATTRIBUTES_AT :: STATES_AT+EMITTER_CAPACITY*STATE_BYTES

// shaders/particles.slang.
Gpu_Particle :: struct {
    position:[3]f32, age:f32, // relative to the origin of the pool, or local to the emitter
    velocity:[3]f32, lifetime:f32,
    size,rotation,spin:f32, seed:u32,
    color:u32,          // rgba8 of the mix it started with
    light:u32,          // rgb with a shared exponent: the light it receives
    emitter:u32,        // slot
    flags:u32,          // 1: light holds a value
}
#assert(size_of(Gpu_Particle)==64)

Gpu_Emitter :: struct {
    world,previous:[3][4]f32,
    range:[4]u32,       // first slot of the pool, capacity, births this frame, FLAG_*
    random:[4]u32,      // seed, event target slot+1 (0: none), particles per event, groups of births
    program:[4]u32,     // Vfx program (0: none), first slot of the drawn lists, Particle_Event its reports tell, bytes of the world buffer to the copy of the reports channel the frame writes (INVALID: it reports nothing)
    shape:[4]f32,       // size, w cone half-angle
    kinds:[4]u32,       // Particle_Shape, Particle_Render, Particle_Collision, Particle_Event
    lifetime_speed:[4]f32,
    size_rotation:[4]f32,
    spin:[4]f32,        // range, shell, inherit
    color_a,color_b:[4]f32,
    velocity_a,velocity_b:[4]f32,
    acceleration:[4]f32, // w drag
    noise:[4]f32,       // strength, frequency, speed; w the share of the gravity of where a particle is
    collide:[4]f32,     // bounce, friction, life lost
    look:[4]f32,        // stretch, soft, intensity, flipbook speed
    attractor:[4]f32,
    mesh:[4]u32,        // vertex count (index count of a sprite), the mesh, 0, material row
    flipbook:[4]u32,    // columns, rows
    size_curve,size_times:[2][4]f32,
    gradient:[effect.PARTICLE_CURVE_KEYS][4]f32,
    gradient_times:[2][4]f32,
    step:[4]f32,        // seconds of the frame, of each step, steps, and the time at the end of the frame
    spawns:[SPAWNS][4]u32, // count, per, birth, age (f32 bits)
    spacing:[2][4]f32,
    frame:[4]u32,       // in the rows of the frame: bytes to its resources (max(u32): none), to its births, how many, to the births of the frame
    light:[4]f32,       // intensity (cd), range (m), radius (m; 0: half the size of the particle)
    lights:[4]u32,      // its share of the room of the frame (light_share): x the first of its lights with shadows, y how many; z, w those without
    data:[4]u32,        // bytes of the data buffer to the Attributes of its range, bytes of those of a particle, its age (f32 bits), particles it started
}
#assert(size_of(Gpu_Emitter)==864)

// Per emitter on the GPU: counters and its draw.
Gpu_State :: struct {
    dead,alive:u32, // free slots on its list, and particles on the one drawn
    births,born:u32, // of an emitter whose program gives its births: those of the frame, and all it started
    draw:[5]u32,    // index count, instance count, first index, vertex offset, first instance; of a mesh: vertex count, instance count, first vertex, first instance
    pad1:[3]u32,
}
#assert(size_of(Gpu_State)==48)

Gpu_Event :: struct {
    position:[3]f32, target:u32, // relative to the origin of the pool
    velocity:[3]f32, color:u32,
}
#assert(size_of(Gpu_Event)==32)

// The buffers of the pool of a world. Events: the event counts of the two
// halves and the dispatches that consume them, then from EVENTS_AT the
// events of each half.
Pool_Buffer :: enum u8 {Particles,Lists,State,Events,Data}

EVENTS_AT :: 256 // bytes of the events buffer before the events

pool_buffer :: proc "contextless" (pool:^Pool,b:Pool_Buffer) -> erender.Buffer_Desc {
    count:=u64(max(pool.capacity,1))
    switch b {
    case .Particles: return {"vfx particles",count*size_of(Gpu_Particle)}
    case .Lists:     return {"vfx particle lists",3*count*size_of(u32)}
    case .State:     return {"vfx particle state",EMITTER_CAPACITY*size_of(Gpu_State)}
    case .Events:    return {"vfx particle events",EVENTS_AT+2*EVENT_CAPACITY*size_of(Gpu_Event)}
    case .Data:      return {"vfx particle data",pool_data_bytes(pool.capacity)}
    }
    return {}
}

// Bytes of the data buffer of a pool: the parameters of the program of every
// emitter, then the Attributes of the particles.
@(private)
pool_data_bytes :: proc "contextless" (capacity:u32) -> u64 {
    return ATTRIBUTES_AT+pool_attribute_bytes(capacity)
}

@(private)
pool_attribute_bytes :: proc "contextless" (capacity:u32) -> u64 {return u64(max(capacity,1))*ATTRIBUTE_SHARE}

@(private)
Pool_Slot :: struct {
    id:u64,
    offset,capacity:u32,
    attributes,stride:u32, // bytes of the Attributes of the pool to those of its range, and of each particle
    generation:u32,
    live,fresh:bool,
    pending:bool,          // desc was given since the last frame simulated: its births add up
    program_dirty:bool,    // its program has parameters the GPU does not
    seen:u64,              // the frame of its last desc
    desc:Emitter_Desc,
}

@(private)
Pool_Draw :: struct {
    slot:u32,
    distance:f32,
}

// The particles of one world, as the CPU keeps them.
Pool :: struct {
    capacity:u32,
    previous:u32,            // the capacity before, which a refused one goes back to
    refused:u32,             // a capacity the device could not take, not tried again
    slots:[]Pool_Slot,
    order:[]u16,             // live slots by id
    order_count:int,
    free:base.Ranges,           // the slots of the pool the emitters' ranges take
    attribute_free:base.Ranges, // the bytes of the Attributes of the pool their ranges take
    slot_end:int,            // slots ever used, live or not
    pool_end:u32,            // end of the pool in use
    regroup:bool,            // a range, a program or an event target changed since the spans of the programs were found
    dt:f32,                  // simulated by the next frame: every list given since the last one adds its seconds
    drawn:bool,              // a frame simulated the particles since the last list
    frame:u64,               // lists given
    step:u64,                // steps simulated: the half of the events each one writes
    dropped:u32,             // emitters of the last list that found no room
    made:bool,               // the buffers have the size of capacity
    origin:[3]f32,           // what the places its buffers keep are relative to: the origin of the renderer when they last moved
    gpu:[]Gpu_Emitter,
    frame_bytes:[dynamic]u8, // of the frame: RESOURCE_ROWS Gpu_Resource for each emitter that reads some, then the births of the channels
    draws:[]Pool_Draw,
    dirty:[EMITTER_CAPACITY/64]u64, // slots whose desc changed: their rows are built again (emitter_row)
    // Of the frame, from pool_prepare.
    rows,resources:erender.Pass_Rows,
    rows_frame:u64,          // the frame whose rows they are; 0: none
    steps:u32,
    spawn_max:u32,           // most particles an emitter starts this frame
    births_max:u32,          // largest range of an emitter whose program gives its births
    prepares:bool,           // some program prepares what it keeps this frame
    birth_max:u32,           // most births of a channel an emitter takes this frame
    reset_max:u32,           // largest range that starts this frame
    sprites,meshes:bool,     // some live emitter draws them
    grids_at:u32,            // bytes of the rows of the frame to those of the grids
    volumes_at:u32,          // and to those of the volumes
    fields_at:u32,           // and to the gravity and the wind of the world (Gpu_Fields)
    volume_count:u32,
    volume_cells:u32,        // the most cells of a volume
    stage_count:u32,         // stages of the emitter that has the most
    plan:[erender.PROGRAM_STAGES]Stage_Plan,
    lights:[2]u32,           // that the live emitters light, with shadows and without: the room particles_frame asks for
}

// Makes the tables of a pool for a capacity: none of its particles stays.
// False without memory, and the pool has none.
pool_make :: proc(pool:^Pool,capacity:u32,allocator:=context.allocator) -> bool {
    previous,refused:=pool.capacity,pool.refused
    pool_free(pool,allocator)
    pool^={capacity=capacity,previous=previous,refused=refused}
    errors:[4]runtime.Allocator_Error
    pool.slots,errors[0]=make([]Pool_Slot,EMITTER_CAPACITY,allocator)
    pool.order,errors[1]=make([]u16,EMITTER_CAPACITY,allocator)
    pool.gpu,errors[2]=make([]Gpu_Emitter,EMITTER_CAPACITY,allocator)
    pool.draws,errors[3]=make([]Pool_Draw,EMITTER_CAPACITY,allocator)
    starved:=!base.ranges_reset(&pool.free,u64(capacity),EMITTER_CAPACITY,allocator) || !base.ranges_reset(&pool.attribute_free,pool_attribute_bytes(capacity),EMITTER_CAPACITY,allocator)
    for error in errors {starved||=error!=nil}
    if starved {
        pool_free(pool,allocator)
        return false
    }
    return true
}

pool_free :: proc(pool:^Pool,allocator:=context.allocator) {
    delete(pool.slots,allocator);delete(pool.order,allocator);delete(pool.gpu,allocator);delete(pool.draws,allocator)
    base.ranges_free(&pool.free);base.ranges_free(&pool.attribute_free)
    delete(pool.frame_bytes)
    pool^={capacity=pool.capacity,previous=pool.previous,refused=pool.refused}
}

// The emitters of a world for the next frame, and the seconds it simulates.
// The pool is made the first time it gets emitters, and made again, without
// its particles, for another capacity; one more than max_bytes binds, or that
// the device refused before, leaves the pool as it was. An emitter whose id
// was not in the last list starts empty, and one that is not in this list
// loses its particles. Returns the emitters that found no room in the pool or
// the table of emitters (they are left out); ok is false without a pool.
pool_emitters :: proc(pool:^Pool,emitters:[]Emitter_Desc,dt:f32,capacity:u32,max_bytes:u64,allocator:=context.allocator) -> (dropped:u32,ok:bool) {
    if pool.slots==nil && len(emitters)==0 {return 0,true}
    if pool.slots==nil || pool.capacity!=capacity && capacity!=pool.refused {
        if u64(max(capacity,1))*size_of(Gpu_Particle)>max_bytes {
            pool.refused=capacity
            if pool.slots==nil {return 0,false}
        } else if !pool_make(pool,capacity,allocator) {return 0,false}
    }
    pool.frame+=1
    added:=clamp(dt,0,FRAME_MAX)
    pool.dt=clamp(((pool.drawn || pool.order_count==0)?0:pool.dt)+added,0,FRAME_MAX)
    pool.drawn=false
    pool.dropped=0
    for desc in emitters {
        slot_at:=pool_slot_find(pool,desc.id)
        capacity:=desc.capacity
        if desc.sort || desc.render==.Ribbon {capacity=min(capacity,SORT_MAX)}
        stride:=(desc.program.attributes+15)&~u32(15)
        if slot_at>=0 && (pool.slots[slot_at].capacity!=capacity || pool.slots[slot_at].stride!=stride || pool.slots[slot_at].generation!=desc.generation) {
            pool_slot_release(pool,slot_at)
            slot_at=-1
        }
        if slot_at<0 {
            if slot_at=pool_slot_take(pool,desc.id,capacity,stride);slot_at<0 {pool.dropped+=1;continue}
            pool.slots[slot_at].generation=desc.generation
        }
        slot:=&pool.slots[slot_at]
        slot.seen=pool.frame
        if slot.desc.program!=desc.program || slot.fresh {slot.program_dirty=desc.program.id!=0}
        if slot.desc.program.id!=desc.program.id || slot.desc.event!=desc.event || slot.desc.event_target!=desc.event_target {pool.regroup=true}
        if desc.revision==0 || desc.revision!=slot.desc.revision {pool.dirty[slot_at/64]|=u64(1)<<(uint(slot_at)%64)}
        if slot.pending {
            spawns:=slot.desc.spawns
            previous:=slot.desc.previous
            slot.desc=desc
            slot.desc.previous=previous
            spawns_join(&slot.desc.spawns,spawns,desc.spawns,added)
        } else {slot.desc=desc}
        slot.pending=true
    }
    for i:=pool.order_count-1;i>=0;i-=1 {
        slot_at:=int(pool.order[i])
        if pool.slots[slot_at].seen!=pool.frame {pool_slot_release(pool,slot_at)}
    }
    return pool.dropped,true
}

// The device could not make the buffers of the capacity of the pool: it goes
// back to the one it had, without its particles, and does not try it again.
@(private)
pool_refused :: proc(pool:^Pool,allocator:=context.allocator) {
    refused,previous:=pool.capacity,pool.previous
    if previous==0 || previous==refused {
        pool_free(pool,allocator)
        pool.capacity,pool.refused=0,refused
        return
    }
    pool_make(pool,previous,allocator)
    pool.refused=refused
}

// The births of two lists that come before a frame simulates them: the
// first ones grow older by the seconds of the second. Past SPAWNS,
// neighbours join into one group spread between their oldest and youngest.
spawns_join :: proc(spawns:^[SPAWNS]Particle_Spawn,before,after:[SPAWNS]Particle_Spawn,later:f32) {
    all:[2*SPAWNS]Particle_Spawn
    count:=0
    for s in before {
        if s.count==0 {continue}
        all[count]=s
        all[count].age+=later
        count+=1
    }
    for s in after {
        if s.count==0 {continue}
        all[count]=s
        count+=1
    }
    for count>SPAWNS {
        // The pair that spans the least time joins.
        best,span:=0,f32(max(f32))
        for i in 0..<count-1 {
            if s:=spawn_oldest(all[i])-spawn_youngest(all[i+1]);abs(s)<span {best,span=i,abs(s)}
        }
        a,b:=all[best],all[best+1]
        oldest:=max(spawn_oldest(a),spawn_oldest(b))
        youngest:=min(spawn_youngest(a),spawn_youngest(b))
        total:=a.count+b.count
        all[best]={count=total,per=1,birth=a.birth,age=oldest,spacing=total>1?(oldest-youngest)/f32(total-1):0}
        copy(all[best+1:count-1],all[best+2:count])
        count-=1
    }
    spawns^={}
    copy(spawns[:],all[:count])
}

spawn_oldest :: proc "contextless" (s:Particle_Spawn) -> f32 {return s.age}

spawn_youngest :: proc "contextless" (s:Particle_Spawn) -> f32 {
    instants:=(s.count+max(s.per,1)-1)/max(s.per,1)
    return s.age-f32(max(instants,1)-1)*s.spacing
}

// The live slot of an id, or -1.
pool_slot_find :: proc(p:^Pool,id:u64) -> int {
    order:=p.order[:p.order_count]
    low,high:=0,len(order)
    for low<high {
        middle:=(low+high)/2
        if p.slots[order[middle]].id<id {low=middle+1} else {high=middle}
    }
    if low<len(order) && p.slots[order[low]].id==id {return int(order[low])}
    return -1
}

pool_slot_take :: proc(p:^Pool,id:u64,capacity:u32,stride:u32=0) -> int {
    if capacity==0 || p.order_count>=len(p.order) {return -1}
    bytes:=u64(capacity)*u64(stride)
    if bytes>u64(max(u32)) {return -1}
    offset,fits:=base.ranges_take(&p.free,u64(capacity))
    if !fits {return -1}
    attributes:u64
    if bytes>0 {
        if attributes,fits=base.ranges_take(&p.attribute_free,bytes);!fits {
            base.ranges_give(&p.free,offset,u64(capacity))
            return -1
        }
    }
    at:=-1
    for slot,i in p.slots[:p.slot_end] {
        if !slot.live {at=i;break}
    }
    if at<0 {at=p.slot_end;p.slot_end+=1}
    p.slots[at]={id=id,offset=u32(offset),capacity=capacity,attributes=u32(attributes),stride=stride,live=true,fresh=true}
    p.pool_end=max(p.pool_end,u32(offset)+capacity)
    p.regroup=true
    low,high:=0,p.order_count
    for low<high {
        middle:=(low+high)/2
        if p.slots[p.order[middle]].id<id {low=middle+1} else {high=middle}
    }
    copy(p.order[low+1:p.order_count+1],p.order[low:p.order_count])
    p.order[low]=u16(at)
    p.order_count+=1
    return at
}

pool_slot_release :: proc(p:^Pool,at:int) {
    slot:=&p.slots[at]
    for i in 0..<p.order_count {
        if int(p.order[i])!=at {continue}
        copy(p.order[i:p.order_count-1],p.order[i+1:p.order_count])
        p.order_count-=1
        break
    }
    base.ranges_give(&p.free,u64(slot.offset),u64(slot.capacity))
    base.ranges_give(&p.attribute_free,u64(slot.attributes),u64(slot.capacity)*u64(slot.stride))
    slot.live=false
    p.regroup=true
    for p.slot_end>0 && !p.slots[p.slot_end-1].live {p.slot_end-=1}
    p.pool_end=0
    for s in p.slots[:p.slot_end] {
        if s.live {p.pool_end=max(p.pool_end,s.offset+s.capacity)}
    }
}

// The rows of a transform of the world, its place relative to origin.
@(private)
rows_of :: proc "contextless" (m:matrix[4,4]f32,origin:[3]f32) -> [3][4]f32 {
    return erender.origin_to_world(mm.mat4_rows(m),origin)
}

// The table of emitters of the frame, and the rows of their resources,
// uploaded once for its passes, and the steps it takes. What an emitter
// starts stays until a frame simulates it. reset: every range starts again
// (the buffers of the pool were made anew).
@(private)
pool_prepare :: proc(sync:^Particle_Sync,pass:^erender.Pass,reset:bool) -> bool {
    pool:=&sync.pool
    if pool.rows_frame==pass.frame && !reset {return true}
    pool.spawn_max,pool.birth_max,pool.reset_max,pool.sprites,pool.meshes,pool.steps=0,0,0,false,false,0
    pool.births_max,pool.prepares=0,false
    pool.stage_count,pool.plan=0,{}
    if pool.slot_end==0 {return false}
    // Where the reports of the frame go: the copy of their channel it writes.
    reports_at:=max(u32)
    if at:=data_find(&sync.data,REPORTS_CHANNEL);at>=0 {reports_at=data_base(sync)+sync.data.entries[at].offset+u32(pool.frame&1)*data_copy_bytes(REPORT_WORDS)}
    clear(&pool.frame_bytes)
    // The bones of the frame first, then the grids: the resources that read them name their bytes.
    append(&pool.frame_bytes,..([^]u8)(raw_data(sync.segments))[:len(sync.segments)*size_of(Gpu_Segment)])
    pool.grids_at=u32(len(pool.frame_bytes))
    base:=grids_base(sync)
    for &entry,at in sync.grids.entries {
        row:=Gpu_Grid{
            cells=entry.cells,layers=entry.layers,first=entry.first,cell_size=entry.cell_size,
            previous=entry.cleared,parity=base+u32(at)*4,offset=base+entry.offset,splat=base+entry.splat,
            moved=u32(entry.cleared!=entry.first),phase=grid_phase(entry.first,entry.cells),
            corner=erender.origin_cell(entry.first,f64(entry.cell_size),pass.origin),
        }
        append(&pool.frame_bytes,..([^]u8)(&row)[:size_of(row)])
    }
    pool.volumes_at,pool.volume_count,pool.volume_cells=u32(len(pool.frame_bytes)),0,0
    for &entry,at in sync.grids.entries {
        if !entry.has_volume {continue}
        v:=entry.volume
        row:=Gpu_Volume{
            grid=pool.grids_at+u32(at)*size_of(Gpu_Grid),light=base+entry.light,
            density=max(v.density,0),anisotropy=clamp(v.anisotropy,-0.95,0.95),albedo=v.albedo,emission=v.emission,
        }
        append(&pool.frame_bytes,..([^]u8)(&row)[:size_of(row)])
        pool.volume_count+=1
        pool.volume_cells=max(pool.volume_cells,grid_cells(entry.cells))
    }
    pool.fields_at=u32(len(pool.frame_bytes))
    fields:=fields_relative(sync.fields,pass.origin)
    append(&pool.frame_bytes,..([^]u8)(&fields)[:size_of(fields)])
    pool.steps=u32(clamp(math.ceil(pool.dt/STEP),1,STEPS))
    lights_taken:=[2]u32{}
    step_dt:=pool.dt/f32(pool.steps)
    for &g,at in pool.gpu[:pool.slot_end] {
        s:=&pool.slots[at]
        // The shares of the lights follow the slots, also through those that have none (particle_light_at).
        if !s.live {g.range,g.lights={},light_share(0,false,&lights_taken,pool.lights);continue}
        if reset {s.fresh=true;s.program_dirty=s.desc.program.id!=0}
        d:=&s.desc
        flags:=u32(FLAG_ACTIVE)
        if s.fresh {flags|=FLAG_RESET;pool.reset_max=max(pool.reset_max,s.capacity)}
        if d.local {flags|=FLAG_LOCAL}
        if d.lit {flags|=FLAG_LIT}
        if d.sort || d.render==.Ribbon {flags|=FLAG_SORT}
        if d.paused {flags|=FLAG_PAUSED}
        if d.blend==.Additive {flags|=FLAG_ADDITIVE}
        if d.relative {flags|=FLAG_RELATIVE}
        // The places of an emitter of an effect view are of that view.
        origin:=pass.origin
        if d.view!=0 {flags|=FLAG_VIEW;origin={}}
        if d.program.moves {flags|=FLAG_MOVED}
        if d.program.births {flags|=FLAG_BIRTHS;pool.births_max=max(pool.births_max,s.capacity)}
        if d.program.prepare {flags|=FLAG_PREPARE;pool.prepares=true}
        spawn,groups:=u32(0),u32(0)
        for group in d.spawns {
            if group.count==0 {continue}
            g.spawns[groups]={group.count,max(group.per,1),group.birth,transmute(u32)group.age}
            g.spacing[groups/4][groups%4]=group.spacing
            spawn+=group.count
            groups+=1
        }
        for i in groups..<SPAWNS {g.spawns[i]={};g.spacing[i/4][i%4]=0}
        // More than a few times its capacity cannot start: the rest would find no slot.
        spawn=min(spawn,s.capacity*4)
        pool.spawn_max=max(pool.spawn_max,spawn)
        target:=u32(0)
        if d.event!=.None {
            if t:=pool_slot_find(pool,d.event_target);t>=0 {target=u32(t)+1}
        }
        if d.render==.Mesh && !d.blended {pool.meshes=true} else {pool.sprites=true}
        if bit:=u64(1)<<(uint(at)%64);s.fresh || pool.dirty[at/64]&bit!=0 {
            emitter_row(&g,s,pool.capacity)
            pool.dirty[at/64]&~=bit
        }
        g.world=rows_of(d.transform,origin)
        g.previous=rows_of(d.previous,origin)
        g.range={s.offset,s.capacity,spawn,flags}
        g.random.y,g.random.w=target,groups
        g.program.w=reports_at if d.report!=.None else max(u32)
        g.step={pool.dt,step_dt,f32(pool.steps),pass.time}
        g.frame={max(u32),0,0,0}
        g.lights=light_share(d.lights,d.shadows,&lights_taken,pool.lights)
        g.data.z,g.data.w=transmute(u32)d.age,d.born
        if d.resources>0 && int(d.resources-1)+RESOURCE_ROWS<=len(sync.resources) {
            g.frame.x=u32(len(pool.frame_bytes))
            for resource in sync.resources[d.resources-1:][:RESOURCE_ROWS] {
                row:=Gpu_Resource{world=rows_of(resource.transform,origin),previous=rows_of(resource.previous,origin)}
                switch resource.kind {
                case .None:
                case .Surface:
                    if first,placed:=surface_place(&sync.surfaces,resource.mesh,resource.triangles,pool.frame);placed {
                        row.head={u32(Resource_Kind.Surface),u32(resource.mesh),first,resource.triangles}
                    }
                case .Channel: row.head={u32(Resource_Kind.Channel),0,resource.first,resource.count}
                case .Bones:
                    if int(resource.first+resource.count)<=len(sync.segments) {
                        row.head={u32(Resource_Kind.Bones),0,resource.first*size_of(Gpu_Segment),resource.count}
                    }
                case .Grid:
                    if int(resource.first)<len(sync.grids.entries) {
                        row.head={u32(Resource_Kind.Grid),pool.grids_at+resource.first*size_of(Gpu_Grid),0,0}
                    }
                case .Emitter:
                    if other:=pool_slot_find(pool,resource.emitter);other>=0 {row.head={u32(Resource_Kind.Emitter),0,u32(other),0}}
                case .Data:
                    // The bytes of the channel, the words of an entry, and the copy the frame writes.
                    if at:=data_find(&sync.data,resource.emitter);at>=0 {
                        entry:=&sync.data.entries[at]
                        row.head={u32(Resource_Kind.Data),data_base(sync)+entry.offset,entry.words,u32(pool.frame&1)}
                    }
                }
                append(&pool.frame_bytes,..([^]u8)(&row)[:size_of(row)])
            }
            // Its stages after its resources, and what each stage index runs.
            if d.stages>0 && int(d.stages-1)+erender.PROGRAM_STAGES<=len(sync.stage_rows) {
                stages:=sync.stage_rows[d.stages-1:][:erender.PROGRAM_STAGES]
                append(&pool.frame_bytes,..([^]u8)(raw_data(stages))[:len(stages)*size_of(Gpu_Stage)])
                for stage,k in stages {
                    plan:=&pool.plan[k]
                    for resource in 0..<u32(RESOURCES) {
                        if stage.writes&(1<<resource)==0 {continue}
                        grid:=sync.resources[d.resources-1+1+resource]
                        if grid.kind==.Grid {plan.written_max=max(plan.written_max,grid_cells(sync.grids.entries[grid.first].cells))}
                    }
                    switch Stage_Kind(stage.kind) {
                    case .None: continue
                    case .Particles:
                        plan.particles=true
                        plan.iterations=max(plan.iterations,stage.iterations)
                    case .Cells:
                        grid:=sync.resources[d.resources-1+stage.row]
                        if grid.kind!=.Grid {continue}
                        plan.cells=true
                        plan.iterations=max(plan.iterations,stage.iterations)
                        plan.cells_max=max(plan.cells_max,grid_cells(sync.grids.entries[grid.first].cells))
                    }
                    pool.stage_count=max(pool.stage_count,u32(k)+1)
                }
            }
        }
    }
    // The births of the channels after the resources; each emitter finds those of its channel.
    births:=u32(len(pool.frame_bytes))
    for birth in sync.births {
        row:=birth
        row.position=erender.origin_point(birth.position,pass.origin)
        append(&pool.frame_bytes,..([^]u8)(&row)[:size_of(row)])
    }
    for &g,at in pool.gpu[:pool.slot_end] {
        s:=&pool.slots[at]
        if !s.live {continue}
        g.frame.y,g.frame.z,g.frame.w=births+s.desc.births.x*size_of(Gpu_Birth),s.desc.births.y,births
        pool.birth_max=max(pool.birth_max,s.desc.births.y)
    }
    rows,ok:=erender.pass_rows_upload(pass,raw_data(pool.gpu),pool.slot_end*size_of(Gpu_Emitter))
    if !ok {return false}
    // Bytes of nothing when no emitter reads anything: the stages read their binding.
    zero:[16]u8
    if len(pool.frame_bytes)==0 {append(&pool.frame_bytes,..zero[:])}
    resources:erender.Pass_Rows
    resources,ok=erender.pass_rows_upload(pass,raw_data(pool.frame_bytes),len(pool.frame_bytes))
    if !ok {return false}
    pool.rows,pool.resources,pool.rows_frame=rows,resources,pass.frame
    return true
}

// The row of an emitter but for what each frame gives: built again when what
// its emitter is told changes (Emitter_Desc.revision) or its range starts.
@(private)
emitter_row :: proc(g:^Gpu_Emitter,s:^Pool_Slot,capacity:u32) {
    d:=&s.desc
    vertex_count,mesh:=u32(6),u32(0)
    if d.render==.Mesh {vertex_count,mesh=d.mesh[0],d.mesh[1]}
    g.random.x,g.random.z=d.seed,min(d.event_count,EVENT_SPAWN_MAX)
    g.program.xyz={d.program.id,capacity,u32(d.report)}
    g.shape={d.shape_size.x,d.shape_size.y,d.shape_size.z,d.shape_angle}
    g.kinds={u32(d.shape),u32(d.render),u32(d.collision),u32(d.event)}
    g.lifetime_speed={max(d.lifetime[0],0.001),max(d.lifetime[1],0.001),d.speed[0],d.speed[1]}
    g.size_rotation={d.size[0],d.size[1],d.rotation[0],d.rotation[1]}
    g.spin={d.spin[0],d.spin[1],clamp(d.shell,0,1),d.inherit}
    g.color_a,g.color_b=d.color[0],d.color[1]
    g.velocity_a={d.velocity[0].x,d.velocity[0].y,d.velocity[0].z,0}
    g.velocity_b={d.velocity[1].x,d.velocity[1].y,d.velocity[1].z,0}
    g.acceleration={d.acceleration.x,d.acceleration.y,d.acceleration.z,max(d.drag,0)}
    g.noise={d.noise_strength,max(d.noise_frequency,0),d.noise_speed,d.gravity}
    // The particles of an effect view are of no place: they fall with GRAVITY.
    if d.view!=0 {g.acceleration.xyz+=GRAVITY*d.gravity;g.noise.w=0}
    g.collide={clamp(d.bounce,0,1),clamp(d.friction,0,1),clamp(d.collision_life,0,1),0}
    g.look={max(d.stretch,0),max(d.soft,0),d.intensity,max(d.flipbook_speed,0)}
    g.attractor={d.attractor.x,d.attractor.y,d.attractor.z,d.attractor_strength}
    g.mesh={vertex_count,mesh,0,u32(d.material)}
    g.flipbook={max(d.flipbook[0],1),max(d.flipbook[1],1),0,0}
    g.size_curve=transmute([2][4]f32)d.size_curve.values
    g.size_times=transmute([2][4]f32)d.size_curve.times
    g.gradient=d.color_curve.colors
    g.gradient_times=transmute([2][4]f32)d.color_curve.times
    g.light={d.light.x,d.light.y,d.light.z,0}
    g.data.xy={ATTRIBUTES_AT+s.attributes,s.stride}
}

// What the passes of a world draw its particles with: the pipelines of the
// stages of the plugin, 0 while the shaders in use do not have them. They are
// asked again when the shaders are, or when the renderer takes another
// variant of a stage (the one particle_simulate gives changes).
Particle_Pipelines :: struct {
    shift,begin,emit,simulate,finish,surface,stage,volume_light,lights,world_texture,additive,alpha,volume:erender.Pipeline,
    // The emitters without a program run on the stages above; each program on those of its own.
    programs:[PROGRAMS_IN_USE]Program_Pipelines,
    program_count:int,
    none:Program_Span, // of the emitters without a program
    reloads:u64,       // the shader generation they were asked from
}

// The pipelines a pass runs: those of the emitters without a program, then
// those of each program in use, over the slots their emitters hold.
@(private)
Program_Group :: struct {
    program:u32,
    emit,simulate,stage:erender.Pipeline,
    using span:Program_Span,
}

@(private)
program_groups :: proc(p:^Particle_Pipelines,out:^[PROGRAMS_IN_USE+1]Program_Group) -> []Program_Group {
    count:=0
    if p.none.emitter_end>p.none.emitter_first {
        out[0]={0,p.emit,p.simulate,p.stage,p.none}
        count=1
    }
    for &each in p.programs[:p.program_count] {
        if each.emit==0 || each.simulate==0 || each.stage==0 || each.emitter_end<=each.emitter_first {continue}
        out[count]={each.id,each.emit,each.simulate,each.stage,each.span}
        count+=1
    }
    return out[:count]
}

// The pipelines of the program of an emitter; nil without one.
@(private)
program_pipelines :: proc(p:^Particle_Pipelines,id:u32) -> ^Program_Pipelines {
    if id==0 {return nil}
    for &each in p.programs[:p.program_count] {if each.id==id {return &each}}
    return nil
}

// The programs of the live emitters with their pipelines, and the slots each
// one's emitters hold. Past PROGRAMS_IN_USE, the emitters of the rest do not run.
@(private)
programs_find :: proc(sync:^Particle_Sync,renderer:^erender.Renderer) {
    pool:=&sync.pool
    p:=&sync.pipelines
    for {
        left_out:=programs_span(sync,renderer)
        // Those no live emitter runs give their room.
        kept:=0
        for each in p.programs[:p.program_count] {
            if each.emitter_end>each.emitter_first {p.programs[kept]=each;kept+=1}
        }
        freed:=kept<p.program_count
        p.program_count=kept
        if !left_out || !freed {break}
    }
    for &s in pool.slots[:pool.slot_end] {
        if !s.live || s.desc.event==.None {continue}
        target:=pool_slot_find(pool,s.desc.event_target)
        if target<0 {continue}
        if id:=pool.slots[target].desc.program.id;id==0 {p.none.events=true} else if each:=program_pipelines(p,id);each!=nil {each.events=true}
    }
}

@(private)
programs_span :: proc(sync:^Particle_Sync,renderer:^erender.Renderer) -> (left_out:bool) {
    pool:=&sync.pool
    p:=&sync.pipelines
    p.none={}
    for &each in p.programs[:p.program_count] {each.span={}}
    for &s,at in pool.slots[:pool.slot_end] {
        if !s.live {continue}
        span:=&p.none
        if id:=s.desc.program.id;id!=0 {
            each:=program_pipelines(p,id)
            if each==nil {
                if p.program_count==PROGRAMS_IN_USE {left_out=true;continue}
                name:=base.text_get(s.desc.program.name[:])
                each=&p.programs[p.program_count]
                p.program_count+=1
                each^={id=id}
                each.emit=erender.stage_pipeline(renderer,{stage=.Simulate,shader=fmt.tprintf("particle_emit__%s",name),name="particle emit"})
                each.simulate=erender.stage_pipeline(renderer,{stage=.Simulate,shader=fmt.tprintf("particle_simulate__%s",name),name="particle simulate"})
                each.stage=erender.stage_pipeline(renderer,{stage=.Simulate,shader=fmt.tprintf("particle_stage__%s",name),name="particle stage"})
                base.text_set(each.sprite[:],fmt.tprintf("particle_sprite__%s",name))
                base.text_set(each.mesh[:],fmt.tprintf("particle_mesh__%s",name))
                base.text_set(each.mesh_blend[:],fmt.tprintf("particle_mesh_blend__%s",name))
            }
            span=&each.span
        }
        if span.emitter_end<=span.emitter_first {
            span^={first=s.offset,end=s.offset+s.capacity,emitter_first=u32(at),emitter_end=u32(at)+1}
        } else {
            span.first,span.end=min(span.first,s.offset),max(span.end,s.offset+s.capacity)
            span.emitter_end=u32(at)+1
        }
    }
    return
}

// The pipelines of the frame, and its passes for the particles of a world.
// False while the shaders in use have no stages of the plugin.
particles_frame :: proc(sync:^Particle_Sync,app:^host.App) -> bool {
    pool:=&sync.pool
    // The data channels the programs asked for, and that of the reports while a live emitter reports.
    for s in pool.slots[:pool.slot_end] {
        if s.live && s.desc.report!=.None {data_need(&sync.data,REPORTS_CHANNEL,REPORT_WORDS,nil,core.NONE);break}
    }
    data_place(&sync.data)
    if pool.slot_end==0 {return true}
    p:=&sync.pipelines
    simulate:=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_simulate",name="particle simulate"})
    if simulate==0 {return false}
    if simulate!=p.simulate || p.reloads!=app.shaders.reloads {
        p^={reloads=app.shaders.reloads}
        p.shift=erender.stage_pipeline(app.renderer,{stage=.Geometry,shader="particle_shift",name="particle shift"})
        p.begin=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_begin",name="particle begin"})
        p.emit=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_emit",name="particle emit"})
        p.finish=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_finish",name="particle finish"})
        p.surface=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_surface",name="particle surface"})
        p.stage=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_stage",name="particle stage"})
        p.volume_light=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_volume_light",name="particle volume light"})
        p.lights=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_lights",name="particle lights"})
        p.world_texture=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_world_texture",name="particle world texture"})
        p.volume=erender.stage_pipeline(app.renderer,{stage=.Blend,shader="particle_volume",blend=.Premultiplied,name="particle volumes"})
        p.additive=erender.stage_pipeline(app.renderer,{stage=.Blend,shader="particle_sprite",blend=.Additive,name="particles additive"})
        p.alpha=erender.stage_pipeline(app.renderer,{stage=.Blend,shader="particle_sprite",blend=.Premultiplied,name="particles blended"})
        if p.shift==0 || p.begin==0 || p.emit==0 || p.finish==0 || p.surface==0 || p.stage==0 || p.volume_light==0 || p.lights==0 || p.world_texture==0 || p.additive==0 || p.alpha==0 || p.volume==0 {return false}
        p.simulate=simulate
        pool.regroup=true
    }
    if pool.regroup {
        programs_find(sync,app.renderer)
        pool.regroup=false
    }
    // The vertices of the scene made again: so are the areas of its surfaces.
    if made:=erender.vertices_made(app.renderer);made!=sync.surfaces.vertices {
        sync.surfaces.vertices=made
        for &entry in sync.surfaces.entries {entry.built=false}
    }
    pool.lights=lights_asked(pool.slots[:pool.slot_end])
    if pool.lights!={} {erender.lights_ask(app.renderer,pool.lights[0],pool.lights[1])}
    world_textures_make(sync,app.renderer)
    grids_load_prepare(sync,app.assets)
    if pool.made {erender.frame_pass(app.renderer,.Geometry,particles_shift,sync)}
    erender.frame_pass(app.renderer,.Simulate,particles_simulate,sync)
    if sync.world_texture_count>0 || sync.world_shown.names!={} {erender.frame_pass(app.renderer,.Mask,world_textures_frame,sync)}
    erender.frame_pass(app.renderer,.Gbuffer,particles_meshes,sync)
    // What Mesh particles reflect and their layers reach the G-buffer of every
    // view, and their meshes stay whole: they draw every cluster of level 0.
    for &s in pool.slots[:pool.slot_end] {
        if !s.live || s.desc.render!=.Mesh {continue}
        if !s.desc.blended {erender.frame_gbuffer_mesh(app.renderer,erender.Mesh_Handle(s.desc.mesh[1]),s.desc.material)}
        erender.frame_mesh_whole(app.renderer,erender.Mesh_Handle(s.desc.mesh[1]))
    }
    erender.frame_pass(app.renderer,.Blend,particles_volumes,sync)
    erender.frame_pass(app.renderer,.Blend,particles_sprites,sync)
    if pool_has_views(pool) {erender.frame_pass(app.renderer,.Effect,particles_sprites,sync)}
    return true
}

// Binds the buffers of the pool at the slots of particles.slang. made: one
// of them was made now, so what the pool holds starts again.
@(private)
pool_bind :: proc(pass:^erender.Pass,pool:^Pool) -> (ok,made:bool) {
    slots:=[Pool_Buffer]u32{.Particles=0,.State=2,.Lists=3,.Events=5,.Data=9}
    for slot,b in slots {
        bound,new:=erender.pass_buffer(pass,slot,pool_buffer(pool,b))
        if !bound {return false,made}
        made||=new
    }
    return true,made
}

// Starts, moves and lights the particles of the frame, in its first view (of
// the window, or into a texture in a frame that draws only into textures):
// they collide with its depth.
@(private)
particles_simulate :: proc(pass:^erender.Pass,user:rawptr) {
    sync:=cast(^Particle_Sync)user
    pool:=&sync.pool
    p:=&sync.pipelines
    if pass.world!=sync.world || pool.slot_end==0 {return}
    erender.pass_timestamp(pass,"particles")
    bound,made:=pool_bind(pass,pool)
    if !bound {
        pool_refused(pool)
        return
    }
    if made {
        erender.pass_buffer_fill(pass,pool_buffer(pool,.Events),0,EVENTS_AT)
        pool.origin=pass.origin
    }
    if !pool_prepare(sync,pass,made) || pool.steps==0 {return}
    params:=Simulate_Params{emitters=u32(pool.slot_end),fields=pool.fields_at}
    erender.pass_rows(pass,1,pool.rows)
    erender.pass_rows(pass,4,pool.resources)
    if !world_prepare(sync,pass,&params) {return}
    // The parameters of the programs that changed.
    data:=pool_buffer(pool,.Data)
    for &s,at in pool.slots[:pool.slot_end] {
        if !s.live || !s.program_dirty {continue}
        if erender.pass_buffer_write(pass,data,u64(at)*erender.PROGRAM_PARAMETER_BYTES,&s.desc.program.parameters,erender.PROGRAM_PARAMETER_BYTES) {s.program_dirty=false}
    }
    erender.pass_surface_read(pass,7,.Linear_Depth)
    erender.pass_surface_read(pass,8,.Normal)
    data_frame(sync,pass,u32(pool.frame&1))
    if pool.reset_max>0 {
        params.mode=0
        erender.pass_pipeline(pass,p.begin)
        erender.pass_params(pass,&params,size_of(params))
        erender.pass_dispatch(pass,groups(pool.reset_max,64),u32(pool.slot_end))
    }
    events:=pool_buffer(pool,.Events)
    world:=world_buffer(sync)
    for step in 0..<pool.steps {
        params.parity,params.step,params.last=u32(pool.step&1),step,u32(step+1==pool.steps)
        // What the particles of the step splat starts at zero.
        if g:=&sync.grids;len(g.entries)>0 {erender.pass_buffer_fill(pass,world,u64(grids_base(sync)+g.splats),u64(g.bytes-g.splats))}
        params.mode=1
        erender.pass_pipeline(pass,p.begin)
        erender.pass_params(pass,&params,size_of(params))
        erender.pass_dispatch(pass,groups(u32(pool.slot_end),64))
        // Each pass once for the emitters without a program and once for each program.
        all:[PROGRAMS_IN_USE+1]Program_Group
        for group in program_groups(p,&all) {
            params.program,params.emitter_first=group.program,group.emitter_first
            emitters:=group.emitter_end-group.emitter_first
            erender.pass_pipeline(pass,group.emit)
            // The programs that give their births say them first, once a frame.
            if (pool.births_max>0 || pool.prepares) && group.program!=0 && step==0 {
                params.mode,params.count=3,u32(pool.slot_end)
                erender.pass_params(pass,&params,size_of(params))
                erender.pass_dispatch(pass,groups(emitters,64))
            }
            if starts:=max(pool.spawn_max,group.program!=0?pool.births_max:0);starts>0 {
                params.mode,params.count=0,starts
                erender.pass_params(pass,&params,size_of(params))
                erender.pass_dispatch(pass,groups(starts,64),emitters)
            }
            if pool.birth_max>0 {
                params.mode,params.count=2,pool.birth_max
                erender.pass_params(pass,&params,size_of(params))
                erender.pass_dispatch(pass,groups(pool.birth_max,64),emitters)
            }
            if group.events {
                params.mode=1
                erender.pass_params(pass,&params,size_of(params))
                erender.pass_dispatch_indirect(pass,events,u64(16+16*(1-params.parity)))
            }
        }
        params.program,params.emitter_first=0,0
        if pool.stage_count>0 {stages_step(sync,pass,&params)}
        for group in program_groups(p,&all) {
            params.program,params.first,params.count=group.program,group.first,group.end
            erender.pass_pipeline(pass,group.simulate)
            erender.pass_params(pass,&params,size_of(params))
            erender.pass_dispatch(pass,groups(group.end-group.first,64))
        }
        params.program,params.first,params.count=0,0,pool.pool_end
        pool.step+=1
    }
    erender.pass_pipeline(pass,p.finish)
    erender.pass_params(pass,&params,size_of(params))
    erender.pass_counters(pass,9,"particles")
    erender.pass_dispatch(pass,u32(pool.slot_end))
    // The lights of the particles complete the tree the media of the volumes walk.
    particles_lights(sync,pass)
    volumes_light(sync,pass,&params)
    world_textures_write(sync,pass)
    data_readback(sync,pass,u32(pool.frame&1))
    // Started: a frame simulated without a new list moves what there is and starts nothing.
    for &s in pool.slots[:pool.slot_end] {
        if !s.live {continue}
        s.fresh,s.pending=false,false
        s.desc.spawns={}
        s.desc.previous=s.desc.transform
    }
    pool.drawn=true
    pool.made=true
}

// What the pool keeps of places moves once the origin of the renderer moved
// since it last did, before a view of the frame draws it, so that it stays
// where it is in the world without looking like motion: the living particles
// of the world (not those local to their emitter or of an effect view) and
// the events that wait for a step. A world not drawn while the origin moved
// takes all of it when it is drawn again.
@(private)
particles_shift :: proc(pass:^erender.Pass,user:rawptr) {
    sync:=cast(^Particle_Sync)user
    pool:=&sync.pool
    if pass.world!=sync.world || !pool.made || pool.slot_end==0 || pool.origin==pass.origin {return}
    for b in ([]Pool_Buffer{.Particles,.Lists,.State,.Events}) {
        if !erender.pass_buffer_held(pass,pool_buffer(pool,b)) {return}
    }
    if !pool_prepare(sync,pass,false) {return}
    erender.pass_buffer(pass,0,pool_buffer(pool,.Particles))
    erender.pass_buffer(pass,2,pool_buffer(pool,.State))
    erender.pass_buffer(pass,3,pool_buffer(pool,.Lists))
    erender.pass_buffer(pass,5,pool_buffer(pool,.Events))
    erender.pass_rows(pass,1,pool.rows)
    Params :: struct {shift:[4]f32,count,emitters,pad0,pad1:u32}
    shift:=pool.origin-pass.origin
    params:=Params{shift={shift.x,shift.y,shift.z,0},count=pool.pool_end,emitters=u32(pool.slot_end)}
    erender.pass_pipeline(pass,sync.pipelines.shift)
    erender.pass_params(pass,&params,size_of(params))
    erender.pass_dispatch(pass,groups(max(pool.pool_end,EVENT_CAPACITY),64),3)
    pool.origin=pass.origin
}

// The lights of the particles, in the room the renderer keeps for them: a
// group writes all of each part, also with none to light.
@(private)
particles_lights :: proc(sync:^Particle_Sync,pass:^erender.Pass) {
    if sync.pool.lights=={} {return}
    room,ok:=erender.pass_lights(pass,7,8)
    if !ok {return}
    Params :: struct {emitters,scene_root,pad0,pad1:u32,parts:[2][4]u32}
    params:=Params{emitters=u32(sync.pool.slot_end),scene_root=room.scene_root}
    for part,at in ([2]erender.Pass_Light_Part{room.shadows,room.shadowless}) {params.parts[at]={part.first_light,part.capacity,part.root,0}}
    erender.pass_pipeline(pass,sync.pipelines.lights)
    erender.pass_params(pass,&params,size_of(params))
    erender.pass_dispatch(pass,2 if room.shadowless.capacity>0 else 1)
}

// The lights the live emitters of a pool ask the room for: those with
// shadows and those without, up to what the renderer gives of each.
@(private)
lights_asked :: proc(slots:[]Pool_Slot) -> (asked:[2]u32) {
    for &s in slots {
        if s.live {asked[0 if s.desc.shadows else 1]+=s.desc.lights}
    }
    return {min(asked[0],erender.LIGHTS_ASKED_MAX),min(asked[1],erender.LIGHTS_ASKED_MAX)}
}

// The share of the room of an emitter of lights, in the order of the slots
// (Gpu_Emitter.lights): it takes them from the part of its kind, after those
// the emitters before it took, as many as asked leaves; from the other part,
// none, where the shares of its emitters reach. taken: of each part so far.
@(private)
light_share :: proc "contextless" (lights:u32,shadows:bool,taken:^[2]u32,asked:[2]u32) -> [4]u32 {
    part:=0 if shadows else 1
    budget:=min(lights,asked[part]-min(taken[part],asked[part]))
    share:=[4]u32{taken[0],0,taken[1],0}
    share[2*part+1]=budget
    taken[part]+=budget
    return share
}

@(private)
groups :: proc "contextless" (size,group:u32) -> u32 {return (size+group-1)/group}

// The emitters a view draws, back to front: blended sprites read what is
// behind them, so the farther ones go first. eye: where the view looks from,
// or with w 0 the direction an orthographic one looks along. view: the
// texture of the effect view drawn, or 0 for a view of the world. origin:
// what eye is relative to.
@(private)
draw_list :: proc(pool:^Pool,eye:[4]f32,origin:[3]f32,meshes:bool,view:erender.Texture_Handle=0) -> []Pool_Draw {
    count:=0
    for &s,at in pool.slots[:pool.slot_end] {
        if !s.live || (s.desc.render==.Mesh && !s.desc.blended)!=meshes || s.desc.view!=view {continue}
        place:=erender.origin_point({s.desc.transform[0,3],s.desc.transform[1,3],s.desc.transform[2,3]},origin)
        pool.draws[count]={u32(at),linalg.length(place-eye.xyz) if eye.w>0.5 else linalg.dot(place,eye.xyz)}
        count+=1
    }
    draws:=pool.draws[:count]
    if !meshes {slice.sort_by(draws,proc(a,b:Pool_Draw) -> bool {return a.distance>b.distance})}
    return draws
}

// Whether an emitter of the pool draws into an effect view.
@(private)
pool_has_views :: proc(pool:^Pool) -> bool {
    for &s in pool.slots[:pool.slot_end] {if s.live && s.desc.view!=0 {return true}}
    return false
}

// Whether the pool of a world has buffers to draw from in this frame: the
// Simulate stage made them, and its rows are up.
@(private)
pool_drawable :: proc(pass:^erender.Pass,sync:^Particle_Sync) -> bool {
    pool:=&sync.pool
    if !pool.made || pool.slot_end==0 {return false}
    for b in ([]Pool_Buffer{.Particles,.Lists,.Data}) {
        if !erender.pass_buffer_held(pass,pool_buffer(pool,b)) {return false}
    }
    return erender.pass_buffer_held(pass,world_buffer(sync)) && erender.pass_buffer_held(pass,pool_buffer(pool,.State)) && pool_prepare(sync,pass,false)
}

// Binds the rows of the frame and the world buffer at the slots the passes
// of the pool read them from.
@(private)
pool_bind_frame :: proc(pass:^erender.Pass,sync:^Particle_Sync) {
    erender.pass_rows(pass,1,sync.pool.rows)
    erender.pass_rows(pass,4,sync.pool.resources)
    erender.pass_buffer(pass,6,world_buffer(sync))
}

// What the passes of the Simulate stage are told: their mode, the emitters
// and threads, the half of the events and the step, and of a stage, which
// and its iteration.
// program: the passes that run programs run the emitters of that one (0: those without), from
// slot first of the pool and emitter_first of the table of emitters. fields: Pool.fields_at.
Simulate_Params :: struct {mode,emitters,count,parity,step,last,stage,iteration,program,first,emitter_first,fields:u32}

// The slot of the media of the view (render.pass_media) in the blended passes.
@(private) MEDIA_SLOT :: 5

// Sprites, ribbons and the mesh particles whose material blends over the lit
// scene, on the side of glass of the pass, behind the media of the view; at
// the Effect stage, those of the effect view of the pass over nothing.
@(private)
particles_sprites :: proc(pass:^erender.Pass,user:rawptr) {
    sync:=cast(^Particle_Sync)user
    pool:=&sync.pool
    if pass.world!=sync.world || !pool_drawable(pass,sync) || !pool.sprites {return}
    view:=pass.texture if pass.stage==.Effect else 0
    draws:=draw_list(pool,pass.eye,pass.origin,false,view)
    if len(draws)==0 {return}
    media:=erender.pass_media(pass,MEDIA_SLOT)
    erender.pass_blend_begin(pass,"particle sprites")
    erender.pass_indices(pass,.Quad)
    erender.pass_buffer(pass,0,pool_buffer(pool,.Particles))
    pool_bind_frame(pass,sync)
    erender.pass_buffer(pass,3,pool_buffer(pool,.Lists))
    erender.pass_buffer(pass,9,pool_buffer(pool,.Data))
    erender.pass_surface_read(pass,7,.Linear_Depth)
    erender.pass_surface_read(pass,8,.Glass_Depth)
    state:=pool_buffer(pool,.State)
    Params :: struct {emitter,pass,pad0,pad1:u32,media:erender.Media_Grid}
    for draw in draws {
        // The stage of its program, with the fragment of the Surface program of its material.
        desc:=&pool.slots[draw.slot].desc
        additive:=desc.blend==.Additive
        mesh:=desc.render==.Mesh
        stage:=erender.Stage_Pipeline_Desc{stage=.Blend,shader="particle_sprite",blend=.Additive if additive else .Premultiplied,name="particles additive" if additive else "particles blended"}
        if mesh {stage.shader,stage.fragment="particle_mesh_blend","particle_sprite"}
        if own:=program_pipelines(&sync.pipelines,desc.program.id);own!=nil {stage.shader,stage.fragment=base.text_get(own.mesh_blend[:] if mesh else own.sprite[:]),"particle_sprite"}
        stage.program=erender.pass_material_program(pass,desc.material)
        pipeline:=erender.pass_stage_pipeline(pass,stage)
        if pipeline==0 {continue}
        erender.pass_pipeline(pass,pipeline)
        params:=Params{emitter=draw.slot,pass=u32(pass.glass),media=media}
        erender.pass_params(pass,&params,size_of(params))
        // A mesh draws its clusters without indices, as in the G-buffer.
        at:=u64(draw.slot)*size_of(Gpu_State)+u64(offset_of(Gpu_State,draw))
        if mesh {erender.pass_draw_indirect(pass,state,at)} else {erender.pass_draw_indexed_indirect(pass,state,at)}
    }
    erender.pass_end(pass)
}

// Mesh particles into the G-buffer after the scene: lit, shadowed and
// reflected by the passes that follow like any surface.
@(private)
particles_meshes :: proc(pass:^erender.Pass,user:rawptr) {
    sync:=cast(^Particle_Sync)user
    pool:=&sync.pool
    if pass.world!=sync.world || !pool_drawable(pass,sync) || !pool.meshes {return}
    pipeline:=erender.pass_gbuffer_pipeline(pass,"particle_mesh","particle meshes")
    if pipeline==0 {return}
    erender.pass_gbuffer_begin(pass,"particle meshes")
    erender.pass_pipeline(pass,pipeline)
    erender.pass_buffer(pass,0,pool_buffer(pool,.Particles))
    pool_bind_frame(pass,sync)
    erender.pass_buffer(pass,3,pool_buffer(pool,.Lists))
    erender.pass_buffer(pass,9,pool_buffer(pool,.Data))
    state:=pool_buffer(pool,.State)
    Params :: struct {emitter,program,pad0,pad1:u32}
    bound:=pipeline
    for draw in draw_list(pool,pass.eye,pass.origin,true) {
        desc:=&pool.slots[draw.slot].desc
        shader:="particle_mesh"
        if own:=program_pipelines(&sync.pipelines,desc.program.id);own!=nil {shader=base.text_get(own.mesh[:])}
        // A draw for each Surface program of what its mesh shows, with the fragment of that program.
        programs:[MESH_PROGRAMS]u32
        count:=erender.pass_mesh_programs(pass,erender.Mesh_Handle(desc.mesh[1]),desc.material,programs[:])
        for program in programs[:min(count,len(programs))] {
            want:=erender.pass_gbuffer_pipeline(pass,shader,"particle meshes",program=program)
            if want==0 {continue}
            if want!=bound {erender.pass_pipeline(pass,want);bound=want}
            params:=Params{emitter=draw.slot,program=program if count>1 else max(u32)}
            erender.pass_params(pass,&params,size_of(params))
            erender.pass_draw_indirect(pass,state,u64(draw.slot)*size_of(Gpu_State)+u64(offset_of(Gpu_State,draw)))
        }
    }
    erender.pass_end(pass)
}

// Lets go of the buffers of the pool of a world.
pool_release :: proc(renderer:^erender.Renderer,world:core.World_Id,pool:^Pool) {
    for b in Pool_Buffer {erender.buffer_release(renderer,world,pool_buffer(pool,b).name)}
    pool.made=false
}
