// The Vfx programs of the emitters, in the data buffer of the pool: the
// parameters of the program of each emitter, then the Attributes of the
// particles, those of the range of each emitter where its row says.
#ifndef MIRAI_PARTICLE_PROGRAMS_SLANG
#define MIRAI_PARTICLE_PROGRAMS_SLANG
#include "particles.slang"
#include "mirai_vfx.slang"
#ifdef PARTICLES_WRITABLE
[[vk::binding(SLOT_PASS9, 0)]] RWByteAddressBuffer particle_data : register(MIRAI_REGISTER(u, SLOT_PASS9), space0);
#else
[[vk::binding(SLOT_PASS9, 0)]] ByteAddressBuffer particle_data : register(MIRAI_REGISTER(t, SLOT_PASS9), space0);
#endif
// The passes that start and move particles read the depth and the normal of
// the first view of the window.
#ifdef PARTICLE_SCENE_READ
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
#define GBUFFER_NORMAL SLOT_PASS8
#include "gbuffer.slang"
#endif
float4 mirai_vfx_texture(uint index, float2 uv, float level) {
    if (index == INVALID) return float4(1.0);
    return material_textures[mirai_nonuniform(index)].SampleLevel(material_sampler, uv, level);
}

// The point of a triangle of a surface at barycentrics (of its second and
// third corners), as it is this frame, and how fast it moves since the frame
// before over dt seconds.
Mirai_Vfx_Surface particle_surface_at(Particle_Resource r, uint triangle, float2 barycentric, float dt) {
    Mirai_Vfx_Surface s = (Mirai_Vfx_Surface)0;
    if (r.kind != PARTICLE_RESOURCE_SURFACE || triangle >= r.count) return s;
    Mesh m = meshes[r.mesh];
    Cluster cluster = mesh_cluster(m, primitive_cluster(triangle));
    if (primitive_triangle(triangle) >= cluster_triangle_count(cluster) || !cluster_resident(m, cluster)) return s;
    uint3 corner = cluster_triangle(m, cluster, primitive_triangle(triangle));
    Mesh_Point a = cluster_point(m, cluster, corner.x), b = cluster_point(m, cluster, corner.y), c = cluster_point(m, cluster, corner.z);
    float w = 1.0 - barycentric.x - barycentric.y;
    float3 local = a.position * w + b.position * barycentric.x + c.position * barycentric.y;
    float3 before = cluster_position_previous(m, cluster, corner.x, m.previous_word) * w + cluster_position_previous(m, cluster, corner.y, m.previous_word) * barycentric.x
        + cluster_position_previous(m, cluster, corner.z, m.previous_word) * barycentric.y;
    float3 normal = a.normal * w + b.normal * barycentric.x + c.normal * barycentric.y;
    s.position = transform_point(r.world, local);
    s.velocity = dt > 0.0 ? (s.position - transform_point(r.previous, before)) / dt : float3(0.0);
    float3 turned = transform_vector(r.world, normal);
    s.normal = dot(turned, turned) > 1e-12 ? normalize(turned) : float3(0.0, 1.0, 0.0);
    s.uv = a.uv * w + b.uv * barycentric.x + c.uv * barycentric.y;
    s.triangle = triangle;
    s.barycentric = barycentric;
    s.valid = true;
    return s;
}

// A point of a surface chosen by area: the triangle whose running area
// passes a random share of the whole, and a point of it chosen evenly.
Mirai_Vfx_Surface particle_surface_sample(Particle_Resource r, inout uint seed, float dt) {
    if (r.kind != PARTICLE_RESOURCE_SURFACE || r.count == 0u) return (Mirai_Vfx_Surface)0;
    float wanted = random01(seed) * particle_surface_area(r.first + r.count - 1u);
    uint low = 0u, high = r.count - 1u;
    while (low < high) {
        uint middle = (low + high) / 2u;
        if (particle_surface_area(r.first + middle) <= wanted) low = middle + 1u; else high = middle;
    }
    float along = sqrt(random01(seed)), across = random01(seed);
    return particle_surface_at(r, low, float2(along * (1.0 - across), along * across), dt);
}

Mirai_Vfx_Surface mirai_vfx_surface_sample(Mirai_Vfx_Context ctx, uint resource, inout uint seed) {
    return particle_surface_sample(particle_resource(ctx.emitter, 1u + resource), seed, particle_emitters[ctx.emitter].step.x);
}

