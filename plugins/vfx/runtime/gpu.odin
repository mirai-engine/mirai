package vfx

import "base:intrinsics"
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

// The pool belongs to a renderer world. Emitters own ranges of particles and
// free slots, with a dense live list for each step parity. Only the final draw
// lists are reordered for transparency, ribbons or mesh variants.

CAPACITY :: 262144
PARTICLE_LIGHTS :: 128 // of a world at once, by default (Particle_Settings.max_lights)
EMITTER_CAPACITY :: 1024 // of a world
EVENT_CAPACITY :: 16384
EVENT_SPAWN_MAX :: 64
SPAWNS :: 8 // groups of births an emitter gives in a frame
STEP :: f32(1.0/30) // the longest step a simulation takes
TRAILS_PER_SECOND :: 30 // Trail events of a particle in each second of its life
BEAM_PIECES :: 16
RIBBON_PIECES :: 8 // most pieces a ribbon cuts the curve between two of its particles into
DRAW_LOOK_BYTES :: 128 // what a particle shows in the frame (particle_draw_look): its look, the pose it was born with and where it is along its ribbon, then the turn and the scale its program gives it
POSE_AT :: 96 // bytes of the look of a particle to its pose
TURN_AT :: 112 // and to the turn and the scale of its program
STEPS :: 8
FRAME_MAX :: f32(0.25) // seconds a frame simulates at most

// Births of an emitter: count particles, per of them at each instant. The
// first ones are age seconds old at the end of the frame, and each next
// instant spacing seconds younger. Older than the frame, they start where and
// how old their life took them (a prewarm). birth: the index of the first,
// which picks the random values of each particle. ribbon: the one they join,
// the segment of the clock that started them (Emitter_Clock.segment).
Particle_Spawn :: struct {
    count,per:u32,
    birth:u32,
    age,spacing:f32,
    ribbon:u32,
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
}

// A program’s range in the frame’s emitter slot list.
Program_Span :: struct {
    first,count:u32,
    lights:u32, // its first slots, of Light layers whose particles give lights
    events,births,prepare:bool,
}

MESH_PROGRAMS :: 8 // Surface programs of the materials of the mesh of an emitter it draws

// An emitter of a frame: the effect it shows and what its frame resolves.
Emitter_Desc :: struct {
    using spec:^Emitter_Info,
    id:u64,              // stable while the emitter lives
    look:u64,            // what its values were resolved from: another one writes its row and parameters again
    generation:u32,      // another one starts its range empty
    capacity:u32,        // particles alive at once
    transform:matrix[4,4]f32, // where the emitter is this frame
    previous:matrix[4,4]f32,  // and was the last one: births spread between both
    spawns:[SPAWNS]Particle_Spawn, // since the last list, in the order of their births
    paused:bool,         // its particles stay as they are
    culled:bool,         // and they are not drawn: its emitter waits (Emitter_Clock.culled)
    material:erender.Material_Handle, // of info.material
    meshes:[effect.PARTICLE_MESHES]Mesh_Choice, // of Mesh particles: what each mesh draws, mesh_count of them
    mesh_count:u32,
    mesh_extent:f32,
    external_positions:bool,
    mixed:bool,               // a mesh uses opaque and blended slots
    blended:bool,             // of Mesh particles: its material blends or adds (asset.alpha_blended), so they are drawn over the lit scene with the sprites
    view:erender.Texture_Handle, // drawn only into the effect view of this texture (gui.UI_Effects); 0: in the views of the world
    event_target:u64,         // id of the emitter info.trigger starts info.sub_count particles in; 0: none
    resources:u32,           // first resource row + 1, or 0 without resources
    stages:u32,              // first stage row + 1, or 0 without stages
    births:[2]u32,                          // of its channel: the first among those of the frame, and how many
    birth_limit:f32,                        // seconds of its clock up to which its program gives births (Emitter_Clock.program_until); an effect of the UI gives them always
    age:f32,                                // seconds since it started, at the end of the frame
    born:u32,                               // particles it started before this frame
    owner:core.Entity,                      // its entity, whose reports and problems they are; NONE for an effect of the UI
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
FLAG_DRAIN :: 4096
FLAG_VIEW :: 2048 // drawn into an effect view: its places are of that view, not of the world, and the origin does not move them
FLAG_MULTIPLY :: 8192 // its sprites multiply what is behind them by their color
FLAG_LIGHT :: 16384 // its particles give lights (effect.Particle_Light)
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
    flags:u32,          // 1: light holds a value; from MESH_CHOICE_SHIFT, the mesh of a Mesh particle; from RIBBON_PIECES_SHIFT, the pieces of the segment of a ribbon it starts; at SUN_SHIFT, whether the sun reaches a lit Mesh particle; above RIBBON_SHIFT, the ribbon it joins (0: that of its emitter)
}
#assert(size_of(Gpu_Particle)==64)
RIBBON_SHIFT :: 11
RIBBON_PIECES_SHIFT :: 3 // 4 bits
MESH_CHOICE_SHIFT :: 1 // 2 bits: which of the meshes of its emitter a Mesh particle shows (PARTICLE_MESHES of them)
SUN_SHIFT :: 7 // 1 bit: the sun reaches a lit Mesh particle, which shades it by its normal; its light is the rest

Gpu_Emitter :: struct {
    world,previous:[3][4]f32,
    range:[4]u32,       // first slot of the pool, capacity, births this frame, FLAG_*
    random:[4]u32,      // seed, event target slot+1 (0: none), particles per event, groups of births
    program:[4]u32,     // Vfx program (0: none), first slot of the drawn lists, 0, 0
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
    mesh:[4]u32,        // of Mesh particles: its meshes, Particle_Facing, 0; material row
    flipbook:[4]u32,    // columns, rows
    size_curve,size_times:[2][4]f32,
    gradient:[effect.PARTICLE_CURVE_KEYS][4]f32,
    gradient_times:[2][4]f32,
    spawns:[SPAWNS][4]u32, // count, per, birth, age (f32 bits)
    spacing:[2][4]f32,
    frame:[4]u32,       // in the rows of the frame: bytes to its resources (max(u32): none), from Gpu_Frame.births to its births, how many, 0
    data:[4]u32,        // bytes of the data buffer to the Attributes of its range, bytes of those of a particle, its age (f32 bits), particles it started
    mesh_weights:[effect.PARTICLE_MESHES]f32,  // of Mesh particles: the weights of its meshes added up, the last 1
    from_world:[3][4]f32,
    emitter_uid:[2]u32,
    birth_limit:f32,
    ribbon_axis:u32,    // effect.Particle_Ribbon_Axis
    beam:[4]f32,
    mesh_handles:[effect.PARTICLE_MESHES]u32, // and the meshes, whose indices the frame lists (erender.frame_mesh_whole)
    scale:[4]f32,       // of every particle (effect.particle_scale); w: metres a ribbon repeats its texture over, 0 once over its length
    ribbons:[2][4]u32,  // the ribbon each group of births joins
    light:[4]f32,       // of effect.Particle_Light: its color (0: that of each particle), intensity (cd)
    light_reach:[4]f32, // its range and radius (m), fraction (0: every particle), shares (erender.light_shares)
    light_limit:[4]u32, // lights of the emitter at once (0: as many as the world shows), 0, 0, 0
}
#assert(size_of(Gpu_Emitter)==1024)

// What the emitters of a frame share, first in its rows (particle_frame of particles.slang).
Gpu_Frame :: struct {
    step:[4]f32, // seconds of the frame, of each step, steps, and the time at the end of the frame
    births:u32,  // bytes of the rows of the frame to the births of the channels
    slots:u32,
    lights:u32,  // the most lights the particles give (Pool.light_capacity)
    pad:u32,
}
#assert(size_of(Gpu_Frame)==32)

// A mesh a Mesh particle can show: the mesh of the scene and its weight, the
// weights before it added.
Mesh_Choice :: struct {
    handle:erender.Mesh_Handle,
    weight:f32,
}

// Per emitter on the GPU: counters and its draw.
Gpu_State :: struct {
    dead,alive:u32, // free slots on its list, and particles on the one drawn
    births,born:u32, // of an emitter whose program gives its births: those of the frame, and all it started
    draw:[5]u32,    // indexed sprite draw
    live_count:[2]u32,
    lights:u32,     // lights its particles gave this frame, also those left out
    drained:[2]u32,
}

Gpu_Event :: struct {
    position:[3]f32, target:u32, // relative to the origin of the pool
    velocity:[3]f32, color:u32,
    ribbon:u32,          // that the particles it starts join: one of the particle that made it
}
#assert(size_of(Gpu_Event)==36)

// Events contains the event queues, mesh draws and indirect work lists.
Pool_Buffer :: enum u8 {Particles,Lists,State,Events,Data,Emitters}

EVENTS_AT :: 256 // bytes of the events buffer before the events
MESH_DRAWS_AT :: EVENTS_AT+2*EVENT_CAPACITY*size_of(Gpu_Event)
WORK_AT :: 1245440
SORT_AT :: 1253648
#assert(WORK_AT==MESH_DRAWS_AT+EMITTER_CAPACITY*effect.PARTICLE_MESHES*size_of(Mesh_Draw))
#assert(SORT_AT==WORK_AT+16+EMITTER_CAPACITY*8)
// The lights the particles give (FLAG_LIGHT), as the renderer takes them
// (erender.pass_dynamic_lights_copy): a header, then a Gpu_Light each.
LIGHTS_AT :: 1257760
LIGHT_BYTES :: 80
#assert(LIGHTS_AT==SORT_AT+16+EMITTER_CAPACITY*4 && LIGHTS_AT%16==0)
DRAIN_READBACK :: "vfx drained emitters"

