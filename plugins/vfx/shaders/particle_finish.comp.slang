#include "native.slang"
// A group per emitter, once a frame: the indirect draw of what is alive, for
// an emitter that sorts its list back to front (a ribbon: by its ribbon, then
// youngest first, the order it was laid along its path, the slot breaking
// ties so a burst keeps one order), and for a ribbon the pieces each segment
// is cut into to follow the curve through its particles, the most its turn
// needs to stay within about a pixel, rising at once and coming down a piece
// a frame. Mesh particles: a run of the list for each mesh of the emitter,
// and its draw.
#define PARTICLES_WRITABLE
#define PARTICLES_COUNTED
#include "particles.slang"
#define MIRAI_GROUP_X 512
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mode; uint emitters; uint count; uint parity; uint step; uint last; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The counters "particles" (render.pass_counters): those alive and the emitters that have some.
[[vk::binding(SLOT_PASS9, 0)]] RWStructuredBuffer<uint> counted : register(MIRAI_REGISTER(u, SLOT_PASS9), space0);

// The error a ribbon may leave between the curve through its particles and
// the straight pieces it is drawn with, metres: at least the first, and
// growing with the distance from the eye by the second, about one pixel of a
// view 1080 pixels high and 60 degrees wide.
#define RIBBON_ERROR_MIN 0.002
#define RIBBON_ERROR_SLOPE 0.001

// What a particle is ordered by, in two words: its age (a ribbon) or its
// depth; and its slot in the range, below SORT_SLOT_BITS, under its ribbon,
// which comes first (RIBBON_SHIFT: as wide as the rest of the word).
groupshared float keys[PARTICLE_SORT_MAX];
groupshared uint values[PARTICLE_SORT_MAX];
groupshared uint partial[MIRAI_GROUP_X];
groupshared uint mesh_counts[PARTICLE_MESHES];
groupshared uint mesh_cursors[PARTICLE_MESHES];

bool sorted_before(uint a, uint b) {
    uint ra = values[a] >> SORT_SLOT_BITS, rb = values[b] >> SORT_SLOT_BITS;
    if (ra != rb) return ra < rb;
    if (keys[a] != keys[b]) return keys[a] < keys[b];
    return values[a] < values[b];
}

float3 unit(float3 v) { return length(v) > 1e-6 ? normalize(v) : float3(0.0); }