Mirai_Vfx_Surface mirai_vfx_surface_at(Mirai_Vfx_Context ctx, uint resource, uint triangle, float2 barycentric) {
    return particle_surface_at(particle_resource(ctx.emitter, 1u + resource), triangle, barycentric, particle_emitters[ctx.emitter].step.x);
}

// A point of a bone of the Bones shape: where it is in the world, the way the
// bone goes (from the joint of its parent to its own) and how fast it moves.
struct Particle_Bone {
    float3 position;
    float3 axis;
    float3 velocity;   // m/s
    bool valid;
};

// The point of a bone at along (0: the joint of its parent, 1: its own), as
// it is this frame, and how fast it moves since the frame before over dt.
Particle_Bone particle_bone_at(Particle_Resource r, uint bone, float along, float dt) {
    Particle_Bone b = (Particle_Bone)0;
    if (r.kind != PARTICLE_RESOURCE_BONES || bone >= r.count) return b;
    Particle_Segment s = particle_segment_at(r.first + bone * PARTICLE_SEGMENT_BYTES);
    b.position = transform_point(r.world, lerp(s.start, s.end, along));
    float3 before = transform_point(r.previous, lerp(s.previous_start, s.previous_end, along));
    b.velocity = dt > 0.0 ? (b.position - before) / dt : float3(0.0);
    float3 axis = transform_vector(r.world, s.end - s.start);
    b.axis = dot(axis, axis) > 1e-12 ? normalize(axis) : float3(0.0, 1.0, 0.0);
    b.valid = true;
    return b;
}

// A point of the bones chosen by length: the bone whose running length
// passes a random share of the whole, and a point of it chosen evenly.
Particle_Bone particle_bone_sample(Particle_Resource r, inout uint seed, float dt) {
    if (r.kind != PARTICLE_RESOURCE_BONES || r.count == 0u) return (Particle_Bone)0;
    float wanted = random01(seed) * particle_segment_at(r.first + (r.count - 1u) * PARTICLE_SEGMENT_BYTES).length;
    uint low = 0u, high = r.count - 1u;
    while (low < high) {
        uint middle = (low + high) / 2u;
        if (particle_segment_at(r.first + middle * PARTICLE_SEGMENT_BYTES).length <= wanted) low = middle + 1u; else high = middle;
    }
    return particle_bone_at(r, low, random01(seed), dt);
}

// The grid of a resource of an emitter; false without one.
bool particle_grid_of(uint slot, uint resource, out Particle_Grid_Row g) {
    Particle_Resource r = particle_resource(slot, 1u + resource);
    g = (Particle_Grid_Row)0;
    if (r.kind != PARTICLE_RESOURCE_GRID) return false;
    g = particle_grid_row_at(r.mesh);
    return true;
}

// Where a cell of the world is among those of a grid, which wrap in place; false outside
// its region. An axis of one cell takes every index.
bool particle_grid_cell(Particle_Grid_Row g, int3 index, out uint at) {
    uint3 local = uint3(0u);
    at = 0u;
    for (uint axis = 0u; axis < 3u; axis++) {
        int cells = int(g.cells[axis]);
        if (cells <= 1) continue;
        int along = index[axis] - g.first[axis];
        if (along < 0 || along >= cells) return false;
        // phase < cells (grid_phase): one wrap at most, without the cost of a remainder.
        uint wrapped = uint(along) + g.phase[axis];
        local[axis] = wrapped >= uint(cells) ? wrapped - uint(cells) : wrapped;
    }
    at = local.x + g.cells.x * (local.y + g.cells.y * local.z);
    return true;
}

// The copy of a grid that holds what the stage before left.
uint particle_grid_copy(Particle_Grid_Row g) { return particle_world_bytes.Load(g.parity) & 1u; }

uint particle_grid_address(Particle_Grid_Row g, uint copy, uint at, uint layer) {
    return g.offset + ((copy * g.cells.x * g.cells.y * g.cells.z + at) * g.layers + layer) * 16u;
}

float4 particle_grid_read(Particle_Grid_Row g, uint copy, int3 index, uint layer) {
    uint at;
    if (layer >= g.layers || !particle_grid_cell(g, index, at)) return float4(0.0);
    return asfloat(particle_world_bytes.Load4(particle_grid_address(g, copy, at, layer)));
}

