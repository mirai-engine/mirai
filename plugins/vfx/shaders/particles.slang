//! mirai constant EMITTER_CAPACITY uint ../runtime/gpu.odin
//! mirai constant WORK_AT uint ../runtime/gpu.odin
//! mirai constant SORT_AT uint ../runtime/gpu.odin
//! mirai constant FLAG_DRAIN uint ../runtime/gpu.odin
//! mirai constant PARTICLE_CURVE_KEYS uint ../runtime/effect/effect.odin
//! mirai constant RIBBON_SHIFT uint ../runtime/gpu.odin
//! mirai constant BEAM_PIECES uint ../runtime/gpu.odin
//! mirai constant RIBBON_PIECES_SHIFT uint ../runtime/gpu.odin
//! mirai constant DRAW_LOOK_BYTES uint ../runtime/gpu.odin
//! mirai constant POSE_AT uint ../runtime/gpu.odin
//! mirai constant TURN_AT uint ../runtime/gpu.odin
//! mirai constant FLAG_MULTIPLY uint ../runtime/gpu.odin
//! mirai constant FLAG_LIGHT uint ../runtime/gpu.odin
//! mirai constant LIGHTS_AT uint ../runtime/gpu.odin
//! mirai constant RIBBON_PIECES uint ../runtime/gpu.odin
//! mirai constant TRAILS_PER_SECOND uint ../runtime/gpu.odin
//! mirai constant MESH_CHOICE_SHIFT uint ../runtime/gpu.odin
//! mirai constant SUN_SHIFT uint ../runtime/gpu.odin
//! mirai constant PARTICLE_MESHES uint ../runtime/effect/effect.odin
// Particles: the pool, the emitters and what the passes share. Layouts are
// those of gpu.odin of the vfx plugin (sizes asserted there).
#ifndef MIRAI_PARTICLES_SLANG
#define MIRAI_PARTICLES_SLANG
#include "scene.slang"
#include "volume.slang"
#include <constants/plugins/vfx.slang>

struct Particle {
    float3 position; float age;     // in the world relative to the origin of the frame, or local to the emitter
    float3 velocity; float lifetime; // lifetime 0: the slot is free
    float size; float rotation; float spin; uint seed;
    uint color;                     // rgba8 of the square root of the linear color
    uint light;                     // rgb with a shared exponent: the light it receives
    uint emitter;                   // slot
    uint flags;                     // 1: light holds a value; from MESH_CHOICE_SHIFT, the mesh of a Mesh particle; from RIBBON_PIECES_SHIFT, the pieces of the segment it starts; at SUN_SHIFT, the sun reaches a lit Mesh particle; above RIBBON_SHIFT, the ribbon it joins
};

#define PARTICLE_SPAWNS 8u

struct Particle_Emitter {
    float4 world[3];
    float4 previous[3];
    uint4 range;          // first slot, capacity, births this frame, PARTICLE_FLAG_*
    uint4 random;         // seed, event target slot+1, particles per event, groups of births
    uint4 program;        // Vfx program (0: none), first slot of the drawn lists
    float4 shape;         // size, w cone half-angle
    uint4 kinds;          // shape, render, collision, event
    float4 lifetime_speed;
    float4 size_rotation;
    float4 spin;          // range, shell, inherit
    float4 color_a;
    float4 color_b;
    float4 velocity_a;
    float4 velocity_b;
    float4 acceleration;  // w drag
    float4 noise;         // strength, frequency, speed; w the share of the gravity of where a particle is
    float4 collide;       // bounce, friction, life lost
    float4 look;          // stretch, soft, intensity, flipbook speed
    float4 attractor;
    uint4 mesh;           // vertex count of a draw of the clusters of level 0 of its mesh (geometry.slang), the mesh, 0, material row
    uint4 flipbook;
    float4 size_curve[2];
    float4 size_times[2];
    float4 gradient[PARTICLE_CURVE_KEYS];
    float4 gradient_times[2];
    uint4 spawns[PARTICLE_SPAWNS]; // count, per, birth, age (bits)
    float4 spacing[2];
    uint4 frame;          // in particle_frame: bytes to its resources and stages (INVALID: none), from particle_frame_births to the births of its channel, how many
    uint4 data;           // bytes of particle_data to the Attributes of its range, bytes of those of a particle, its age (bits), particles it started before the frame
    float4 mesh_weights;  // of Mesh particles: the weights of its meshes added up
    float4 from_world[3];
    uint2 emitter_uid;
    float birth_limit;
    uint ribbon_axis;     // PARTICLE_RIBBON_AXIS_*
    float4 beam;
    uint4 mesh_handles;   // and the meshes, whose indices the frame lists (render.frame_mesh_whole)
    float4 scale;         // of every particle; w metres a ribbon repeats its texture over (0: once over its length)
    uint4 ribbons[2];     // the ribbon each group of births joins
    float4 light;         // of its Particle_Light: color (0: that of each particle), intensity (cd)
    float4 light_reach;   // its range and radius (m), fraction (0: every particle), shares (light_shares_bits)
    uint4 light_limit;    // lights of the emitter at once (0: as many as the world shows), cutout_count (0 or 3..8), 0, 0
    float4 cutout[4];     // pairs of UV-space sprite cutout polygon vertices (xy, zw)
};

struct Particle_State {
    uint dead;            // free slots on its list
    uint alive;
    uint births; uint born; // of an emitter whose program gives its births: those of the frame, and all it started
    // An indexed draw; that of a mesh, without indices: vertex count, instance count, first vertex, first instance.
    uint index_count; uint instance_count; uint first_index; int vertex_offset; uint first_instance;
    uint live_count[2];
    uint lights;          // lights its particles gave this frame, also those left out
    uint2 drained;
};

