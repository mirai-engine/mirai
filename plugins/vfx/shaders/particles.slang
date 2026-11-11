//! mirai constant PARTICLE_CURVE_KEYS uint ../runtime/effect/effect.odin
//! mirai constant RIBBON_SHIFT uint ../runtime/gpu.odin
//! mirai constant RIBBON_PIECES uint ../runtime/gpu.odin
//! mirai constant TRAILS_PER_SECOND uint ../runtime/gpu.odin
//! mirai constant MESH_CHOICE_SHIFT uint ../runtime/gpu.odin
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
    uint flags;                     // 1: light holds a value; from MESH_CHOICE_SHIFT, its mesh; above RIBBON_SHIFT, the ribbon it joins
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
    float4 step;          // seconds of the frame, of each step, steps, time at the end of the frame
    uint4 spawns[PARTICLE_SPAWNS]; // count, per, birth, age (bits)
    float4 spacing[2];
    uint4 frame;          // in particle_frame: bytes to its resources and stages (INVALID: none), to the births of its channel, how many, to the births of the frame
    float4 light;         // intensity (cd), range, radius (0: half the size of the particle)
    uint4 lights;         // its share of the room of the frame: x the first of its lights with shadows, y how many; z, w those without
    uint4 data;           // bytes of particle_data to the Attributes of its range, bytes of those of a particle, its age (bits), particles it started before the frame
};

struct Particle_State {
    uint dead;            // free slots on its list
    uint alive;
    uint births; uint born; // of an emitter whose program gives its births: those of the frame, and all it started
    // An indexed draw; that of a mesh, without indices: vertex count, instance count, first vertex, first instance.
    uint index_count; uint instance_count; uint first_index; int vertex_offset; uint first_instance;
    uint pieces;          // of a ribbon: those each segment is cut into this frame
    uint pad3; uint pad4;
    uint4 meshes[PARTICLE_MESHES]; // of Mesh particles, a draw of each mesh without indices
};

struct Particle_Event {
    float3 position; uint target; // slot of the emitter it starts particles in, and how many above 16 bits
    float3 velocity; uint color;
    uint ribbon;                  // that the particles it starts join
};

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
#define PARTICLE_SHAPE_BONES 8u

#define PARTICLE_RENDER_BILLBOARD 0u
#define PARTICLE_RENDER_VELOCITY 1u
#define PARTICLE_RENDER_HORIZONTAL 2u
#define PARTICLE_RENDER_RIBBON 3u
#define PARTICLE_RENDER_MESH 4u

#define PARTICLE_COLLISION_WORLD 1u
#define PARTICLE_FACING_TUMBLE 0u
#define PARTICLE_FACING_VELOCITY 1u
#define PARTICLE_EVENT_DEATH 1u
#define PARTICLE_EVENT_COLLISION 2u
#define PARTICLE_EVENT_TRAIL 3u

#define PARTICLE_EVENT_CAPACITY 16384u
#define PARTICLE_EVENTS_AT 64u // words of particle_queue before the events: their counts and dispatches
#define PARTICLE_EVENT_WORDS 12u