// The cell of the world of a point (relative to the origin of the frame), and how far into
// it the point is, from the middle of the cell before; an axis of one cell takes its cell.
void particle_grid_corner(Particle_Grid_Row g, float3 position, out int3 low, out float3 along) {
    float3 u = (position - g.corner) / max(g.cell_size, 1e-6) - 0.5;
    float3 below = floor(u);
    low = g.first + int3(below);
    along = u - below;
    for (uint axis = 0u; axis < 3u; axis++) {
        if (g.cells[axis] <= 1u) { low[axis] = g.first[axis]; along[axis] = 0.0; }
    }
}

Mirai_Vfx_Grid mirai_vfx_grid(Mirai_Vfx_Context ctx, uint resource) {
    Mirai_Vfx_Grid info = (Mirai_Vfx_Grid)0;
    Particle_Grid_Row g;
    if (!particle_grid_of(ctx.emitter, resource, g)) return info;
    info.cells = int3(g.cells); info.cell_size = g.cell_size; info.first = g.first; info.layers = g.layers; info.corner = g.corner; info.valid = true;
    return info;
}

float4 mirai_vfx_grid_load(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer) {
    Particle_Grid_Row g;
    if (!particle_grid_of(ctx.emitter, resource, g)) return float4(0.0);
    return particle_grid_read(g, particle_grid_copy(g), index, layer);
}

// A layer of a copy of a grid at a point of the world, between its cells.
// The cells of the world around a point and their trilinear weights, a weight 0 where a cell is
// out of the grid: worked out once for every layer and buffer a point reads.
struct Particle_Grid_Corners { uint at[8]; float weight[8]; };

Particle_Grid_Corners particle_grid_corners(Particle_Grid_Row g, float3 position) {
    Particle_Grid_Corners c;
    int3 low;
    float3 along;
    particle_grid_corner(g, position, low, along);
    for (uint corner = 0u; corner < 8u; corner++) {
        uint3 side = uint3(corner & 1u, (corner >> 1u) & 1u, corner >> 2u);
        float3 weights = lerp(1.0 - along, along, float3(side));
        c.weight[corner] = weights.x * weights.y * weights.z;
        if (!(c.weight[corner] > 0.0) || !particle_grid_cell(g, low + int3(side), c.at[corner])) { c.weight[corner] = 0.0; c.at[corner] = 0u; }
    }
    return c;
}

float4 particle_grid_sample_corners(Particle_Grid_Row g, uint copy, Particle_Grid_Corners c, uint layer) {
    if (layer >= g.layers) return float4(0.0);
    float4 sum = float4(0.0);
    for (uint corner = 0u; corner < 8u; corner++) {
        if (c.weight[corner] > 0.0) sum += c.weight[corner] * asfloat(particle_world_bytes.Load4(particle_grid_address(g, copy, c.at[corner], layer)));
    }
    return sum;
}

float4 particle_grid_sample_row(Particle_Grid_Row g, uint copy, float3 position, uint layer) {
    return particle_grid_sample_corners(g, copy, particle_grid_corners(g, position), layer);
}

float4 mirai_vfx_grid_sample(Mirai_Vfx_Context ctx, uint resource, float3 position, uint layer) {
    Particle_Grid_Row g;
    if (!particle_grid_of(ctx.emitter, resource, g)) return float4(0.0);
    return particle_grid_sample_row(g, particle_grid_copy(g), position, layer);
}

// What the cells of a volume around a point receive, between them: rgb from around and
// the local lights, a from the sun.
float4 particle_volume_light(Particle_Volume_Row v, Particle_Grid_Corners c) {
    float4 sum = float4(0.0);
    for (uint corner = 0u; corner < 8u; corner++) {
        if (c.weight[corner] > 0.0) sum += c.weight[corner] * asfloat(particle_world_bytes.Load4(v.light + c.at[corner] * 16u));
    }
    return sum;
}

float4 mirai_vfx_grid_splatted(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer) {
    Particle_Grid_Row g;
    uint at;
    if (!particle_grid_of(ctx.emitter, resource, g) || layer >= g.layers || !particle_grid_cell(g, index, at)) return float4(0.0);
    return asfloat(particle_world_bytes.Load4(g.splat + (at * g.layers + layer) * 16u));
}

void mirai_vfx_grid_store(Mirai_Vfx_Cell cell, uint layer, float4 value) {
#ifdef PARTICLES_WRITABLE
    Particle_Grid_Row g;
    uint at;
    if (!particle_grid_of(cell.ctx.emitter, cell.grid, g) || layer >= g.layers || !particle_grid_cell(g, cell.index, at)) return;
    particle_world_bytes.Store4(particle_grid_address(g, particle_grid_copy(g) ^ 1u, at, layer), asuint(value));
#endif
}