struct Particle_Event {
    float3 position; uint target; // slot of the emitter it starts particles in, and how many above 16 bits
    float3 velocity; uint color;
    uint ribbon;                  // that the particles it starts join
};
// An event a trail makes at the end of each frame: the point it starts lives
// until the next step, drawn where its head is now.
#define PARTICLE_EVENT_LEADER 0x80000000u

#define PARTICLE_FLAG_ACTIVE 1u
#define PARTICLE_FLAG_RESET 2u
#define PARTICLE_FLAG_LOCAL 4u
#define PARTICLE_FLAG_LIT 8u
#define PARTICLE_FLAG_SORT 16u
#define PARTICLE_FLAG_PAUSED 32u
#define PARTICLE_FLAG_ADDITIVE 64u
#define PARTICLE_FLAG_RELATIVE 128u
#define PARTICLE_FLAG_MOVED 256u // its program moves and ages its particles
#define PARTICLE_FLAG_BIRTHS 512u // its program gives its births
#define PARTICLE_FLAG_PREPARE 1024u // its program prepares what it keeps each frame
#define PARTICLE_FLAG_VIEW 2048u // of an effect view: its places are of the view, not of the world
#define PARTICLE_STATE_BYTES 512u // vfx.STATE_BYTES
#define PARTICLE_STATES_AT (1024u * PROGRAM_PARAMETER_BYTES) // vfx.STATES_AT

#define PARTICLE_SHAPE_POINT 0u
#define PARTICLE_SHAPE_SPHERE 1u
#define PARTICLE_SHAPE_HEMISPHERE 2u
#define PARTICLE_SHAPE_CONE 3u
#define PARTICLE_SHAPE_BOX 4u
#define PARTICLE_SHAPE_CIRCLE 5u
#define PARTICLE_SHAPE_LINE 6u
#define PARTICLE_SHAPE_SURFACE 7u

#define PARTICLE_RENDER_BILLBOARD 0u
#define PARTICLE_RENDER_VELOCITY 1u
#define PARTICLE_RENDER_HORIZONTAL 2u
#define PARTICLE_RENDER_RIBBON 3u
#define PARTICLE_RENDER_MESH 4u
#define PARTICLE_RENDER_BEAM 5u
#define PARTICLE_RENDER_LIGHT 6u

#define PARTICLE_COLLISION_WORLD 1u
#define PARTICLE_FACING_TUMBLE 0u
#define PARTICLE_FACING_VELOCITY 1u
#define PARTICLE_FACING_EMITTER 2u
#define PARTICLE_RIBBON_AXIS_CAMERA 0u
#define PARTICLE_RIBBON_AXIS_EMITTER_UP 1u
#define PARTICLE_EVENT_DEATH 1u
#define PARTICLE_EVENT_COLLISION 2u
#define PARTICLE_EVENT_TRAIL 3u

#define PARTICLE_EVENT_CAPACITY 16384u
#define PARTICLE_EVENTS_AT 64u // words of particle_queue before the events: their counts and dispatches
#define PARTICLE_EVENT_WORDS 9u
// Words of particle_queue to an indexed draw of each mesh of each emitter
// (vfx.MESH_DRAWS_AT), PARTICLE_MESH_DRAW_WORDS each.
#define PARTICLE_MESH_DRAWS_AT (PARTICLE_EVENTS_AT + 2u * PARTICLE_EVENT_CAPACITY * PARTICLE_EVENT_WORDS)
#define PARTICLE_MESH_DRAW_WORDS 4u

// The resources of an emitter in particle_frame: the surface of its shape,
// then those of its program, in the order it declares them.
#define PARTICLE_RESOURCES 17u
#define PARTICLE_RESOURCE_BYTES 112u
#define PARTICLE_RESOURCE_NONE 0u
#define PARTICLE_RESOURCE_SURFACE 1u
#define PARTICLE_RESOURCE_CHANNEL 2u
#define PARTICLE_RESOURCE_GRID 3u
#define PARTICLE_RESOURCE_BONES 4u
#define PARTICLE_RESOURCE_TRANSFORM 5u
#define PARTICLE_BONE_BYTES 80u // vfx.Gpu_Bone: position+parent, rotation (xyzw), scale, velocity, angular velocity
// The stages of an emitter after its resources (vfx.Gpu_Stage).
#define PARTICLE_STAGES 32u
#define PARTICLE_STAGE_BYTES 32u
#define PARTICLE_STAGE_NONE 0u
#define PARTICLE_STAGE_PARTICLES 1u
#define PARTICLE_STAGE_CELLS 2u
#define PARTICLE_BIRTH_BYTES 96u

// render.Glass_Side: the side of glass a Blend pass draws (Stage_Pass.glass).
#define PARTICLE_PASS_BEHIND_GLASS 1u
#define PARTICLE_PASS_FRONT_OF_GLASS 2u

