#include "native.slang"
//! variant hw MIRAI_HW_RT=1
// color: colored shadows, whose rays take the filters of the glass they cross (trace.slang).
//! constant color MIRAI_COLORED_SHADOWS
// The medium and the light of each cell of the grid of the view
// (fog.fog_record): the medium of the volumes at a point of the cell, the
// same place in every frame, with the wisps of the variable ones as they are
// now; and the light that point gets for each metre of what it scatters,
// from the sun with a shadow ray, from one local light the tree of lights
// picks for what it gives the point, with another, and from around, by the
// probe volume. The rays are those of the shadows of the direct light: what
// crosses glass takes its color. Only the light keeps what the frame before
// found where the cell was then, by fog.history: wisps that drift through a
// shaft take its light at once, with no trail. It is not kept where a ray of
// the cell met what casts shadows and changed since then, or its light
// moved: a shaft of light that a moving thing cuts shows at once. A cell
// behind everything its column and those around it see is lit one frame in
// fog.hidden, by turns, and keeps what it had in the others: once the camera
// shows it, it has its light. With fog.hidden 0 it is never lit, and once
// shown its light starts again.
#include "media.slang"
#include <extension_hooks.slang>
#define FOG_VOLUMES_SLOT SLOT_PASS2
#include "fog_volumes.slang"
#define MIRAI_GROUP_X 4
#define MIRAI_GROUP_Y 4
#define MIRAI_GROUP_Z 4

// rgb the light towards the eye for each metre of what the medium scatters
// there, times a: 1 where there is a medium, 0 where none, below 0 never lit.
[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture3D<float4> light_now : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture3D<float4> light_before : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// The farthest depth each column and those around it see (fog_reach.comp).
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> column_reach : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
// rgb what the medium of the cell scatters in a metre, a what it stops.
[[vk::binding(SLOT_PASS4, 0)]] [[vk::image_format("rgba16f")]] RWTexture3D<float4> medium_now : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);

// The media of the volumes at a point, without what dry boxes take out
// (taken, fog_dry_at), for a cell footprint metres across: rgb what they
// scatter in a metre, a what they stop. mean: the same by the mean density
// of each, what the light of the point is weighed by; mean_sun_only, what
// of it the volumes the sun alone lights scatter; g, their anisotropy.
float4 fog_medium(float3 position, float taken, float footprint, out float4 mean, out float3 mean_sun_only, out float g) {
    float4 sum = float4(0.0);
    float3 sun_only = float3(0.0);
    float turned = 0.0;
    mean = float4(0.0);
    mean_sun_only = float3(0.0);
    for (uint i = 0u; i < fog.grid.w; i++) {
        Fog_Volume v = fog_volumes[i];
        if (fog_taken(v, taken)) continue;
        float w = volume_weight(v.volume, position);
        if (!(w > 0.0)) continue;
        float4 medium = v.medium * exp(-v.params.z * max(position.y - v.params.w, 0.0));
        float4 varied = medium * fog_wisps(v, position, footprint);
        float t = v.params.y * luminance(medium.rgb);
        if (fog_carve(v, FOG_CARVE_SUN_ONLY)) {
            // A medium the sun alone lights adds to what is there.
            sun_only += varied.rgb * w;
            sum.a += varied.a * w;
            mean_sun_only += medium.rgb * w;
            mean.a += medium.a * w;
            turned += t * w;
            continue;
        }
        sum = volume_mix(sum, varied, w, v.volume);
        mean = volume_mix(mean, medium, w, v.volume);
        turned = v.volume.kind.y != 0u ? turned + t * w : lerp(turned, t, w);
    }
    g = turned / max(luminance(mean.rgb + mean_sun_only), 1e-8);
    return float4(sum.rgb + sun_only, sum.a);
}

// The light the frame before left where the middle of the cell was then; false
// when the view keeps none, when it was outside the grid then, or when the
// cell there was not lit.
bool fog_before(uint3 id, out float4 before) {
    before = float4(0.0);
    if (fog.kept == 0u) return false;
    float3 middle = position_from_depth((float2(id.xy) + 0.5) / float2(fog.grid.xy), fog_slice_depth(float(id.z) + 0.5));
    float4 clip = view_clip_previous(middle);
    if (!(clip.w > 1e-6)) return false;
    float depth = dot(frame.prev_depth_plane.xyz, middle) + frame.prev_depth_plane.w;
    float3 at = float3(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5, fog_depth_slice(depth) / float(fog.grid.z));
    if (any(at < 0.0) || any(at > 1.0)) return false;
    before = light_before.SampleLevel(linear_sampler, at, 0.0);
    return before.a >= 0.0;
}

// How many places of a cell the sun is taken at: the shafts of narrow windows
// cross a cell in part, and one place took all of it or nothing.
#define FOG_SUN_POINTS 4u
#define FOG_GLASS_FOOTPRINT 1.0

