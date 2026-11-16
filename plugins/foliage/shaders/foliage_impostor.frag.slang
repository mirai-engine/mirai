// The surface of a far instance of foliage, from the frames of its type, into
// the G-buffer as gbuffer.frag writes the scene: base color, normal and
// depth where its leaves are, so that it is lit and shadowed as its mesh is.
//! variant plain MIRAI_GBUFFER_PLAIN=1
//! variant layers MIRAI_GBUFFER_LAYERS=1
#include "foliage_impostor.slang"
#include "gbuffer.slang"

struct Stage_Output {
    [[vk::location(0)]] float4 g_albedo : SV_Target0;
    [[vk::location(1)]] float4 g_normal : SV_Target1;
    [[vk::location(2)]] float4 g_emission : SV_Target2;
    [[vk::location(3)]] float4 g_motion : SV_Target3;
    [[vk::location(4)]] float g_depth : SV_Target4;
#ifndef MIRAI_GBUFFER_PLAIN
    [[vk::location(5)]] float4 g_specular : SV_Target5;
#endif
#ifdef MIRAI_GBUFFER_LAYERS
    [[vk::location(6)]] uint4 g_layers : SV_Target6;
#endif
#ifdef MIRAI_INSTANCE_IDS
    // No instance of the scene drew it: 0, as a surface of the Gbuffer stage.
#if defined(MIRAI_GBUFFER_LAYERS)
    [[vk::location(7)]] uint g_instance : SV_Target7;
#elif defined(MIRAI_GBUFFER_PLAIN)
    [[vk::location(5)]] uint g_instance : SV_Target5;
#else
    [[vk::location(6)]] uint g_instance : SV_Target6;
#endif
#endif
    float depth : SV_Depth;
};

[shader("fragment")]
Stage_Output main(Impostor_Varyings input, float4 pixel_position : SV_Position) {
    // A pixel the fading mesh still covers is not drawn, and the reverse: the
    // two make the instance whole. Far away it fades out as the batches do.
    uint2 pixel = uint2(pixel_position.xy);
    if (!fade_pixel_left(pixel, input.fades.x) || fade_pixel_left(pixel, input.fades.y)) discard;
    Impostor_Row row = impostor_rows[input.frames.w];
    float3 origin = input.local;
    float3 dir = input.eye.w > 0.5 ? normalize(input.local - input.eye.xyz) : input.eye.xyz;
    float radius = row.sphere.w;
    float3 center = row.sphere.xyz;
    uint n = max(row.frames.w & 0xffffu, 2u);
    float lod = input.weights.w;
    float covered = 0.0;
    float3 color = float3(0.0);
    float3 normal = float3(0.0);
    float3 surface = float3(0.0);
    float4 terms = float4(0.0); // roughness, metallic, occlusion, diffuse transmission
    for (uint k = 0u; k < 3u; k++) {
        float weight = input.weights[k];
        if (weight <= 0.0) continue;
        uint2 at = uint2(input.frames[k] & 0xffffu, input.frames[k] >> 16u);
        float3 d = impostor_direction(n, at);
        float facing = dot(dir, d);
        if (facing > -1e-4) continue;
        float3 right, up;
        impostor_axes(d, right, up);
        // The ray meets the plane of the frame through the centre, then the
        // plane of the leaves the frame keeps there: depth 0.5 is the centre.
        float to_center = dot(center - origin, d);
        float3 p = origin + dir * (to_center / facing);
        float2 uv = float2(dot(p - center, right), -dot(p - center, up)) / (2.0 * radius) + 0.5;
        float2 atlas = (float2(at) + saturate(uv)) / float(n);
        float depth = material_textures[mirai_nonuniform(row.frames.y)].SampleLevel(material_sampler, atlas, lod).a;
        p = origin + dir * (((0.5 - depth) * 2.0 * radius + to_center) / facing);
        uv = float2(dot(p - center, right), -dot(p - center, up)) / (2.0 * radius) + 0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) continue;
        atlas = (float2(at) + uv) / float(n);
        float4 albedo = material_textures[mirai_nonuniform(row.frames.x)].SampleLevel(material_sampler, atlas, lod);
        float4 shape = material_textures[mirai_nonuniform(row.frames.y)].SampleLevel(material_sampler, atlas, lod);
        float4 material = material_textures[mirai_nonuniform(row.frames.z)].SampleLevel(material_sampler, atlas, lod);
        float share = weight * albedo.a;
        covered += share;
        color += albedo.rgb * share;
        normal += (shape.rgb * 2.0 - 1.0) * share;
        surface += p * share;
        terms += material * share;
    }
    if (covered < 0.5) discard;
    color /= covered;
    surface /= covered;
    terms /= covered;
    float roughness = terms.x;
    float metallic = terms.y;
    // What the instance shows of its own, as an instance of a batch does.
    uint own = input.color;
    color *= float3(float(own & 255u), float((own >> 8u) & 255u), float((own >> 16u) & 255u)) / 255.0;
    surface_wet(color, roughness, metallic, float(own >> 24u) / 255.0);
    float4 world[3] = {input.world0, input.world1, input.world2};
    float3 place = transform_point(world, surface);
    // Normals go by the inverse transpose: the axes divided by their squared scales.
    float3 axis_x = float3(world[0].x, world[1].x, world[2].x);
    float3 axis_y = float3(world[0].y, world[1].y, world[2].y);
    float3 axis_z = float3(world[0].z, world[1].z, world[2].z);
    float3 turned = axis_x * (normal.x / max(dot(axis_x, axis_x), 1e-12)) + axis_y * (normal.y / max(dot(axis_y, axis_y), 1e-12)) + axis_z * (normal.z / max(dot(axis_z, axis_z), 1e-12));
    turned = dot(turned, turned) > 1e-12 ? normalize(turned) : to_eye(place);
    Stage_Output output;
    uint bits = 0u;
#ifdef MIRAI_GBUFFER_LAYERS
    // The light its leaves let through, in the color its materials give it.
    Material_Layers layers = material_layers_none();
    if (terms.w > 0.0) {
        layers.bits = MATERIAL_LAYER_DIFFUSE_TRANSMISSION;
        layers.diffuse_transmission = terms.w;
        layers.diffuse_transmission_color = row.transmission.rgb;
    }
    bits = layers.bits;
    output.g_layers = gbuffer_layers_pack(layers);
#endif
    output.g_albedo = float4(saturate(color), metallic);
    output.g_normal = gbuffer_normal_pack(turned, roughness, bits);
    output.g_emission = float4(0.0, 0.0, 0.0, terms.z);
    float4 current = view_clip_unjittered(place);
    float4 previous = view_clip_previous(place);
    output.g_motion = float4((previous.xy / previous.w - current.xy / current.w) * float2(0.5, -0.5), roughness, 1.0);
    output.g_depth = dot(place - frame.camera_position.xyz, frame.camera_forward.xyz);
#ifndef MIRAI_GBUFFER_PLAIN
    output.g_specular = specular_pack(lerp(float3(0.04, 0.04, 0.04), saturate(color), metallic), 1.0);
#endif
#ifdef MIRAI_INSTANCE_IDS
    output.g_instance = 0u;
#endif
    float4 clip = view_clip(place);
    output.depth = clip.z / clip.w;
    return output;
}
