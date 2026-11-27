#include "native.slang"
//! per surface program particle_sprite
// The color of a sprite, and of a mesh particle whose material blends
// (particle_mesh_blend.vert): its material, the color of the particle and the
// light it receives, faded where it meets the scene behind it or the camera.
// A material with a Surface program runs it at the point, facing the camera,
// with uv0 in this frame of the flipbook, uv1 in the next, the color of the
// particle (particle_color), which it uses as it will, the share of its life
// it lived, the color of the mesh of a Mesh particle (vertex_color) and what
// the particle gives it (Mirai_Surface_Context.particle_data); another shows
// its base color texture as the flipbook, blended between two frames, tinted
// by the color of the particle and, as its material says, by that of its mesh.
// Radiance is premultiplied: additive emitters, and mesh particles of an
// additive material, add it; the others cover what is behind by alpha. A
// multiplying emitter darkens what is behind by its color instead, unlit. The
// second target is the share of the pixel covered.
// An additive emitter adds the light of its material whatever its opacity (an
// additive material, by its opacity). An unlit one shows the emission of its
// material, or of its Surface program, in its own units
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
    [[vk::location(1)]] float4 in_light : TEXCOORD1;
    [[vk::location(2)]] float4 in_uv : TEXCOORD2;
    [[vk::location(3)]] float3 in_blend_depth_life : TEXCOORD3;
    [[vk::location(4)]] nointerpolation float in_seed : TEXCOORD4;
    [[vk::location(5)]] float3 in_world : TEXCOORD5;
    [[vk::location(6)]] nointerpolation float4 in_data0 : TEXCOORD6;
    [[vk::location(7)]] nointerpolation float4 in_data1 : TEXCOORD7;
    [[vk::location(8)]] nointerpolation float4 in_data2 : TEXCOORD8;
    [[vk::location(9)]] nointerpolation float4 in_data3 : TEXCOORD9;
    [[vk::location(10)]] nointerpolation uint in_given : TEXCOORD10;
    [[vk::location(12)]] nointerpolation uint material : TEXCOORD12;
    [[vk::location(11)]] nointerpolation float2 in_random_radius : TEXCOORD11;
    [[vk::location(13)]] float3 in_normal : TEXCOORD13;
    [[vk::location(14)]] float4 in_vertex_color : TEXCOORD14;
    [[vk::location(15)]] nointerpolation float in_share : TEXCOORD15; // of what is drawn, what the particle covers (particle_sprite.vert)
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
    [[vk::location(1)]] float4 out_coverage : SV_Target1;
};

Mirai_Surface_Context sprite_context(Stage_Input input, float3 facing, float scene) {
    Mirai_Surface_Context ctx = material_context(input.in_world, facing, input.in_uv.xy, input.in_uv.zw, float2(frame.texturing.x), false);
    ctx.position_dx = ddx(input.in_world); ctx.position_dy = ddy(input.in_world);
    ctx.vertex_color = input.in_vertex_color;
    ctx.particle_color = input.in_color;
    if (!depth_empty(scene)) ctx.scene_depth = depth_distance(scene);
    ctx.particle_data[0] = input.in_data0; ctx.particle_data[1] = input.in_data1;
    ctx.particle_data[2] = input.in_data2; ctx.particle_data[3] = input.in_data3;
    ctx.particle_given = input.in_given;
    ctx.particle_random = input.in_random_radius.x; ctx.particle_radius = input.in_random_radius.y; ctx.particle_life = input.in_blend_depth_life.z;
    return ctx;
}