// A place of the cell, the same in every frame: the k-th of its sequence.
float3 fog_cell_point(uint3 id, uint k, out float2 uv, out float along) {
    float2 across = sequence_point(uint2(id.x + id.z * 2039u, id.y), 11u, k);
    float2 along_point = sequence_point(uint2(id.y + id.z * 3121u, id.x), 13u, k);
    uv = (float2(id.xy) + across) / float2(fog.grid.xy);
    along = along_point.x;
    return position_from_depth(uv, fog_slice_depth(float(id.z) + along));
}

// The sun of the cell: the mean of what reaches FOG_SUN_POINTS places of it,
// each with its shadow ray; the first is the place the rest of the light is
// taken at. Glass on the way is read at the level of what a beam as wide as
// the cell covers of it (footprint, metres): a cell wider than the pieces of a
// window takes their mean, a narrow one their pattern.
float3 fog_cell_sun(uint3 id, float3 first, float3 eye_ray, float g, float taken, float footprint, inout bool changed) {
#ifdef MIRAI_RAY_FILTERS
    ray_filter_footprint = footprint * FOG_GLASS_FOOTPRINT;
#endif
    float3 sun = media_sun(first, eye_ray, g, float3(fog_shade(first, frame.sun_direction.xyz, taken)), changed);
    for (uint k = 1u; k < FOG_SUN_POINTS; k++) {
        float2 uv;
        float along;
        float3 at = fog_cell_point(id, k, uv, along);
        bool moved = false;
        sun += media_sun(at, eye_ray, g, float3(fog_shade(at, frame.sun_direction.xyz, taken)), moved);
        changed = changed || moved;
    }
#ifdef MIRAI_RAY_FILTERS
    ray_filter_footprint = 0.0;
#endif
    return sun / float(FOG_SUN_POINTS);
}

// Whether the cell lies behind everything its column and those around it see,
// with a slice to spare for the slices the grid is read between.
bool fog_hidden(uint3 id) {
    return fog_slice_depth(float(id.z) - 1.0) > column_reach.Load(int3(id.xy, 0)).r;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (any(id >= fog.grid.xyz)) return;
    if (fog.hidden != 1u && fog_hidden(id)) {
        // Not lit in this frame: it keeps what it had, and one without it is lit now; never lit, it says so.
        // No pixel reads the medium behind all that its column and those around it see.
        medium_now[id] = float4(0.0);
        if (fog.hidden == 0u) {
            light_now[id] = float4(0.0, 0.0, 0.0, -1.0);
            return;
        }
        // The turn is of the group of the cell: the threads that run together skip together.
        uint3 group = id / uint3(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z);
        float4 kept;
        if ((group.x + group.y * 3u + group.z * 5u + frame.frame_index) % fog.hidden != 0u && fog_before(id, kept)) {
            light_now[id] = kept;
            return;
        }
    }
    // Where in the cell the light is taken: another place for each cell and the same in every
    // frame. A place that moved from frame to frame changed what the shafts of light through a
    // window lit, and the history let the change through as blotches.
    float2 uv;
    float along;
    float3 position = fog_cell_point(id, 0u, uv, along);
    float3 eye_ray = view_direction(uv);
    float2 local_pick = sequence_point(uint2(id.y + id.z * 3121u, id.x), 13u, 0u);
    // About how far the cell reaches across and along the view.
    float depth = fog_slice_depth(float(id.z) + along);
    float width = depth * length(view_ray(uv + 1.0 / float2(fog.grid.xy)) - view_ray(uv));
    float footprint = max(fog_slice_depth(float(id.z + 1u)) - fog_slice_depth(float(id.z)), width);
    float g;
    float4 mean;
    float3 mean_sun_only;
    float taken = fog_dry_at(position);
    float4 medium = fog_medium(position, taken, footprint, mean, mean_sun_only, g);
    medium_now[id] = float4(finite_or_zero(medium.rgb), isfinite(medium.a) ? max(medium.a, 0.0) : 0.0);
    float3 scattered = mean.rgb + mean_sun_only;
    if (!(luminance(scattered) > 0.0)) {
        light_now[id] = float4(0.0);
        return;
    }
    bool changed = false;
    // The volumes that take the light of the sun dim what reaches the point from above and from the sun.
    float3 sun = frame.sun_direction.w > 0.5 ? fog_cell_sun(id, position, eye_ray, g, taken, width, changed) : float3(0.0);
    float3 light = sun * mean_sun_only;
    if (luminance(mean.rgb) > 0.0) light += mean.rgb * (media_ambient(position, -eye_ray) * fog_shade(position, float3(0.0, 1.0, 0.0), taken) + media_local_light(position, eye_ray, g, local_pick.y, changed) + sun);
    float4 now = float4(light / max(scattered, float3(1e-12)), 1.0);
    float4 before;
    if (!changed && fog_before(id, before)) now = lerp(now, before, fog.history);
    light_now[id] = float4(finite_or_zero(now.rgb), saturate(now.a));
}
