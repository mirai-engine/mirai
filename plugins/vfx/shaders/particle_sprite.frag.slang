#include "native.slang"
//! per surface program particle_sprite
// The color of a sprite, and of a mesh particle whose material blends
// (particle_mesh_blend.vert): its material, the color of the particle and the
// light it receives, faded where it meets the scene behind it or the camera.
// A material with a Surface program runs it at the point, by the normal of
// what it draws turned toward the camera,
// with uv0 in this frame of the flipbook, uv1 in the next, the color of the
// particle (particle_color), which it uses as it will, the share of its life
// it lived, the color of the mesh of a Mesh particle (vertex_color) and what
// the particle gives it (Mirai_Surface_Context.particle_data); another shows
// its base color texture as the flipbook, blended between two frames moved
// along the flipbook_motion of its effect, tinted by the color of the particle
// and, as its material says, by that of its mesh.
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
// A lit one shaded where it is drawn (particle_shaded) takes the sun by the
// normal of its fragment, mapped by its material or given by its program,
// and by the layers of its material: through one with diffuse transmission
// the sun behind it shines (backlit smoke); a stylized one takes the light
// around it by its shade.
#define MATERIAL_RASTER
#define MIRAI_NO_INSTANCES
#include "particle_fragment.slang"
#include "media_grid.slang"

struct Params_Block { uint emitter; uint pass; uint pad0; uint pad1; Media_Grid media; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture3D<float4> media : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);

struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
    [[vk::location(1)]] float4 out_coverage : SV_Target1;
};

Mirai_Surface_Context sprite_context(Particle_Varyings input, float4 uv, float3 normal, float scene) {
    Mirai_Surface_Context ctx = material_context(input.world, normal, normal, input.tangent, uv.xy, uv.zw, float2(frame.texturing.x), false);
    ctx.position_dx = ddx(input.world); ctx.position_dy = ddy(input.world);
    ctx.vertex_color = input.vertex_color;
    ctx.particle_color = input.color;
    if (!depth_empty(scene)) ctx.scene_depth = depth_distance(scene);
    ctx.particle_data[0] = input.data0; ctx.particle_data[1] = input.data1;
    ctx.particle_data[2] = input.data2; ctx.particle_data[3] = input.data3;
    ctx.particle_given = input.given_material.x;
    ctx.particle_random = input.particle.y; ctx.particle_radius = input.particle.z; ctx.particle_life = input.blend_depth_life.z;
    ctx.particle_frame = input.blend_depth_life.x;
    return ctx;
}

[shader("fragment")]
Stage_Output main(Particle_Varyings input) {
    Stage_Output output;

    int2 pixel = int2(input.position.xy);
    float depth = input.blend_depth_life.y;
    if (!particle_glass_side(params.pass, pixel, depth)) discard;
    Material m = material_row(input.given_material.y);
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
    float4 tint = input.color * float4(material_vertex_tint(m, input.vertex_color.rgb), 1.0);
    Material_Sample values;
    float3 eye = to_eye(input.world);
    float3 facing = particle_facing(input.normal, eye);
    float3 normal = facing;
    // The frames of a flipbook move along its motion before anything reads
    // them, filtered by the uv before the move.
    float t = input.blend_depth_life.x;
    float2 dx = ddx(input.uv.xy), dy = ddy(input.uv.xy);
    float4 uv = mesh ? input.uv : particle_flipbook_moved(params.emitter, input.uv, t, dx, dy);
    Material_Layers layers = material_layers_none();
    bool program = m.program_id != 0u && material_program(m, sprite_context(input, uv, facing, scene), float3(1.0), float3(0.0), values, normal);
    if (program) {
        base_color = (values.layers.bits & MATERIAL_LAYER_UNLIT) != 0u ? float3(0.0) : values.base_color;
        emission = values.emission;
        alpha = values.alpha;
        metallic = values.metallic;
        roughness = values.roughness;
        layers = values.layers;
        tint = float4(1.0);
    } else {
        // Without a texture a sprite is a puff, a ribbon fades to its edges and a mesh is whole.
        float2 tile = frac(uv.xy * float2(particle_emitters[params.emitter].flipbook.xy)) * 2.0 - 1.0;
        bool band = kind == PARTICLE_RENDER_RIBBON || kind == PARTICLE_RENDER_BEAM;
        float4 texel = float4(1.0, 1.0, 1.0, band ? 1.0 - abs(tile.x) : mesh ? 1.0 : particle_puff(tile, input.particle.x));
        if (material_has(m.textures[MATERIAL_MAP_BASE_COLOR]) && mesh) {
            // A mesh reads its texture through the map of its material, at the uv of its vertices.
            texel = material_texel(m.textures[MATERIAL_MAP_BASE_COLOR], material_map_uv(m, MATERIAL_MAP_BASE_COLOR, uv.xy, uv.zw), frame.texturing.x);
        } else if (material_has(m.textures[MATERIAL_MAP_BASE_COLOR])) {
            texel = lerp(particle_flipbook_texel(m.textures[MATERIAL_MAP_BASE_COLOR], uv.xy, dx, dy), particle_flipbook_texel(m.textures[MATERIAL_MAP_BASE_COLOR], uv.zw, dx, dy), t);
        }
        if (material_has(m.textures[MATERIAL_MAP_NORMAL])) {
            float3 bent = mesh ? material_map_normal(m, uv.xy, uv.zw, float2(frame.texturing.x), false) : particle_flipbook_normal(m, uv, t, dx, dy);
            normal = tangent_frame_normal(facing, input.tangent, bent);
        }
        base_color = m.base_color * texel.rgb;
        emission = m.emission * texel.rgb;
        alpha = (additive && !mesh ? 1.0 : m.opacity) * texel.a;
    }
    float3 surface = base_color * tint.rgb;
    alpha = saturate(alpha * tint.a) * particle_soft(params.emitter, scene, depth) * input.particle.w;
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
    float3 radiance = emission_render_units(emission * tint.rgb, relative);
    float3 around = input.light.rgb;
    // Shaded where it is drawn: the sun by its normal and the layers of its
    // material, as the scene shades it, and through it from behind. A
    // stylized one takes the light around it by its shade, as a stylized
    // surface does, whether the sun reaches it or not.
    if ((flags & PARTICLE_FLAG_LIT) != 0u && particle_shaded(params.emitter)) {
        if (!program) layers = material_layers(m, sprite_context(input, uv, normal, scene));
        Shading s = shading_surface(input.world, normal, eye, surface, metallic, roughness);
        shading_layers(s, layers, metallic);
        if ((layers.bits & MATERIAL_LAYER_STYLIZED) != 0u) around *= s.shade;
        if (input.light.w > 0.0) {
            radiance += sun_radiance(s, input.light.w);
            if (shading_transmits(s)) radiance += sun_radiance(shading_back(s), input.light.w);
        }
    }
    radiance += surface * around;
    radiance = finite_or_zero(radiance);
    float4 medium = media_over(media, params.media, input.world);
    radiance = radiance * medium.a + (additive ? float3(0.0) : medium.rgb);
    output.out_color = float4(radiance * alpha, additive ? 0.0 : alpha);
    output.out_coverage = float4(additive ? saturate(alpha * luminance(radiance)) : alpha, 0.0, 0.0, 0.0);
    return output;
}
