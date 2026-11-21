#include "native.slang"
#define PARTICLES_WRITABLE
#include "particles.slang"
#define MIRAI_GROUP_X 512
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mode; uint emitters; uint count; uint parity; uint step; uint last; uint pad0; uint pad1; };
[[vk::binding(SLOT_PASS7, 0)]] StructuredBuffer<uint> particle_sort_slots : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

// The error a ribbon may leave between the curve through its particles and
// the straight pieces it is drawn with, metres: at least the first, and
// growing with the distance from the eye by the second, about one pixel of a
// view 1080 pixels high and 60 degrees wide.
#define RIBBON_ERROR_MIN 0.002
#define RIBBON_ERROR_SLOPE 0.001

#define SORT_TILE 1024u
groupshared float keys[SORT_TILE];
groupshared uint ribbons[SORT_TILE];
groupshared uint values[SORT_TILE];
groupshared uint partial[MIRAI_GROUP_X];
groupshared uint mesh_counts[PARTICLE_MESHES];
groupshared uint mesh_cursors[PARTICLE_MESHES];

struct Sort_Key { uint ribbon; float depth; uint index; };

Sort_Key sort_key(uint slot, uint index, bool ribbon) {
    Sort_Key key;
    key.index = index;
    if (index == INVALID) {
        key.ribbon = INVALID;
        key.depth = FLT_MAX;
        return key;
    }
    Particle p = particles[index];
    key.ribbon = ribbon ? particle_ribbon(p) : 0u;
    key.depth = ribbon ? p.age : -dot(particle_world(slot, p.position), frame.camera_forward.xyz);
    if (!isfinite(key.depth)) key.depth = FLT_MAX;
    return key;
}

bool sorted_before(Sort_Key a, Sort_Key b) {
    if (a.ribbon != b.ribbon) return a.ribbon < b.ribbon;
    if (a.depth != b.depth) return a.depth < b.depth;
    return a.index < b.index;
}

Sort_Key shared_key(uint i) {
    Sort_Key key = {ribbons[i], keys[i], values[i]};
    return key;
}

void shared_key_store(uint i, Sort_Key key) {
    ribbons[i] = key.ribbon;
    keys[i] = key.depth;
    values[i] = key.index;
}