pool_buffer :: proc "contextless" (pool:^Pool,b:Pool_Buffer) -> erender.Buffer_Desc {
    count:=u64(max(pool.capacity,1))
    switch b {
    case .Particles: return {"vfx particles",count*size_of(Gpu_Particle)}
    case .Lists:     return {"vfx particle lists",5*count*size_of(u32)}
    case .State:     return {"vfx particle state",EMITTER_CAPACITY*size_of(Gpu_State)}
    case .Events:    return {"vfx particle events",LIGHTS_AT+(1+erender.DYNAMIC_LIGHTS_MAX)*LIGHT_BYTES}
    case .Data:      return {particle_data_name(pool.data_side),pool.data_bytes}
    case .Emitters:  return {"vfx particle emitters",EMITTER_CAPACITY*size_of(Gpu_Emitter)}
    }
    return {}
}

// Parameters and emitter state, then draw records; the attribute arena follows these.
@(private)
pool_data_bytes :: proc "contextless" (capacity:u32) -> u64 {
    return ATTRIBUTES_AT+u64(max(capacity,1))*DRAW_LOOK_BYTES
}

@(private)
Pool_Slot :: struct {
    order_at:int,
    id:u64,
    offset,capacity:u32,
    attributes,stride:u32, // bytes of the Attributes of the pool to those of its range, and of each particle
    generation:u32,
    live,fresh,draining:bool,
    uid:u64,
    bounds_min,bounds_max:[3]f32,
    unbounded:bool,
    bound_scale:[3]f32,
    program_dirty,look_dirty:bool,
    structure:Emitter_Structure,
    desc:Emitter_Desc,
}

// What of an emitter decides the spans of the programs and the kinds of the
// frame (pool_kinds, programs_find): another one groups the pool again. Values
// that change alone, as a parameter a game animates, only write its row again.
@(private)
Emitter_Structure :: struct {
    program:u32,
    births,prepare:bool,
    render:effect.Particle_Render,
    blended,mixed:bool,
    view:erender.Texture_Handle,
    event_target:u64,
    material:erender.Material_Handle,
    mesh_count:u32,
    meshes:[effect.PARTICLE_MESHES]Mesh_Choice,
    lights:bool, // its particles give lights (emitter_lights): the frame asks for them, Light layers first
}

@(private)
emitter_structure :: proc "contextless" (d:^Emitter_Desc) -> Emitter_Structure {
    return {
        program=d.program.id,births=d.program.births,prepare=d.program.prepare,render=d.info.render,
        blended=d.blended,mixed=d.mixed,view=d.view,event_target=d.event_target,material=d.material,
        mesh_count=d.mesh_count,meshes=d.meshes,lights=emitter_lights(d),
    }
}

// A bit for each slot of the pool.
@(private)
Slot_Bits :: [EMITTER_CAPACITY/64]u64

@(private)
bits_add :: proc "contextless" (bits:^Slot_Bits,at:int) {bits[at/64]|=u64(1)<<(uint(at)%64)}

@(private)
bits_has :: proc "contextless" (bits:^Slot_Bits,at:int) -> bool {return bits[at/64]&(u64(1)<<(uint(at)%64))!=0}

// The next slot of bits from at on, below end, for a `for`; at goes past it.
@(private)
bits_next :: proc "contextless" (bits:^Slot_Bits,at:^int,end:int) -> (slot:int,ok:bool) {
    for at^<end {
        word:=bits[at^/64]>>(uint(at^)%64)
        if word==0 {
            at^=(at^/64+1)*64
            continue
        }
        slot=at^+int(intrinsics.count_trailing_zeros(word))
        if slot>=end {break}
        at^=slot+1
        return slot,true
    }
    at^=end
    return
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
    made_count:u64,          // times its tables were made: whoever puts its emitters puts them all again when it changes
    slots:[]Pool_Slot,
    order:[]u16,             // live slots
    by_id:base.Hash_Map(u16),
    order_count:int,
    free:base.Ranges,           // the slots of the pool the emitters' ranges take
    data_bytes,data_limit:u64,
    data_side:u8,
    retire_data:bool,
    attribute_free:base.Ranges, // the bytes of the Attributes of the pool their ranges take
    slot_end:int,            // slots ever used, live or not
    next_uid:u64,
    drains:int,
    frame_slots:[]u32,
    pool_end:u32,            // end of the pool in use
    regroup:bool,            // a range, a program, an event target or how an emitter is drawn changed since the spans of the programs were found
    dt:f32,                  // simulated by the next frame: every frame given since the last one that simulated adds its seconds
    gravity_reach,wind_reach:f32, // m/s2 and m/s: the strongest gravity and wind of the fields of the world, which the boxes of the emitters take
    added:f32,               // seconds the last frame given added
    drawn:bool,              // a frame simulated the particles since the last one given
    still:bool,              // the emitters of the world keep their particles as they are: effect views play alone
    frame:u64,               // frames given
    step:u64,                // steps simulated: the half of the events each one writes
    made:bool,               // the buffers have the size of capacity
    origin:[3]f32,           // what the places its buffers keep are relative to: the origin of the renderer when they last moved
    left_out:core.Entity,    // the views draw none of its emitters: an audit counts the pixels they drew; NONE: none is left out
    gpu:[]Gpu_Emitter,       // the rows of the table of emitters, as the GPU has them once those of dirty are written
    frame_bytes:[dynamic]u8, // header, grids, volumes, resources, stages and channel births
    draws:[]Pool_Draw,
    pending:Slot_Bits,       // slots put since the last frame simulated: their births add up
    dirty:Slot_Bits,         // slots whose rows are built and written again
    meshed:[]u16,            // live slots whose Mesh particles the G-buffer draws, mesh_count of them
    mesh_count:int,
    // What the live emitters ask, found with the spans of the programs.
    sprites,meshes:bool,     // some draws them
    views:bool,              // some draws into an effect view
    lights:bool,             // the particles of some give lights
    light_layers:bool,       // and some of those are of a Light layer, whose lights come first
    light_capacity:u32,      // of the frame: the most lights its particles give (Particle_Settings.max_lights)
    // Of the frame, from pool_prepare.
    resources:erender.Pass_Rows,
    rows_frame:u64,          // the frame whose rows they are; 0: none
    rows_origin:[3]f32,      // the origin of the renderer the rows are relative to
    steps:u32,
    needs_reset,needs_clock:bool,
    grids_at:u32,            // bytes of the rows of the frame to those of the grids
    bones_at:u32,            // and to the bones of the frame
    volumes_at:u32,          // and to those of the volumes
    volume_count:u32,
    volume_cells:u32,        // the most cells of a volume
    stage_count:u32,         // stages of the emitter that has the most
    plan:[erender.PROGRAM_STAGES]Stage_Plan,
}

// Makes the tables of a pool for a capacity: none of its particles stays.
// False without memory, and the pool has none.
pool_make :: proc(pool:^Pool,capacity:u32,allocator:=context.allocator) -> bool {
    previous,refused,made,uid:=pool.capacity,pool.refused,pool.made_count,pool.next_uid
    pool_free(pool,allocator)
    pool^={capacity=capacity,previous=previous,refused=refused,made_count=made+1,next_uid=uid,
        data_bytes=pool_data_bytes(capacity),data_limit=u64(max(u32))}
    pool.frame_bytes.allocator=allocator
    errors:[6]runtime.Allocator_Error
    pool.slots,errors[0]=make([]Pool_Slot,EMITTER_CAPACITY,allocator)
    pool.order,errors[1]=make([]u16,EMITTER_CAPACITY,allocator)
    pool.gpu,errors[2]=make([]Gpu_Emitter,EMITTER_CAPACITY,allocator)
    pool.draws,errors[3]=make([]Pool_Draw,EMITTER_CAPACITY,allocator)
    pool.meshed,errors[4]=make([]u16,EMITTER_CAPACITY,allocator)
    pool.frame_slots,errors[5]=make([]u32,EMITTER_CAPACITY,allocator)
    indexed:=base.hash_map_init(&pool.by_id,EMITTER_CAPACITY,allocator)
    starved:=!indexed || !base.ranges_reset(&pool.free,u64(capacity),EMITTER_CAPACITY,allocator) || !base.ranges_reset(&pool.attribute_free,0,2*EMITTER_CAPACITY,allocator)
    for error in errors {starved||=error!=nil}
    if starved {
        pool_free(pool,allocator)
        return false
    }
    return true
}

pool_free :: proc(pool:^Pool,allocator:=context.allocator) {
    for at in pool.order[:pool.order_count] {emitter_info_drop(pool.slots[at].desc.spec)}
    delete(pool.slots,allocator);delete(pool.order,allocator);delete(pool.gpu,allocator);delete(pool.draws,allocator);delete(pool.meshed,allocator)
    delete(pool.frame_slots,allocator)
    base.hash_map_destroy(&pool.by_id)
    base.ranges_free(&pool.free);base.ranges_free(&pool.attribute_free)
    delete(pool.frame_bytes)
    pool^={capacity=pool.capacity,previous=pool.previous,refused=pool.refused,made_count=pool.made_count,next_uid=pool.next_uid}
}

