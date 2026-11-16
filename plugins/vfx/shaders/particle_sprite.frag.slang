#include "native.slang"
//! per surface program
// The color of a sprite, and of a mesh particle whose material blends
// (particle_mesh_blend.vert): its material, the color of the particle and the
// light it receives, faded where it meets the scene behind it or the camera.
// A material with a Surface program runs it at the point, facing the camera,
// with uv0 in this frame of the flipbook, uv1 in the next, the color of the
// particle as vertex_color, which it uses as it will, and what the particle
// gives it (Mirai_Surface_Context.particle_data); another shows its base
// color texture as the flipbook, blended between two frames, tinted by the
// color of the particle.
// Radiance is premultiplied: additive emitters add it, the others cover what
// is behind by alpha. The second target is the share of the pixel covered.
// An additive emitter adds the light of its material whatever its opacity,
// and an unlit one shows the emission of its material in its own units
// (Particle_Info.emission_mode), as it shows its color. The media of the view
// between it and the eye take what it sends and add what they scatter over
// what it covers, as over the opaque scene behind.
#define MATERIAL_RASTER
#define MIRAI_NO_INSTANCES
#include "particles.slang"
#include "depth.slang"
#include "media_grid.slang"

struct Params_Block { uint emitter; uint pass; uint pad0; uint pad1; Media_Grid media; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] Texture2D<float4> glass_depth : register(MIRAI_REGISTER(t, SLOT_PASS8), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture3D<float4> media : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);

struct Stage_Input {
    [[vk::location(0)]] float4 in_color : TEXCOORD0;
    [[vk::location(1)]] float3 in_light : TEXCOORD1;
    [[vk::location(2)]] float4 in_uv : TEXCOORD2;
    [[vk::location(3)]] float2 in_blend_depth : TEXCOORD3;
    [[vk::location(4)]] nointerpolation float in_seed : TEXCOORD4;
    [[vk::location(5)]] float3 in_world : TEXCOORD5;
    [[vk::location(6)]] nointerpolation float4 in_data0 : TEXCOORD6;
    [[vk::location(7)]] nointerpolation float4 in_data1 : TEXCOORD7;
    [[vk::location(8)]] nointerpolation float4 in_data2 : TEXCOORD8;
    [[vk::location(9)]] nointerpolation float4 in_data3 : TEXCOORD9;
    [[vk::location(10)]] nointerpolation uint in_given : TEXCOORD10;
    [[vk::location(11)]] nointerpolation float2 in_random_radius : TEXCOORD11;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
    [[vk::location(1)]] float4 out_coverage : SV_Target1;
};

Mirai_Surface_Context sprite_context(Stage_Input input, float3 facing, float scene) {
    Mirai_Surface_Context ctx = material_context(input.in_world, facing, input.in_uv.xy, input.in_uv.zw, float2(frame.texturing.x), false);
    ctx.position_dx = ddx(input.in_world); ctx.position_dy = ddy(input.in_world);
    ctx.vertex_color = input.in_color;
    if (!depth_empty(scene)) ctx.scene_depth = depth_distance(scene);
    ctx.particle_data[0] = input.in_data0; ctx.particle_data[1] = input.in_data1;
    ctx.particle_data[2] = input.in_data2; ctx.particle_data[3] = input.in_data3;
    ctx.particle_given = input.in_given;
    ctx.particle_random = input.in_random_radius.x; ctx.particle_radius = input.in_random_radius.y;
    return ctx;
}

[shader("fragment")]
Stage_Output main(Stage_Input input, float4 pixel_position : SV_Position) {
    Stage_Output output;
    Particle_Emitter e = particle_emitters[params.emitter];
    int2 pixel = int2(pixel_position.xy);
    float depth = input.in_blend_depth.y;
    if (params.pass != 0u) {
        float layer = glass_depth.Load(int3(pixel, 0)).r;
        bool in_front = layer > 0.0 && depth <= layer * 1.0001 + 1e-4;
        if (in_front != (params.pass == PARTICLE_PASS_FRONT_OF_GLASS)) discard;
    }
    Material m = material_row(e.mesh.w);
    bool additive = (e.range.w & PARTICLE_FLAG_ADDITIVE) != 0u;
    bool lit = (e.range.w & PARTICLE_FLAG_LIT) != 0u;
    float scene = g_depth.Load(int3(pixel, 0)).r;
    float3 base_color, emission;
    float alpha;
    float4 tint = input.in_color;
    Material_Sample values;
    float3 facing = to_eye(input.in_world);
    if (m.program_id != 0u && material_program(m, sprite_context(input, facing, scene), float3(1.0), float3(0.0), values, facing)) {
        base_color = (values.layers.bits & MATERIAL_LAYER_UNLIT) != 0u ? float3(0.0) : values.base_color;
        emission = values.emission;
        alpha = values.alpha;
        tint = float4(1.0);
    } else {
        // Without a texture a sprite is a puff, a ribbon fades to its edges and a mesh is whole.
        float2 tile = frac(input.in_uv.xy * float2(e.flipbook.xy)) * 2.0 - 1.0;
        float4 texel = float4(1.0, 1.0, 1.0, e.kinds.y == PARTICLE_RENDER_RIBBON ? 1.0 - abs(tile.x) : e.kinds.y == PARTICLE_RENDER_MESH ? 1.0 : particle_puff(tile, input.in_seed));
        if (material_has(m.textures[MATERIAL_MAP_BASE_COLOR]) && e.kinds.y == PARTICLE_RENDER_MESH) {
            // A mesh reads its texture through the map of its material, at the uv of its vertices.
            texel = material_texel(m.textures[MATERIAL_MAP_BASE_COLOR], material_map_uv(m, MATERIAL_MAP_BASE_COLOR, input.in_uv.xy, input.in_uv.zw), frame.texturing.x);
        } else if (material_has(m.textures[MATERIAL_MAP_BASE_COLOR])) {
            texel = lerp(material_texel(m.textures[MATERIAL_MAP_BASE_COLOR], input.in_uv.xy, frame.texturing.x), material_texel(m.textures[MATERIAL_MAP_BASE_COLOR], input.in_uv.zw, frame.texturing.x), input.in_blend_depth.x);
        }
        base_color = m.base_color * texel.rgb;
        emission = m.emission * texel.rgb;
        alpha = (additive ? 1.0 : m.opacity) * texel.a;
    }
    float3 surface = base_color * tint.rgb;
    alpha = saturate(alpha * tint.a);
    float soft = e.look.y;
    if (soft > 0.0) {
        if (!depth_empty(scene)) alpha *= saturate((depth_distance(scene) - depth) / soft);
        alpha *= saturate((depth - frame.camera_position.w) / soft);
    }
    if (alpha <= 1e-4) discard;
    bool relative = lit ? m.emission_mode == EMISSION_RELATIVE : (e.range.w & PARTICLE_FLAG_RELATIVE) != 0u;
    float3 radiance = finite_or_zero(surface * input.in_light + emission_render_units(emission * tint.rgb, relative));
    float4 medium = media_over(media, params.media, input.in_world);
    radiance = radiance * medium.a + (additive ? float3(0.0) : medium.rgb);
    output.out_color = float4(radiance * alpha, additive ? 0.0 : alpha);
    output.out_coverage = float4(additive ? saturate(alpha * luminance(radiance)) : alpha, 0.0, 0.0, 0.0);
    return output;
}