[shader("fragment")]
Stage_Output main(Stage_Input input, float4 pixel_position : SV_Position) {
    Stage_Output output;

    int2 pixel = int2(pixel_position.xy);
    float depth = input.in_blend_depth_life.y;
    if (params.pass != 0u) {
        float layer = glass_depth.Load(int3(pixel, 0)).r;
        bool in_front = layer > 0.0 && depth <= layer * 1.0001 + 1e-4;
        if (in_front != (params.pass == PARTICLE_PASS_FRONT_OF_GLASS)) discard;
    }
    Material m = material_row(input.material);
    uint kind = particle_emitters[params.emitter].kinds.y;
    bool mesh = kind == PARTICLE_RENDER_MESH;
    uint flags = particle_emitters[params.emitter].range.w;
    // A mesh blends as the alpha mode of its material says.
    bool additive = mesh ? m.alpha_mode == ALPHA_ADDITIVE : (flags & PARTICLE_FLAG_ADDITIVE) != 0u;
    bool multiply = !mesh && (flags & FLAG_MULTIPLY) != 0u;
    float scene = g_depth.Load(int3(pixel, 0)).r;
    float3 base_color, emission;
    float alpha, metallic = m.metallic, roughness = m.roughness;
    // The color of a mesh tints it as it tints the mesh in the G-buffer.
    float4 tint = input.in_color * float4(material_vertex_tint(m, input.in_vertex_color.rgb), 1.0);
    Material_Sample values;
    // A quad faces the eye; a mesh its normal, turned toward the eye.
    float3 facing = to_eye(input.in_world);
    if (mesh) {
        float3 n = particle_unit(input.in_normal, facing);
        facing = dot(n, facing) < 0.0 ? -n : n;
    }
    if (m.program_id != 0u && material_program(m, sprite_context(input, facing, scene), float3(1.0), float3(0.0), values, facing)) {
        base_color = (values.layers.bits & MATERIAL_LAYER_UNLIT) != 0u ? float3(0.0) : values.base_color;
        emission = values.emission;
        alpha = values.alpha;
        metallic = values.metallic;
        roughness = values.roughness;
        tint = float4(1.0);
    } else {
        // Without a texture a sprite is a puff, a ribbon fades to its edges and a mesh is whole.
        float2 tile = frac(input.in_uv.xy * float2(particle_emitters[params.emitter].flipbook.xy)) * 2.0 - 1.0;
        bool band = kind == PARTICLE_RENDER_RIBBON || kind == PARTICLE_RENDER_BEAM;
        float4 texel = float4(1.0, 1.0, 1.0, band ? 1.0 - abs(tile.x) : mesh ? 1.0 : particle_puff(tile, input.in_seed));
        if (material_has(m.textures[MATERIAL_MAP_BASE_COLOR]) && mesh) {
            // A mesh reads its texture through the map of its material, at the uv of its vertices.
            texel = material_texel(m.textures[MATERIAL_MAP_BASE_COLOR], material_map_uv(m, MATERIAL_MAP_BASE_COLOR, input.in_uv.xy, input.in_uv.zw), frame.texturing.x);
        } else if (material_has(m.textures[MATERIAL_MAP_BASE_COLOR])) {
            texel = lerp(material_texel(m.textures[MATERIAL_MAP_BASE_COLOR], input.in_uv.xy, frame.texturing.x), material_texel(m.textures[MATERIAL_MAP_BASE_COLOR], input.in_uv.zw, frame.texturing.x), input.in_blend_depth_life.x);
        }
        base_color = m.base_color * texel.rgb;
        emission = m.emission * texel.rgb;
        alpha = (additive && !mesh ? 1.0 : m.opacity) * texel.a;
    }
    float3 surface = base_color * tint.rgb;
    alpha = saturate(alpha * tint.a);
    float soft = particle_emitters[params.emitter].look.y;
    if (soft > 0.0) {
        if (!depth_empty(scene)) alpha *= saturate((depth_distance(scene) - depth) / soft);
        alpha *= saturate((depth - frame.camera_position.w) / soft);
    }
    alpha *= input.in_share;
    if (alpha <= 1e-4) discard;
    if (multiply) {
        // What is behind times its color, by how much of the pixel it covers.
        output.out_color = float4(lerp(float3(1.0), saturate(surface), alpha), 1.0);
        output.out_coverage = float4(alpha, 0.0, 0.0, 0.0);
        return output;
    }
    // An unlit particle shows its emission in the units of its emitter, as it
    // shows its color (particle_sprite.vert); a lit one, in those of its material.
    bool relative = (flags & PARTICLE_FLAG_LIT) != 0u ? m.emission_mode == EMISSION_RELATIVE : (flags & PARTICLE_FLAG_RELATIVE) != 0u;
    float3 radiance = surface * input.in_light.rgb + emission_render_units(emission * tint.rgb, relative);
    // A lit mesh shades the sun by its normal and its material, as the scene shades it.
    if (input.in_light.w > 0.0) {
        radiance += sun_radiance(shading_surface(input.in_world, facing, to_eye(input.in_world), surface, metallic, roughness), input.in_light.w);
    }
    radiance = finite_or_zero(radiance);
    float4 medium = media_over(media, params.media, input.in_world);
    radiance = radiance * medium.a + (additive ? float3(0.0) : medium.rgb);
    output.out_color = float4(radiance * alpha, additive ? 0.0 : alpha);
    output.out_coverage = float4(additive ? saturate(alpha * luminance(radiance)) : alpha, 0.0, 0.0, 0.0);
    return output;
}