// The next frame of the pool of a world, and the seconds it adds to what the
// next simulating frame simulates. The pool is made when the world wants one
// (it has emitters) and has none, and made again, without its particles, for
// another capacity; one more than max_bytes binds, or that the device refused
// before, leaves the pool as it was. still: the emitters of the world keep
// their particles as they are, and only those of effect views move. False
// when the world wants a pool and has none.
pool_frame :: proc(pool:^Pool,dt:f32,capacity:u32,max_bytes:u64,still,wanted:bool,allocator:=context.allocator) -> bool {
    if pool.slots==nil && !wanted {return true}
    if pool.slots==nil || pool.capacity!=capacity && capacity!=pool.refused {
        if pool_data_bytes(capacity)>min(max_bytes,u64(max(u32))) {
            pool.refused=capacity
            if pool.slots==nil {return false}
        } else if !pool_make(pool,capacity,allocator) {return false}
    }
    pool.data_limit=min(max_bytes,u64(max(u32)))
    pool.frame+=1
    pool.added=clamp(dt,0,FRAME_MAX)
    // What waits for a frame that simulates grows older by the seconds of this one.
    if !pool.drawn {
        at:=0
        for slot in bits_next(&pool.pending,&at,pool.slot_end) {
            d:=&pool.slots[slot].desc
            spawns_join(&d.spawns,d.spawns,{},pool.added)
        }
    }
    pool.dt=clamp(((pool.drawn || pool.order_count==0)?0:pool.dt)+pool.added,0,FRAME_MAX)
    pool.drawn=false
    if still!=pool.still {
        pool.still=still
        pool_dirty_all(pool)
    }
    return true
}

// An emitter of the pool as it is now, for the next frame that simulates:
// a new id takes a range (first free gap; freed gaps join their neighbors)
// and starts empty, and so does one that changes capacity, Attributes or
// generation. Its row is built and written again. False when it found no room
// in the pool or the table of emitters: it is left out.
pool_put :: proc(pool:^Pool,desc:^Emitter_Desc) -> bool {
    if pool.slots==nil || desc.spec==nil {return false}
    slot_at:=pool_slot_find(pool,desc.id)
    capacity:=desc.capacity
    stride:=(desc.program.attributes+15)&~u32(15)
    if slot_at>=0 && (pool.slots[slot_at].draining || pool.slots[slot_at].capacity!=capacity || pool.slots[slot_at].stride!=stride || pool.slots[slot_at].generation!=desc.generation) {
        pool_slot_release(pool,slot_at)
        slot_at=-1
    }
    if slot_at<0 {
        if slot_at=pool_slot_take(pool,desc.id,capacity,stride);slot_at<0 {return false}
        pool.slots[slot_at].generation=desc.generation
    }
    slot:=&pool.slots[slot_at]
    before:=&slot.desc
    if before.spec!=desc.spec || before.look!=desc.look {
        if before.spec!=desc.spec {
            emitter_info_keep(desc.spec)
            emitter_info_drop(before.spec)
        }
        slot.look_dirty=true
        slot.program_dirty=desc.program.id!=0
    }
    if structure:=emitter_structure(desc);structure!=slot.structure {
        slot.structure=structure
        pool.regroup=true
        slot.look_dirty=true
    }
    if bits_has(&pool.pending,slot_at) {
        spawns:=slot.desc.spawns
        previous:=slot.desc.previous
        slot.desc=desc^
        slot.desc.previous=previous
        spawns_join(&slot.desc.spawns,spawns,desc.spawns,0)
    } else {slot.desc=desc^}
    emitter_bounds(pool,slot)
    bits_add(&pool.pending,slot_at)
    bits_add(&pool.dirty,slot_at)
    return true
}

// The emitter of an id leaves the pool with its particles; nothing without one.
pool_remove :: proc(pool:^Pool,id:u64) {
    if at:=pool_slot_find(pool,id);at>=0 {pool_slot_release(pool,at)}
}

// Every row of the table is built and written again.
@(private)
pool_orphan :: proc(pool:^Pool,id:u64) {
    at:=pool_slot_find(pool,id)
    if at<0 {return}
    slot:=&pool.slots[at]
    if slot.fresh || slot.desc.info.local_space {pool_slot_release(pool,at);return}
    if slot.draining {return}
    slot.draining=true
    pool.drains+=1
    slot.desc.spawns,slot.desc.births,slot.desc.event_target={}, {}, 0
    slot.desc.resources,slot.desc.stages=0,0
    slot.look_dirty=true
    slot.desc.paused=false
    bits_add(&pool.dirty,at)
    pool.regroup=true
}

@(private)
pool_drain :: proc(pool:^Pool,renderer:^erender.Renderer,world:core.World_Id) {
    if pool.drains==0 {return}
    data,_,ok:=erender.readback(renderer,world,DRAIN_READBACK)
    if !ok || len(data)!=EMITTER_CAPACITY*size_of(Gpu_State) {return}
    rows:=([^]Gpu_State)(raw_data(data))
    for at in 0..<pool.slot_end {
        slot:=&pool.slots[at]
        if !slot.live || !slot.draining {continue}
        stamp:=rows[at].drained
        if slot.uid==u64(stamp[0]) | u64(stamp[1])<<32 {pool_slot_release(pool,at)}
    }
    if pool.drains==0 {erender.readback_release(renderer,world,DRAIN_READBACK)}
}

@(private)
pool_dirty_all :: proc(pool:^Pool) {
    for at in 0..<pool.slot_end {bits_add(&pool.dirty,at)}
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
        // The pair that spans the least time joins, one of a ribbon before two of two.
        best,span,apart:=0,f32(max(f32)),true
        for i in 0..<count-1 {
            s:=abs(spawn_oldest(all[i])-spawn_youngest(all[i+1]))
            split:=all[i].ribbon!=all[i+1].ribbon
            if !split && apart || split==apart && s<span {best,span,apart=i,s,split}
        }
        a,b:=all[best],all[best+1]
        oldest:=max(spawn_oldest(a),spawn_oldest(b))
        youngest:=min(spawn_youngest(a),spawn_youngest(b))
        total:=a.count+b.count
        all[best]={count=total,per=1,birth=a.birth,age=oldest,spacing=total>1?(oldest-youngest)/f32(total-1):0,ribbon=a.ribbon}
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
    if slot,found:=base.hash_map_get(&p.by_id,id);found {return int(slot)}
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
        if attributes,fits=pool_data_take(p,bytes);!fits {
            base.ranges_give(&p.free,offset,u64(capacity))
            return -1
        }
    }
    at:=-1
    for slot,i in p.slots[:p.slot_end] {
        if !slot.live {at=i;break}
    }
    if at<0 {at=p.slot_end;p.slot_end+=1}
    if !base.hash_map_set(&p.by_id,id,u16(at)) {
        base.ranges_give(&p.free,offset,u64(capacity))
        base.ranges_give(&p.attribute_free,attributes,bytes)
        return -1
    }
    p.next_uid+=1
    p.slots[at]={order_at=p.order_count,id=id,uid=p.next_uid,offset=u32(offset),capacity=capacity,attributes=u32(attributes),stride=stride,live=true,fresh=true}
    p.pool_end=max(p.pool_end,u32(offset)+capacity)
    p.regroup=true
    p.order[p.order_count]=u16(at)
    p.order_count+=1
    return at
}

pool_slot_release :: proc(p:^Pool,at:int) {
    slot:=&p.slots[at]
    emitter_info_drop(slot.desc.spec)
    slot.desc.spec=nil
    base.hash_map_remove(&p.by_id,slot.id)
    p.order_count-=1
    swapped:=p.order[p.order_count]
    p.order[slot.order_at]=swapped
    p.slots[swapped].order_at=slot.order_at
    base.ranges_give(&p.free,u64(slot.offset),u64(slot.capacity))
    base.ranges_give(&p.attribute_free,u64(slot.attributes),u64(slot.capacity)*u64(slot.stride))
    if slot.draining {p.drains-=1}
    slot.live=false
    p.pending[at/64]&~=u64(1)<<(uint(at)%64)
    bits_add(&p.dirty,at)
    p.regroup=true
    for p.slot_end>0 && !p.slots[p.slot_end-1].live {p.slot_end-=1}
    p.pool_end=p.capacity
    if n:=len(p.free.free);n>0 {
        tail:=p.free.free[n-1]
        if tail.offset+tail.size==u64(p.capacity) {p.pool_end=u32(tail.offset)}
    }
}

// The rows of a transform of the world, its place relative to origin.
@(private)
rows_of :: proc "contextless" (m:matrix[4,4]f32,origin:[3]f32) -> [3][4]f32 {
    return erender.origin_to_world(mm.mat4_rows(m),origin)
}

