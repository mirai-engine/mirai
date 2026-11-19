//! mirai hook vertex foliage_lean foliage_sway
// How a vertex of an instance of a batch of foliage moves (params.y 1; the
// batches of anything else are left alone): bent about the place of its
// instance by the lean of the whole plant, by the red of its vertex color,
// and its leaves fluttering on top, by the red and the green. The lean is
// that of the wind where it stands with the phase of the gust wave there, by
// the sway of its type (params.x: Batch_Desc.vertex), and that of the field
// of trampled foliage, which leans every batch of foliage away from where
// bodies passed (foliage.Foliage_Trample); the flutter, that of the wind by
// the flutter of its type (params.z). What the whole plant does is the part
// of each instance; each vertex only places itself by it.
// The maps of the shadows near the eye place a swaying caster through it too;
// no ray meets it swaying.
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

// The lean of a plant at time, radians along x and z of the world, in xy,
// and how its leaves flutter (foliage_wind_flutter) in zw.
float4 foliage_lean(float3 pivot, float4 params, float time) {
    if (!(params.y > 0.0)) return float4(0.0);
    float2 lean = foliage_trampled(pivot, time);
    float2 flutter = float2(0.0);
    if (params.x > 0.0 || params.z > 0.0) {
        float4 wind = wind_at(frame.foliage_wind.wind, pivot);
        float phase = foliage_wave(pivot, frame.origin.xyz);
        lean += foliage_wind_lean(wind.xyz, wind.w, 1.0, params.x, phase, time);
        if (params.z > 0.0) flutter = foliage_wind_flutter(wind.xyz, wind.w, params.z, phase, time);
    }
    return float4(lean, flutter);
}

float3 foliage_sway(float3 world, float3 pivot, float4 color, float4 lean) {
    float3 rest = world - pivot;
    float3 p = pivot + foliage_bend(rest, lean.xy * color.r);
    if (lean.z > 0.0) p += foliage_flutter(rest, lean.xy, float2(lean.z * color.r * color.g, lean.w));
    return p;
}
