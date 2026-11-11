#include "native.slang"
// A group per emitter, once a frame: the indirect draw of what is alive, for
// an emitter that sorts its list back to front (a ribbon: by its ribbon, then
// youngest first, the order it was laid along its path, the slot breaking
// ties so a burst keeps one order), and for a ribbon the pieces each segment
// is cut into to follow the curve through its particles.
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
// depth; and its slot in the range, below SORT_SLOT_BITS, under the low bits
// of its ribbon, which come first.
#define SORT_SLOT_BITS 11u
groupshared float keys[PARTICLE_SORT_MAX];
groupshared uint values[PARTICLE_SORT_MAX];
groupshared uint most_pieces;

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
                uint low = ribbon ? particle_ribbon(p) & (0xFFFFFFFFu >> SORT_SLOT_BITS) : 0u;
                values[i] = (low << SORT_SLOT_BITS) | (index - e.range.x);
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
    uint pieces = 1u;
    if (ribbon && alive >= 2u) {
        if (t == 0u) most_pieces = 1u;
        GroupMemoryBarrierWithGroupSync();
        for (uint i = t; i + 1u < alive; i += MIRAI_GROUP_X) {
            Particle a = particles[particle_lists[drawn + i]];
            Particle b = particles[particle_lists[drawn + i + 1u]];
            uint id_a = particle_ribbon(a);
            if (id_a != particle_ribbon(b)) continue;
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
            InterlockedMax(most_pieces, segment_pieces(pa, pb, unit(ta), unit(tb), error));
        }
        GroupMemoryBarrierWithGroupSync();
        // It rises at once and comes down a piece a frame, so that it does not flicker.
        uint before = (e.range.w & PARTICLE_FLAG_RESET) != 0u ? 1u : particle_states[slot].pieces;
        pieces = max(most_pieces, max(before, 2u) - 1u);
    }
    if (t != 0u) return;
    bool mesh = e.kinds.y == PARTICLE_RENDER_MESH;
    particle_states[slot].index_count = mesh ? e.mesh.x : 6u;
    particle_states[slot].instance_count = ribbon ? (max(alive, 1u) - 1u) * pieces : alive;
    particle_states[slot].first_index = 0u;
    particle_states[slot].vertex_offset = 0;
    particle_states[slot].first_instance = 0u;
    particle_states[slot].pieces = pieces;
    if (alive > 0u) {
        InterlockedAdd(counted[0], alive);
        InterlockedAdd(counted[1], 1u);
    }
}
