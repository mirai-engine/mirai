//! mirai hook vertex foliage_sway
// How a vertex of an instance of a batch of foliage moves (params.y 1; the
// batches of anything else are left alone): bent about the place of its
// instance, by the red of its vertex color, by the wind where it stands with
// the phase of the gust wave there, if its batch sways in the hook (params.x,
// the sway of its type: Batch_Desc.vertex; a type without shadows, which no
// ray meets swaying), and by the field of trampled foliage, which leans every
// batch of foliage away from where bodies passed (foliage.Foliage_Trample).
#include "foliage_sway.slang"

// The lean the field keeps at a plant standing at pivot, radians along x and
// z of the world: none outside the field, fading at its edge, nor where what
// leaned it passed far above or below the plant. The call for the motion
// vectors (time of the frame before) reads the field of the frame before.
float2 foliage_trampled(float3 pivot, float time) {
    uint texture = time != frame.time.x ? frame.foliage_wind.textures.y : frame.foliage_wind.textures.x;
    if (texture == 0xffffffffu) return float2(0.0);
    float4 field = frame.foliage_wind.trample;
    float2 from = abs(pivot.xz - field.xy) / (0.5 * field.w);
    float edge = 1.0 - smoothstep(0.8, 1.0, max(from.x, from.y));
    if (!(edge > 0.0)) return float2(0.0);
    // Texel i of the world is kept at i modulo the side, which the repeating sampler wraps.
    float2 wrap = origin_wrap(frame.origin.xyz, float3(field.w, 1.0, field.w)).xz;
    float4 v = mirai_sample_texture_level(texture, (pivot.xz + wrap) / field.w, 0.0);
    if (!(v.w > 1e-3)) return float2(0.0);
    float above = pivot.y - (field.z + v.z / v.w);
    float near = 1.0 - smoothstep(0.5, 1.0, max(-above, 2.0 * above) / FOLIAGE_BEND_RADIUS_MAX);
    return v.xy * (edge * near);
}

float3 foliage_sway(float3 world, float3 pivot, float4 color, float4 params, float time) {
    if (!(params.y > 0.0)) return world;
    float2 lean = foliage_trampled(pivot, time);
    if (params.x > 0.0) {
        float4 wind = wind_at(frame.foliage_wind.wind, pivot);
        lean += foliage_wind_lean(wind.xyz, wind.w, 1.0, params.x, foliage_wave(pivot, frame.origin.xyz), time);
    }
    return pivot + foliage_bend(world - pivot, lean * color.r);
}