// The resources of an emitter in particle_frame: the surface of its shape,
// then those of its program, in the order it declares them.
#define PARTICLE_RESOURCES 17u
#define PARTICLE_RESOURCE_BYTES 112u
#define PARTICLE_RESOURCE_NONE 0u
#define PARTICLE_RESOURCE_SURFACE 1u
#define PARTICLE_RESOURCE_CHANNEL 2u
#define PARTICLE_RESOURCE_BONES 3u
#define PARTICLE_RESOURCE_GRID 4u
#define PARTICLE_RESOURCE_EMITTER 5u
#define PARTICLE_RESOURCE_DATA 6u
#define PARTICLE_DATA_ENTRIES 4096u      // vfx.DATA_ENTRIES
#define PARTICLE_REPORT_WORDS 11u        // vfx.REPORT_WORDS
#define PARTICLE_SEGMENT_BYTES 64u
// The stages of an emitter after its resources (vfx.Gpu_Stage).
#define PARTICLE_STAGES 32u
#define PARTICLE_STAGE_BYTES 32u
#define PARTICLE_STAGE_NONE 0u
#define PARTICLE_STAGE_PARTICLES 1u
#define PARTICLE_STAGE_CELLS 2u
#define PARTICLE_BIRTH_BYTES 80u
#define PARTICLE_SORT_MAX 2048u

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
#ifndef PARTICLES_COUNTED
// What the frame gives the emitters besides their rows: the bones they read, the grids of
// the world, their resources and stages, then the births of channels.
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
    uint mesh;            // a surface: the mesh of the scene it is
    uint first;           // a surface: the area of its first triangle in particle_surfaces; a channel: bytes to its first birth; bones: to its first bone; an emitter: its slot
    uint count;           // a surface: its triangles by primitive (geometry.slang), CLUSTER_TRIANGLES a cluster of level 0, of no area past those of the cluster; a channel: its births; bones: its bones
    float4 world[3];      // where it is this frame
    float4 previous[3];   // and the frame before
};

float4 particle_frame_row(uint at) { return asfloat(particle_frame.Load4(at)); }

// The gravity and the wind of the world in the rows of the frame (vfx.Gpu_Fields): the
// gravity where no Gravity rules, then every Gravity and every Wind in the order they apply.
#define PARTICLE_GRAVITY_VOLUMES 8u // vfx.GRAVITY_VOLUMES
#define PARTICLE_FIELDS_GRAVITY 16u
// volume.Gpu_Outlines: its count and its rows.
#define PARTICLE_OUTLINES_BYTES (16u + VOLUME_OUTLINE_POINTS * 8u)
#define PARTICLE_FIELDS_WIND (PARTICLE_FIELDS_GRAVITY + 16u + PARTICLE_GRAVITY_VOLUMES * 112u + PARTICLE_OUTLINES_BYTES)

Gpu_Volume particle_frame_volume(uint at) {
    Gpu_Volume v;
    v.to_local[0] = particle_frame_row(at);
    v.to_local[1] = particle_frame_row(at + 16u);
    v.to_local[2] = particle_frame_row(at + 32u);
    v.shape = particle_frame_row(at + 48u);
    v.kind = particle_frame.Load4(at + 64u);
    return v;
}

