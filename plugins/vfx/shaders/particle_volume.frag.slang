#include "native.slang"
// The media of the volumes over the lit scene: a ray from the camera through
// the region of each volume, in steps of a cell from where it enters to
// where it leaves, the scene behind it or the glass of the pass. Each step
// takes what the medium there stops, what it scatters of the light its cells
// receive (the sun with the phase of the medium towards the eye) and what it
// glows, behind what the steps before stopped. Radiance is premultiplied; the
// second target is the share of the pixel it covers.
#include "media.slang"
#include "particle_programs.slang"
#include "depth.slang"
#define VOLUME_STEPS 256u

#include "media_grid.slang"
struct Params_Block { uint volumes; uint count; uint pass; uint pad; Media_Grid media; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] Texture2D<float4> glass_depth : register(MIRAI_REGISTER(t, SLOT_PASS8), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture3D<float4> media : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);

struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
    [[vk::location(1)]] float4 out_coverage : SV_Target1;
};

[shader("fragment")]
Stage_Output main(float4 pixel_position : SV_Position) {
    Stage_Output output;
    int2 pixel = int2(pixel_position.xy);
    float2 uv = pixel_position.xy * frame.inv_resolution;
    float3 origin = view_origin(uv), ray = view_ray(uv);
    float metres = length(ray);
    float3 eye_ray = ray / max(metres, 1e-8);
    // Along the ray in linear depth: from the near plane to the scene, or to or from the glass of the pass.
    float scene = g_depth.Load(int3(pixel, 0)).r;
    float near = frame.camera_position.w, far = depth_empty(scene) ? frame.camera_forward.w : depth_distance(scene);
    if (params.pass != 0u) {
        float layer = glass_depth.Load(int3(pixel, 0)).r;
        bool front = params.pass == PARTICLE_PASS_FRONT_OF_GLASS;
        if (layer > 0.0) {
            if (front) far = min(far, layer); else near = max(near, layer);
        } else if (front) discard;
    }
    float jitter = float(hash_u32(uint(pixel.x) * 73856093u ^ uint(pixel.y) * 19349663u ^ frame.frame_index * 83492791u) >> 8) / 16777216.0;
    float3 radiance = float3(0.0);
    float through = 1.0;
    // Where along the ray the light it sends starts: the media of the view lie between there and the eye.
    float first = -1.0;
    for (uint i = 0u; i < params.count && through > 0.01; i++) {
        Particle_Volume_Row v = particle_volume_at(params.volumes + i * PARTICLE_VOLUME_ROW_BYTES);
        Particle_Grid_Row g = particle_grid_row_at(v.grid);
        float3 lo = g.corner, hi = g.corner + float3(g.cells) * g.cell_size;
        float3 inverse = 1.0 / select(abs(ray) > 1e-12, ray, float3(1e-12));
        float3 a = (lo - origin) * inverse, b = (hi - origin) * inverse;
        float3 enter = min(a, b), leave = max(a, b);
        float t0 = max(max(enter.x, max(enter.y, enter.z)), near), t1 = min(min(leave.x, min(leave.y, leave.z)), far);
        if (!(t1 > t0)) continue;
        uint copy = particle_grid_copy(g);
        uint steps = min(uint(ceil((t1 - t0) * metres / g.cell_size)), VOLUME_STEPS);
        float step = (t1 - t0) / float(max(steps, 1u));
        float ds = step * metres;
        float sun_phase = media_phase(dot(eye_ray, frame.sun_direction.xyz), v.anisotropy);
        for (uint s = 0u; s < steps && through > 0.01; s++) {
            float3 at = origin + ray * (t0 + (float(s) + jitter) * step);
            Particle_Grid_Corners corners = particle_grid_corners(g, at);
            float4 cell = particle_grid_sample_corners(g, copy, corners, 0u);
            float density = max(cell.x, 0.0) * v.density;
            float glow = max(cell.y, 0.0);
            // Where the cells around are empty the next one is passed over.
            if (!(density > 0.0) && !(glow > 0.0)) { s++; continue; }
            float4 light = particle_volume_light(v, corners);
            float3 sun = frame.sun_direction.w >= 0.5 ? sun_light(at) * light.a * sun_phase : float3(0.0);
            float3 source = v.albedo * density * (light.rgb + sun) + emission_render_units(v.emission * glow, false);
            if (first < 0.0) first = t0 + (float(s) + jitter) * step;
            float kept = exp(-density * ds);
            radiance += through * (density > 0.0 ? source * (1.0 - kept) / density : source * ds);
            through *= kept;
        }
    }
    if (through >= 0.9999) discard;
    float4 medium = first >= 0.0 ? media_over(media, params.media, origin + ray * first) : float4(0.0, 0.0, 0.0, 1.0);
    output.out_color = float4(finite_or_zero(radiance * medium.a + medium.rgb * (1.0 - through)), 1.0 - through);
    output.out_coverage = float4(1.0 - through, 0.0, 0.0, 0.0);
    return output;
}