// The rows of the frame, uploaded once for its passes, the steps it takes and
// the rows of the table of emitters built again where they changed (dirty),
// which pool_rows_write writes. What an emitter starts stays until a frame
// simulates it. reset: every range starts again (the buffers of the pool were
// made anew).
@(private)
pool_prepare :: proc(sync:^Particle_Sync,pass:^erender.Pass,reset:bool) -> bool {
    pool:=&sync.pool
    if pool.rows_frame==pass.frame && !reset {return true}
    pool.steps=0
    pool.needs_reset,pool.needs_clock=false,false
    pool.stage_count,pool.plan=0,{}
    if pool.slot_end==0 {return false}
    if reset {
        for &s,at in pool.slots[:pool.slot_end] {
            if !s.live {continue}
            s.fresh,s.program_dirty,s.look_dirty=true,s.desc.program.id!=0,true
            bits_add(&pool.pending,at)
        }
    }
    // The rows are relative to the origin of the renderer: where it moved, all of them are built again.
    if reset || pass.origin!=pool.rows_origin {pool_dirty_all(pool)}
    pool.rows_origin=pass.origin
    header:Gpu_Frame
    bytes:=size_of(Gpu_Frame)
    bytes+=len(sync.grids.entries)*(size_of(Gpu_Grid)+size_of(Gpu_Volume))
    if len(sync.resources)>=RESOURCE_ROWS {bytes+=pool.order_count*RESOURCE_ROWS*size_of(Gpu_Resource)}
    bytes+=len(sync.bones)*size_of(Gpu_Bone)
    if len(sync.stage_rows)>=erender.PROGRAM_STAGES {
        bytes+=pool.order_count*erender.PROGRAM_STAGES*size_of(Gpu_Stage)
    }
    bytes+=len(sync.births)*size_of(Gpu_Birth)+pool.order_count*size_of(u32)
    if reserve(&pool.frame_bytes,bytes)!=nil {return false}
    clear(&pool.frame_bytes)
    append(&pool.frame_bytes,..([^]u8)(&header)[:size_of(header)])
    // The grids: the resources that read them name their bytes.
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
    // The skeletons the resources read, once each.
    pool.bones_at=u32(len(pool.frame_bytes))
    for bone in sync.bones {
        row:=bone
        row.position=erender.origin_point(bone.position,pass.origin)
        append(&pool.frame_bytes,..([^]u8)(&row)[:size_of(row)])
    }
    pool.steps=u32(clamp(math.ceil(pool.dt/STEP),1,STEPS))
    header.step={pool.dt,pool.dt/f32(pool.steps),f32(pool.steps),pass.time}
    header.lights=pool.light_capacity
    // An emitter that is not dirty starts nothing, reads nothing of the frame
    // and is not new: what each frame gives is in the rows of the dirty ones.
    at:=0
    for slot in bits_next(&pool.dirty,&at,pool.slot_end) {
        g,s:=&pool.gpu[slot],&pool.slots[slot]
        if !s.live {g^={};continue}
        d:=&s.desc
        flags:=u32(FLAG_ACTIVE)
        if s.fresh {flags|=FLAG_RESET;pool.needs_reset=true}
        if d.info.local_space {flags|=FLAG_LOCAL}
        if d.info.lit && d.info.render!=.Light {flags|=FLAG_LIT}
        if d.info.sort || d.info.render==.Ribbon {flags|=FLAG_SORT}
        // While an effect view plays alone, the emitters of the world keep their particles as they are.
        if d.paused || pool.still && d.view==0 {flags|=FLAG_PAUSED}
        // A Mesh particle blends as its material says.
        if d.info.render!=.Mesh && d.info.blend==.Additive {flags|=FLAG_ADDITIVE}
        if d.info.render!=.Mesh && d.info.blend==.Multiply {flags|=FLAG_MULTIPLY}
        if d.info.emission_mode==.Relative {flags|=FLAG_RELATIVE}
        if pool.light_capacity>0 && emitter_lights(d) {flags|=FLAG_LIGHT}
        // The places of an emitter of an effect view are of that view.
        origin:=pass.origin
        if d.view!=0 {flags|=FLAG_VIEW;origin={}}
        if d.program.moves {flags|=FLAG_MOVED}
        if d.program.births && !s.draining {flags|=FLAG_BIRTHS}
        if d.program.prepare && !s.draining {flags|=FLAG_PREPARE}
        if s.draining {flags|=FLAG_DRAIN}
        if s.look_dirty {emitter_row(g,s,pool.capacity)}
        spawn,groups:=u32(0),u32(0)
        for group in d.spawns {
            if group.count==0 {continue}
            g.spawns[groups]={group.count,max(group.per,1),group.birth,transmute(u32)group.age}
            g.spacing[groups/4][groups%4]=group.spacing
            g.ribbons[groups/4][groups%4]=group.ribbon if d.info.render==.Ribbon else 0
            spawn+=group.count
            groups+=1
        }
        for i in groups..<SPAWNS {g.spawns[i]={};g.spacing[i/4][i%4]=0;g.ribbons[i/4][i%4]=0}
        // More than a few times its capacity cannot start: the rest would find no slot.
        spawn=min(spawn,s.capacity*4)
        pool.needs_clock||=spawn>0
        target:=u32(0)
        if d.event_target!=0 {
            if t:=pool_slot_find(pool,d.event_target);t>=0 {target=u32(t)+1}
        }
        g.world=rows_of(d.transform,origin)
        g.previous=rows_of(d.previous,origin)
        if d.info.local_space {
            pose:=d.transform
            pose[0,3],pose[1,3],pose[2,3]=g.world[0].w,g.world[1].w,g.world[2].w
            if math.abs(linalg.determinant(pose))>=1e-12 {
                g.from_world=rows_of(linalg.inverse(pose),{})
            } else {
                g.from_world={{1,0,0,-g.world[0].w},{0,1,0,-g.world[1].w},{0,0,1,-g.world[2].w}}
            }
        }
        g.range={s.offset,s.capacity,spawn,flags}
        g.random.y,g.random.w=target,groups
        g.frame={max(u32),d.births.x*size_of(Gpu_Birth),d.births.y,max(u32)}
        g.data.z,g.data.w=transmute(u32)d.age,d.born
        g.birth_limit=d.birth_limit if d.owner!=core.NONE else max(f32)
        g.flipbook.zw={}
        if d.resources>0 && int(d.resources-1)+RESOURCE_ROWS<=len(sync.resources) {
            resources:=sync.resources[d.resources-1:][:RESOURCE_ROWS]
            count:=len(resources)
            for count>0 && resources[count-1].kind==.None {count-=1}
            if count>0 {g.frame.x=u32(len(pool.frame_bytes))}
            g.flipbook.z=u32(count)
            for &resource in resources[:count] {
                row:=Gpu_Resource{world=rows_of(resource.transform,origin),previous=rows_of(resource.previous,origin)}
                switch resource.kind {
                case .None:
                case .Surface:
                    if first,placed:=surface_place(&sync.surfaces,resource.mesh,resource.triangles,pool.frame);placed {
                        row.head={u32(Resource_Kind.Surface),u32(resource.mesh),first+size_of(Gpu_Fields)/4,resource.triangles}
                    }
                case .Channel: row.head={u32(Resource_Kind.Channel),0,resource.first,resource.count}
                case .Grid:
                    if int(resource.first)<len(sync.grids.entries) {
                        row.head={u32(Resource_Kind.Grid),pool.grids_at+resource.first*size_of(Gpu_Grid),0,0}
                    }
                case .Bones:
                    // Of no place in an effect view.
                    if d.view==0 && int(resource.first+resource.count)<=len(sync.bones) {
                        row.head={u32(Resource_Kind.Bones),pool.bones_at+resource.first*size_of(Gpu_Bone),0,resource.count}
                    }
                case .Transform:
                    if d.view==0 {row.head={u32(Resource_Kind.Transform),0,0,0}}
                }
                append(&pool.frame_bytes,..([^]u8)(&row)[:size_of(row)])
            }
            // Its stages after its resources, and what each stage index runs.
            if d.stages>0 && int(d.stages-1)+erender.PROGRAM_STAGES<=len(sync.stage_rows) {
                stages:=sync.stage_rows[d.stages-1:][:erender.PROGRAM_STAGES]
                count:=len(stages)
                for count>0 && stages[count-1].kind==0 {count-=1}
                stages=stages[:count]
                if count>0 {g.frame.w=u32(len(pool.frame_bytes))}
                g.flipbook.w=u32(count)
                append(&pool.frame_bytes,..([^]u8)(raw_data(stages))[:len(stages)*size_of(Gpu_Stage)])
                for stage,k in stages {
                    plan:=&pool.plan[k]
                    for resource in 0..<u32(RESOURCES) {
                        if stage.writes&(1<<resource)==0 {continue}
                        grid:=sync.resources[d.resources-1+1+resource]
                        if grid.kind==.Grid {
                            plan.writes=true
                            sync.grids.entries[grid.first].texture_dirty=true
                        }
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
                        sync.grids.entries[grid.first].texture_dirty=true
                    }
                    pool.stage_count=max(pool.stage_count,u32(k)+1)
                }
            }
        }
    }
    // The births of the channels after the resources; each emitter finds those of its channel from them.
    header.births=u32(len(pool.frame_bytes))
    for birth in sync.births {
        row:=birth
        row.position=erender.origin_point(birth.position,pass.origin)
        append(&pool.frame_bytes,..([^]u8)(&row)[:size_of(row)])
    }
    header.slots=u32(len(pool.frame_bytes))
    append(&pool.frame_bytes,..([^]u8)(raw_data(pool.frame_slots[:]))[:pool.order_count*size_of(u32)])
    (^Gpu_Frame)(raw_data(pool.frame_bytes))^=header
    resources,ok:=erender.pass_rows_upload(pass,raw_data(pool.frame_bytes),len(pool.frame_bytes))
    if !ok {return false}
    pool.resources,pool.rows_frame=resources,pass.frame
    return true
}