#ifdef PARTICLES_WRITABLE
// Adds to a float of the world buffer that other threads add to.
void particle_world_add(uint address, float value) {
    if (value == 0.0) return;
    uint before = particle_world_bytes.Load(address);
    for (uint tries = 0u; tries < 64u; tries++) {
        uint seen;
        particle_world_bytes.InterlockedCompareExchange(address, before, asuint(asfloat(before) + value), seen);
        if (seen == before) return;
        before = seen;
    }
}
#endif

void mirai_vfx_grid_splat(Mirai_Vfx_Context ctx, uint resource, float3 position, uint layer, float4 value) {
#ifdef PARTICLES_WRITABLE
    Particle_Grid_Row g;
    if (!particle_grid_of(ctx.emitter, resource, g) || layer >= g.layers) return;
    int3 low;
    float3 along;
    particle_grid_corner(g, position, low, along);
    for (uint corner = 0u; corner < 8u; corner++) {
        uint3 side = uint3(corner & 1u, (corner >> 1u) & 1u, corner >> 2u);
        float3 weights = lerp(1.0 - along, along, float3(side));
        float weight = weights.x * weights.y * weights.z;
        uint at;
        if (!(weight > 0.0) || !particle_grid_cell(g, low + int3(side), at)) continue;
        uint address = g.splat + (at * g.layers + layer) * 16u;
        for (uint c = 0u; c < 4u; c++) particle_world_add(address + c * 4u, value[c] * weight);
    }
#endif
}

// Where the Attributes of the particle at index of the pool are.
uint particle_attributes(uint slot, uint index) {
    uint2 data = particle_emitters[slot].data.xy;
    return data.x + (index - particle_emitters[slot].range.x) * data.y;
}

// The seed of the particle an emitter starts as its birth-th; the table of
// the lists after the drawn ones keeps the slot of each birth, by birth
// modulo the range.
uint particle_birth_seed(uint slot, uint birth) { return hash_u32(hash_u32(particle_emitters[slot].random.x * 9781u + birth * 26699u) ^ 0x9E3779B9u); }
uint particle_birth_entry(uint slot, uint birth) {
    uint2 range = particle_emitters[slot].range.xy;
    return 2u * particle_emitters[slot].program.y + range.x + birth % max(range.y, 1u);
}

// What the program of an emitter keeps of it between its prepare and the rest of the frame.
uint mirai_vfx_state_load(Mirai_Vfx_Context ctx, uint word) {
    return word * 4u < PARTICLE_STATE_BYTES ? particle_data.Load(PARTICLE_STATES_AT + ctx.emitter * PARTICLE_STATE_BYTES + word * 4u) : 0u;
}
#ifdef PARTICLES_WRITABLE
void mirai_vfx_state_store(Mirai_Vfx_Context ctx, uint word, uint value) {
    if (word * 4u < PARTICLE_STATE_BYTES) particle_data.Store(PARTICLE_STATES_AT + ctx.emitter * PARTICLE_STATE_BYTES + word * 4u, value);
}
#else
void mirai_vfx_state_store(Mirai_Vfx_Context ctx, uint word, uint value) {}
#endif

// The slot of the emitter a resource of the emitter of ctx reads; false without one.
bool particle_emitter_resource(Mirai_Vfx_Context ctx, uint resource, out uint other) {
    Particle_Resource r = particle_resource(ctx.emitter, 1u + resource);
    other = 0u;
    if (r.kind != PARTICLE_RESOURCE_EMITTER) return false;
    other = r.first;
    return (particle_emitters[other].range.w & PARTICLE_FLAG_ACTIVE) != 0u;
}

uint mirai_vfx_emitter_capacity(Mirai_Vfx_Context ctx, uint resource) {
    uint other;
    return particle_emitter_resource(ctx, resource, other) ? particle_emitters[other].range.y : 0u;
}

bool mirai_vfx_emitter_particle(Mirai_Vfx_Context ctx, uint resource, uint slot, out Mirai_Vfx_Particle value) {
    uint other;
    value = (Mirai_Vfx_Particle)0;
    if (!particle_emitter_resource(ctx, resource, other) || slot >= particle_emitters[other].range.y) return false;
    Particle p = particles[particle_emitters[other].range.x + slot];
    if (p.lifetime <= 0.0) return false;
    value = particle_program_value(other, p);
    return true;
}

