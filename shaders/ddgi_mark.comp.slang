#include "native.slang"
// Marks the probes the pixels of the view read, for the priority of
// ddgi_select.comp: one pixel of each block of 8x8, a different one every
// frame, marks the probes around it in the cascade it reads.
#define PROBES_WRITABLE
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block { uint frame_number; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint turn = hash_u32(params.frame_number) & 63u;
    int2 p = int2(dispatch_id.xy) * 8 + int2(int(turn & 7u), int(turn >> 3u));
    if (any(p >= int2(frame.resolution))) return;
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    Pixel pixel = pixel_at(p, uv, depth);
    float3 n = gbuffer_normal(p);
    float3 counts = float3(frame.volume_counts.xyz);
    for (uint c = 0u; c < probe_cascades(); c++) {
        float spacing = probe_spacing(c);
        float3 rel = (pixel.position - frame.volume_cascades[c].xyz) / spacing;
        float3 inside = min(rel, counts - 1.0 - rel);
        if (min(inside.x, min(inside.y, inside.z)) < 0.5) continue;
        float3 biased = pixel.position + (n * 0.2 - pixel.view * 0.8) * (0.6 * spacing);
        int3 base = clamp(int3(floor((biased - frame.volume_cascades[c].xyz) / spacing)), int3(0), int3(frame.volume_counts.xyz) - 2);
        int3 corner = probe_corner_cell(c);
        for (int i = 0; i < 8; i++) {
            int3 cell = corner + base + int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
            probes[probe_slot(c, cell)].frames.y = params.frame_number;
        }
        // The next cascade blends in near the edge and stands in where this one holds nothing yet.
        if (c + 1u < probe_cascades()) {
            float spacing_next = probe_spacing(c + 1u);
            int3 base_next = clamp(int3(floor((pixel.position - frame.volume_cascades[c + 1u].xyz) / spacing_next)), int3(0), int3(frame.volume_counts.xyz) - 2);
            int3 corner_next = probe_corner_cell(c + 1u);
            for (int i = 0; i < 8; i++) {
                int3 cell = corner_next + base_next + int3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
                probes[probe_slot(c + 1u, cell)].frames.y = params.frame_number;
            }
        }
        return;
    }
}
