#include "native.slang"
// The irradiance of each probe chosen this frame from its rays, into its
// octahedral tile (6x6 interior and a border of one texel that wraps for
// bilinear filtering). Its rays are the same every update. The rays and the
// tiles hold the light encoded (probe_light_encode); this pass weighs,
// filters and blends it decoded.
//
// Each texel takes, with what its rays give, what the probes next to it along
// the grid hold in the same direction, where they see what this probe would:
// the point their rays meet there (their mean distance) lies within
// PROBE_FILTER_ANGLE of that direction from this probe, and this probe's own
// distance that way ends there too; a wall
// between them, or a corner, leaves the neighbor out. A neighbor moved out of
// a wall thinner than the spacing, to its other side, sees the light beyond
// it the same way, behind what this probe meets. The
// neighbors are read from the atlas ddgi_keep.comp copies each probe into
// after its trace, never from the one being written: what each held after its
// last trace. A probe a change keeps awake filters as a settled one does: with
// its own rays alone its light strayed from that of the settled probes around,
// and a change that woke the coarse cascades over a view (a thrown cube that
// glows) moved the light of the whole volume, and of the fog it lights, until
// they settled again.
//
// A probe follows a change of its light whole. Its light moves between traces
// also by the noise of the bounces its rays read from the volume: it measures how much
// (Probe.frames.w, as a share of its light), and a change within it moves the
// probe by PROBE_BLEND only, so that it comes to the mean of that noise
// instead of keeping the noise of its last trace. A probe whose light moved
// by more than its noise, or PROBE_SETTLED, is traced again next frame with
// the probes beside it, which read it: what its rays meet is still settling,
// and a probe new to its cell is traced twice. One whose light stays is left
// alone until a change reaches it, or one beside it moves. A probe that sees the inside of geometry with
// more than a quarter of its rays keeps what it held, if it held the light of
// this cell: something moved over it.
#define PROBES_WRITABLE
#include "probe_update.slang"
#include "probe_tile.slang"
#define TILE 8
#define MIRAI_GROUP_X TILE
#define MIRAI_GROUP_Y TILE
#define MIRAI_GROUP_Z 1
#define PROBE_SETTLED 0.01
// How many times its noise the light of a probe must move to be a change, the
// share of the new light a move within it takes, and how fast the noise
// follows what the probe measures.
#define PROBE_NOISE_CHANGE 2.0
#define PROBE_BLEND 0.25
#define PROBE_NOISE_RATE 0.25
// The cosine of the angle a neighbor's point may lie off a direction, the
// weight of a neighbor against the probe's own rays, how far, in spacings,
// the point a neighbor sees may lie from where this probe's own distance that
// way ends, and the share of the distance limit from which a distance is
// open: the probe meets nothing as far as it looks.
#define PROBE_FILTER_ANGLE 0.97
#define PROBE_FILTER_WEIGHT 0.5
#define PROBE_FILTER_REACH 0.5
#define PROBE_FILTER_OPEN 0.9

[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> ray_data : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> irradiance : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
// What each probe held after its last trace (ddgi_keep.comp).
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> kept : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);

groupshared float4 tile_values[TILE][TILE];
#define MAX_RAYS 256
groupshared float4 ray_values[MAX_RAYS];
groupshared float3 ray_dirs[MAX_RAYS];
groupshared uint backfaces;
// The light of the tile, before or after, how much it moved, in thousandths
// of its brightest texel, and that texel.
groupshared uint tile_light;
groupshared uint tile_moved;
groupshared uint tile_peak;

