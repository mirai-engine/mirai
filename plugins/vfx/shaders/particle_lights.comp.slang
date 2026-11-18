#include "native.slang"
// The lights of the particles, after their simulation: each emitter with
// lights takes its share of the room the renderer keeps for them
// (render.pass_lights), over its live particles, in the part of the room of
// its kind. A group per part builds the tree of its lights as
// render/light_tree.odin builds the tree of the scene: along a curve that
// keeps neighbors together, each node what its lights give together. That
// of the lights with shadows goes under the root of the lights of the scene,
// and they shine and cast shadows as those of the scene do; the others shine
// through what stands in their way, from a tree of their own.
#define PARTICLES_WRITABLE
#include "particle_programs.slang"
#define MIRAI_GROUP_X 512
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
#define PARTICLE_LIGHTS_MAX 1024u
// Where an empty node or light lies: far from all, so that it reaches nothing
// and weighs nothing, without sums that overflow.
#define PARTICLE_LIGHT_AWAY float3(0.0, -1e6, 0.0)

// Where the room is. Each part (render.Pass_Light_Part), the one with
// shadows first: x its first light, y its capacity, z the root of its tree,
// whose capacity leaves are followed by an empty leaf, whose light follows
// those of the part. scene_root: the root of the lights of the scene, or the
// empty leaf of the part with shadows; node 0 groups it with the root of
// that part, at 1.
struct Params_Block { uint emitters; uint scene_root; uint pad0; uint pad1; uint4 parts[2]; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS7, 0)]] RWStructuredBuffer<Light> light_writes : register(MIRAI_REGISTER(u, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] RWStructuredBuffer<Light_Node> node_writes : register(MIRAI_REGISTER(u, SLOT_PASS8), space0);

groupshared uint keys[PARTICLE_LIGHTS_MAX];
groupshared uint order[PARTICLE_LIGHTS_MAX];
groupshared uint bounds[6]; // low then high, as ordered bits

uint ordered_bits(float x) { uint u = asuint(x); return (u & 0x80000000u) != 0u ? ~u : u | 0x80000000u; }
float ordered_float(uint u) { return asfloat((u & 0x80000000u) != 0u ? u & 0x7fffffffu : ~u); }
uint curve_spread(uint v) {
    v &= 1023u;
    v = (v | (v << 16u)) & 0x030000ffu;
    v = (v | (v << 8u)) & 0x0300f00fu;
    v = (v | (v << 4u)) & 0x030c30c3u;
    v = (v | (v << 2u)) & 0x09249249u;
    return v;
}

Light light_none() {
    Light l;
    l.position_range = float4(PARTICLE_LIGHT_AWAY, 0.0);
    l.color_intensity = float4(0.0);
    l.direction_cone = float4(0.0, 0.0, 0.0, LIGHT_POINT);
    l.size = float4(0.0);
    l.axis = float4(0.0);
    return l;
}

// The light of a part of the room at i: of the emitter whose share holds it,
// one of its live particles. With more of them than its budget, those of
// evenly spread slots of its pool, so that a particle keeps its light while
// it lives. The shares of a part follow the slots of the emitters
// (light_share of gpu.odin), and an emitter of the other part has an empty
// one where the shares before it end: the one of i starts at the last
// emitter whose share starts at i or before.
Light particle_light_at(uint i, uint part) {
    uint low = 0u, high = params.emitters;
    while (low < high) {
        uint middle = (low + high) / 2u;
        if (particle_emitters[middle].lights[2u * part] <= i) low = middle + 1u; else high = middle;
    }
    if (low == 0u) return light_none();
    uint slot = low - 1u;
    Particle_Emitter e = particle_emitters[slot];
    uint first = e.lights[2u * part], budget = e.lights[2u * part + 1u];
    if (budget == 0u || i >= first + budget || (e.range.w & PARTICLE_FLAG_ACTIVE) == 0u) return light_none();
    uint alive = min(particle_states[slot].alive, e.range.y);
    uint j = i - first;
    uint index;
    if (alive <= budget) {
        if (j >= alive) return light_none();
        index = particle_drawn(slot, j);
    } else {
        index = e.range.x + (j * e.range.y) / budget;
    }
    Particle p = particles[index];
    if (!(p.lifetime > 0.0)) return light_none();
    Particle_Look look = particle_program_look(slot, index, p);
    float3 color = max(look.color.rgb, float3(0.0)) * saturate(look.color.a);
    // Candelas in the units of the lights of the scene (gpu_light of render/scene.odin).
    float intensity = e.light.x / PI * frame.sky_color.w;
    if (!(luminance(color) * intensity > 0.0) || !(e.light.y > 0.0)) return light_none();
    Light l = light_none();
    l.position_range = float4(particle_world(slot, p.position), e.light.y);
    l.color_intensity = float4(color, intensity);
    l.size.x = e.light.z > 0.0 ? e.light.z : look.size * 0.5;
    return l;
}

uint node_count(Light_Node n) { return n.flags >> LIGHT_NODE_COUNT_SHIFT; }

// node_leaf and node_group are light_tree_leaf and light_tree_group of
// render/light_tree.odin for lights that face every way: a change to one goes
// to the other.
Light_Node node_leaf(Light l, uint light) {
    Light_Node n;
    bool lit = l.color_intensity.w > 0.0;
    n.center_radius = float4(l.position_range.xyz, lit ? max(l.size.x, 0.0) : 0.0);
    n.power_reach = float4(l.color_intensity.rgb * l.color_intensity.w, l.position_range.w);
    n.cone = float4(0.0, 1.0, 0.0, PI);
    n.emission = 0.5 * PI;
    n.range = l.position_range.w;
    n.spread = n.center_radius.w;
    n.child = light;
    n.flags = LIGHT_NODE_LEAF | ((lit ? 1u : 0u) << LIGHT_NODE_COUNT_SHIFT);
    return n;
}

// What two nodes give together; second is where the second is. An empty one
// adds nothing, and its place is not one of their places.
Light_Node node_group(Light_Node a, Light_Node b, uint second) {
    Light_Node n;
    uint spot = (a.flags | b.flags) & LIGHT_NODE_SPOT;
    if (node_count(b) == 0u || node_count(a) == 0u) {
        n = node_count(b) == 0u ? a : b;
        n.child = second;
        n.flags = spot | ((node_count(a) + node_count(b)) << LIGHT_NODE_COUNT_SHIFT);
        return n;
    }
    float wa = luminance(a.power_reach.rgb), wb = luminance(b.power_reach.rgb);
    float share = wa + wb > 0.0 ? wa / (wa + wb) : 0.5;
    float3 center = lerp(b.center_radius.xyz, a.center_radius.xyz, share);
    float da = length(a.center_radius.xyz - center), db = length(b.center_radius.xyz - center);
    n.center_radius = float4(center, max(da + a.center_radius.w, db + b.center_radius.w));
    n.power_reach = float4(a.power_reach.rgb + b.power_reach.rgb, max(da + a.power_reach.w, db + b.power_reach.w));
    // The lights of particles face every way: so does a group that holds one.
    n.cone = float4(0.0, 1.0, 0.0, PI);
    n.emission = max(a.emission, b.emission);
    n.range = share * a.range + (1.0 - share) * b.range;
    n.spread = sqrt(share * (da * da + a.spread * a.spread) + (1.0 - share) * (db * db + b.spread * b.spread));
    n.child = second;
    n.flags = spot | ((node_count(a) + node_count(b)) << LIGHT_NODE_COUNT_SHIFT);
    return n;
}

// Where the node q of a level is in the tree of a part from its root: a
// first child follows its group, a second one the nodes of the first.
uint node_place(uint level, uint q, uint root, uint capacity) {
    uint at = root;
    for (uint t = 1u; t <= level; t++) at += ((q >> (level - t)) & 1u) != 0u ? capacity >> (t - 1u) : 1u;
    return at;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 local : SV_GroupThreadID, uint3 group : SV_GroupID) {
    uint t = local.x;
    uint part = group.x;
    uint4 room = params.parts[part];
    uint first_light = room.x, root = room.z;
    uint n = min(room.y, PARTICLE_LIGHTS_MAX);
    if (n == 0u) return;
    if (t < 3u) {
        bounds[t] = 0xffffffffu;
        bounds[t + 3u] = 0u;
    }
    GroupMemoryBarrierWithGroupSync();
    for (uint i = t; i < n; i += MIRAI_GROUP_X) {
        Light l = particle_light_at(i, part);
        light_writes[first_light + i] = l;
        if (l.color_intensity.w > 0.0) {
            for (uint axis = 0u; axis < 3u; axis++) {
                uint bits = ordered_bits(l.position_range[axis]);
                InterlockedMin(bounds[axis], bits);
                InterlockedMax(bounds[axis + 3u], bits);
            }
        }
    }
    if (t == 0u) light_writes[first_light + n] = light_none();
    AllMemoryBarrierWithGroupSync();
    float3 low = float3(ordered_float(bounds[0]), ordered_float(bounds[1]), ordered_float(bounds[2]));
    float3 high = float3(ordered_float(bounds[3]), ordered_float(bounds[4]), ordered_float(bounds[5]));
    float3 scale = 1023.0 / max(high - low, float3(1e-4));
    for (uint i = t; i < n; i += MIRAI_GROUP_X) {
        Light l = light_writes[first_light + i];
        uint key = 0xffffffffu;
        if (l.color_intensity.w > 0.0) {
            uint3 cell = uint3(clamp((l.position_range.xyz - low) * scale, float3(0.0), float3(1023.0)));
            key = curve_spread(cell.x) | (curve_spread(cell.y) << 1u) | (curve_spread(cell.z) << 2u);
        }
        keys[i] = key;
        order[i] = i;
    }
    GroupMemoryBarrierWithGroupSync();
    // Along the curve, the lights that give nothing last; the same keys by their place.
    for (uint k = 2u; k <= n; k <<= 1u) {
        for (uint j = k >> 1u; j > 0u; j >>= 1u) {
            for (uint i = t; i < n; i += MIRAI_GROUP_X) {
                uint other = i ^ j;
                if (other > i) {
                    bool ascending = (i & k) == 0u;
                    bool after = keys[i] > keys[other] || (keys[i] == keys[other] && order[i] > order[other]);
                    if (after == ascending) {
                        uint key = keys[i]; keys[i] = keys[other]; keys[other] = key;
                        uint value = order[i]; order[i] = order[other]; order[other] = value;
                    }
                }
            }
            GroupMemoryBarrierWithGroupSync();
        }
    }
    // The leaves, then each level of groups from the deepest up.
    uint levels = firstbithigh(max(n, 1u));
    for (uint q = t; q < n; q += MIRAI_GROUP_X) {
        uint light = first_light + order[q];
        node_writes[node_place(levels, q, root, n)] = node_leaf(light_writes[light], light);
    }
    AllMemoryBarrierWithGroupSync();
    for (int level = int(levels) - 1; level >= 0; level--) {
        uint size = n >> uint(level);
        for (uint q = t; q < (1u << uint(level)); q += MIRAI_GROUP_X) {
            uint at = node_place(uint(level), q, root, n);
            uint second = at + size;
            node_writes[at] = node_group(node_writes[at + 1u], node_writes[second], second);
        }
        AllMemoryBarrierWithGroupSync();
    }
    if (t == 0u) {
        Light_Node none = node_leaf(light_none(), first_light + n);
        uint empty = root + 2u * n - 1u;
        node_writes[empty] = none;
        // The root of the lights with shadows and of the scene: that of the
        // others is no child of it.
        if (part == 0u) {
            Light_Node scene = params.scene_root == empty ? none : node_writes[params.scene_root];
            node_writes[0] = node_group(node_writes[root], scene, params.scene_root);
        }
    }
}