// The pieces a segment from a to b needs so that each straight piece stays
// within error of the arc that turns from the direction ta at a to tb at b:
// an arc turning by angle over a chord of length c has radius
// c / (2 sin(angle / 2)), and a piece of it that turns by phi strays from its
// chord by radius (1 - cos(phi / 2)).
uint segment_pieces(float3 a, float3 b, float3 ta, float3 tb, float error) {
    float chord = length(b - a);
    float turn = acos(clamp(dot(ta, tb), -1.0, 1.0));
    if (chord <= 1e-6 || turn <= 1e-3) return 1u;
    float radius = chord / (2.0 * sin(turn * 0.5));
    float phi = 2.0 * acos(clamp(1.0 - error / radius, -1.0, 1.0));
    return uint(clamp(ceil(turn / max(phi, 1e-4)), 1.0, float(RIBBON_PIECES)));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID) {
    uint slot = group.x;
    uint t = local.x;
    Particle_Emitter e = particle_emitters[slot];
    bool active = (e.range.w & PARTICLE_FLAG_ACTIVE) != 0u;
    uint alive = active ? min(particle_states[slot].alive, e.range.y) : 0u;
    bool ribbon = e.kinds.y == PARTICLE_RENDER_RIBBON;
    uint drawn = e.program.y + e.range.x;
    // The events of the last step started their particles already.
    if (slot == 0u && t == 0u) particle_queue[params.parity] = 0u;
    if ((e.range.w & PARTICLE_FLAG_SORT) != 0u && alive >= 2u) {
        uint n = min(alive, PARTICLE_SORT_MAX);
        uint size = 2u;
        while (size < n) size <<= 1u;
        for (uint i = t; i < size; i += MIRAI_GROUP_X) {
            if (i < n) {
                uint index = particle_lists[drawn + i];
                Particle p = particles[index];
                float3 world = particle_world(slot, p.position);
                keys[i] = ribbon ? p.age : -dot(world - frame.camera_position.xyz, frame.camera_forward.xyz);
                values[i] = ((ribbon ? particle_ribbon(p) : 0u) << SORT_SLOT_BITS) | (index - e.range.x);
            } else {
                keys[i] = FLT_MAX;
                values[i] = 0xFFFFFFFFu;
            }
        }
        GroupMemoryBarrierWithGroupSync();
        for (uint k = 2u; k <= size; k <<= 1u) {
            for (uint j = k >> 1u; j > 0u; j >>= 1u) {
                for (uint i = t; i < size; i += MIRAI_GROUP_X) {
                    uint other = i ^ j;
                    if (other > i && sorted_before(other, i) == ((i & k) == 0u)) {
                        float key = keys[i]; keys[i] = keys[other]; keys[other] = key;
                        uint value = values[i]; values[i] = values[other]; values[other] = value;
                    }
                }
                GroupMemoryBarrierWithGroupSync();
            }
        }
        for (uint i = t; i < n; i += MIRAI_GROUP_X) particle_lists[drawn + i] = e.range.x + (values[i] & ((1u << SORT_SLOT_BITS) - 1u));
        DeviceMemoryBarrierWithGroupSync();
    }
    // A ribbon: the pieces of each segment, none where the ribbon changes,
    // and where the quads of each start (the quarter of the lists after the
    // births): its draw has their sum.
    uint total = alive;
    if (ribbon) {
        uint segments = alive >= 2u ? min(alive, PARTICLE_SORT_MAX) - 1u : 0u;
        uint starts = 3u * e.program.y + e.range.x;
        for (uint i = t; i < segments; i += MIRAI_GROUP_X) {
            uint index_a = particle_lists[drawn + i];
            Particle a = particles[index_a];
            Particle b = particles[particle_lists[drawn + i + 1u]];
            uint id_a = particle_ribbon(a);
            uint pieces = 0u;
            if (id_a == particle_ribbon(b)) {
                float3 pa = particle_world(slot, a.position), pb = particle_world(slot, b.position);
                float3 ta = pb - pa, tb = pb - pa;
                if (i > 0u) {
                    Particle before = particles[particle_lists[drawn + i - 1u]];
                    if (particle_ribbon(before) == id_a) ta = ribbon_tangent(particle_world(slot, before.position), pa, pb);
                }
                if (i + 2u < alive) {
                    Particle after = particles[particle_lists[drawn + i + 2u]];
                    if (particle_ribbon(after) == id_a) tb = ribbon_tangent(pa, pb, particle_world(slot, after.position));
                }
                float error = max(RIBBON_ERROR_MIN, RIBBON_ERROR_SLOPE * length(pa - frame.camera_position.xyz));
                // It rises at once and comes down a piece a frame, so that it does not flicker.
                pieces = max(segment_pieces(pa, pb, unit(ta), unit(tb), error), max(particle_pieces(a), 2u) - 1u);
            }
            particles[index_a].flags = (a.flags & ~(PARTICLE_PIECES_MASK << RIBBON_PIECES_SHIFT)) | (pieces << RIBBON_PIECES_SHIFT);
            values[i] = pieces;
        }
        GroupMemoryBarrierWithGroupSync();
        // An exclusive scan: each thread adds up a run of four, the runs scan by doubling.
        uint run = t * 4u, sum = 0u;
        uint own[4];
        for (uint k = 0u; k < 4u; k++) {
            own[k] = run + k < segments ? values[run + k] : 0u;
            sum += own[k];
        }
        GroupMemoryBarrierWithGroupSync();
        partial[t] = sum;
        GroupMemoryBarrierWithGroupSync();
        for (uint stride = 1u; stride < MIRAI_GROUP_X; stride <<= 1u) {
            uint add = t >= stride ? partial[t - stride] : 0u;
            GroupMemoryBarrierWithGroupSync();
            partial[t] += add;
            GroupMemoryBarrierWithGroupSync();
        }
        uint start = partial[t] - sum;
        for (uint k = 0u; k < 4u; k++) {
            if (run + k < segments) particle_lists[starts + run + k] = start;
            start += own[k];
        }
        total = partial[MIRAI_GROUP_X - 1u];
    }
    // Mesh particles: its list in a run per mesh, through the scratch quarter of
    // the lists (in no order within a run: a sorted effect has one mesh), and a
    // draw of each run, its first instance where it starts.
    if (e.kinds.y == PARTICLE_RENDER_MESH) {
        uint count = clamp(e.mesh.x, 1u, PARTICLE_MESHES);
        if (t < PARTICLE_MESHES) mesh_counts[t] = t == 0u && count == 1u ? alive : 0u;
        GroupMemoryBarrierWithGroupSync();
        if (count > 1u) {
            for (uint i = t; i < alive; i += MIRAI_GROUP_X) InterlockedAdd(mesh_counts[particle_mesh_choice(slot, particles[particle_lists[drawn + i]])], 1u);
            GroupMemoryBarrierWithGroupSync();
            if (t == 0u) {
                uint at = 0u;
                for (uint c = 0u; c < PARTICLE_MESHES; c++) { mesh_cursors[c] = at; at += mesh_counts[c]; }
            }
            GroupMemoryBarrierWithGroupSync();
            uint scratch = 3u * e.program.y + e.range.x;
            for (uint i = t; i < alive; i += MIRAI_GROUP_X) {
                uint index = particle_lists[drawn + i];
                uint at;
                InterlockedAdd(mesh_cursors[particle_mesh_choice(slot, particles[index])], 1u, at);
                particle_lists[scratch + at] = index;
            }
            DeviceMemoryBarrierWithGroupSync();
            for (uint i = t; i < alive; i += MIRAI_GROUP_X) particle_lists[drawn + i] = particle_lists[scratch + i];
        }
        if (t < PARTICLE_MESHES) {
            uint first = 0u;
            for (uint c = 0u; c < t; c++) first += mesh_counts[c];
            uint words = PARTICLE_MESH_DRAWS_AT + (slot * PARTICLE_MESHES + t) * 4u;
            particle_queue[words] = t < count ? e.mesh_vertices[t] : 0u;
            particle_queue[words + 1u] = mesh_counts[t];
            particle_queue[words + 2u] = 0u;
            particle_queue[words + 3u] = first;
        }
    }
    if (t != 0u) return;
    bool mesh = e.kinds.y == PARTICLE_RENDER_MESH;
    particle_states[slot].index_count = mesh ? e.mesh.x : 6u;
    particle_states[slot].instance_count = total;
    particle_states[slot].first_index = 0u;
    particle_states[slot].vertex_offset = 0;
    particle_states[slot].first_instance = 0u;
    if (alive > 0u) {
        InterlockedAdd(counted[0], alive);
        InterlockedAdd(counted[1], 1u);
    }
}
