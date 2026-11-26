#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// The color of the ground of a chunk (render/ground.odin). Level 0: a thread
// per sample of the chunk traces a ray straight up from under the instance
// that draws the chunk, past what else it meets under the ground, and keeps
// the base color of the ground it finds in the texel of the sample. Where the
// material has a program the point waits for it (points.slang) and the resume
// (params.resume) keeps what the program gave. A sample without ground, or
// whose point has nothing of its program, covers nothing. A level above 0: a
// thread per texel of it, the mean of the four of the level before it covers.
// Small instances stand on the ground: the rays do not meet them.
#define MIRAI_TRACE_PROBES
#define POINTS_SLOT SLOT_POINTS
#include "trace.slang"
#define MIRAI_GROUP_X 32
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
// Surfaces under the ground a ray goes past before it gives up.
#define GROUND_PASSES 8u

struct Params_Block {
    uint resume;
    uint level;
    uint instance; // the one that draws the chunk
    uint pad0;
    float2 low;    // x and z of the first sample, relative to the origin
    float step;    // metres between samples
    float bottom;  // a height under the instance
    float height;  // from it to above the instance
    float3 pad1;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The texels of the levels, level after level, each as its texture takes it:
// sRGB, the color times what the texel covers, and that in its last byte.
[[vk::binding(SLOT_PASS0, 0)]] RWStructuredBuffer<uint> texels : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);

uint level_first(uint level) {
    uint first = 0u;
    for (uint l = 0u; l < level; l++) first += (GROUND_TEXELS >> l) * (GROUND_TEXELS >> l);
    return first;
}
float3 srgb_encode(float3 c) { return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, step(float3(0.0031308), c)); }
float3 srgb_decode(float3 c) { return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(float3(0.04045), c)); }
uint texel_pack(float3 color, float cover) { return record_unorm8x4(float4(srgb_encode(saturate(color)), cover)); }

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint local : SV_GroupIndex) {
    uint texel = dispatch_id.x;
    if (params.level != 0u) {
        uint side = GROUND_TEXELS >> params.level;
        if (texel >= side * side) return;
        uint2 at = uint2(texel % side, texel / side) * 2u;
        uint from = level_first(params.level - 1u);
        float4 sum = float4(0.0);
        for (uint k = 0u; k < 4u; k++) {
            float4 covered = unpackUnorm4x8(texels[from + (at.y + (k >> 1u)) * side * 2u + at.x + (k & 1u)]);
            sum += float4(srgb_decode(covered.rgb), covered.a);
        }
        texels[level_first(params.level) + texel] = texel_pack(sum.rgb * 0.25, sum.a * 0.25);
        return;
    }
    if (params.resume != 0u) {
        Point_Head head;
        if (!head_of_round(group.x * MIRAI_GROUP_X + local, head)) return;
        if (!point_record_given(head.point)) return;
        Material_Point point = point_load(head.point);
        Hit_Point waited = hit_point(point.instance, point.primitive, point.bary, point.footprint);
        texels[head.owner] = texel_pack(surface_from_hit(waited, true, point_record_load(head.point)).base_color, 1.0);
        return;
    }
    if (texel >= GROUND_TEXELS * GROUND_TEXELS) return;
    texels[texel] = 0u;
    // A sample of an edge is taken just inside it, where the mesh of the chunk is.
    float2 sample = clamp(float2(texel % GROUND_TEXELS, texel / GROUND_TEXELS), 0.002, float(GROUND_TEXELS - 1u) - 0.002);
    float2 place = params.low + sample * params.step;
    Hit found;
    float t_min = 0.0;
    for (uint pass = 0u; pass < GROUND_PASSES; pass++) {
        found = trace_ray_impl(float3(place.x, params.bottom, place.y), float3(0.0, 1.0, 0.0), t_min, params.height, false, BLEND_PASSES, RAY_SEEN);
        if (found.instance == INVALID || found.instance == params.instance) break;
        t_min = found.t + 1e-3;
    }
    if (found.instance != params.instance) return;
    Hit_Point met = hit_point(found.instance, found.primitive, found.bary, params.step);
    if (met.m.program_id != 0u) {
        Material_Point point = {found.instance, found.primitive, found.bary, params.step, met.m.program_id, 0u, INVALID};
        uint index = point_append(point);
        if (index != INVALID) head_append(point_head(index, INVALID, texel));
        return;
    }
    texels[texel] = texel_pack(surface_from_hit(met, false, (Mirai_Surface)0).base_color, 1.0);
}
