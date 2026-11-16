#include "native.slang"
// After the rays of the probes chosen this frame: each records the cell it
// was traced for and when. A probe buried in geometry (a quarter of its rays
// on backfaces) moves out through the nearest backface, one too close to a
// surface moves away, within its cell.
// A buried probe that held the light of its cell keeps it (something moved
// over it); one that never did holds nothing until it gets out.
#define PROBES_WRITABLE
#include "probe_update.slang"
#define MIRAI_GROUP_X 32
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> ray_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint slot = dispatch_id.x;
    if (slot >= chosen[0]) return;
    uint probe = chosen[1u + slot];
    uint cascade;
    int3 cell = probe_slot_cell(probe, cascade);
    float spacing = probe_spacing(cascade);
    uint backfaces = 0u;
    float closest_back = 1e9, closest_front = 1e9, farthest_front = 0.0;
    float3 closest_back_dir = float3(0.0), farthest_front_dir = float3(0.0);
    for (uint r = 0u; r < params.rays_per_probe; r++) {
        float d = ray_data.Load(int3(int2(r, slot), 0)).a;
        float3 dir = probe_ray_direction(probe, r, params.rays_per_probe);
        if (d < 0.0) {
            backfaces++;
            float back = -d * 5.0;
            if (back < closest_back) { closest_back = back; closest_back_dir = dir; }
        } else {
            closest_front = min(closest_front, d);
            if (d > farthest_front) { farthest_front = d; farthest_front_dir = dir; }
        }
    }
    Probe held = probes[probe];
    float3 offset = all(held.cell.xyz == cell) ? held.offset.xyz : float3(0.0);
    float3 before = offset;
    bool buried = backfaces * 4u > params.rays_per_probe;
    float min_front = 0.2 * spacing;
    if (buried && closest_back < 1e8) {
        offset += closest_back_dir * (closest_back + min_front * 0.5);
    } else if (closest_front < min_front && farthest_front > 0.0) {
        offset += farthest_front_dir * min(min_front - closest_front, 0.1 * spacing);
    }
    // Inside its cell, so that the grid stays a valid interpolant.
    offset = clamp(offset, -0.45 * spacing, 0.45 * spacing);
    int flags = PROBE_VALID;
    if (buried) flags = probe_holds(held, cell) ? (PROBE_VALID | PROBE_BURIED) : PROBE_BURIED;
    probes[probe].offset = float4(offset, held.offset.w);
    probes[probe].cell = int4(cell, flags);
    // A probe that moved is untraced again: the next frame traces it first.
    probes[probe].frames.x = length(offset - before) > 0.05 * spacing ? 0u : params.frame_number;
}