// Writes the dirty rows of the table of emitters, in runs of neighbors, and
// the parameters of the programs that changed, outside a render pass. A row
// that could not be written stays dirty.
@(private)
pool_rows_write :: proc(sync:^Particle_Sync,pass:^erender.Pass) -> bool {
    pool:=&sync.pool
    emitters,data:=pool_buffer(pool,.Emitters),pool_buffer(pool,.Data)
    at:=0
    for first in bits_next(&pool.dirty,&at,pool.slot_end) {
        end:=first+1
        for end<pool.slot_end && bits_has(&pool.dirty,end) {end+=1}
        at=end
        if !erender.pass_buffer_write(pass,emitters,u64(first)*size_of(Gpu_Emitter),&pool.gpu[first],(end-first)*size_of(Gpu_Emitter)) {return false}
        for slot in first..<end {
            s:=&pool.slots[slot]
            if s.live {s.look_dirty=false}
            if s.live && s.program_dirty {
                if !erender.pass_buffer_write(pass,data,u64(slot)*erender.PROGRAM_PARAMETER_BYTES,&s.desc.program.parameters,erender.PROGRAM_PARAMETER_BYTES) {return false}
                s.program_dirty=false
            }
            pool.dirty[slot/64]&~=u64(1)<<(uint(slot)%64)
        }
    }
    return true
}

// The row of an emitter but for what its frame gives.
@(private)
emitter_row :: proc(g:^Gpu_Emitter,s:^Pool_Slot,capacity:u32) {
    d,m:=&s.desc,&s.desc.info
    event:=m.trigger if d.event_target!=0 else .None
    g.random.x,g.random.z=u32(base.hash_combine(d.id,0x7061727469636c65)),min(m.sub_count,EVENT_SPAWN_MAX)
    g.program={d.program.id,capacity,0,u32(ATTRIBUTES_AT)}
    g.emitter_uid={u32(s.uid),u32(s.uid>>32)}
    g.shape={m.shape_size.x,m.shape_size.y,m.shape_size.z,m.shape_angle}
    g.kinds={u32(m.shape),u32(m.render),u32(m.collision),u32(event)}
    g.lifetime_speed={max(m.lifetime[0],0.001),max(m.lifetime[1],0.001),m.speed[0],m.speed[1]}
    g.size_rotation={m.size[0],m.size[1],m.rotation[0],m.rotation[1]}
    g.spin={m.spin[0],m.spin[1],clamp(m.shell,0,1),m.inherit_velocity}
    g.color_a,g.color_b=m.colors[0],m.colors[1]
    g.velocity_a={m.velocity[0].x,m.velocity[0].y,m.velocity[0].z,0}
    g.velocity_b={m.velocity[1].x,m.velocity[1].y,m.velocity[1].z,0}
    g.acceleration={m.acceleration.x,m.acceleration.y,m.acceleration.z,max(m.drag,0)}
    g.noise={m.noise,max(m.noise_frequency,0),m.noise_speed,m.gravity}
    // The particles of an effect view are of no place: they fall with GRAVITY.
    if d.view!=0 {g.acceleration.xyz+=GRAVITY*m.gravity;g.noise.w=0}
    g.collide={clamp(m.bounce,0,1),clamp(m.friction,0,1),clamp(m.collision_life,0,1),0}
    g.look={max(m.stretch,0),max(m.soft,0),m.intensity,max(m.flipbook_speed,0)}
    g.beam={m.beam_end.x,m.beam_end.y,m.beam_end.z,m.beam_arc}
    g.attractor={m.attractor.x,m.attractor.y,m.attractor.z,m.attractor_strength}
    g.mesh={d.mesh_count,u32(m.facing),0,u32(d.material)}
    scale:=effect.particle_scale(m)
    g.scale={scale.x,scale.y,scale.z,max(m.ribbon_tile,0)}
    g.ribbon_axis=u32(m.ribbon_axis)
    g.mesh_weights,g.mesh_handles={},{}
    for choice,c in d.meshes[:min(d.mesh_count,effect.PARTICLE_MESHES)] {g.mesh_weights[c],g.mesh_handles[c]=choice.weight,u32(choice.handle)}
    g.flipbook={max(m.flipbook[0],1),max(m.flipbook[1],1),0,0}
    size_count:=effect.particle_key_count(m.size_over_life.times[:])
    color_count:=effect.particle_key_count(m.color_over_life.times[:])
    for i in 0..<effect.PARTICLE_CURVE_KEYS {
        size_key,color_key:=min(i,size_count-1),min(i,color_count-1)
        g.size_curve[i/4][i%4]=m.size_over_life.values[size_key]
        g.size_times[i/4][i%4]=m.size_over_life.times[size_key]
        g.gradient[i]=m.color_over_life.colors[color_key]
        g.gradient_times[i/4][i%4]=m.color_over_life.times[color_key]
    }
    g.data.xy={u32(pool_data_bytes(capacity))+s.attributes,s.stride}
    light:=m.light
    g.light={max(light.color.r,0),max(light.color.g,0),max(light.color.b,0),max(light.intensity,0)}
    g.light_reach={max(light.range,0),max(light.radius,0),clamp(light.fraction,0,1),erender.light_shares(light.indirect,light.scattering)}
    g.light_limit={u32(light.max_lights),0,0,0}
}

// Whether the particles of an emitter give lights: those of a Light layer,
// whose program may give them, or of one whose light has an intensity and a
// range. Those of an effect view have no place in the world: none.
emitter_lights :: proc "contextless" (d:^Emitter_Desc) -> bool {
    return d.view==0 && (d.info.render==.Light || d.info.light.intensity>0 && d.info.light.range>0)
}

// What the passes of a world draw its particles with: the pipelines of the
// stages of the plugin, 0 while the shaders in use do not have them. They are
// asked again when the shaders are, or when the renderer takes another
// variant of a stage (the one particle_simulate gives changes).
Particle_Pipelines :: struct {
    shift,data_copy,begin,emit,simulate,finish,sort,mesh_draws,surface,stage,volume_light,world_texture,additive,alpha,multiply,volume:erender.Pipeline,
    groups:[dynamic]Program_Group, // first: emitters without a program
    by_program:map[u32]int,
    reloads:u64,
}

@(private)
Program_Group :: struct {
    program:u32,
    emit,simulate,stage,rebase:erender.Pipeline,
    cursor:u32,
    using span:Program_Span,
}

// What the live emitters ask of the frame, found again when they change: whether
// some draw sprites, meshes or into an effect view, or report, and the slots
// whose Mesh particles the G-buffer draws. The rows of those that start
// particles in another are built again: its slot may have moved.
@(private)
pool_kinds :: proc(pool:^Pool) {
    pool.sprites,pool.meshes,pool.views,pool.mesh_count=false,false,false,0
    pool.lights,pool.light_layers=false,false
    for at in pool.order[:pool.order_count] {
        s:=&pool.slots[at]
        d:=&s.desc
        pool.meshes||=d.info.render==.Mesh && !d.blended
        pool.sprites||=d.info.render!=.Mesh && d.info.render!=.Light || d.blended || d.mixed
        pool.views||=d.view!=0
        pool.lights||=emitter_lights(d)
        pool.light_layers||=emitter_lights(d) && d.info.render==.Light
        if d.info.render==.Mesh {
            pool.meshed[pool.mesh_count]=u16(at)
            pool.mesh_count+=1
        }
        if d.event_target!=0 {bits_add(&pool.dirty,int(at))}
    }
}

// Groups the frame slots and keeps one pipeline span per program in use.
@(private)
programs_find :: proc(sync:^Particle_Sync,renderer:^erender.Renderer,assets:^host.Assets) -> bool {
    pool:=&sync.pool
    p:=&sync.pipelines
    clear(&p.groups)
    clear(&p.by_program)
    if reserve(&p.groups,pool.order_count+1)!=nil {return false}
    append(&p.groups,Program_Group{emit=p.emit,simulate=p.simulate,stage=p.stage})
    for at in pool.order[:pool.order_count] {
        s:=&pool.slots[at]
        id:=s.desc.program.id
        index:=0
        if id!=0 {
            found:bool
            index,found=p.by_program[id]
            if !found {
                index=len(p.groups)
                if _,err:=map_insert(&p.by_program,id,index);err!=nil {return false}
                name:=base.text_get(s.desc.info.program[:])
                program:=erender.program_find(assets,name,.Vfx)
                each:=Program_Group{program=id}
                each.emit=erender.stage_pipeline(renderer,{stage=.Simulate,shader=fmt.tprintf("particle_emit__%s",name),name="particle emit"})
                each.simulate=erender.stage_pipeline(renderer,{stage=.Simulate,shader=fmt.tprintf("particle_simulate__%s",name),name="particle simulate"})
                each.rebase=erender.stage_pipeline(renderer,{
                    stage=.Geometry,shader=fmt.tprintf("particle_shift__%s",name),name="particle rebase",
                })
                if program!=nil && len(program.stages)>0 {
                    each.stage=erender.stage_pipeline(renderer,{stage=.Simulate,shader=fmt.tprintf("particle_stage__%s",name),name="particle stage"})
                }
                if each.emit==0 || each.simulate==0 {return false}
                if _,err:=append(&p.groups,each);err!=nil {return false}
            }
        }
        span:=&p.groups[index].span
        span.count+=1
        span.births||=!s.draining && s.desc.program.births
        span.prepare||=!s.draining && s.desc.program.prepare
    }
    for at in pool.order[:pool.order_count] {
        s:=&pool.slots[at]
        if s.desc.event_target==0 {continue}
        if target:=pool_slot_find(pool,s.desc.event_target);target>=0 {
            slot:=&pool.slots[target]
            slot.unbounded=true
            p.groups[p.by_program[slot.desc.program.id]].events=true
        }
    }
    next:u32
    for &group in p.groups {group.first=next;next+=group.count}
    // Light layers first in each group: their lights are written before the others.
    for layers in ([]bool{true,false}) {
        for at in pool.order[:pool.order_count] {
            d:=&pool.slots[at].desc
            if (emitter_lights(d) && d.info.render==.Light)!=layers {continue}
            group:=&p.groups[p.by_program[d.program.id]]
            pool.frame_slots[group.first+group.cursor]=u32(at)
            group.cursor+=1
            if layers {group.lights+=1}
        }
    }
    return true
}

