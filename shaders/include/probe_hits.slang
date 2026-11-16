// What the rays of the probes found (render.Probe_Hits). A probe traces the
// same rays every update, so one that holds a slot (probe_slots.slang) keeps,
// of each, where it ended and what was there, with the light the hit emits
// and reflects of the lights apart from the bounces it reads of the volume.
// An update traces a ray again only where
// what it may meet changed, and lights its hit again only where its lights
// did; of the others it only reads the bounces again.
//
// What changed is what the scene listed since the probe was last updated
// (probe_changes, the newest first): a probe checks what it keeps against the
// changes newer than its last check, whenever it is chosen.
#ifndef MIRAI_PROBE_HITS_SLANG
#define MIRAI_PROBE_HITS_SLANG
#include "probe_update.slang"

// PROBE_HIT_WORDS words a ray, the rays of a slot one after another.
[[vk::binding(PROBE_HITS_SLOT, 0)]] RWStructuredBuffer<uint> probe_hits : register(MIRAI_REGISTER(u, PROBE_HITS_SLOT), space0);

// A change of the scene (render.Probe_Change): a box, with its kind
// (PROBE_CHANGE_*) and the update that listed it, plus one; and the light of a
// shadow, or the sphere of a light that changed (xyz, w its reach).
struct Probe_Change {
    float3 low;
    uint kind;
    float3 high;
    uint stamp;
    float4 light;
};
[[vk::binding(PROBE_CHANGES_SLOT, 0)]] StructuredBuffer<Probe_Change> probe_changes : register(MIRAI_REGISTER(t, PROBE_CHANGES_SLOT), space0);

// Probe_Hit.flags. What the ray met:
#define HIT_NONE 0u    // nothing is kept of it
#define HIT_SKY 1u
#define HIT_BACK 2u    // the back of a surface: the probe is inside something
#define HIT_SURFACE 3u
#define HIT_KIND 3u
// What it found may change with nothing that says so (a program that reads
// the time, the gate of an extension it went through, a program its batch had
// no room for): it is traced every update.
#define HIT_PASSING 4u
// Its light is not what the lights give what is kept of it (it glows, or
// glass filters the ray): where its lights change it is traced again.
#define HIT_FIXED 8u

struct Probe_Hit {
    float t;        // metres along the ray
    float3 normal;  // of the hit, on the side of the probe
    float3 albedo;  // what it reflects of the light around it, less what the glass on the way keeps; of the sky, what that glass leaves
    float3 through; // what it lets through of the light around its other side, the same way
    float3 direct;  // what it emits and reflects of the lights, the same way
    uint flags;
};

uint hit_color(float3 c) {
    uint3 q = uint3(round(sqrt(saturate(c)) * float3(2047.0, 2047.0, 1023.0)));
    return q.r | (q.g << 11u) | (q.b << 22u);
}
float3 hit_uncolor(uint v) {
    float3 q = float3(float(v & 2047u), float((v >> 11u) & 2047u), float(v >> 22u)) / float3(2047.0, 2047.0, 1023.0);
    return q * q;
}
uint hit_through(float3 c) {
    uint3 q = uint3(round(sqrt(saturate(c)) * float3(31.0, 63.0, 31.0)));
    return q.r | (q.g << 5u) | (q.b << 11u);
}
float3 hit_unthrough(uint v) {
    float3 q = float3(float(v & 31u), float((v >> 5u) & 63u), float((v >> 11u) & 31u)) / float3(31.0, 63.0, 31.0);
    return q * q;
}

struct Probe_Hit_Words { uint w[PROBE_HIT_WORDS]; };