uint mirai_vfx_emitter_word(Mirai_Vfx_Context ctx, uint resource, uint slot, uint word) {
    uint other;
    if (!particle_emitter_resource(ctx, resource, other) || slot >= particle_emitters[other].range.y || word * 4u >= particle_emitters[other].data.y) return 0u;
    return particle_data.Load(particle_attributes(other, particle_emitters[other].range.x + slot) + word * 4u);
}

uint2 mirai_vfx_emitter_births(Mirai_Vfx_Context ctx, uint resource) {
    uint other;
    if (!particle_emitter_resource(ctx, resource, other)) return uint2(0u);
#ifdef PARTICLES_WRITABLE
    if ((particle_emitters[other].range.w & PARTICLE_FLAG_BIRTHS) != 0u) return uint2(particle_states[other].born - particle_states[other].births, particle_states[other].births);
#endif
    return uint2(particle_emitters[other].data.w, particle_emitters[other].range.z);
}

int mirai_vfx_emitter_birth(Mirai_Vfx_Context ctx, uint resource, uint birth, out uint seed) {
    uint other;
    seed = 0u;
    if (!particle_emitter_resource(ctx, resource, other)) return -1;
    uint2 range = particle_emitters[other].range.xy;
    if (range.y == 0u) return -1;
    seed = particle_birth_seed(other, birth);
    uint slot = particle_lists[particle_birth_entry(other, birth)];
    if (slot >= range.y) return -1;
    Particle p = particles[range.x + slot];
    return p.lifetime > 0.0 && p.seed == seed ? int(slot) : -1;
}

// A data channel (vfx/runtime/data.odin): its bytes in the world buffer, the
// words of an entry and the copy the frame writes.
struct Particle_Data_Channel { uint at; uint words; uint parity; };

bool particle_data_of(Mirai_Vfx_Context ctx, uint resource, out Particle_Data_Channel d) {
    Particle_Resource r = particle_resource(ctx.emitter, 1u + resource);
    d.at = r.mesh; d.words = r.first; d.parity = r.count;
    return r.kind == PARTICLE_RESOURCE_DATA && d.words > 0u;
}

// Where a copy is: its counter, padding, then its entries.
uint particle_data_copy(Particle_Data_Channel d, uint parity) { return d.at + parity * (16u + PARTICLE_DATA_ENTRIES * d.words * 4u); }

uint particle_data_written(Particle_Data_Channel d) {
    return min(particle_world_bytes.Load(particle_data_copy(d, 1u - d.parity)), PARTICLE_DATA_ENTRIES);
}

uint mirai_vfx_data_count(Mirai_Vfx_Context ctx, uint resource) {
    Particle_Data_Channel d;
    if (!particle_data_of(ctx, resource, d)) return 0u;
    return particle_data_written(d);
}

uint mirai_vfx_data_word(Mirai_Vfx_Context ctx, uint resource, uint entry, uint word) {
    Particle_Data_Channel d;
    if (!particle_data_of(ctx, resource, d) || word >= d.words) return 0u;
    if (entry >= particle_data_written(d)) return 0u;
    return particle_world_bytes.Load(particle_data_copy(d, 1u - d.parity) + 16u + (entry * d.words + word) * 4u);
}

// Updates and stages append to data channels in the last step of the frame
// alone: a frame of several steps would write each entry once a step.
static bool particle_step_last = true;

#ifdef PARTICLES_WRITABLE
bool mirai_vfx_data_append(Mirai_Vfx_Context ctx, uint resource, out uint entry) {
    entry = 0u;
    Particle_Data_Channel d;
    if (!particle_step_last || !particle_data_of(ctx, resource, d)) return false;
    particle_world_bytes.InterlockedAdd(particle_data_copy(d, d.parity), 1u, entry);
    return entry < PARTICLE_DATA_ENTRIES;
}

void mirai_vfx_data_store(Mirai_Vfx_Context ctx, uint resource, uint entry, uint word, uint value) {
    Particle_Data_Channel d;
    if (!particle_data_of(ctx, resource, d) || word >= d.words || entry >= PARTICLE_DATA_ENTRIES) return;
    particle_world_bytes.Store(particle_data_copy(d, d.parity) + 16u + (entry * d.words + word) * 4u, value);
}
#else
bool mirai_vfx_data_append(Mirai_Vfx_Context ctx, uint resource, out uint entry) { entry = 0u; return false; }
void mirai_vfx_data_store(Mirai_Vfx_Context ctx, uint resource, uint entry, uint word, uint value) {}
#endif