// The pipelines of the frame, and its passes for the particles of a world.
// False while the shaders in use have no stages of the plugin.
particles_frame :: proc(sync:^Particle_Sync,app:^host.App,lights:=u32(PARTICLE_LIGHTS)) -> bool {
    pool:=&sync.pool
    if pool.regroup {pool_kinds(pool)}
    // The lights of the particles: the emitters that give them are told again when their number changes.
    if capacity:=min(lights,erender.DYNAMIC_LIGHTS_MAX);capacity!=pool.light_capacity {
        if (capacity==0)!=(pool.light_capacity==0) {pool_dirty_all(pool)}
        pool.light_capacity=capacity
    }
    if pool.lights && pool.light_capacity>0 && pool.slot_end>0 {erender.frame_dynamic_lights(app.renderer,pool.light_capacity)}
    if pool.retire_data {
        erender.buffer_release(app.renderer,sync.world_id,particle_data_name(pool.data_side~1))
        pool.retire_data=false
    }
    if pool.slot_end==0 {return true}
    p:=&sync.pipelines
    simulate:=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_simulate",name="particle simulate"})
    if simulate==0 {return false}
    if simulate!=p.simulate || p.reloads!=app.shaders.reloads {
        groups,by_program:=p.groups,p.by_program
        p^={reloads=app.shaders.reloads,groups=groups,by_program=by_program}
        p.data_copy=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_data_copy",name="particle data copy"})
        p.shift=erender.stage_pipeline(app.renderer,{stage=.Geometry,shader="particle_shift",name="particle shift"})
        p.begin=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_begin",name="particle begin"})
        p.emit=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_emit",name="particle emit"})
        p.finish=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_finish",name="particle finish"})
        p.mesh_draws=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_mesh_draws",name="particle mesh LOD"})
        p.sort=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_sort",name="particle sort"})
        p.surface=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_surface",name="particle surface"})
        p.stage=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_stage",name="particle stage"})
        p.volume_light=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_volume_light",name="particle volume light"})
        p.world_texture=erender.stage_pipeline(app.renderer,{stage=.Simulate,shader="particle_world_texture",name="particle world texture"})
        p.volume=erender.stage_pipeline(app.renderer,{stage=.Blend,shader="particle_volume",blend=.Premultiplied,name="particle volumes"})
        p.additive=erender.stage_pipeline(app.renderer,{stage=.Blend,shader="particle_sprite",blend=.Additive,name="particles additive"})
        p.alpha=erender.stage_pipeline(app.renderer,{stage=.Blend,shader="particle_sprite",blend=.Premultiplied,name="particles blended"})
        p.multiply=erender.stage_pipeline(app.renderer,{stage=.Blend,shader="particle_sprite",blend=.Multiply,name="particles multiplied"})
        if p.shift==0 || p.begin==0 || p.emit==0 || p.finish==0 || p.sort==0 || p.mesh_draws==0 || p.surface==0 || p.stage==0 || p.volume_light==0 || p.world_texture==0 || p.additive==0 || p.alpha==0 || p.multiply==0 || p.volume==0 {return false}
        p.simulate=simulate
        pool.regroup=true
    }
    if pool.regroup {
        if !programs_find(sync,app.renderer,app.assets) {return false}
        pool.regroup=false
    }
    // The vertices of the scene made again: so are the areas of its surfaces.
    if made:=erender.vertices_made(app.renderer);made!=sync.surfaces.vertices {
        sync.surfaces.vertices=made
        for &entry in sync.surfaces.entries {entry.built=false}
    }
    world_textures_make(sync,app.renderer)
    if pool.made {erender.frame_pass(app.renderer,.Geometry,particles_shift,sync)}
    erender.frame_pass(app.renderer,.Simulate,particles_simulate,sync)
    if sync.world_texture_count>0 || sync.world_shown.names!={} {erender.frame_pass(app.renderer,.Mask,world_textures_frame,sync)}
    erender.frame_pass(app.renderer,.Gbuffer,particles_meshes,sync)
    // The G-buffer of each view needs the targets those meshes write.
    for at in pool.meshed[:pool.mesh_count] {
        s:=&pool.slots[at]
        if s.desc.blended {continue}
        for choice in s.desc.meshes[:min(s.desc.mesh_count,effect.PARTICLE_MESHES)] {
            erender.frame_gbuffer_mesh(app.renderer,choice.handle,s.desc.material)
        }
    }
    erender.frame_pass(app.renderer,.Blend,particles_volumes,sync)
    erender.frame_pass(app.renderer,.Blend,particles_sprites,sync)
    if pool.views {erender.frame_pass(app.renderer,.Effect,particles_sprites,sync)}
    return true
}

// Binds the buffers of the pool at the slots of particles.slang. made: one
// of them was made now, so what the pool holds starts again.
@(private)
pool_bind :: proc(pass:^erender.Pass,pool:^Pool) -> (ok,made:bool) {
    slots:=[Pool_Buffer]u32{.Particles=0,.Emitters=1,.State=2,.Lists=3,.Events=5,.Data=9}
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
    if !pool_data_make(pool,pass,p.data_copy) {return}
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
    params:=Simulate_Params{emitters=u32(pool.slot_end),fields=0}
    erender.pass_rows(pass,4,pool.resources)
    if !world_prepare(sync,pass,&params) {return}
    if !pool_rows_write(sync,pass) {
        pool_dirty_all(pool)
        return
    }
    erender.pass_surface_read(pass,7,.Linear_Depth)
    erender.pass_surface_read(pass,8,.Normal)
    // An interval of the profiler per kind of pass, each to the next mark: those of the first
    // step, then the steps after it together.
    erender.pass_timestamp(pass,"particle begin")
    events:=pool_buffer(pool,.Events)
    all:=Program_Span{count=u32(pool.order_count)}
    programs:=p.groups[:]
    for step in 0..<pool.steps {
        if step==1 {erender.pass_timestamp(pass,"particle steps")}
        params.parity,params.step,params.last=u32(pool.step&1),step,u32(step+1==pool.steps)
        if g:=&sync.grids;len(g.entries)>0 {erender.pass_buffer_fill(pass,world_buffer(sync),u64(grids_base(sync)+g.splats),u64(g.bytes-g.splats))}
        params.mode,params.count=1,all.count
        erender.pass_pipeline(pass,p.begin)
        erender.pass_params(pass,&params,size_of(params))
        erender.pass_dispatch(pass,groups(all.count,64))
        if step==0 {
            if pool.needs_reset {particle_work(sync,pass,&params,all,.Reset,p.begin,0)}
            erender.pass_timestamp(pass,"particle emit")
            for group in programs {
                if !group.births && !group.prepare {continue}
                params.program=group.program
                particle_work(sync,pass,&params,group.span,.Prepare,group.emit,3)
            }
        }
        for group in programs {
            params.program=group.program
            if pool.needs_clock || group.births {particle_work(sync,pass,&params,group.span,.Emit,group.emit,0)}
            if len(sync.births)>0 {particle_work(sync,pass,&params,group.span,.Channel,group.emit,2)}
            if group.events {
                params.mode,params.program=1,group.program
                erender.pass_pipeline(pass,group.emit)
                erender.pass_params(pass,&params,size_of(params))
                erender.pass_dispatch_indirect(pass,events,u64(16+16*(1-params.parity)))
            }
        }
        if pool.stage_count>0 {
            if step==0 {erender.pass_timestamp(pass,"particle stage")}
            stages_step(sync,pass,&params)
        }
        if step==0 {erender.pass_timestamp(pass,"particle simulate")}
        for group in programs {
            particle_work(sync,pass,&params,group.span,.Alive,group.simulate,0)
        }
        pool.step+=1
    }
    // Late events join the surviving particles before the draw list is built.
    params.step=pool.steps
    params.mode=2
    erender.pass_pipeline(pass,p.begin)
    erender.pass_params(pass,&params,size_of(params))
    erender.pass_dispatch(pass,1)
    for group in programs {
        if !group.events {continue}
        params.program,params.mode=group.program,4
        erender.pass_pipeline(pass,group.emit)
        erender.pass_params(pass,&params,size_of(params))
        erender.pass_dispatch_indirect(pass,events,u64(16+16*params.parity))
    }
    params.parity~=1
    // What each particle shows, and the lights they give: those of Light layers first, in passes of their own.
    lights:=pool.lights && pool.light_capacity>0
    for group in programs {
        params.program=group.program
        span:=group.span
        if lights && pool.light_layers {
            if span.lights==0 {continue}
            span.count=span.lights
        }
        particle_work(sync,pass,&params,span,.Alive,group.simulate,1)
    }
    if lights && pool.light_layers {
        for group in programs {
            if group.count<=group.lights {continue}
            params.program=group.program
            span:=group.span
            span.first,span.count=span.first+span.lights,span.count-span.lights
            particle_work(sync,pass,&params,span,.Alive,group.simulate,1)
        }
    }
    erender.pass_timestamp(pass,"particle finish")
    erender.pass_pipeline(pass,p.finish)
    params.count=all.count
    erender.pass_params(pass,&params,size_of(params))
    erender.pass_counters(pass,9,"particles")
    erender.pass_dispatch(pass,groups(all.count,64))
    if lights {erender.pass_dynamic_lights_copy(pass,events,LIGHTS_AT,pool.light_capacity)}
    erender.pass_pipeline(pass,p.sort)
    params.mode=0
    erender.pass_params(pass,&params,size_of(params))
    erender.pass_buffer(pass,7,pool_buffer(pool,.Events))
    // Where the ribbons write how far along them each particle is: the counters took the slot.
    erender.pass_buffer(pass,9,pool_buffer(pool,.Data))
    erender.pass_dispatch_indirect(pass,events,SORT_AT)
    if pool.drains>0 {
        erender.pass_readback(pass,pool_buffer(pool,.State),0,{DRAIN_READBACK,u64(EMITTER_CAPACITY)*size_of(Gpu_State)})
    }
    volumes_light(sync,pass,&params)
    world_textures_write(sync,pass)
    // Started: a frame simulated without them moves what there is and starts
    // nothing, and the rows that told more say so again.
    at:=0
    for slot in bits_next(&pool.pending,&at,pool.slot_end) {
        s:=&pool.slots[slot]
        d:=&s.desc
        if s.fresh || d.spawns!={} || d.previous!=d.transform {bits_add(&pool.dirty,slot)}
        s.fresh=false
        d.spawns={}
        d.previous=d.transform
    }
    pool.pending={}
    pool.drawn=true
    pool.made=true
}