Probe_Hit_Words probe_hit_pack(Probe_Hit hit) {
    Probe_Hit_Words words;
    uint2 normal = uint2(int2(round(clamp(oct_encode(dot(hit.normal, hit.normal) > 0.0 ? hit.normal : float3(0.0, 0.0, 1.0)), -1.0, 1.0) * 2047.0)) + 2048);
    float3 direct = probe_light_encode(finite_or_zero(hit.direct));
    words.w[0] = asuint(hit.t);
    words.w[1] = normal.x | (normal.y << 12u) | (hit.flags << 24u);
    words.w[2] = hit_color(hit.albedo);
    words.w[3] = hit_through(hit.through) | (half_bits(direct.b) << 16u);
    words.w[4] = half_bits(direct.r) | (half_bits(direct.g) << 16u);
    return words;
}
Probe_Hit probe_hit_unpack(Probe_Hit_Words words) {
    Probe_Hit hit;
    hit.t = asfloat(words.w[0]);
    hit.normal = oct_decode((float2(float(words.w[1] & 4095u), float((words.w[1] >> 12u) & 4095u)) - 2048.0) / 2047.0);
    hit.flags = words.w[1] >> 24u;
    hit.albedo = hit_uncolor(words.w[2]);
    hit.through = hit_unthrough(words.w[3] & 0xffffu);
    hit.direct = probe_light_decode(float3(half_value(words.w[4] & 0xffffu), half_value(words.w[4] >> 16u), half_value(words.w[3] >> 16u)));
    return hit;
}

// Where the hit of a ray of the probe that holds a slot is kept.
uint probe_hit_at(uint slot, uint ray) { return (slot * params.rays_per_probe + ray) * PROBE_HIT_WORDS; }
Probe_Hit probe_hit_load(uint at) {
    Probe_Hit_Words words;
    [ForceUnroll]
    for (uint i = 0u; i < PROBE_HIT_WORDS; i++) words.w[i] = probe_hits[at + i];
    return probe_hit_unpack(words);
}
void probe_hit_store(uint at, Probe_Hit_Words words) {
    [ForceUnroll]
    for (uint i = 0u; i < PROBE_HIT_WORDS; i++) probe_hits[at + i] = words.w[i];
}

bool box_crossed(float3 origin, float3 inverse, float reach, float3 low, float3 high) {
    float3 t0 = (low - origin) * inverse;
    float3 t1 = (high - origin) * inverse;
    float3 near = min(t0, t1);
    float3 far = max(t0, t1);
    return max(max(near.x, near.y), max(near.z, 0.0)) <= min(min(far.x, far.y), min(far.z, reach));
}
float3 ray_inverse(float3 direction) { return 1.0 / select(abs(direction) > float3(1e-12), direction, float3(1e-12)); }

// What the changes listed since a probe last checked (`checked`) ask of a hit
// it keeps of a ray from `origin` along `direction`.
#define HIT_ASKS_TRACE 1u // a box of what changed lies on the way to what the ray met, which lies in the box when it is what changed
#define HIT_ASKS_LIGHT 2u // a light that changed reaches the hit, or a box of what casts shadows lies between it and the sun or a light
uint probe_hit_asked(Probe_Hit hit, float3 origin, float3 direction, uint checked) {
    uint kind = hit.flags & HIT_KIND;
    float reach = kind == HIT_SKY ? params.max_distance : hit.t * 1.001 + 0.01;
    float3 inverse = ray_inverse(direction);
    float3 position = origin + direction * hit.t;
    bool sun = kind == HIT_SURFACE && frame.sun_direction.w > 0.5;
    float3 sun_inverse = ray_inverse(frame.sun_direction.xyz);
    uint asks = 0u;
    for (uint i = 0u; i < params.changes; i++) {
        Probe_Change change = probe_changes[i];
        if (change.stamp <= checked) break;
        if (change.kind == PROBE_CHANGE_LIGHT || change.kind == PROBE_CHANGE_SHADOW) {
            float3 to = change.light.xyz - position;
            float distance = length(to);
            if (kind != HIT_SURFACE || distance >= change.light.w) continue;
            if (change.kind == PROBE_CHANGE_LIGHT || box_crossed(position, ray_inverse(to / max(distance, 1e-6)), distance, change.low, change.high)) asks |= HIT_ASKS_LIGHT;
            continue;
        }
        if (box_crossed(origin, inverse, reach, change.low, change.high)) return HIT_ASKS_TRACE;
        if (change.kind == PROBE_CHANGE_CASTER && sun && box_crossed(position, sun_inverse, FLT_MAX, change.low, change.high)) asks |= HIT_ASKS_LIGHT;
    }
    return asks;
}

#endif