uint2 mirai_vfx_particle_id(Mirai_Vfx_Context ctx) {
    if (ctx.particle == INVALID) return uint2(INVALID, 0u);
    return uint2(ctx.particle - particle_emitters[ctx.emitter].range.x, particles[ctx.particle].seed);
}

// The address of a word of a cell of a grid resource in the copy that the
// stage leaves; false outside its region.
bool particle_grid_word(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, bool written, out uint address) {
    Particle_Grid_Row g;
    uint at;
    address = 0u;
    if (!particle_grid_of(ctx.emitter, resource, g) || word >= g.layers * 4u || !particle_grid_cell(g, index, at)) return false;
    uint copy = particle_grid_copy(g) ^ (written ? 1u : 0u);
    address = particle_grid_address(g, copy, at, word / 4u) + (word % 4u) * 4u;
    return true;
}

float4 mirai_vfx_grid_load_written(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer) {
    uint address;
    if (!particle_grid_word(ctx, resource, index, layer * 4u, true, address)) return float4(0.0);
    return asfloat(particle_world_bytes.Load4(address));
}

uint mirai_vfx_grid_word_load(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, bool written) {
    uint address;
    if (!particle_grid_word(ctx, resource, index, word, written, address)) return 0u;
    return particle_world_bytes.Load(address);
}

void mirai_vfx_grid_write(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer, float4 value) {
#ifdef PARTICLES_WRITABLE
    uint address;
    if (particle_grid_word(ctx, resource, index, layer * 4u, true, address)) particle_world_bytes.Store4(address, asuint(value));
#endif
}

void mirai_vfx_grid_word_store(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, uint value) {
#ifdef PARTICLES_WRITABLE
    uint address;
    if (particle_grid_word(ctx, resource, index, word, true, address)) particle_world_bytes.Store(address, value);
#endif
}

uint mirai_vfx_grid_word_add(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, uint value) {
    uint before = 0u;
#ifdef PARTICLES_WRITABLE
    uint address;
    if (particle_grid_word(ctx, resource, index, word, true, address)) particle_world_bytes.InterlockedAdd(address, value, before);
#endif
    return before;
}

Mirai_Vfx_View mirai_vfx_view() {
    Mirai_Vfx_View v;
    v.position = frame.camera_position.xyz;
    v.forward = frame.camera_forward.xyz;
    // The matrices of the frame take a point from the eye; those of the view, a place.
    float4x4 from_eye = float4x4(float4(1, 0, 0, -v.position.x), float4(0, 1, 0, -v.position.y), float4(0, 0, 1, -v.position.z), float4(0, 0, 0, 1));
    float4x4 to_eye = float4x4(float4(1, 0, 0, v.position.x), float4(0, 1, 0, v.position.y), float4(0, 0, 1, v.position.z), float4(0, 0, 0, 1));
    v.view = mul(frame.view, from_eye);
    v.projection = frame.proj;
    v.view_projection = mul(frame.view_proj, from_eye);
    v.inverse_view_projection = mul(to_eye, frame.inv_view_proj);
    v.resolution = frame.resolution;
    v.near = frame.camera_position.w;
    v.far = frame.camera_forward.w;
    return v;
}

float mirai_vfx_scene_depth(float2 uv) {
#ifdef PARTICLE_SCENE_READ
    if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) return 0.0;
    return g_depth.Load(int3(int2(uv * frame.resolution), 0)).r;
#else
    return 0.0;
#endif
}

float3 mirai_vfx_scene_normal(float2 uv) {
#ifdef PARTICLE_SCENE_READ
    if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) return float3(0.0);
    return normalize(gbuffer_normal(int2(uv * frame.resolution)));
#else
    return float3(0.0);
#endif
}

float mirai_vfx_scene_roughness(float2 uv) {
#ifdef PARTICLE_SCENE_READ
    if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) return 1.0;
    return gbuffer_normal_roughness(int2(uv * frame.resolution)).w;
#else
    return 1.0;
#endif
}

