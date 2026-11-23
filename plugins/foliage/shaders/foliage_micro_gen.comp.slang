// The instances of a tile of micro foliage, written once when it changes, in
// the Simulate stage: candidates on a jittered grid over its cell (side by
// side of them), each kept by the share of the density of its layer the CPU
// gave the samples around it (pcg.micro_samples) and by the detail, placed
// on the heights of its ground tile (pcg.Pcg_Ground). Only those that stand
// are written, one after the other from the first of its slot; the count of
// the slot, zeroed by the record, says how many.
#include "foliage_micro.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Micro_Gen {
    uint4 a;  // x: the slot, y: its first instance, z: candidates a side, w: samples a side of the heights
    uint4 b;  // x: the seed of the tile, y: the candidates the detail keeps of 2^32 (thinned by a hash), z: samples a side of the densities
    float4 c; // x: metres across the cell
};

[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<Micro_Instance> micro_instances : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<uint> micro_counts : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
// The heights of the ground tile (NaN where there is none), x first, then the
// densities, a byte each, four to a word.
[[vk::binding(SLOT_PASS2, 0)]] StructuredBuffer<uint> micro_packet : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Micro_Gen> gen : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

float micro_density_byte(uint at) {
    uint first = gen.a.w * gen.a.w;
    return float((micro_packet[first + at / 4u] >> ((at % 4u) * 8u)) & 0xffu) / 255.0;
}

// The share of the density at a point of the cell, between the samples around it.
float micro_density(float2 at) {
    uint n = gen.b.z;
    float2 g = clamp(at / gen.c.x * float(n - 1u), 0.0, float(n - 1u));
    uint2 c = min(uint2(g), uint2(n - 2u));
    float2 f = g - float2(c);
    uint i = c.y * n + c.x;
    float a = micro_density_byte(i), b = micro_density_byte(i + 1u), d = micro_density_byte(i + n), e = micro_density_byte(i + n + 1u);
    return lerp(lerp(a, b, f.x), lerp(d, e, f.x), f.y);
}

// The height and normal of the ground at a point of the cell, as pcg.ground_at gives them.
bool micro_ground(float2 at, out float height, out float3 normal) {
    height = 0.0;
    normal = float3(0.0, 1.0, 0.0);
    uint n = gen.a.w;
    float step = gen.c.x / float(n - 1u);
    float2 g = clamp(at / step, 0.0, float(n - 1u));
    uint2 c = min(uint2(g), uint2(n - 2u));
    float2 f = g - float2(c);
    uint i = c.y * n + c.x;
    float a = asfloat(micro_packet[i]), b = asfloat(micro_packet[i + 1u]), d = asfloat(micro_packet[i + n]), e = asfloat(micro_packet[i + n + 1u]);
    if (isnan(a) || isnan(b) || isnan(d) || isnan(e)) return false;
    height = a + (b - a) * f.x + (d - a) * f.y + (a - b - d + e) * f.x * f.y;
    float dx = ((b - a) + (a - b - d + e) * f.y) / step;
    float dz = ((d - a) + (a - b - d + e) * f.x) / step;
    normal = normalize(float3(-dx, 1.0, -dz));
    return true;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint side = gen.a.z;
    uint i = dispatch_id.x;
    if (i >= side * side || gen.a.w < 2u || gen.b.z < 2u) return;
    uint h0 = micro_hash(gen.b.x ^ micro_hash(i + 0x9e3779b9u));
    uint h1 = micro_hash(h0), h2 = micro_hash(h1), h3 = micro_hash(h2);
    if (gen.b.y != 0xffffffffu && h3 >= gen.b.y) return;
    float2 at = (float2(float(i % side), float(i / side)) + float2(micro_unit(h0), micro_unit(h1))) / float(side) * gen.c.x;
    if (micro_unit(h2) >= micro_density(at)) return;
    float height;
    float3 normal;
    if (!micro_ground(at, height, normal)) return;
    uint k;
    InterlockedAdd(micro_counts[gen.a.x], 1u, k);
    if (k >= side * side) return;
    float2 unit = saturate(at / gen.c.x);
    Micro_Instance o;
    o.place = uint(unit.x * 65535.0 + 0.5) | uint(unit.y * 65535.0 + 0.5) << 16u;
    o.height = height;
    o.normal = micro_normal_pack(normal);
    o.slot = gen.a.x;
    micro_instances[gen.a.y + k] = o;
}