Work_Kind :: enum u32 {Reset, Prepare, Emit, Channel, Alive, Particles, Cells, Grid_Copy, Swap_Cells, Swap_Particles}

@(private)
particle_work :: proc(sync:^Particle_Sync,pass:^erender.Pass,params:^Simulate_Params,span:Program_Span,kind:Work_Kind,pipeline:erender.Pipeline,mode:u32) {
    params.mode,params.count,params.first,params.emitter_first=3,u32(kind),span.first,span.count
    erender.pass_pipeline(pass,sync.pipelines.begin)
    erender.pass_params(pass,params,size_of(params^))
    erender.pass_dispatch(pass,1)
    params.mode=mode
    erender.pass_pipeline(pass,pipeline)
    erender.pass_params(pass,params,size_of(params^))
    erender.pass_dispatch_indirect(pass,pool_buffer(&sync.pool,.Events),WORK_AT)
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
    for b in ([]Pool_Buffer{.Particles,.Lists,.State,.Events,.Data,.Emitters}) {
        if !erender.pass_buffer_held(pass,pool_buffer(pool,b)) {return}
    }
    if !pool_data_make(pool,pass,sync.pipelines.data_copy) || !pool_prepare(sync,pass,false) {return}
    if !pool_rows_write(sync,pass) {return}
    erender.pass_buffer(pass,0,pool_buffer(pool,.Particles))
    erender.pass_buffer(pass,1,pool_buffer(pool,.Emitters))
    erender.pass_buffer(pass,2,pool_buffer(pool,.State))
    erender.pass_buffer(pass,3,pool_buffer(pool,.Lists))
    erender.pass_buffer(pass,5,pool_buffer(pool,.Events))
    Params :: struct {shift:[4]f32,count,emitters,first,slot_plus_one:u32}
    shift:=pool.origin-pass.origin
    params:=Params{shift={shift.x,shift.y,shift.z,0},count=pool.pool_end,emitters=u32(pool.slot_end)}
    erender.pass_pipeline(pass,sync.pipelines.shift)
    if !erender.pass_params(pass,&params,size_of(params)) {return}
    erender.pass_dispatch(pass,groups(max(pool.pool_end,EVENT_CAPACITY),64),3)
    erender.pass_buffer(pass,9,pool_buffer(pool,.Data))
    for at in pool.order[:pool.order_count] {
        slot:=&pool.slots[at]
        if slot.fresh || slot.desc.view!=0 || slot.desc.program.id==0 {continue}
        pipeline:=sync.pipelines.groups[sync.pipelines.by_program[slot.desc.program.id]].rebase
        if pipeline==0 {continue}
        params.count,params.first,params.slot_plus_one=slot.capacity,slot.offset,u32(at)+1
        erender.pass_pipeline(pass,pipeline)
        if !erender.pass_params(pass,&params,size_of(params)) {continue}
        erender.pass_dispatch(pass,groups(slot.capacity,64))
    }
    pool.origin=pass.origin
}

@(private)
groups :: proc "contextless" (size,group:u32) -> u32 {return (size+group-1)/group}

// A box every particle of an emitter stays in, from its values: past its
// shape and its size, as far as its speed, the velocity its entity gives,
// its acceleration and the gravity and the wind of the world (pool.reach)
// take a particle over its life. Drag and collisions only slow a particle
// (a bounce turns it, which the sphere of the reach holds); the wind drag
// pulls toward is in the acceleration. Unbounded: an emitter whose program
// moves its particles, or whose particles start elsewhere (a surface, the
// births of a channel, the events of another).
@(private)
emitter_bounds :: proc(pool:^Pool,s:^Pool_Slot) {
    d,m:=&s.desc,&s.desc.info
    if s.unbounded {return}
    s.unbounded=d.external_positions || d.births.y>0 || d.program.id!=0 || m.shape==.Surface ||
        m.render==.Mesh && d.mesh_extent<=0
    if s.unbounded {return}
    life:=max(m.lifetime[0],m.lifetime[1],0)
    speed:=max(math.abs(m.speed[0]),math.abs(m.speed[1]))
    velocity:=[3]f32{}
    for i in 0..<3 {velocity[i]=max(math.abs(m.velocity[0][i]),math.abs(m.velocity[1][i]))}
    // A bound on the linear map, including nonuniform scale.
    axes:[3]f32
    for i in 0..<3 {
        axes[i]=linalg.length([3]f32{d.transform[0,i],d.transform[1,i],d.transform[2,i]})
    }
    if m.local_space && !s.fresh && linalg.length(axes-s.bound_scale)>1e-4 {
        s.unbounded=true
        return
    }
    s.bound_scale=axes
    rows:=rows_of(d.transform,{})
    scale:=max(linalg.length(rows[0].xyz),linalg.length(rows[1].xyz),
        linalg.length(rows[2].xyz),1)*1.733
    speed+=linalg.length(velocity)*scale
    now:=[3]f32{d.transform[0,3],d.transform[1,3],d.transform[2,3]}
    prev:=[3]f32{d.previous[0,3],d.previous[1,3],d.previous[2,3]}
    // What the motion of its entity gives a particle it starts, as particle_emit.comp gives it.
    speed+=math.abs(m.inherit_velocity)*linalg.length(now-prev)/max(pool.dt,1e-5)
    gravity:=max(pool.gravity_reach,linalg.length(GRAVITY))
    acceleration:=linalg.length(m.acceleration)+96*math.abs(m.noise)+math.abs(m.attractor_strength)+
        math.abs(m.gravity)*gravity+max(m.drag,0)*pool.wind_reach
    curve:=f32(1)
    for value in m.size_over_life.values {curve=max(curve,value)}
    scaled:=effect.particle_scale(m)
    size:=max(m.size[0],m.size[1])*curve*max(scaled.x,scaled.y,scaled.z)
    radius:=linalg.length(m.shape_size)*scale+(speed+acceleration*life)*life
    radius+=size*max(d.mesh_extent*scale,1)+(speed+acceleration*life)*m.stretch
    // A bounce can turn any velocity component into any other one.
    if m.render==.Beam {radius+=(linalg.length(m.beam_end)+abs(m.beam_arc))*scale}
    radius*=2
    if !(radius<=1e30) {s.unbounded=true;return}
    for axis in 0..<3 {
        low,high:=min(now[axis],prev[axis])-radius,max(now[axis],prev[axis])+radius
        if !s.fresh && !m.local_space {
            low,high=min(low,s.bounds_min[axis]),max(high,s.bounds_max[axis])
        }
        s.bounds_min[axis],s.bounds_max[axis]=low,high
    }
}