// The scene, for the shaders that trace it (trace.slang before this file): the
// sprite and mesh vertices do not, and their render meets nothing.
#ifdef MIRAI_TRACE_SLANG
Mirai_Vfx_Hit mirai_vfx_trace(Mirai_Vfx_Context ctx, float3 origin, float3 direction, float distance) {
    Mirai_Vfx_Hit h = (Mirai_Vfx_Hit)0;
    float length_of = length(direction);
    if (!(length_of > 1e-8) || !(distance > 0.0)) return h;
    float3 d = direction / length_of;
    Hit found = trace_ray_impl(origin, d, 0.0, distance, false, BLEND_PASSES, RAY_OPAQUE);
    if (found.instance == INVALID) return h;
    bool blended;
    h.hit = true;
    h.distance = found.t;
    h.normal = hit_normal(found.instance, found.primitive, found.bary, d, blended);
    // The face as its corners wind: facing along the ray, the ray is inside.
    Instance inst = scene_instance(found.instance);
    float3 a, b, c;
    uint material;
    mesh_triangle_positions(meshes[instance_mesh(inst)], found.primitive, a, b, c, material);
    h.inside = dot(transform_normal(inst.world_inv, cross(b - a, c - a)), d) > 0.0;
    return h;
}
#else
Mirai_Vfx_Hit mirai_vfx_trace(Mirai_Vfx_Context ctx, float3 origin, float3 direction, float distance) { return (Mirai_Vfx_Hit)0; }
#endif

uint mirai_vfx_channel_count(Mirai_Vfx_Context ctx, uint resource) {
    Particle_Resource r = particle_resource(ctx.emitter, 1u + resource);
    return r.kind == PARTICLE_RESOURCE_CHANNEL ? r.count : 0u;
}

Mirai_Vfx_Birth mirai_vfx_channel_birth(Mirai_Vfx_Context ctx, uint resource, uint index) {
    Particle_Resource r = particle_resource(ctx.emitter, 1u + resource);
    Mirai_Vfx_Birth birth = (Mirai_Vfx_Birth)0;
    if (r.kind != PARTICLE_RESOURCE_CHANNEL || index >= r.count) return birth;
    Particle_Birth b = particle_birth_at(particle_emitters[ctx.emitter].frame.w + (r.first + index) * PARTICLE_BIRTH_BYTES);
    birth.position = b.position; birth.velocity = b.velocity; birth.color = b.color;
    birth.size = b.size; birth.count = b.count; birth.values = b.values;
    return birth;
}
#include <vfx_programs.slang>

void particle_parameters(uint slot, out float4 packed[16]) {
    uint at = slot * PROGRAM_PARAMETER_BYTES;
    for (uint i = 0u; i < 16u; i++) packed[i] = asfloat(particle_data.Load4(at + i * 16u));
}

Mirai_Vfx_Context particle_program_context(uint slot, float time, float dt) {
    Mirai_Vfx_Context ctx;
    ctx.emitter = slot;
    ctx.particle = INVALID;
    ctx.values = float4(0.0);
    ctx.time = time;
    ctx.delta_time = dt;
    ctx.world = particle_emitters[slot].world;
    ctx.origin = float3(ctx.world[0].w, ctx.world[1].w, ctx.world[2].w);
    ctx.axis = normalize(transform_vector(ctx.world, float3(0.0, 1.0, 0.0)));
    ctx.emitter_age = asfloat(particle_emitters[slot].data.z);
    ctx.born = particle_emitters[slot].data.w;
#ifdef PARTICLES_WRITABLE
    if ((particle_emitters[slot].range.w & PARTICLE_FLAG_BIRTHS) != 0u) ctx.born = particle_states[slot].born - particle_states[slot].births;
#endif
    ctx.birth = INVALID;
    ctx.spawned = 0u;
    ctx.iteration = 0u;
    return ctx;
}

// A particle in the world, as programs see it. Its color only for an emitter with a program:
// nothing else reads it.
Mirai_Vfx_Particle particle_program_value(uint slot, Particle p) {
    Mirai_Vfx_Particle v;
    v.position = particle_world(slot, p.position);
    v.velocity = particle_world_vector(slot, p.velocity);
    v.age = p.age; v.lifetime = p.lifetime;
    v.size = p.size; v.rotation = p.rotation; v.spin = p.spin; v.seed = p.seed;
    v.color = particle_emitters[slot].program.x != 0u ? particle_color(p) : float4(0.0);
    v.ribbon = particle_ribbon(p);
    return v;
}