void sort_particles(uint slot, uint t, uint alive, uint drawn, uint scratch, bool ribbon) {
    uint size = 2u;
    while (size < min(alive, SORT_TILE)) size <<= 1u;
    for (uint start = 0u; start < alive; start += size) {
        uint count = min(size, alive - start);
        for (uint i = t; i < size; i += MIRAI_GROUP_X) {
            shared_key_store(i, sort_key(slot, i < count ? particle_lists[drawn + start + i] : INVALID, ribbon));
        }
        GroupMemoryBarrierWithGroupSync();
        for (uint k = 2u; k <= size; k <<= 1u) {
            for (uint j = k >> 1u; j > 0u; j >>= 1u) {
                for (uint i = t; i < size; i += MIRAI_GROUP_X) {
                    uint other = i ^ j;
                    if (other <= i) continue;
                    Sort_Key a = shared_key(i), b = shared_key(other);
                    if (sorted_before(b, a) == ((i & k) == 0u)) {
                        shared_key_store(i, b);
                        shared_key_store(other, a);
                    }
                }
                GroupMemoryBarrierWithGroupSync();
            }
        }
        for (uint i = t; i < count; i += MIRAI_GROUP_X) particle_lists[drawn + start + i] = values[i];
        GroupMemoryBarrierWithGroupSync();
    }
    DeviceMemoryBarrierWithGroupSync();
    uint read_at = drawn, write_at = scratch;
    for (uint span = size; span < alive; span <<= 1u) {
        for (uint i = t; i < alive; i += MIRAI_GROUP_X) {
            uint pair = (i / (2u * span)) * (2u * span);
            uint middle = min(pair + span, alive), end = min(middle + span, alive);
            bool left = i < middle;
            uint begin = left ? middle : pair;
            uint lo = begin, hi = left ? end : middle;
            Sort_Key key = sort_key(slot, particle_lists[read_at + i], ribbon);
            while (lo < hi) {
                uint m = (lo + hi) / 2u;
                if (sorted_before(sort_key(slot, particle_lists[read_at + m], ribbon), key)) lo = m + 1u;
                else hi = m;
            }
            uint rank = i - (left ? pair : middle) + lo - begin;
            particle_lists[write_at + pair + rank] = key.index;
        }
        DeviceMemoryBarrierWithGroupSync();
        uint next = read_at; read_at = write_at; write_at = next;
    }
    if (read_at == drawn) return;
    for (uint i = t; i < alive; i += MIRAI_GROUP_X) particle_lists[drawn + i] = particle_lists[read_at + i];
    DeviceMemoryBarrierWithGroupSync();
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
    bool view = params.mode != 0u;
    uint slot = view ? particle_sort_slots[group.x] : particle_queue[SORT_AT / 4u + 4u + group.x];
    uint t = local.x;
    uint alive = particle_states[slot].alive;
    if (alive < 2u) return;
    bool ribbon = particle_emitters[slot].kinds.y == PARTICLE_RENDER_RIBBON;
    uint base = particle_emitters[slot].range.x;
    uint capacity = particle_emitters[slot].program.y;
    uint drawn = capacity + base;
    uint scratch = 2u * capacity + base;
    if (ribbon || view) sort_particles(slot, t, alive, drawn, scratch, ribbon);
    if (view) return;
    // The scratch list holds the first quad of each segment. Segments between ribbons have no quads.
    uint total = alive;
    if (ribbon) {
        uint segments = alive - 1u;
        uint starts = scratch;
        uint prefix = 0u;
        for (uint block = 0u; block < segments; block += MIRAI_GROUP_X) {
            uint i = block + t;
            uint pieces = 0u;
            if (i < segments) {
                uint index_a = particle_lists[drawn + i];
                Particle a = particles[index_a];
                Particle b = particles[particle_lists[drawn + i + 1u]];
                uint id_a = particle_ribbon(a);
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
            }
            partial[t] = pieces;
            GroupMemoryBarrierWithGroupSync();
            for (uint stride = 1u; stride < MIRAI_GROUP_X; stride <<= 1u) {
                uint add = t >= stride ? partial[t - stride] : 0u;
                GroupMemoryBarrierWithGroupSync();
                partial[t] += add;
                GroupMemoryBarrierWithGroupSync();
            }
            if (i < segments) particle_lists[starts + i] = prefix + partial[t] - pieces;
            prefix += partial[MIRAI_GROUP_X - 1u];
            GroupMemoryBarrierWithGroupSync();
        }
        total = prefix;
    }
    // The scratch list groups particles by mesh and gives each draw its first instance.
    if (particle_emitters[slot].mesh.x > 1u) {
        if (t < PARTICLE_MESHES) mesh_counts[t] = 0u;
        GroupMemoryBarrierWithGroupSync();
        {
            for (uint i = t; i < alive; i += MIRAI_GROUP_X) InterlockedAdd(mesh_counts[particle_mesh_choice(slot, particles[particle_lists[drawn + i]])], 1u);
            GroupMemoryBarrierWithGroupSync();
            if (t == 0u) {
                uint at = 0u;
                for (uint c = 0u; c < PARTICLE_MESHES; c++) { mesh_cursors[c] = at; at += mesh_counts[c]; }
            }
            GroupMemoryBarrierWithGroupSync();
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
            uint words = PARTICLE_MESH_DRAWS_AT + (slot * PARTICLE_MESHES + t) * PARTICLE_MESH_DRAW_WORDS;
            particle_queue[words + 1u] = mesh_counts[t];
            particle_queue[words + 3u] = first;
        }
    }
    if (t == 0u && ribbon) particle_states[slot].instance_count = total;
}
