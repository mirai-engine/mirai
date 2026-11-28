#include "native.slang"
// How far a sprite, a ribbon or a beam of a Distort emitter shifts what is
// behind it, added into the distortion target of the view
// (render.pass_distortion_begin) in uv, x right and y down, with its depth by
// how much of the pixel it covers and that share: along the slope of
// the normal map of its material, or without one of its puff (across a ribbon
// or a beam, out from its middle), Particle_Info.distortion metres at the
// particle by how much of the pixel it covers. Metres at the particle keep the
// shift the same size in the world whatever its distance, so it does not
// shimmer as the view moves or jitters.
#define MATERIAL_RASTER
#define MIRAI_NO_INSTANCES
#include "particle_fragment.slang"

struct Params_Block { uint emitter; uint pass; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

struct Stage_Output {
    [[vk::location(0)]] float4 out_offset : SV_Target0;
};

// The step across the puff its slope is measured over, in halves of its tile.
#define DISTORT_SLOPE_STEP 0.05

[shader("fragment")]
Stage_Output main(Particle_Varyings input) {
    Stage_Output output;
    int2 pixel = int2(input.position.xy);
    float depth = input.blend_depth_life.y;
    if (!particle_glass_side(params.pass, pixel, depth)) discard;
    Material m = material_row(input.given_material.y);
    uint kind = particle_emitters[params.emitter].kinds.y;
    bool band = kind == PARTICLE_RENDER_RIBBON || kind == PARTICLE_RENDER_BEAM;
    float t = input.blend_depth_life.x;
    float2 dx = ddx(input.uv.xy), dy = ddy(input.uv.xy);
    float4 uv = particle_flipbook_moved(params.emitter, input.uv, t, dx, dy);
    float2 tile = frac(uv.xy * float2(particle_emitters[params.emitter].flipbook.xy)) * 2.0 - 1.0;
    // How much of the pixel it covers, as its sprite would.
    float alpha = band ? 1.0 - abs(tile.x) : particle_puff(tile, input.particle.x);
    if (material_has(m.textures[MATERIAL_MAP_BASE_COLOR])) {
        alpha = lerp(particle_flipbook_texel(m.textures[MATERIAL_MAP_BASE_COLOR], uv.xy, dx, dy).a, particle_flipbook_texel(m.textures[MATERIAL_MAP_BASE_COLOR], uv.zw, dx, dy).a, t);
    }
    alpha = saturate(alpha * input.color.a) * particle_soft(params.emitter, g_depth.Load(int3(pixel, 0)).r, depth) * input.particle.w;
    if (alpha <= 1e-4) discard;
    // The slope in the tangent space of what it draws: x along u, y up its texture.
    float2 slope;
    if (material_has(m.textures[MATERIAL_MAP_NORMAL])) {
        slope = particle_flipbook_normal(m, uv, t, dx, dy).xy;
    } else if (band) {
        slope = float2(sign(tile.x), 0.0);
    } else {
        // Down the puff, which is high in its middle; tile goes down its texture.
        float2 e = float2(DISTORT_SLOPE_STEP, 0.0);
        float2 rise = float2(particle_puff(tile + e.xy, input.particle.x) - particle_puff(tile - e.xy, input.particle.x),
                             particle_puff(tile + e.yx, input.particle.x) - particle_puff(tile - e.yx, input.particle.x)) / (2.0 * DISTORT_SLOPE_STEP);
        slope = float2(-rise.x, rise.y) * 0.5;
    }
    if (dot(slope, slope) > 1.0) slope = normalize(slope);
    float3 normal = particle_unit(input.normal, to_eye(input.world));
    float3 bitangent = input.tangent.w * cross(normal, input.tangent.xyz);
    float3 shift = (slope.x * input.tangent.xyz + slope.y * bitangent) * (particle_emitters[params.emitter].collide.w * alpha);
    // Metres at the view depth of the fragment to uv of the view.
    float z = max(depth, frame.camera_position.w);
    float2 offset = 0.5 * float2(abs(frame.proj[0][0]) * dot(shift, frame.view[0].xyz), -abs(frame.proj[1][1]) * dot(shift, frame.view[1].xyz)) / max(z, 1e-4);
    if (any(isnan(offset)) || any(isinf(offset))) discard;
    output.out_offset = float4(offset, depth * alpha, alpha);
    return output;
}
