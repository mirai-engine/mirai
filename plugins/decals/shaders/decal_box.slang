// What the stages of the decals share.
#ifndef DECAL_BOX_SLANG
#define DECAL_BOX_SLANG
#include "scene.slang"

// decals.Gpu_Decal.
struct Decal {
    float4 to_box[3];   // rows: the world to the box of the decal, whose sides are 1
    float4 to_world[3]; // rows: that box to the world
    float4 color;       // rgb multiplies the image, a is the opacity
    float4 emission;    // rgb: emission, nits; a: the facing below which it fades (0: it never does)
    uint texture;       // of the texture table; INVALID: the plain color
    uint normal_map;
    float density;      // texels of the image in a metre of the box
    float normal_density;
    float roughness;
    float metallic;
    uint writes;        // DECAL_WRITE_*
    uint pad;
};
[[vk::binding(SLOT_PASS0, 0)]]
StructuredBuffer<Decal> decals : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

float4 decal_sample(uint texture, float2 uv, float footprint, float density) {
    // Derivatives of a position found from depth break at every edge.
    float level = log2(max(footprint * density, 1.0));
    return material_textures[mirai_nonuniform(texture)].SampleLevel(material_sampler, uv, level);
}

float4 decal_color(Decal d, float2 uv, float footprint, float3 normal) {
    float4 color = d.color;
    if (material_has(d.texture)) color *= decal_sample(d.texture, uv, footprint, d.density);
    float3 axis = normalize(transform_vector(d.to_world, float3(0.0, 1.0, 0.0)));
    float facing = abs(dot(normal, axis));
    float fade = d.emission.a > 0.0 ? smoothstep(0.0, d.emission.a, facing) : 1.0;
    color.a = saturate(color.a) * fade;
    return float4(saturate(color.rgb), color.a);
}

#endif