#ifdef PARTICLES_WRITABLE
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<Particle> particles : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<Particle_State> particle_states : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
// The free slots of each emitter, then (from range.y of the pool) the particles each one draws.
[[vk::binding(SLOT_PASS3, 0)]] RWStructuredBuffer<uint> particle_lists : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// The event counts of the two halves, the indirect dispatch that consumes
// each half, and from PARTICLE_EVENTS_AT the events of each half.
[[vk::binding(SLOT_PASS5, 0)]] RWStructuredBuffer<uint> particle_queue : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
#else
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Particle> particles : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS3, 0)]] StructuredBuffer<uint> particle_lists : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
#ifdef PARTICLE_STATES_READ
[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<Particle_State> particle_states : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
#endif
#endif
[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<Particle_Emitter> particle_emitters : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// What the frame gives the emitters besides their rows: the grids of the world, their
// resources and stages, then the births of channels.
[[vk::binding(SLOT_PASS4, 0)]] ByteAddressBuffer particle_frame : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
// The world buffer: for each surface of the world, the area of its triangles added up in
// their order, as floats; then the grids (vfx.Gpu_Grid says where).
#ifdef PARTICLES_WRITABLE
[[vk::binding(SLOT_PASS6, 0)]] RWByteAddressBuffer particle_world_bytes : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);
#else
[[vk::binding(SLOT_PASS6, 0)]] ByteAddressBuffer particle_world_bytes : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
#endif
float particle_surface_area(uint at) { return asfloat(particle_world_bytes.Load(at * 4u)); }

struct Particle_Resource {
    uint kind;
    uint mesh;            // a surface: the mesh of the scene it is; bones: bytes to the first in particle_frame
    uint first;           // a surface: the area of its first triangle in particle_surfaces; a channel: bytes to its first birth
    uint count;           // a surface: its triangles by primitive (geometry.slang), CLUSTER_TRIANGLES a cluster of level 0, of no area past those of the cluster; a channel: its births; bones: how many
    float4 world[3];      // where it is this frame
    float4 previous[3];   // and the frame before
};

float4 particle_frame_row(uint at) { return asfloat(particle_frame.Load4(at)); }

// What the emitters of the frame share, first in particle_frame (vfx.Gpu_Frame): the seconds
// of the frame, of each step, the steps and the time at the end of the frame; the bytes to
// the births of the channels and to the slots of the frame.
float4 particle_frame_step() { return particle_frame_row(0u); }
uint particle_frame_births() { return particle_frame.Load(16u); }
uint particle_frame_slot(uint index) { return particle_frame.Load(particle_frame.Load(20u) + index * 4u); }
// The most lights the particles of the frame give (vfx.Pool.light_capacity).
uint particle_frame_lights() { return particle_frame.Load(24u); }

// The lights the particles give, in particle_queue from LIGHTS_AT as the
// renderer copies them (render.frame_dynamic_lights): a header of
// PARTICLE_LIGHT_WORDS words, its first how many lights were given (also
// those past the most the frame shows), then the box of what they reach,
// low corner and high (dynamic_light_order); then each light, a Light.
#define PARTICLE_LIGHTS_WORD (LIGHTS_AT / 4u)
#define PARTICLE_LIGHT_WORDS 20u

// The gravity and the wind of the world in the rows of the frame (vfx.Gpu_Fields): the
// gravity where no Gravity rules, then every Gravity and every Wind in the order they apply.
#define PARTICLE_GRAVITY_VOLUMES 8u // vfx.GRAVITY_VOLUMES
#define PARTICLE_FIELDS_GRAVITY 16u
// volume.Gpu_Outlines: its count and its rows.
#define PARTICLE_OUTLINES_BYTES (16u + VOLUME_OUTLINE_POINTS * 8u)
#define PARTICLE_FIELDS_WIND (PARTICLE_FIELDS_GRAVITY + 16u + PARTICLE_GRAVITY_VOLUMES * 112u + PARTICLE_OUTLINES_BYTES)

float4 particle_field_row(uint at) { return asfloat(particle_world_bytes.Load4(at)); }

Gpu_Volume particle_field_volume(uint at) {
    Gpu_Volume v;
    v.to_local[0] = particle_field_row(at);
    v.to_local[1] = particle_field_row(at + 16u);
    v.to_local[2] = particle_field_row(at + 32u);
    v.shape = particle_field_row(at + 48u);
    v.kind = particle_world_bytes.Load4(at + 64u);
    return v;
}

// The points of a Gpu_Outlines at bytes at of particle_world_bytes.
struct Particle_Outlines : IVolume_Outlines {
    uint at;
    float2 outline_point(uint i) { float4 r = particle_field_row(at + 16u + (i >> 1) * 16u); return (i & 1u) != 0u ? r.zw : r.xy; }
};

// What a Gravity pulls with at p, as volume gravity_of: along xyz of pull, or toward
// it as a center with the acceleration y and the surface z of center.
float3 particle_gravity_of(float4 pull, float4 center, float3 p) {
    if (center.x == 0.0) return pull.xyz;
    float3 to = pull.xyz - p;
    float distance = length(to);
    if (!(distance > 1e-4)) return float3(0.0);
    float strength = center.y;
    if (center.z > 0.0) strength *= distance > center.z ? center.z * center.z / (distance * distance) : distance / center.z;
    return to / distance * strength;
}

// What the gravity and the wind of where a particle of the world is add to its
// acceleration: the share of the gravity its effect takes, and the wind its drag takes
// it to. The fields are at bytes at of particle_world_bytes; an effect view has none.
float3 particle_fields(uint slot, uint at, float3 p) {
    float gravity_scale = particle_emitters[slot].noise.w;
    float drag = particle_emitters[slot].acceleration.w;
    if (gravity_scale == 0.0 && drag == 0.0) return float3(0.0);
    if ((particle_emitters[slot].range.w & PARTICLE_FLAG_VIEW) != 0u) return float3(0.0);
    float4 gravity = float4(particle_field_row(at).xyz, 0.0);
    uint g = at + PARTICLE_FIELDS_GRAVITY;
    uint pulls = g + 16u + PARTICLE_GRAVITY_VOLUMES * 80u;
    Particle_Outlines pulled = {g + 16u + PARTICLE_GRAVITY_VOLUMES * 112u};
    for (uint i = 0u; i < (gravity_scale != 0.0 ? min(particle_world_bytes.Load(g), PARTICLE_GRAVITY_VOLUMES) : 0u); i++) {
        Gpu_Volume v = particle_field_volume(g + 16u + i * 80u);
        float w = volume_weight(v, p, pulled);
        if (w > 0.0) gravity = volume_mix(gravity, float4(particle_gravity_of(particle_field_row(pulls + i * 16u), particle_field_row(pulls + PARTICLE_GRAVITY_VOLUMES * 16u + i * 16u), p), 0.0), w, v);
    }
    float4 wind = float4(0.0);
    uint winds = at + PARTICLE_FIELDS_WIND;
    Particle_Outlines blown = {winds + 16u + WIND_VOLUMES * 96u};
    for (uint i = 0u; i < (drag != 0.0 ? min(particle_world_bytes.Load(winds), WIND_VOLUMES) : 0u); i++) {
        Gpu_Volume v = particle_field_volume(winds + 16u + i * 80u);
        float w = volume_weight(v, p, blown);
        if (w > 0.0) wind = volume_mix(wind, particle_field_row(winds + 16u + WIND_VOLUMES * 80u + i * 16u), w, v);
    }
    return gravity.xyz * gravity_scale + wind.xyz * drag;
}

// A birth a game gave a channel (vfx.Gpu_Birth).
struct Particle_Birth {
    float3 position; float size;
    float3 velocity; float age; // seconds old at the end of the frame
    float4 color;
    float4 values;
    uint count;
    uint number;                // among those of its channel
    float3 normal;
};

Particle_Birth particle_birth_at(uint at) {
    Particle_Birth b;
    float4 a = particle_frame_row(at), c = particle_frame_row(at + 16u);
    b.position = a.xyz; b.size = a.w;
    b.velocity = c.xyz; b.age = c.w;
    b.color = particle_frame_row(at + 32u);
    b.values = particle_frame_row(at + 48u);
    uint2 n = particle_frame.Load2(at + 64u);
    b.count = n.x; b.number = n.y;
    b.normal = asfloat(particle_frame.Load3(at + 72u));
    return b;
}

// A grid of the world (vfx.Gpu_Grid): its cells, layers, where its region starts and
// started when its cells were cleared last, the word of which copy holds what the stage
// before left, where its copies and splats are in particle_world_bytes, in bytes, where
// the first cell of its region is among its cells, which wrap in place, and the lowest
// corner of that cell relative to the origin of the frame. Cells are of the world: a place
// is found from that corner, not from the cell, which far from the centre would lose it.
struct Particle_Grid_Row {
    uint3 cells; uint layers;
    int3 first; float cell_size;
    int3 previous; uint parity;
    uint offset; uint splat; uint moved; uint pad;
    uint3 phase;
    float3 corner;
};
#define PARTICLE_GRID_ROW_BYTES 96u

Particle_Grid_Row particle_grid_row_at(uint at) {
    Particle_Grid_Row g;
    uint4 a = particle_frame.Load4(at), b = particle_frame.Load4(at + 16u), c = particle_frame.Load4(at + 32u), d = particle_frame.Load4(at + 48u);
    g.cells = a.xyz; g.layers = a.w;
    g.first = int3(b.xyz); g.cell_size = asfloat(b.w);
    g.previous = int3(c.xyz); g.parity = c.w;
    g.offset = d.x; g.splat = d.y; g.moved = d.z; g.pad = d.w;
    g.phase = particle_frame.Load3(at + 64u);
    g.corner = asfloat(particle_frame.Load3(at + 80u));
    return g;
}

// The middle of a cell of the world, relative to the origin of the frame.
float3 particle_grid_middle(Particle_Grid_Row g, int3 index) {
    return g.corner + (float3(index - g.first) + 0.5) * g.cell_size;
}

// A volume (vfx.Gpu_Volume): the bytes of its grid in particle_frame and of the light of
// its cells in particle_world_bytes, and its medium.
struct Particle_Volume_Row {
    uint grid; uint light; float density; float anisotropy;
    float3 albedo;
    float3 emission;
};
#define PARTICLE_VOLUME_ROW_BYTES 48u

Particle_Volume_Row particle_volume_at(uint at) {
    Particle_Volume_Row v;
    uint4 a = particle_frame.Load4(at);
    v.grid = a.x; v.light = a.y; v.density = asfloat(a.z); v.anisotropy = asfloat(a.w);
    v.albedo = asfloat(particle_frame.Load3(at + 16u));
    v.emission = asfloat(particle_frame.Load3(at + 32u));
    return v;
}

// A stage of an emitter (vfx.Gpu_Stage): its kind, the resource row of its grid, its
// iterations, the grid resources it writes besides its own and those of them that
// start the stage at zero, a bit each.
struct Particle_Stage {
    uint kind; uint row; uint iterations;
    uint writes; uint clears;
};

Particle_Stage particle_stage_of(uint slot, uint k) {
    Particle_Stage s = (Particle_Stage)0;
    uint frame_at = particle_emitters[slot].frame.w;
    if (frame_at == INVALID || k >= particle_emitters[slot].flipbook.w) return s;
    uint at = frame_at + k * PARTICLE_STAGE_BYTES;
    uint4 w = particle_frame.Load4(at);
    s.kind = w.x; s.row = w.y; s.iterations = w.z; s.writes = w.w;
    s.clears = particle_frame.Load(at + 16u);
    return s;
}

// The row-th resource of an emitter; kind NONE when it has none.
Particle_Resource particle_resource(uint slot, uint row) {
    Particle_Resource r = (Particle_Resource)0;
    uint frame_at = particle_emitters[slot].frame.x;
    if (frame_at == INVALID || row >= particle_emitters[slot].flipbook.z) return r;
    uint at = frame_at + row * PARTICLE_RESOURCE_BYTES;
    uint4 head = particle_frame.Load4(at);
    r.kind = head.x; r.mesh = head.y; r.first = head.z; r.count = head.w;
    for (uint i = 0u; i < 3u; i++) {
        r.world[i] = particle_frame_row(at + 16u + i * 16u);
        r.previous[i] = particle_frame_row(at + 64u + i * 16u);
    }
    return r;
}
// The grid of a resource of an emitter; false without one.
bool particle_grid_of(uint slot, uint resource, out Particle_Grid_Row g) {
    Particle_Resource r = particle_resource(slot, 1u + resource);
    g = (Particle_Grid_Row)0;
    if (r.kind != PARTICLE_RESOURCE_GRID) return false;
    g = particle_grid_row_at(r.mesh);
    return true;
}

#ifdef PARTICLES_WRITABLE
Particle_Event particle_event_load(uint half, uint at) {
    uint base = PARTICLE_EVENTS_AT + (half * PARTICLE_EVENT_CAPACITY + at) * PARTICLE_EVENT_WORDS;
    Particle_Event ev;
    ev.position = asfloat(uint3(particle_queue[base], particle_queue[base + 1u], particle_queue[base + 2u]));
    ev.target = particle_queue[base + 3u];
    ev.velocity = asfloat(uint3(particle_queue[base + 4u], particle_queue[base + 5u], particle_queue[base + 6u]));
    ev.color = particle_queue[base + 7u];
    ev.ribbon = particle_queue[base + 8u];
    return ev;
}

void particle_event_store(uint half, uint at, Particle_Event ev) {
    uint base = PARTICLE_EVENTS_AT + (half * PARTICLE_EVENT_CAPACITY + at) * PARTICLE_EVENT_WORDS;
    particle_queue[base] = asuint(ev.position.x); particle_queue[base + 1u] = asuint(ev.position.y); particle_queue[base + 2u] = asuint(ev.position.z);
    particle_queue[base + 3u] = ev.target;
    particle_queue[base + 4u] = asuint(ev.velocity.x); particle_queue[base + 5u] = asuint(ev.velocity.y); particle_queue[base + 6u] = asuint(ev.velocity.z);
    particle_queue[base + 7u] = ev.color;
    particle_queue[base + 8u] = ev.ribbon;
}
#endif

uint particle_emitter_of(Particle p) { return p.emitter; }

// The ribbon a particle joins (0: the one of its emitter), and the ribbon of
// its own that the particles its events start join: never 0, the same while
// it lives, apart from those of the others alive in all but rare cases.
#define PARTICLE_RIBBON_MASK (0xFFFFFFFFu >> RIBBON_SHIFT)
uint particle_ribbon(Particle p) { return p.flags >> RIBBON_SHIFT; }
uint particle_own_ribbon(uint seed) { return max(hash_u32(seed) & PARTICLE_RIBBON_MASK, 1u); }

// The pieces of the segment of a ribbon a particle starts, last frame.
#define PARTICLE_PIECES_MASK 15u
uint particle_pieces(Particle p) { return (p.flags >> RIBBON_PIECES_SHIFT) & PARTICLE_PIECES_MASK; }

// The direction a ribbon leaves a particle at here in, between those it came
// from before and goes on to after: the mean of both.
float3 ribbon_tangent(float3 before, float3 here, float3 after) {
    float3 in_dir = here - before, out_dir = after - here;
    float3 mean = (length(in_dir) > 1e-6 ? normalize(in_dir) : float3(0.0)) + (length(out_dir) > 1e-6 ? normalize(out_dir) : float3(0.0));
    return length(mean) > 1e-6 ? normalize(mean) : out_dir;
}

// The pool index of the i-th particle an emitter draws.
uint particle_alive_at(uint slot, uint parity) {
    return (3u + parity) * particle_emitters[slot].program.y + particle_emitters[slot].range.x;
}

#ifdef PARTICLES_WRITABLE
void particle_alive_append(uint slot, uint parity, uint index) {
    // Event lanes may name different emitters. The other passes share one per group.
    bool pending = true;
    while (WaveActiveAnyTrue(pending)) {
        uint first_slot = WaveActiveMin(pending ? slot : 0xFFFFFFFFu);
        bool mine = pending && slot == first_slot;
        uint count = WaveActiveCountBits(mine);
        uint offset = 0u;
        if (WaveIsFirstLane()) InterlockedAdd(particle_states[first_slot].live_count[parity], count, offset);
        offset = WaveReadLaneFirst(offset) + WavePrefixCountBits(mine);
        if (mine) {
            particle_lists[particle_alive_at(slot, parity) + offset] = index;
            pending = false;
        }
    }
}
#endif

float3 particle_unit(float3 value, float3 fallback) {
    float squared = dot(value, value);
    return squared > 1e-12 ? value * rsqrt(squared) : fallback;
}

uint particle_drawn(uint slot, uint i) { return particle_lists[particle_emitters[slot].program.y + particle_emitters[slot].range.x + i]; }

// Where in the data buffer what a particle shows is (particle_draw_look), and
// after it the pose it was born with: the turn of its emitter (a quaternion,
// snorm16 a component, of the space its particles are in) and, of a ribbon,
// the metres from its head to it and its whole length, which the sort finds.
// Last, at TURN_AT, what its program gives of how it is placed: its turn in
// the world (a quaternion as the pose; zero: none) and its scale, in halves.
uint particle_draw_look_at(uint slot, uint index) {
    return particle_emitters[slot].program.w + index * DRAW_LOOK_BYTES;
}
uint particle_pose_at(uint slot, uint index) { return particle_draw_look_at(slot, index) + POSE_AT; }
#define PARTICLE_TRAIL_AT 8u // bytes of the pose to the metres along its ribbon

uint2 particle_pose_pack(float4 q) {
    int4 s = int4(round(clamp(q, -1.0, 1.0) * 32767.0));
    return uint2((uint(s.x) & 0xFFFFu) | (uint(s.y) << 16u), (uint(s.z) & 0xFFFFu) | (uint(s.w) << 16u));
}
float4 particle_pose_unpack(uint2 w) {
    float4 q = float4(int4(int(w.x << 16u) >> 16, int(w.x) >> 16, int(w.y << 16u) >> 16, int(w.y) >> 16)) / 32767.0;
    float squared = dot(q, q);
    return squared > 1e-6 ? q * rsqrt(squared) : float4(0.0, 0.0, 0.0, 1.0);
}

// Two floats as the halves of a word, and back, by the conversions of the
// device: f32tof16 and f16tof32 of Slang go through 16-bit types.
uint particle_halves_pack(float2 value) {
    return spirv_asm {
        result:$$uint = OpExtInst glsl450 PackHalf2x16 $value
    };
}
float2 particle_halves_unpack(uint halves) {
    return spirv_asm {
        result:$$float2 = OpExtInst glsl450 UnpackHalf2x16 $halves
    };
}

// The turn of a basis of three axes at right angles, as a quaternion.
float4 particle_quat_of(float3 x, float3 y, float3 z) {
    float trace = x.x + y.y + z.z;
    float4 q;
    if (trace > 0.0) {
        float s = sqrt(trace + 1.0) * 2.0;
        q = float4((y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, 0.25 * s);
    } else if (x.x > y.y && x.x > z.z) {
        float s = sqrt(1.0 + x.x - y.y - z.z) * 2.0;
        q = float4(0.25 * s, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s);
    } else if (y.y > z.z) {
        float s = sqrt(1.0 + y.y - x.x - z.z) * 2.0;
        q = float4((y.x + x.y) / s, 0.25 * s, (z.y + y.z) / s, (z.x - x.z) / s);
    } else {
        float s = sqrt(1.0 + z.z - x.x - y.y) * 2.0;
        q = float4((z.x + x.z) / s, (z.y + y.z) / s, 0.25 * s, (x.y - y.x) / s);
    }
    return normalize(q);
}

// The turn of an affine transform given by its rows, without its scale.
float4 particle_turn_of(float4 rows[3]) {
    float3 x = particle_unit(float3(rows[0].x, rows[1].x, rows[2].x), float3(1.0, 0.0, 0.0));
    float3 y = float3(rows[0].y, rows[1].y, rows[2].y);
    float3 fallback = normalize(cross(abs(x.z) < 0.99 ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0), x));
    y = particle_unit(y - x * dot(x, y), fallback);
    return particle_quat_of(x, y, cross(x, y));
}

// The scale of an affine transform given by its rows; mirrors along z to match particle_turn_of.
float3 particle_scale_of(float4 rows[3]) {
    float3 x = float3(rows[0].x, rows[1].x, rows[2].x);
    float3 y = float3(rows[0].y, rows[1].y, rows[2].y);
    float3 z = float3(rows[0].z, rows[1].z, rows[2].z);
    float3 s = float3(length(x), length(y), length(z));
    if (dot(cross(x, y), z) < 0.0) s.z = -s.z;
    return s;
}

// The axes of a turn: the columns of its rotation.
float3x3 particle_quat_matrix(float4 q) {
    float3 x = float3(1.0 - 2.0 * (q.y * q.y + q.z * q.z), 2.0 * (q.x * q.y + q.w * q.z), 2.0 * (q.x * q.z - q.w * q.y));
    float3 y = float3(2.0 * (q.x * q.y - q.w * q.z), 1.0 - 2.0 * (q.x * q.x + q.z * q.z), 2.0 * (q.y * q.z + q.w * q.x));
    float3 z = float3(2.0 * (q.x * q.z + q.w * q.y), 2.0 * (q.y * q.z - q.w * q.x), 1.0 - 2.0 * (q.x * q.x + q.y * q.y));
    return float3x3(x.x, y.x, z.x, x.y, y.y, z.y, x.z, y.z, z.z);
}

// The pose a particle of the emitter is born with: none in its space when its particles move
// with it, else its turn between the frame before (t 0) and this one (t 1).
float4 particle_birth_pose(uint slot, float t) {
    if ((particle_emitters[slot].range.w & PARTICLE_FLAG_LOCAL) != 0u) return float4(0.0, 0.0, 0.0, 1.0);
    float4 now = particle_turn_of(particle_emitters[slot].world);
    if (t >= 1.0) return now;
    float4 before = particle_turn_of(particle_emitters[slot].previous);
    if (dot(before, now) < 0.0) before = -before;
    return normalize(lerp(before, now, t));
}

// The scale of the particles of an emitter (effect.particle_scale).
float3 particle_scale(uint slot) { return particle_emitters[slot].scale.xyz; }

uint pack_unorm4(float4 c) {
    uint4 b = uint4(saturate(c) * 255.0 + 0.5);
    return b.x | (b.y << 8u) | (b.z << 16u) | (b.w << 24u);
}
uint particle_color_pack(float4 linear) { return pack_unorm4(float4(sqrt(max(linear.rgb, float3(0.0))), linear.a)); }
float4 particle_color(Particle p) {
    float4 c = unpack_rgba8(p.color);
    return float4(c.rgb * c.rgb, c.a);
}

// The point of the world of an affine transform given by its rows, back in its space.
bool particle_mesh_point(Mesh mesh, uint vertex_id, out Cluster cluster, out Mesh_Point point) {
    cluster = mesh_cluster(mesh, vertex_id / CLUSTER_DRAW_VERTICES);
    point = (Mesh_Point)0;
    uint corner = vertex_id % CLUSTER_DRAW_VERTICES;
    uint triangle = corner / 3u;
    if (triangle >= cluster_triangle_count(cluster) || !cluster_resident(mesh, cluster)) return false;
    point = cluster_point(mesh, cluster, cluster_triangle(mesh, cluster, triangle)[corner % 3u]);
    return true;
}

// Light as three bytes over a shared power of two.
uint pack_rgbe(float3 c) {
    float peak = max(c.r, max(c.g, c.b));
    if (!(peak > 1e-6)) return 0u;
    float e = clamp(ceil(log2(peak)), -126.0, 127.0);
    uint3 m = uint3(saturate(c * exp2(-e)) * 255.0 + 0.5);
    return m.r | (m.g << 8u) | (m.b << 16u) | (uint(e + 128.0) << 24u);
}
float3 particle_light(Particle p) {
    if (p.light == 0u) return float3(0.0);
    uint e = p.light >> 24u;
    return float3(p.light & 255u, (p.light >> 8u) & 255u, (p.light >> 16u) & 255u) * (exp2(float(e) - 128.0) / 255.0);
}

// Piecewise linear between keys at ascending times; past the ends, the end keys.
float particle_curve(float4 values[2], float4 times[2], float x) {
    float previous_time = times[0].x, previous_value = values[0].x;
    if (x <= previous_time) return previous_value;
    for (uint i = 1u; i < PARTICLE_CURVE_KEYS; i++) {
        float t = times[i / 4u][i % 4u], v = values[i / 4u][i % 4u];
        if (x <= t) return lerp(previous_value, v, saturate((x - previous_time) / max(t - previous_time, 1e-5)));
        previous_time = t; previous_value = v;
    }
    return previous_value;
}

float4 particle_gradient(uint slot, float x) {
    float previous_time = particle_emitters[slot].gradient_times[0].x;
    float4 previous = particle_emitters[slot].gradient[0];
    if (x <= previous_time) return previous;
    for (uint i = 1u; i < PARTICLE_CURVE_KEYS; i++) {
        float t = particle_emitters[slot].gradient_times[i / 4u][i % 4u];
        float4 key = particle_emitters[slot].gradient[i];
        if (x <= t) return lerp(previous, key, saturate((x - previous_time) / max(t - previous_time, 1e-5)));
        previous_time = t; previous = key;
    }
    return previous;
}

// What the places of the particles of an emitter are relative to: the origin of the frame, in steps,
// or nothing for those of an effect view. Only for what needs the place of the world (origin.slang).
int3 particle_origin(uint slot) {
    return (particle_emitters[slot].range.w & PARTICLE_FLAG_VIEW) != 0u ? int3(0) : frame.origin.xyz;
}

// Where a particle is in the world, relative to the origin of the frame.
float3 particle_world(uint slot, float3 position) {
    return (particle_emitters[slot].range.w & PARTICLE_FLAG_LOCAL) != 0u ? transform_point(particle_emitters[slot].world, position) : position;
}
float3 particle_world_vector(uint slot, float3 v) {
    return (particle_emitters[slot].range.w & PARTICLE_FLAG_LOCAL) != 0u ? transform_vector(particle_emitters[slot].world, v) : v;
}

// The share of its life a particle lived.
float particle_life(Particle p) { return saturate(p.age / max(p.lifetime, 1e-5)); }

// The color, size and flipbook frame of a particle at its age.
struct Particle_Look {
    float4 color;
    float size;
    float frame;
    float4 data[4]; // Mirai_Vfx_Visual.data and given
    uint given;
    float random;
    float3 scale;       // Mirai_Vfx_Visual.scale: over that of its effect
    float4 orientation; // Mirai_Vfx_Visual.orientation: zero, the facing of its effect
    // The light it gives (Mirai_Vfx_Visual.light_*), with FLAG_LIGHT.
    float3 light_color;
    float light_intensity; // cd
    float light_range;     // m
    float light_radius;    // m
};
Particle_Look particle_look(uint slot, Particle p) {
    Particle_Look look;
    float life = particle_life(p);
    float4 shown = particle_emitters[slot].look;
    uint2 flipbook = particle_emitters[slot].flipbook.xy;
    look.color = particle_color(p) * particle_gradient(slot, life);
    // Its light: the color of the light, else its own before the intensity of the effect, by its alpha.
    float4 light = particle_emitters[slot].light;
    float4 reach = particle_emitters[slot].light_reach;
    look.light_color = any(light.rgb > 0.0) ? light.rgb : max(look.color.rgb, float3(0.0));
    look.light_intensity = light.w * saturate(look.color.a);
    look.light_range = reach.x;
    look.light_radius = reach.y;
    look.color.rgb *= shown.z;
    look.size = p.size * particle_curve(particle_emitters[slot].size_curve, particle_emitters[slot].size_times, life);
    float frames = float(flipbook.x * flipbook.y);
    look.frame = shown.w > 0.0 ? p.age * shown.w + float(p.seed & 255u) : life * frames;
    look.frame = frames > 1.0 ? mod(look.frame, frames) : 0.0;
    look.data[0] = float4(0.0); look.data[1] = float4(0.0); look.data[2] = float4(0.0); look.data[3] = float4(0.0);
    look.given = 0u;
    look.random = float(p.seed >> 8u) * (1.0 / 16777216.0);
    look.scale = float3(1.0);
    look.orientation = float4(0.0);
    return look;
}

// The sprite of a particle without a texture: a soft disc broken by two
// octaves of value noise, different for each particle. tile goes from -1 to 1.
float particle_puff(float2 tile, float seed) {
    float2 p = tile * 1.6 + seed;
    float n = 0.0, amplitude = 0.6;
    for (int octave = 0; octave < 2; octave++) {
        float2 i = floor(p), f = frac(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = float(hash_u32(asuint(i.x) * 73856093u ^ asuint(i.y) * 19349663u) >> 8) / 16777216.0;
        float b = float(hash_u32(asuint(i.x + 1.0) * 73856093u ^ asuint(i.y) * 19349663u) >> 8) / 16777216.0;
        float c = float(hash_u32(asuint(i.x) * 73856093u ^ asuint(i.y + 1.0) * 19349663u) >> 8) / 16777216.0;
        float d = float(hash_u32(asuint(i.x + 1.0) * 73856093u ^ asuint(i.y + 1.0) * 19349663u) >> 8) / 16777216.0;
        n += lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y) * amplitude;
        p = p * 2.1 + 17.3;
        amplitude *= 0.5;
    }
    float disc = saturate(1.0 - dot(tile, tile));
    return disc * disc * saturate(0.35 + n * 1.1);
}

// Which of the meshes of an emitter a particle shows, by a number from 0 to 1 against their weights.
uint particle_mesh_pick(uint slot, float u) {
    uint count = max(particle_emitters[slot].mesh.x, 1u);
    float4 weights = particle_emitters[slot].mesh_weights;
    for (uint c = 0u; c + 1u < count; c++) {
        if (u < weights[c]) return c;
    }
    return count - 1u;
}

// Where a Mesh particle that faces its velocity last went faster than
// PARTICLE_MESH_FACING_SPEED, in the bits of flags a ribbon has: two of 10
// over an octahedron and whether they hold it. Slower, it keeps it, so that
// what rests does not jitter.
#define PARTICLE_MESH_FACING_SPEED 0.1
#define PARTICLE_HEADING_HELD 0x80000000u
uint particle_heading_pack(float3 d) {
    float2 o = d.xy / (abs(d.x) + abs(d.y) + abs(d.z));
    if (d.z < 0.0) o = (1.0 - abs(o.yx)) * float2(o.x >= 0.0 ? 1.0 : -1.0, o.y >= 0.0 ? 1.0 : -1.0);
    uint2 q = uint2(saturate(o * 0.5 + 0.5) * 1023.0 + 0.5);
    return (q.x | (q.y << 10u)) << RIBBON_SHIFT | PARTICLE_HEADING_HELD;
}
float3 particle_heading(uint flags) {
    uint bits = flags >> RIBBON_SHIFT;
    float2 o = float2(float(bits & 1023u), float((bits >> 10u) & 1023u)) / 1023.0 * 2.0 - 1.0;
    float3 d = float3(o, 1.0 - abs(o.x) - abs(o.y));
    if (d.z < 0.0) d.xy = (1.0 - abs(d.yx)) * float2(d.x >= 0.0 ? 1.0 : -1.0, d.y >= 0.0 ? 1.0 : -1.0);
    return normalize(d);
}

// The mesh a Mesh particle shows among those of its emitter.
uint particle_mesh_choice(uint slot, Particle p) {
    return min((p.flags >> MESH_CHOICE_SHIFT) & (PARTICLE_MESHES - 1u), max(particle_emitters[slot].mesh.x, 1u) - 1u);
}

// Rotation of a particle mesh: about an axis of its own.
float3x3 particle_rotation(uint seed, float angle) {
    uint s = seed * 31u + 7u;
    float3 axis = normalize(float3(random01(s), random01(s), random01(s)) * 2.0 - 1.0 + float3(0.0, 1e-3, 0.0));
    float c = cos(angle), si = sin(angle), t = 1.0 - c;
    return float3x3(
        t * axis.x * axis.x + c, t * axis.x * axis.y - si * axis.z, t * axis.x * axis.z + si * axis.y,
        t * axis.x * axis.y + si * axis.z, t * axis.y * axis.y + c, t * axis.y * axis.z - si * axis.x,
        t * axis.x * axis.z - si * axis.y, t * axis.y * axis.z + si * axis.x, t * axis.z * axis.z + c);
}

// The rotation of a Mesh particle as its effect turns it (Particle_Facing):
// Tumble, about an axis of its own; Velocity, its front (-Z) along its
// velocity (up when still), its +Y as near the up of the world; Emitter, as
// pose (particle_birth_pose) turns it. The last two roll about its front by
// its rotation.
float3x3 particle_mesh_rotation(uint slot, Particle p, float4 pose) {
    uint facing = particle_emitters[slot].mesh.y;
    if (facing == PARTICLE_FACING_TUMBLE) return particle_rotation(p.seed, p.rotation);
    float3 x, y, z;
    if (facing == PARTICLE_FACING_EMITTER) {
        float3x3 turned = particle_quat_matrix(pose);
        x = float3(turned[0].x, turned[1].x, turned[2].x);
        y = float3(turned[0].y, turned[1].y, turned[2].y);
        z = float3(turned[0].z, turned[1].z, turned[2].z);
    } else {
        float3 v = particle_world_vector(slot, p.velocity);
        float3 forward = (p.flags & PARTICLE_HEADING_HELD) != 0u ? particle_heading(p.flags) : length(v) > 1e-5 ? normalize(v) : float3(0.0, 1.0, 0.0);
        float3 up = abs(forward.y) > 0.99 ? float3(0.0, 0.0, forward.y > 0.0 ? 1.0 : -1.0) : float3(0.0, 1.0, 0.0);
        z = -forward;
        x = normalize(cross(up, z));
        y = cross(z, x);
    }
    float s = sin(p.rotation), c = cos(p.rotation);
    float3 rx = x * c + y * s, ry = y * c - x * s;
    return float3x3(rx.x, ry.x, z.x, rx.y, ry.y, z.y, rx.z, ry.z, z.z);
}

// A vector of the space of its mesh in the world, by the rows of its emitter
// in a frame: one that tumbles, or that its emitter turns when its particles
// move with it, turns in the space of its emitter; the others, and one whose
// program gives its turn (turned), in the world, grown by the scale of its
// emitter along each axis.
float3 particle_mesh_vector_by(uint slot, float4 rows[3], float3x3 rotation, float3 v, bool turned) {
    uint facing = particle_emitters[slot].mesh.y;
    bool local = (particle_emitters[slot].range.w & PARTICLE_FLAG_LOCAL) != 0u;
    if (!turned && (facing == PARTICLE_FACING_TUMBLE || facing == PARTICLE_FACING_EMITTER && local)) {
        float3 turned = mul(rotation, v);
        return local ? transform_vector(rows, turned) : turned;
    }
    float3 scale = float3(length(float3(rows[0].x, rows[1].x, rows[2].x)), length(float3(rows[0].y, rows[1].y, rows[2].y)), length(float3(rows[0].z, rows[1].z, rows[2].z)));
    return mul(rotation, v * scale);
}
float3 particle_mesh_vector(uint slot, float3x3 rotation, float3 v, bool turned) {
    return particle_mesh_vector_by(slot, particle_emitters[slot].world, rotation, v, turned);
}

// The normal of a mesh particle, of a normal of its mesh: across its scale.
float3 particle_mesh_normal(uint slot, float3x3 rotation, float3 n, float3 scale, bool turned) {
    return particle_unit(particle_mesh_vector(slot, rotation, n / max(scale, float3(1e-6)), turned), n);
}

#endif
