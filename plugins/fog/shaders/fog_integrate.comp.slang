#include "native.slang"
// The fog along each column of the grid, from the eye (fog.fog_record): in
// each cell, the light that reaches the eye from it and from those before
// it, and the share of what lies behind the cell that they let through. A
// cell adds its light over its length, dimmed by itself on the way
// (Hillaire 2015). Each cell takes its medium and the light of those around
// it in its slice, by a tent of 3x3: the shadow rays of a cell see the sun or
// not, and what the history leaves of that is spread out.
// Past the grid the same volumes go on along the ray of the column in
// fog.far slices, the last without end, each in closed form: what the mean
// density of each volume stops between where the slice enters and leaves it,
// and what it scatters of the sun, without shadow rays, and of the light
// around where the grid ends, with its phase. The light of the end of the
// grid and that of the slices past it are the same terms, so the fog goes on
// with no seam.
#include "media.slang"
#define FOG_VOLUMES_SLOT SLOT_PASS3
#include "fog_volumes.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] Texture3D<float4> light_now : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
// rgb the light that reaches the eye from the far side of the cell on, a the share it lets through.
[[vk::binding(SLOT_PASS1, 0)]] [[vk::image_format("rgba16f")]] RWTexture3D<float4> seen : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture3D<float4> medium_now : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);

// Metres along the view taken for without end: what a medium there lets through is none.
static const float FOG_ENDLESS = 1e7;

// The light of a slice past the grid from a to b, and in a what it stops:
// each volume by its mean density along the share of the slice in it, the
// one that replaces what is below taking that share of it.
float4 fog_beyond(float3 a, float3 b, float3 eye_ray, float3 around) {
    float3 sun_dir = frame.sun_direction.xyz;
    bool sun_on = frame.sun_direction.w > 0.5;
    float3 middle = 0.5 * (a + b);
    float3 sun = sun_on ? sun_light(middle) * fog_shade(middle, sun_dir, DRY_NONE) : float3(0.0);
    float3 ambient = around * fog_shade(middle, float3(0.0, 1.0, 0.0), DRY_NONE);
    float cosine = dot(eye_ray, sun_dir);
    float length = distance(a, b);
    float depth = 0.0;
    float3 sent = float3(0.0); // what each volume scatters over what it stops, times what it stops
    for (uint i = 0u; i < fog.grid.w; i++) {
        Fog_Volume v = fog_volumes[i];
        if (fog_carve(v, FOG_CARVE_DRY) || !(v.medium.a > 0.0)) continue;
        float start, end;
        fog_volume_segment(v, a, b, start, end);
        if (!(end > start)) continue;
        float stopped = fog_optical_depth(v, lerp(a.y, b.y, start), lerp(a.y, b.y, end), (end - start) * length);
        float3 light = sun * media_phase(cosine, v.params.y);
        if (!fog_carve(v, FOG_CARVE_SUN_ONLY)) light += ambient;
        float3 by = v.medium.rgb / v.medium.a * light * stopped;
        if (v.volume.kind.y != 0u) {
            depth += stopped;
            sent += by;
        } else {
            depth = depth * (1.0 - (end - start)) + stopped;
            sent = sent * (1.0 - (end - start)) + by;
        }
    }
    return float4(sent, depth);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    if (any(id.xy >= fog.grid.xy)) return;
    float2 uv = (float2(id.xy) + 0.5) / float2(fog.grid.xy);
    // Metres along the ray of the column for each metre of depth.
    float stretch = length(view_ray(uv));
    float3 scattered = float3(0.0);
    float through = 1.0;
    float near = 0.0;
    for (uint z = 0u; z < fog.grid.z; z++) {
        // The light for each metre of what scatters, of the cells around that have a medium.
        float4 light = float4(0.0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                int2 at = int2(id.xy) + int2(x, y);
                if (any(at < 0) || any(at >= int2(fog.grid.xy))) continue;
                float w = float((2 - abs(x)) * (2 - abs(y)));
                light += light_now.Load(int4(at, z, 0)) * w;
            }
        }
        float4 medium = medium_now.Load(int4(id.xy, z, 0));
        float4 cell = float4(medium.rgb * (light.a > 0.0 ? light.rgb / light.a : float3(0.0)), medium.a);
        float far = fog_slice_depth(float(z + 1u));
        float length = (far - near) * stretch;
        near = far;
        float lost = exp(-cell.a * length);
        scattered += through * (cell.a > 1e-7 ? cell.rgb * ((1.0 - lost) / cell.a) : cell.rgb * length);
        through *= lost;
        seen[int3(id.xy, z)] = float4(scattered, through);
    }
    float3 eye_ray = view_direction(uv);
    float3 around = media_ambient(position_from_depth(uv, fog.distance), -eye_ray);
    float3 a = position_from_depth(uv, fog.distance);
    for (uint j = 0u; j < fog.far; j++) {
        float3 b = j + 1u < fog.far ? position_from_depth(uv, fog_far_depth(j)) : a + eye_ray * FOG_ENDLESS;
        float4 slice = fog_beyond(a, b, eye_ray, around);
        float lost = exp(-slice.a);
        // Over the slice each volume sends what it scatters over what it stops, as much as the slice lets through.
        scattered += through * (slice.a > 1e-7 ? slice.rgb * ((1.0 - lost) / slice.a) : slice.rgb);
        through *= lost;
        seen[int3(id.xy, fog.grid.z + j)] = float4(scattered, through);
        a = b;
    }
}