#ifdef PARTICLES_WRITABLE
// A particle of the world back into the pool, in the space of its emitter; its color when
// color says it may have changed.
void particle_program_store(uint slot, Mirai_Vfx_Particle v, bool color, inout Particle p) {
    if ((particle_emitters[slot].range.w & PARTICLE_FLAG_LOCAL) != 0u) {
        float4 world[3] = particle_emitters[slot].world;
        p.position = inverse_transform_point(world, v.position);
        p.velocity = inverse_transform_vector(world, v.velocity);
    } else {
        p.position = v.position;
        p.velocity = v.velocity;
    }
    p.age = v.age; p.lifetime = v.lifetime;
    p.size = max(v.size, 0.0); p.rotation = v.rotation; p.spin = v.spin; p.seed = v.seed;
    p.flags = (p.flags & ((1u << RIBBON_SHIFT) - 1u)) | ((v.ribbon & PARTICLE_RIBBON_MASK) << RIBBON_SHIFT);
    if (color) p.color = particle_color_pack(v.color);
}

// The program of the emitter starts a particle: its Attributes from zero.
// values: those of the birth of a channel that started it.
void particle_program_initialize(uint slot, uint index, uint birth, float time, float4 values, inout Mirai_Vfx_Particle v) {
    uint program = particle_emitters[slot].program.x;
    if (program == 0u) return;
    float4 packed[16];
    particle_parameters(slot, packed);
    Mirai_Vfx_Context ctx = particle_program_context(slot, time, 0.0);
    ctx.values = values;
    ctx.particle = index;
    ctx.birth = birth;
    // The births of the frame: those its program gave, else those of its effect.
    uint4 range = particle_emitters[slot].range;
    ctx.spawned = (range.w & PARTICLE_FLAG_BIRTHS) != 0u ? particle_states[slot].births : range.z;
    mirai_vfx_initialize(program, packed, particle_attributes(slot, index), ctx, v);
}

void particle_program_update(uint slot, uint index, float time, float dt, inout Mirai_Vfx_Particle v) {
    uint program = particle_emitters[slot].program.x;
    if (program == 0u) return;
    float4 packed[16];
    particle_parameters(slot, packed);
    Mirai_Vfx_Context ctx = particle_program_context(slot, time, dt);
    ctx.particle = index;
    mirai_vfx_update(program, packed, particle_attributes(slot, index), ctx, v);
}
#endif

// What a particle of a ribbon shows, kept after the Attributes of its program
// (RIBBON_LOOK_BYTES): its vertices read it for both ends of their segment.
uint particle_ribbon_look_at(uint slot, uint index) {
    return particle_attributes(slot, index) + particle_emitters[slot].data.y - RIBBON_LOOK_BYTES;
}
Particle_Look particle_ribbon_look(uint slot, uint index) {
    uint at = particle_ribbon_look_at(slot, index);
    Particle_Look look;
    look.color = asfloat(particle_data.Load4(at));
    float4 w = asfloat(particle_data.Load4(at + 16u));
    look.size = w.x; look.frame = w.y; look.random = w.z; look.given = asuint(w.w);
    for (uint i = 0u; i < 4u; i++) look.data[i] = asfloat(particle_data.Load4(at + 32u + i * 16u));
    return look;
}
#ifdef PARTICLES_WRITABLE
void particle_ribbon_look_store(uint slot, uint index, Particle_Look look) {
    uint at = particle_ribbon_look_at(slot, index);
    particle_data.Store4(at, asuint(look.color));
    particle_data.Store4(at + 16u, uint4(asuint(look.size), asuint(look.frame), asuint(look.random), look.given));
    for (uint i = 0u; i < 4u; i++) particle_data.Store4(at + 32u + i * 16u, asuint(look.data[i]));
}
#endif

// What a particle shows, after the program of its emitter.
Particle_Look particle_program_look(uint slot, uint index, Particle p) {
    Particle_Look look = particle_look(slot, p);
    uint program = particle_emitters[slot].program.x;
    if (program == 0u) return look;
    float4 packed[16];
    particle_parameters(slot, packed);
    Mirai_Vfx_Visual visual;
    visual.color = look.color; visual.size = look.size; visual.frame = look.frame; visual.data = look.data; visual.given = look.given; visual.random = look.random;
    Mirai_Vfx_Context ctx = particle_program_context(slot, particle_emitters[slot].step.w, 0.0);
    ctx.particle = index;
    if (mirai_vfx_render(program, packed, particle_attributes(slot, index), ctx, particle_program_value(slot, p), visual)) {
        look.color = visual.color; look.size = max(visual.size, 0.0); look.frame = visual.frame; look.data = visual.data; look.given = visual.given; look.random = saturate(visual.random);
    }
    return look;
}
#endif