// What a probe next to this one along the grid, `step` away, holds in
// direction `dir` (interior texel `local` of its tile), where it sees what
// this probe, slot `self_index` at `self`, would; a below 0 where it does not.
float4 probe_neighbor(int3 cell, uint cascade, int3 step, uint self_index, float3 self, float3 dir, int2 local) {
    int3 other_cell = cell + step;
    int3 corner = probe_corner_cell(cascade);
    if (any(other_cell < corner) || any(other_cell >= corner + int3(frame.volume_counts.xyz))) return float4(0.0, 0.0, 0.0, -1.0);
    uint other = probe_slot(cascade, other_cell);
    Probe probe = probes[other];
    if (!probe_holds(probe, other_cell) || (probe.cell.w & PROBE_BURIED) != 0) return float4(0.0, 0.0, 0.0, -1.0);
    uint per_row = frame.volume_atlas.x;
    int2 tile = int2(int(other % per_row), int(other / per_row));
    float2 oct = oct_encode(dir) * 0.5 + 0.5;
    int2 inside = 1 + min(int2(oct * float(DISTANCE_TILE - 2)), int2(DISTANCE_TILE - 3));
    float limit = probe_distance_limit(cascade);
    float reach = distance_atlas.Load(int3(tile * DISTANCE_TILE + inside, 0)).r * limit;
    float3 seen = probe_world_position(other) + dir * reach;
    if (dot(normalize(seen - self), dir) < PROBE_FILTER_ANGLE) return float4(0.0, 0.0, 0.0, -1.0);
    // Where its own distance ends short of that point, something stands
    // between; where it ends beyond the point the neighbor meets, the
    // neighbor sees a surface this probe looks past. An open distance says
    // neither.
    int2 self_tile = int2(int(self_index % per_row), int(self_index / per_row));
    float own = distance_atlas.Load(int3(self_tile * DISTANCE_TILE + inside, 0)).r * limit;
    float apart = length(seen - self);
    float slack = PROBE_FILTER_REACH * probe_spacing(cascade);
    bool own_open = own >= PROBE_FILTER_OPEN * limit;
    bool seen_open = reach >= PROBE_FILTER_OPEN * limit;
    if ((!own_open && own < apart - slack) || (!seen_open && own > apart + slack)) return float4(0.0, 0.0, 0.0, -1.0);
    return float4(probe_light_decode(kept.Load(int3(tile * TILE + local, 0)).rgb), 1.0);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID, uint local_index : SV_GroupIndex) {
    uint slot = group_id.x;
    if (slot >= chosen[0]) return;
    uint probe = chosen[1u + slot];
    uint rays = min(params.rays_per_probe, uint(MAX_RAYS));
    if (local_index == 0u) { backfaces = 0u; tile_light = 0u; tile_moved = 0u; tile_peak = 0u; }
    GroupMemoryBarrierWithGroupSync();
    for (uint r = local_index; r < rays; r += (MIRAI_GROUP_X * MIRAI_GROUP_Y)) {
        float4 ray_value = ray_data.Load(int3(int2(r, slot), 0));
        ray_values[r] = float4(probe_light_decode(ray_value.rgb), ray_value.a);
        ray_dirs[r] = probe_ray_direction(probe, r, params.rays_per_probe);
        if (ray_values[r].a < 0.0) InterlockedAdd(backfaces, 1u);
    }
    GroupMemoryBarrierWithGroupSync();
    uint cascade;
    int3 cell = probe_slot_cell(probe, cascade);
    Probe state = probes[probe];
    bool held = probe_holds(state, cell);
    bool buried = backfaces * 4u > rays;
    if (buried && held) return;
    int2 local = int2(local_id.xy);
    uint per_row = frame.volume_atlas.x;
    int2 origin = int2(int(probe % per_row), int(probe / per_row)) * TILE;
    bool interior = all(local >= int2(1)) && all(local < int2(TILE - 1));
    float light = 0.0, moved = 0.0;
    float3 before = probe_light_decode(irradiance[origin + local].rgb);
    if (interior) {
        float2 oct = ((float2(local - 1) + 0.5) / float(TILE - 2)) * 2.0 - 1.0;
        float3 texel_dir = oct_decode(oct);
        float3 sum = float3(0.0);
        float weight_sum = 0.0;
        for (uint r = 0u; r < rays; r++) {
            float4 sample_value = ray_values[r];
            if (sample_value.a < 0.0) continue;
            float w = max(0.0, dot(texel_dir, ray_dirs[r]));
            sum += sample_value.rgb * w;
            weight_sum += w;
        }
        float3 value = finite_or_zero(weight_sum > 1e-4 ? sum / weight_sum : float3(0.0));
        float3 self = probe_world_position(probe);
        float3 filtered = value;
        float filter_weight = 1.0;
        int3 steps[6] = {int3(1, 0, 0), int3(-1, 0, 0), int3(0, 1, 0), int3(0, -1, 0), int3(0, 0, 1), int3(0, 0, -1)};
        for (int k = 0; k < 6; k++) {
            float4 there = probe_neighbor(cell, cascade, steps[k], probe, self, texel_dir, local);
            if (there.a < 0.0) continue;
            filtered += there.rgb * PROBE_FILTER_WEIGHT;
            filter_weight += PROBE_FILTER_WEIGHT;
        }
        value = filtered / filter_weight;
        tile_values[local.y][local.x] = float4(value, 1.0);
        light = luminance(value);
        float shown = luminance(before);
        moved = abs(light - shown);
        light = max(light, shown);
        InterlockedMax(tile_peak, asuint(light));
    }
    GroupMemoryBarrierWithGroupSync();
    float peak = asfloat(tile_peak);
    if (interior && peak > 0.0) {
        InterlockedAdd(tile_light, uint(light / peak * 1000.0 + 0.5));
        InterlockedAdd(tile_moved, uint(min(moved / peak, 1.0) * 1000.0 + 0.5));
    }
    GroupMemoryBarrierWithGroupSync();
    float share = float(tile_moved) / max(float(tile_light), 1.0);
    float noise = asfloat(state.frames.w);
    // Kept awake by a change of the scene, not by its own light moving (frame + 1).
    bool marked = state.frames.z > params.frame_number;
    bool change = !held || marked || share > max(PROBE_SETTLED, PROBE_NOISE_CHANGE * noise);
    if (interior) tile_values[local.y][local.x] = float4(lerp(before, tile_values[local.y][local.x].rgb, change ? 1.0 : PROBE_BLEND), 1.0);
    GroupMemoryBarrierWithGroupSync();
    int2 source = interior ? local : probe_tile_interior(local, TILE);
    irradiance[origin + local] = float4(probe_light_encode(tile_values[source.y][source.x].rgb), 1.0);
    if (local_index != 0u || buried) return;
    if (held && !marked) probes[probe].frames.w = asuint(lerp(noise, share, PROBE_NOISE_RATE));
    if (held && share <= max(PROBE_SETTLED, PROBE_NOISE_CHANGE * noise)) return;
    probes[probe].frames.z = max(probes[probe].frames.z, params.frame_number + 1u);
    // What the probes beside it read of it moved: they are traced again next
    // frame, and a change spreads through the volume while it moves them.
    int3 corner = probe_corner_cell(cascade);
    int3 steps[6] = {int3(1, 0, 0), int3(-1, 0, 0), int3(0, 1, 0), int3(0, -1, 0), int3(0, 0, 1), int3(0, 0, -1)};
    for (int k = 0; k < 6; k++) {
        int3 other_cell = cell + steps[k];
        if (any(other_cell < corner) || any(other_cell >= corner + int3(frame.volume_counts.xyz))) continue;
        uint other = probe_slot(cascade, other_cell);
        if (!probe_holds(probes[other], other_cell)) continue;
        InterlockedMax(probes[other].frames.z, params.frame_number + 1u);
    }
}