// The emitters this view draws, back to front where they blend.
@(private)
draw_list :: proc(pool:^Pool,pass:^erender.Pass,meshes:bool,view:erender.Texture_Handle=0) -> []Pool_Draw {
    count:=0
    frustum:=mm.frustum_from_matrix(pass.view_projection)
    for at in pool.order[:pool.order_count] {
        s:=&pool.slots[at]
        if s.desc.view!=view || s.desc.culled || s.desc.info.render==.Light || s.desc.owner==pool.left_out && pool.left_out!=core.NONE {continue}
        mesh:=s.desc.info.render==.Mesh
        if meshes && (!mesh || s.desc.blended) ||
            !meshes && mesh && !s.desc.blended && !s.desc.mixed {continue}
        origin:=pass.origin if view==0 else [3]f32{}
        if !s.unbounded {
            low:=erender.origin_point(s.bounds_min,origin)-pass.camera.position
            high:=erender.origin_point(s.bounds_max,origin)-pass.camera.position
            if !mm.frustum_overlaps_aabb(frustum,{low,high}) {continue}
        }
        place:=erender.origin_point({s.desc.transform[0,3],s.desc.transform[1,3],s.desc.transform[2,3]},origin)
        pool.draws[count]={u32(at),linalg.dot(place-pass.camera.position,pass.camera.forward)}
        count+=1
    }
    draws:=pool.draws[:count]
    if !meshes {slice.sort_by(draws,proc(a,b:Pool_Draw) -> bool {return a.distance>b.distance})}
    return draws
}

@(private)
mesh_draws_prepare :: proc(sync:^Particle_Sync,pass:^erender.Pass,draws:[]Pool_Draw) -> bool {
    count:=u32(0)
    slots:[EMITTER_CAPACITY]u32
    for draw in draws {
        if sync.pool.slots[draw.slot].desc.info.render!=.Mesh {continue}
        slots[count]=draw.slot
        count+=1
    }
    if count==0 {return true}
    erender.pass_buffer(pass,1,pool_buffer(&sync.pool,.Emitters))
    erender.pass_buffer(pass,5,pool_buffer(&sync.pool,.Events))
    erender.pass_pipeline(pass,sync.pipelines.mesh_draws)
    if !erender.pass_upload(pass,7,&slots,int(count)*size_of(u32)) ||
        !erender.pass_params(pass,&count,size_of(u32)) {return false}
    erender.pass_dispatch(pass,groups(count,64))
    return true
}

@(private)
view_sort :: proc(sync:^Particle_Sync,pass:^erender.Pass,draws:[]Pool_Draw) -> bool {
    pool:=&sync.pool
    slots:[EMITTER_CAPACITY]u32
    count:u32
    for draw in draws {
        info:=&pool.slots[draw.slot].desc.info
        if !info.sort || info.render==.Ribbon {continue}
        slots[count]=draw.slot
        count+=1
    }
    if count==0 {return true}
    for b in ([]Pool_Buffer{.Particles,.Emitters,.State,.Lists,.Events,.Data}) {
        binding:=#partial [Pool_Buffer]u32{.Particles=0,.Emitters=1,.State=2,.Lists=3,.Events=5,.Data=9}
        erender.pass_buffer(pass,binding[b],pool_buffer(pool,b))
    }
    erender.pass_pipeline(pass,sync.pipelines.sort)
    params:=Simulate_Params{mode=1}
    if !erender.pass_upload(pass,7,&slots,int(count)*size_of(u32)) ||
        !erender.pass_params(pass,&params,size_of(params)) {return false}
    erender.pass_dispatch(pass,count)
    return true
}

// Whether the pool of a world has buffers to draw from in this frame: the
// Simulate stage made them, and its rows are up.
@(private)
pool_drawable :: proc(pass:^erender.Pass,sync:^Particle_Sync) -> bool {
    pool:=&sync.pool
    if !pool.made || pool.slot_end==0 {return false}
    for b in ([]Pool_Buffer{.Particles,.Lists,.Data,.Emitters}) {
        if !erender.pass_buffer_held(pass,pool_buffer(pool,b)) {return false}
    }
    return erender.pass_buffer_held(pass,world_buffer(sync)) && erender.pass_buffer_held(pass,pool_buffer(pool,.State)) && pool_prepare(sync,pass,false)
}

// Binds the rows of the frame and the world buffer at the slots the passes
// of the pool read them from.
@(private)
pool_bind_frame :: proc(pass:^erender.Pass,sync:^Particle_Sync) {
    erender.pass_buffer(pass,1,pool_buffer(&sync.pool,.Emitters))
    erender.pass_rows(pass,4,sync.pool.resources)
    erender.pass_buffer(pass,6,world_buffer(sync))
}

// What the passes of the Simulate stage are told: their mode, the emitters
// and threads, the half of the events and the step, and of a stage, which
// and its iteration.
// first and emitter_first are the start and length of a range of frame slots.
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
    draws:=draw_list(pool,pass,false,view)
    if len(draws)==0 || !mesh_draws_prepare(sync,pass,draws) || !view_sort(sync,pass,draws) {return}
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
    erender.pass_buffer(pass,2,state)
    Params :: struct {emitter,pass,mesh,pad1:u32,media:erender.Media_Grid}
    for draw in draws {
        // The stage of its program, with the fragment of the Surface program of its material.
        desc:=&pool.slots[draw.slot].desc
        // A Mesh particle blends as its material says: an additive material gives its light
        // without alpha in the premultiplied blend.
        mesh:=desc.info.render==.Mesh
        stage:=erender.Stage_Pipeline_Desc{stage=.Blend,shader="particle_sprite",blend=.Premultiplied,name="particles blended"}
        if !mesh && desc.info.blend==.Additive {stage.blend,stage.name=.Additive,"particles additive"}
        if !mesh && desc.info.blend==.Multiply {stage.blend,stage.name=.Multiply,"particles multiplied"}
        if mesh {stage.shader,stage.fragment="particle_mesh_blend","particle_sprite"}
        params:=Params{emitter=draw.slot,pass=u32(pass.glass),media=media}
        if !mesh {
            stage.program=erender.pass_material_program(pass,desc.material)
            pipeline:=erender.pass_stage_pipeline(pass,stage)
            if pipeline==0 {continue}
            erender.pass_pipeline(pass,pipeline)
            erender.pass_params(pass,&params,size_of(params))
            erender.pass_draw_indexed_indirect(pass,state,u64(draw.slot)*size_of(Gpu_State)+u64(offset_of(Gpu_State,draw)))
            continue
        }
        for choice,c in desc.meshes[:min(desc.mesh_count,effect.PARTICLE_MESHES)] {
            programs:[MESH_PROGRAMS]u32
            count:=erender.pass_mesh_programs(pass,choice.handle,desc.material,programs[:])
            for program in programs[:min(count,len(programs))] {
                stage.program=program
                pipeline:=erender.pass_stage_pipeline(pass,stage)
                if pipeline==0 {continue}
                erender.pass_pipeline(pass,pipeline)
                params.mesh,params.pad1=u32(choice.handle),program if count>1 else max(u32)
                erender.pass_params(pass,&params,size_of(params))
                erender.pass_draw_indirect(pass,pool_buffer(pool,.Events),mesh_draw(draw.slot,u32(c)))
            }
        }
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
    shown:=draw_list(pool,pass,true)
    if len(shown)==0 || !mesh_draws_prepare(sync,pass,shown) {return}
    erender.pass_gbuffer_begin(pass,"particle meshes")
    erender.pass_pipeline(pass,pipeline)
    erender.pass_buffer(pass,0,pool_buffer(pool,.Particles))
    pool_bind_frame(pass,sync)
    erender.pass_buffer(pass,3,pool_buffer(pool,.Lists))
    erender.pass_buffer(pass,9,pool_buffer(pool,.Data))
    state:=pool_buffer(pool,.State)
    Params :: struct {emitter,program,mesh,pad1:u32}
    draws:=pool_buffer(pool,.Events)
    bound:=pipeline
    for draw in shown {
        desc:=&pool.slots[draw.slot].desc
        shader:="particle_mesh"
        for choice,c in desc.meshes[:min(desc.mesh_count,effect.PARTICLE_MESHES)] {
            // A draw for each Surface program of what the mesh shows, with the fragment of that program.
            programs:[MESH_PROGRAMS]u32
            count:=erender.pass_mesh_programs(pass,choice.handle,desc.material,programs[:])
            for program in programs[:min(count,len(programs))] {
                want:=erender.pass_gbuffer_pipeline(pass,shader,"particle meshes",program=program)
                if want==0 {continue}
                if want!=bound {erender.pass_pipeline(pass,want);bound=want}
                params:=Params{emitter=draw.slot,program=program if count>1 else max(u32),mesh=u32(choice.handle)}
                erender.pass_params(pass,&params,size_of(params))
                erender.pass_draw_indirect(pass,draws,mesh_draw(draw.slot,u32(c)))
            }
        }
    }
    erender.pass_end(pass)
}

// The draw of a mesh of an emitter (particle_finish.comp).
Mesh_Draw :: [4]u32

// Bytes of the events buffer to the draw of a mesh of an emitter.
@(private)
mesh_draw :: proc "contextless" (slot,choice:u32) -> u64 {
    return MESH_DRAWS_AT+(u64(slot)*effect.PARTICLE_MESHES+u64(choice))*size_of(Mesh_Draw)
}

// Lets go of the buffers of the pool of a world.
pool_release :: proc(renderer:^erender.Renderer,world:core.World_Id,pool:^Pool) {
    for b in Pool_Buffer {erender.buffer_release(renderer,world,pool_buffer(pool,b).name)}
    erender.buffer_release(renderer,world,particle_data_name(pool.data_side~1))
    erender.readback_release(renderer,world,DRAIN_READBACK)
    pool.made=false
}
