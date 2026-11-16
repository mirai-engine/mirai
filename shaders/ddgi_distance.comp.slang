#include "native.slang"
// Mean and mean squared hit distance per direction (the Chebyshev test of the
// interpolation) of each probe chosen this frame, into its 14x14 tile and a
// border. Like the irradiance, traced whole; kept by a probe that sees the
// inside of geometry and held the light of its cell.
#include "probe_update.slang"
#include "probe_tile.slang"
#define TILE 16
#define MIRAI_GROUP_X TILE
#define MIRAI_GROUP_Y TILE
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> ray_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
// RGBA16F because Metal read-write textures do not support two-channel half formats.
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> distances : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

groupshared float2 tile_values[TILE][TILE];
#define MAX_RAYS 256
groupshared float4 ray_values[MAX_RAYS];
groupshared float3 ray_dirs[MAX_RAYS];
groupshared uint backfaces;

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID, uint local_index : SV_GroupIndex) {
    uint slot = group_id.x;
    if (slot >= chosen[0]) return;
    uint probe = chosen[1u + slot];
    uint rays = min(params.rays_per_probe, uint(MAX_RAYS));
    if (local_index == 0u) backfaces = 0u;
    GroupMemoryBarrierWithGroupSync();
    for (uint r = local_index; r < rays; r += (MIRAI_GROUP_X * MIRAI_GROUP_Y)) {
        ray_values[r] = ray_data.Load(int3(int2(r, slot), 0));
        ray_dirs[r] = probe_ray_direction(probe, r, params.rays_per_probe);
        if (ray_values[r].a < 0.0) InterlockedAdd(backfaces, 1u);
    }
    GroupMemoryBarrierWithGroupSync();
    uint cascade;
    int3 cell = probe_slot_cell(probe, cascade);
    if (backfaces * 4u > rays && probe_holds(probes[probe], cell)) return;
    int2 local = int2(local_id.xy);
    uint per_row = frame.volume_atlas.x;
    int2 origin = int2(int(probe % per_row), int(probe / per_row)) * TILE;
    bool interior = all(local >= int2(1)) && all(local < int2(TILE - 1));
    float limit = probe_distance_limit(cascade);
    if (interior) {
        float2 oct = ((float2(local - 1) + 0.5) / float(TILE - 2)) * 2.0 - 1.0;
        float3 texel_dir = oct_decode(oct);
        float2 sum = float2(0.0);
        float weight_sum = 0.0;
        for (uint r = 0u; r < rays; r++) {
            float distance = min(abs(ray_values[r].a), limit) / limit; // normalized: fp16-safe moments
            float w = pow(max(0.0, dot(texel_dir, ray_dirs[r])), 50.0);
            sum += float2(distance, distance * distance) * w;
            weight_sum += w;
        }
        tile_values[local.y][local.x] = weight_sum > 1e-5 ? sum / weight_sum : float2(1.0);
    }
    GroupMemoryBarrierWithGroupSync();
    int2 source = interior ? local : probe_tile_interior(local, TILE);
    distances[origin + local] = float4(tile_values[source.y][source.x], 0.0, 0.0);
}