// The points of a Gpu_Outlines at bytes at of particle_frame.
struct Particle_Outlines : IVolume_Outlines {
    uint at;
    float2 outline_point(uint i) { float4 r = particle_frame_row(at + 16u + (i >> 1) * 16u); return (i & 1u) != 0u ? r.zw : r.xy; }
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
// it to. The fields are at bytes at of particle_frame; an effect view has none.
float3 particle_fields(uint slot, uint at, float3 p) {
    if ((particle_emitters[slot].range.w & PARTICLE_FLAG_VIEW) != 0u) return float3(0.0);
    float4 gravity = float4(particle_frame_row(at).xyz, 0.0);
    uint g = at + PARTICLE_FIELDS_GRAVITY;
    uint pulls = g + 16u + PARTICLE_GRAVITY_VOLUMES * 80u;
    Particle_Outlines pulled = {g + 16u + PARTICLE_GRAVITY_VOLUMES * 112u};
    for (uint i = 0u; i < min(particle_frame.Load(g), PARTICLE_GRAVITY_VOLUMES); i++) {
        Gpu_Volume v = particle_frame_volume(g + 16u + i * 80u);
        float w = volume_weight(v, p, pulled);
        if (w > 0.0) gravity = volume_mix(gravity, float4(particle_gravity_of(particle_frame_row(pulls + i * 16u), particle_frame_row(pulls + PARTICLE_GRAVITY_VOLUMES * 16u + i * 16u), p), 0.0), w, v);
    }
    float4 wind = float4(0.0);
    uint winds = at + PARTICLE_FIELDS_WIND;
    Particle_Outlines blown = {winds + 16u + WIND_VOLUMES * 96u};
    for (uint i = 0u; i < min(particle_frame.Load(winds), WIND_VOLUMES); i++) {
        Gpu_Volume v = particle_frame_volume(winds + 16u + i * 80u);
        float w = volume_weight(v, p, blown);
        if (w > 0.0) wind = volume_mix(wind, particle_frame_row(winds + 16u + WIND_VOLUMES * 80u + i * 16u), w, v);
    }
    return gravity.xyz * particle_emitters[slot].noise.w + wind.xyz * particle_emitters[slot].acceleration.w;
}

// A birth a game gave a channel (vfx.Gpu_Birth).
struct Particle_Birth {
    float3 position; float size;
    float3 velocity; float age; // seconds old at the end of the frame
    float4 color;
    float4 values;
    uint count;
    uint number;                // among those of its channel
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
    return b;
}

// A bone of a bones resource (vfx.Gpu_Segment), from the joint of its parent
// to its own, in the space of its mesh, this frame and the one before.
struct Particle_Segment {
    float3 start; float length; // of the bones up to this one, added up
    float3 end;
    float3 previous_start;
    float3 previous_end;
};

Particle_Segment particle_segment_at(uint at) {
    Particle_Segment s;
    float4 a = particle_frame_row(at);
    s.start = a.xyz; s.length = a.w;
    s.end = particle_frame_row(at + 16u).xyz;
    s.previous_start = particle_frame_row(at + 32u).xyz;
    s.previous_end = particle_frame_row(at + 48u).xyz;
    return s;
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
    uint frame_at = particle_emitters[slot].frame.x;
    if (frame_at == INVALID || k >= PARTICLE_STAGES) return s;
    uint at = frame_at + PARTICLE_RESOURCES * PARTICLE_RESOURCE_BYTES + k * PARTICLE_STAGE_BYTES;
    uint4 w = particle_frame.Load4(at);
    s.kind = w.x; s.row = w.y; s.iterations = w.z; s.writes = w.w;
    s.clears = particle_frame.Load(at + 16u);
    return s;
}

// What the rows of the frame hold of a Mesh emitter (vfx.Gpu_Mesh_Row): the mesh of the
// scene of each choice, their weights added up and the vertices of a draw of each.
#define PARTICLE_MESH_ROW_WEIGHTS 16u
#define PARTICLE_MESH_ROW_VERTICES 32u
uint particle_mesh_of(uint slot, uint choice) { return particle_frame.Load(particle_emitters[slot].mesh.z + choice * 4u); }
uint particle_mesh_vertices(uint slot, uint choice) { return particle_frame.Load(particle_emitters[slot].mesh.z + PARTICLE_MESH_ROW_VERTICES + choice * 4u); }

// Which of the meshes of an emitter a particle shows, by a number from 0 to 1 against their weights.
uint particle_mesh_pick(uint slot, float u) {
    uint count = max(particle_emitters[slot].mesh.x, 1u);
    float4 weights = particle_frame_row(particle_emitters[slot].mesh.z + PARTICLE_MESH_ROW_WEIGHTS);
    for (uint c = 0u; c + 1u < count; c++) {
        if (u < weights[c]) return c;
    }
    return count - 1u;
}

// The row-th resource of an emitter; kind NONE when it has none.
Particle_Resource particle_resource(uint slot, uint row) {
    Particle_Resource r = (Particle_Resource)0;
    uint frame_at = particle_emitters[slot].frame.x;
    if (frame_at == INVALID || row >= PARTICLE_RESOURCES) return r;
    uint at = frame_at + row * PARTICLE_RESOURCE_BYTES;
    uint4 head = particle_frame.Load4(at);
    r.kind = head.x; r.mesh = head.y; r.first = head.z; r.count = head.w;
    for (uint i = 0u; i < 3u; i++) {
        r.world[i] = particle_frame_row(at + 16u + i * 16u);
        r.previous[i] = particle_frame_row(at + 64u + i * 16u);
    }
    return r;
}
#endif

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

// The direction a ribbon leaves a particle at here in, between those it came
// from before and goes on to after: the mean of both.
float3 ribbon_tangent(float3 before, float3 here, float3 after) {
    float3 in_dir = here - before, out_dir = after - here;
    float3 mean = (length(in_dir) > 1e-6 ? normalize(in_dir) : float3(0.0)) + (length(out_dir) > 1e-6 ? normalize(out_dir) : float3(0.0));
    return length(mean) > 1e-6 ? normalize(mean) : out_dir;
}

// The pool index of the i-th particle an emitter draws.
uint particle_drawn(uint slot, uint i) { return particle_lists[particle_emitters[slot].program.y + particle_emitters[slot].range.x + i]; }

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
float3 inverse_transform_point(float4 m[3], float3 p) {
    float3 a = float3(m[0].x, m[1].x, m[2].x), b = float3(m[0].y, m[1].y, m[2].y), c = float3(m[0].z, m[1].z, m[2].z);
    float3 d = p - float3(m[0].w, m[1].w, m[2].w);
    float3 bc = cross(b, c), ca = cross(c, a), ab = cross(a, b);
    float det = dot(a, bc);
    if (abs(det) < 1e-12) return d;
    return float3(dot(d, bc), dot(d, ca), dot(d, ab)) / det;
}
float3 inverse_transform_vector(float4 m[3], float3 v) {
    return inverse_transform_point(m, v + float3(m[0].w, m[1].w, m[2].w));
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

// The color, size and flipbook frame of a particle at its age.
struct Particle_Look {
    float4 color;
    float size;
    float frame;
    float4 data[4]; // Mirai_Vfx_Visual.data and given
    uint given;
    float random;
};
Particle_Look particle_look(uint slot, Particle p) {
    Particle_Look look;
    float life = saturate(p.age / max(p.lifetime, 1e-5));
    float4 shown = particle_emitters[slot].look;
    uint2 flipbook = particle_emitters[slot].flipbook.xy;
    look.color = particle_color(p) * particle_gradient(slot, life);
    look.color.rgb *= shown.z;
    look.size = p.size * particle_curve(particle_emitters[slot].size_curve, particle_emitters[slot].size_times, life);
    float frames = float(flipbook.x * flipbook.y);
    look.frame = shown.w > 0.0 ? p.age * shown.w + float(p.seed & 255u) : life * frames;
    look.frame = frames > 1.0 ? mod(look.frame, frames) : 0.0;
    look.data[0] = float4(0.0); look.data[1] = float4(0.0); look.data[2] = float4(0.0); look.data[3] = float4(0.0);
    look.given = 0u;
    look.random = float(p.seed >> 8u) * (1.0 / 16777216.0);
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
// velocity (up when still), its +Y as near the up of the world, rolled about
// its front by its rotation.
float3x3 particle_mesh_rotation(uint slot, Particle p) {
    if (particle_emitters[slot].mesh.y != PARTICLE_FACING_VELOCITY) return particle_rotation(p.seed, p.rotation);
    float3 v = particle_world_vector(slot, p.velocity);
    float3 forward = length(v) > 1e-5 ? normalize(v) : float3(0.0, 1.0, 0.0);
    float3 up = abs(forward.y) > 0.99 ? float3(0.0, 0.0, forward.y > 0.0 ? 1.0 : -1.0) : float3(0.0, 1.0, 0.0);
    float3 z = -forward;
    float3 x = normalize(cross(up, z));
    float3 y = cross(z, x);
    float s = sin(p.rotation), c = cos(p.rotation);
    float3 rx = x * c + y * s, ry = y * c - x * s;
    return float3x3(rx.x, ry.x, z.x, rx.y, ry.y, z.y, rx.z, ry.z, z.z);
}

// A vector of the space of its mesh in the world: one that tumbles turns in
// the space of its emitter; one that faces its velocity, in the world.
float3 particle_mesh_vector(uint slot, float3x3 rotation, float3 v) {
    return particle_emitters[slot].mesh.y == PARTICLE_FACING_TUMBLE ? particle_world_vector(slot, mul(rotation, v)) : mul(rotation, v);
}

#endif
