// What the decals of a view (decal.frag, and the Decal stage of extensions)
// left at a pixel, which the resolve applies to its surface before it packs
// the G-buffer (vis_resolve.frag, with the constant decals). Each target is
// premultiplied, its coverage in alpha: the base color and the surface values
// (roughness, metallic, occlusion) and the emission go to what the decals
// give by their coverage; the shading normal is flattened to the smooth
// normal of the surface by the coverage of the normals of the decals, and
// turned by the differences their shading normals have from their smooth ones.
#ifndef MIRAI_DECAL_BUFFER_SLANG
#define MIRAI_DECAL_BUFFER_SLANG
#include "raster.slang"

[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> decal_color : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
[[vk::binding(SLOT_PASS6, 0)]] Texture2D<float4> decal_normal : register(MIRAI_REGISTER(t, SLOT_PASS6), space0);
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> decal_surface : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] Texture2D<float4> decal_emission : register(MIRAI_REGISTER(t, SLOT_PASS8), space0);

// smooth: the normal of the surface without its normal map, facing the viewer.
void decal_apply(inout Fragment f, int2 pixel, float3 smooth) {
    int3 p = int3(pixel, 0);
    float4 color = decal_color.Load(p), normal = decal_normal.Load(p), surface = decal_surface.Load(p), emission = decal_emission.Load(p);
    if (color.a > 0.0) f.values.base_color = f.values.base_color * (1.0 - color.a) + color.rgb;
    if (surface.a > 0.0) {
        f.material_roughness = clamp(f.material_roughness * (1.0 - surface.a) + surface.r, MIN_ROUGHNESS, 1.0);
        f.values.metallic = saturate(f.values.metallic * (1.0 - surface.a) + surface.g);
        f.values.occlusion = saturate(f.values.occlusion * (1.0 - surface.a) + surface.b);
    }
    if (color.a > 0.0 || surface.a > 0.0) material_specular(f.values, f.material.specular_color, f.material.ior, f.material.specular_factor);
    if (normal.a > 0.0) {
        float3 turned = lerp(f.normal, smooth, normal.a) + normal.xyz;
        f.normal = dot(turned, turned) > 1e-12 ? fragment_facing(normalize(turned), f.to_camera) : smooth;
    }
    if (normal.a > 0.0 || surface.a > 0.0) f.values.roughness = specular_antialiasing(f.normal, f.material_roughness);
    if (emission.a > 0.0) f.values.emission = f.values.emission * (1.0 - emission.a) + emission.rgb;
}
#endif
