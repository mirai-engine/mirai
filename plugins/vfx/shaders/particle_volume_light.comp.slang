#include "native.slang"
// The light each cell of each volume (y) receives, from the light of media
// (media.slang): the sun through the scene, times what the medium lets
// through over its cells towards the sun, one local light the tree of lights
// picks by turns, and the light around. rgb keeps what comes from around and
// from the local lights, a what the sun gives, which the march takes with
// the phase towards the eye; what the frames before found weighs
// VOLUME_HISTORY. A cell without density receives nothing.
//! variant hw MIRAI_HW_RT=1
#define PARTICLES_WRITABLE
#include "media.slang"
#include "particle_programs.slang"
#include <extension_hooks.slang>
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
#define VOLUME_SUN_STEPS 32u
#define VOLUME_HISTORY 0.75

struct Params_Block { uint mode; uint emitters; uint count; uint parity; uint step; uint last; uint volumes; uint iteration; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    Particle_Volume_Row v = particle_volume_at(params.volumes + id.y * PARTICLE_VOLUME_ROW_BYTES);
    Particle_Grid_Row g = particle_grid_row_at(v.grid);
    if (id.x >= g.cells.x * g.cells.y * g.cells.z) return;
    uint3 along = uint3(id.x % g.cells.x, (id.x / g.cells.x) % g.cells.y, id.x / (g.cells.x * g.cells.y));
    int3 index = g.first + int3(along);
    uint at;
    if (!particle_grid_cell(g, index, at)) return;
    uint copy = particle_grid_copy(g);
    uint address = v.light + at * 16u;
    if (!(particle_grid_read(g, copy, index, 0u).x * v.density > 0.0)) {
        particle_world_bytes.Store4(address, uint4(0u));
        return;
    }
    float3 position = particle_grid_middle(g, index);
    float sun = 0.0;
    if (frame.sun_direction.w >= 0.5) {
        // What the medium stops on the way to the sun, cell by cell out of its region.
        float3 lo = g.corner, hi = g.corner + float3(g.cells) * g.cell_size;
        float optical = 0.0;
        for (uint i = 1u; i <= VOLUME_SUN_STEPS; i++) {
            float3 ahead = position + frame.sun_direction.xyz * (float(i) * g.cell_size);
            if (any(ahead < lo) || any(ahead > hi)) break;
            optical += max(particle_grid_sample_row(g, copy, ahead, 0u).x, 0.0) * v.density * g.cell_size;
        }
        sun = luminance(trace_transmission(position, frame.sun_direction.xyz, sun_reach(position, frame.sun_direction.xyz))) * exp(-optical);
    }
    float pick = float(hash_u32(at * 9781u + frame.frame_index * 26699u) >> 8) / 16777216.0;
    float3 up = float3(0.0, 1.0, 0.0);
    float4 now = float4(media_ambient(position, up) + media_local_light(position, up, 0.0, pick), sun);
    float4 before = asfloat(particle_world_bytes.Load4(address));
    if (all(isfinite(before)) && any(before != float4(0.0))) now = lerp(now, before, VOLUME_HISTORY);
    particle_world_bytes.Store4(address, asuint(float4(finite_or_zero(now.rgb), isfinite(now.a) ? max(now.a, 0.0) : 0.0)));
}
