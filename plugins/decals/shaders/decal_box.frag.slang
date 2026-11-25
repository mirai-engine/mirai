#include "native.slang"
// What a decal changes of the surface under the pixels its box covers, into
// the decal targets of the view (render.pass_decal_begin), as decal.frag of
// the engine writes them: before the G-buffer is resolved, so the surface is
// found from the depth buffer, its normal from the depths around it.
//
// emissive: the view has the emission target.
//! variant emissive MIRAI_DECAL_EMISSIVE=1
#include "decal_box.slang"
#include "raster.slang"

[[vk::binding(SLOT_PASS1, 0)]]
Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

struct Stage_Input {
    [[vk::location(0)]] nointerpolation uint in_decal : TEXCOORD0;
    [[vk::location(1)]] float3 in_local : TEXCOORD1;
};
struct Stage_Output {
    [[vk::location(0)]] float4 color : SV_Target0;
    [[vk::location(1)]] float4 normal : SV_Target1;
    [[vk::location(2)]] float4 surface : SV_Target2;
#ifdef MIRAI_DECAL_EMISSIVE
    [[vk::location(3)]] float4 emission : SV_Target3;
#endif
};

// The place in the world a pixel of the depth buffer holds.
float3 decal_place(int2 p) {
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    float4 at = mul(frame.inv_view_proj, float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, g_depth.Load(int3(p, 0)).r, 1.0));
    return at.xyz / at.w + frame.camera_position.xyz;
}

// The normal of the surface at a pixel from the places of its neighbors: on
// each axis the one nearer to it, which is on the same surface where the other
// is across an edge. Facing the eye.
float3 decal_receiver(int2 p, float3 place) {
    float3 right = decal_place(p + int2(1, 0)) - place, left = place - decal_place(p - int2(1, 0));
    float3 down = decal_place(p + int2(0, 1)) - place, up = place - decal_place(p - int2(0, 1));
    float3 across = dot(right, right) < dot(left, left) ? right : left;
    float3 along = dot(down, down) < dot(up, up) ? down : up;
    float3 n = cross(along, across);
    if (!(dot(n, n) > 1e-24)) return to_eye(place);
    n = normalize(n);
    return dot(n, to_eye(place)) < 0.0 ? -n : n;
}

float3 decal_normal(Decal d, float2 uv, float footprint, float3 receiver) {
    float2 xy = decal_sample(d.normal_map, uv, footprint, d.normal_density).rg * 2.0 - 1.0;
    float3 axis_x = transform_vector(d.to_world, float3(1.0, 0.0, 0.0));
    float3 axis_z = transform_vector(d.to_world, float3(0.0, 0.0, 1.0));
    float3 tangent = axis_x - receiver * dot(axis_x, receiver);
    // At a grazing projection the U axis can point straight into the surface.
    if (dot(tangent, tangent) < dot(axis_x, axis_x) * 1e-8) tangent = cross(axis_z, receiver);
    tangent = normalize(tangent);
    float handedness = dot(cross(receiver, tangent), axis_z) < 0.0 ? -1.0 : 1.0;
    return tangent_frame_normal(receiver, float4(tangent, handedness),
                                float3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0))));
}

[shader("fragment")]
Stage_Output main(Stage_Input input, float4 pixel : SV_Position) {
    Decal d = decals[input.in_decal];
    int2 p = int2(pixel.xy);
    // Nothing is drawn there.
    if (!(g_depth.Load(int3(p, 0)).r > 0.0)) discard;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    // A pixel sees two faces of the box and one of them draws it: the far
    // one, which is there with the eye inside the box too.
    float3 face = sign(input.in_local) * step(0.4999, abs(input.in_local));
    if (dot(transform_vector(d.to_world, face), view_direction(uv)) <= 0.0) discard;
    float3 place = decal_place(p);
    float3 local = transform_point(d.to_box, place);
    if (any(abs(local) > float3(0.5))) discard;
    float footprint = frame.footprint.x + frame.footprint.y * view_depth(place);
    float3 receiver = decal_receiver(p, place);
    float4 color = decal_color(d, local.xz + 0.5, footprint, receiver);
    float covered = color.a;
    if (!(covered > 0.0)) discard;
    Stage_Output output = (Stage_Output)0;
    if ((d.writes & DECAL_WRITE_COLOR) != 0u) output.color = float4(color.rgb, 1.0) * covered;
    if ((d.writes & DECAL_WRITE_NORMAL) != 0u) {
        float3 mapped = fragment_facing(decal_normal(d, local.xz + 0.5, footprint, receiver), to_eye(place));
        output.normal = float4(mapped - receiver, 1.0) * covered;
    }
    if ((d.writes & DECAL_WRITE_SURFACE) != 0u) output.surface = float4(d.roughness, d.metallic, 1.0, 1.0) * covered;
#ifdef MIRAI_DECAL_EMISSIVE
    if ((d.writes & DECAL_WRITE_EMISSION) != 0u) output.emission = float4(render_units(d.emission.rgb), 1.0) * covered;
#endif
    return output;
}
