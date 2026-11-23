#include "native.slang"
//! mirai constant DECAL_CAPACITY uint ../runtime/decals.odin
//! mirai constant DECAL_TILE uint ../runtime/decals.odin
#include <constants/plugins/decals.slang>
#include "decal.slang"
#define GBUFFER_NORMAL SLOT_PASS2
#define GBUFFER_ALBEDO SLOT_PASS3
#define GBUFFER_EMISSION SLOT_PASS4
#include "gbuffer.slang"
#include "pixel.slang"
#include "raster.slang"

[[vk::binding(SLOT_PASS1, 0)]]
Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS5, 0)]] [[vk::image_format("rgba16f")]]
RWTexture2DArray<float4> scratch : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
struct Region { int4 rect; uint count; };
[[vk::binding(SLOT_PARAMS, 0)]]
ConstantBuffer<Region> region : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

static const uint MASK_WORDS = (DECAL_CAPACITY + 31u) / 32u;
groupshared uint tile_masks[MASK_WORDS];

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

float4 decal_reflectance(int2 p, float4 before, float4 after) {
    float4 specular = pixel_reflectance(p, before, true);
    float dielectric_weight = 1.0 - before.a;
    float3 dielectric = default_dielectric_f0();
    float grazing = 1.0;
    if (dielectric_weight > 0.0) {
        dielectric = saturate((specular.rgb - before.rgb * before.a) / dielectric_weight);
        grazing = saturate((specular.a - before.a) / dielectric_weight);
    }
    return specular_pack(lerp(dielectric, after.rgb, after.a), lerp(grazing, 1.0, after.a));
}

[shader("compute")]
[numthreads(DECAL_TILE, DECAL_TILE, 1)]
void main(uint3 dispatch_id : SV_DispatchThreadID, uint3 group : SV_GroupID,
          uint lane : SV_GroupIndex) {
    if (lane < MASK_WORDS) tile_masks[lane] = 0u;
    GroupMemoryBarrierWithGroupSync();
    int2 tile = region.rect.xy + int2(group.xy * DECAL_TILE);
    for (uint i = lane; i < region.count; i += DECAL_TILE * DECAL_TILE) {
        int4 rect = decals[i].rect;
        if (all(rect.xy < tile + int(DECAL_TILE)) && all(rect.zw > tile))
            InterlockedOr(tile_masks[i >> 5u], 1u << (i & 31u));
    }
    GroupMemoryBarrierWithGroupSync();

    int2 p = region.rect.xy + int2(dispatch_id.xy);
    if (any(p >= region.rect.zw)) return;
    int3 pixel = int3(p, 0);
    uint covered = 0u;
    for (uint word = 0u; word < MASK_WORDS; ++word) covered |= tile_masks[word];
    float depth = covered != 0u ? g_depth.Load(pixel).r : 0.0;
    // A negative depth is a pixel of a nested view.
    if (depth_empty(depth) || depth_nested(depth)) {
        scratch[uint3(p, 1)] = float4(0.0, 0.0, 0.0, -1.0);
        return;
    }
    Pixel surface = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth);
    float footprint = frame.footprint.x + frame.footprint.y * depth;
    float4 normal_texel = gbuffer_normal_target.Load(pixel);
    float3 receiver = gbuffer_normal_unpack(normal_texel);
    float3 normal = receiver;
    float4 original = gbuffer_albedo_target.Load(pixel);
    float4 albedo = original;
    float4 emission = gbuffer_emission_target.Load(pixel);
    uint bits = gbuffer_bits_unpack(normal_texel);
    bool changed = false;
    for (uint word = 0u; word < MASK_WORDS; ++word) {
        uint mask = tile_masks[word];
        while (mask != 0u) {
            uint i = word * 32u + uint(firstbitlow(mask));
            mask &= mask - 1u;
            Decal d = decals[i];
            if (any(p < d.rect.xy) || any(p >= d.rect.zw)) continue;
            float3 local = transform_point(d.to_box, surface.position);
            if (!all(abs(local) <= 0.5)) continue;
            float2 uv = local.xz + 0.5;
            float4 color = decal_color(d, uv, footprint, receiver);
            if (!(color.a > 0.0)) continue;
            changed = true;
            albedo.rgb = lerp(albedo.rgb, color.rgb, color.a);
            emission.rgb = lerp(emission.rgb, render_units(d.emission.rgb), color.a);
            if (d.metallic >= 0.0) albedo.a = lerp(albedo.a, d.metallic, color.a);
            if (material_has(d.normal_map)) {
                float3 mapped = decal_normal(d, uv, footprint, receiver);
                float3 blended = lerp(normal, fragment_facing(mapped, -surface.view), color.a);
                normal = dot(blended, blended) > 1e-8 ? normalize(blended) : receiver;
            }
            if (d.roughness >= 0.0) {
                normal_texel.z = lerp(normal_texel.z, d.roughness, color.a);
            }
        }
    }
    scratch[uint3(p, 1)] = changed ? gbuffer_normal_pack(normal, normal_texel.z, bits)
                                  : float4(0.0, 0.0, 0.0, -1.0);
    if (!changed) return;
    scratch[uint3(p, 0)] = albedo;
    scratch[uint3(p, 2)] = emission;
    if ((frame.flags & FRAME_FLAG_REFLECTANCE) != 0u)
        scratch[uint3(p, 3)] = decal_reflectance(p, original, albedo);
}
