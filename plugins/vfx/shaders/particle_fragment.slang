// What the fragment stages of the particles that blend share
// (particle_sprite.frag, particle_distort.frag): the side of glass a pass
// draws, the flipbook moved along its motion and its normal map.
#ifndef MIRAI_PARTICLE_FRAGMENT_SLANG
#define MIRAI_PARTICLE_FRAGMENT_SLANG
#include "particles.slang"
#include "depth.slang"

[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] Texture2D<float4> glass_depth : register(MIRAI_REGISTER(t, SLOT_PASS8), space0);

// Whether a fragment at view depth `depth` lies on the side of the nearest
// glass a pass draws (PARTICLE_PASS_*; 0 without glass in view).
bool particle_glass_side(uint pass, int2 pixel, float depth) {
    if (pass == 0u) return true;
    float layer = glass_depth.Load(int3(pixel, 0)).r;
    bool in_front = layer > 0.0 && depth <= layer * 1.0001 + 1e-4;
    return in_front == (pass == PARTICLE_PASS_FRONT_OF_GLASS);
}

// A texel of a texture of the flipbook at uv, filtered by the gradients of the
// uv before its motion moved them (dx, dy): where the motion changes from one
// texel to the next the level filtered stays, with no seam.
float4 particle_flipbook_texel(uint texture_index, float2 uv, float2 dx, float2 dy) {
    material_texel_feedback(texture_index, dx, dy, frame.texturing.x);
    float scale = exp2(frame.texturing.x);
    return material_textures[mirai_nonuniform(texture_index)].SampleGrad(material_sampler, uv, dx * scale, dy * scale);
}

// Where a texel of flipbook_motion moves to by the next frame, in tiles, x
// right and y down: 128 of 255 in a channel is still, so a linear BC5 texture
// keeps it exact.
float2 particle_motion_decode(float2 texel) { return (texel * 255.0 - 128.0) / 127.0; }

// The two frames of the flipbook of an emitter (this one at uv.xy, the next
// at uv.zw) at t between them: each texel of this frame forward by t of its
// motion, each of the next back by the rest of it, so what moves slides
// instead of cross-fading. Each stays half a texel inside its tile.
float4 particle_flipbook_moved(uint slot, float4 uv, float t, float2 dx, float2 dy) {
    uint motion = particle_emitters[slot].light_limit.z;
    if (!material_has(motion)) return uv;
    float scale = asfloat(particle_emitters[slot].light_limit.w);
    float2 tiles = float2(max(particle_emitters[slot].flipbook.xy, uint2(1u)));
    float2 tile = 1.0 / tiles;
    float2 half_texel = 0.5 / float2(texture_size(material_textures[mirai_nonuniform(motion)], 0));
    float2 now = particle_motion_decode(particle_flipbook_texel(motion, uv.xy, dx, dy).rg) * tile * scale;
    float2 next = particle_motion_decode(particle_flipbook_texel(motion, uv.zw, dx, dy).rg) * tile * scale;
    float2 low = floor(uv.xy * tiles) * tile, low_next = floor(uv.zw * tiles) * tile;
    float2 a = clamp(uv.xy - now * t, low + half_texel, low + tile - half_texel);
    float2 b = clamp(uv.zw + next * (1.0 - t), low_next + half_texel, low_next + tile - half_texel);
    return float4(a, b);
}

// The tangent-space normal of the normal map of a sprite at the two frames of
// its flipbook, blended by t, as its material scales it.
float3 particle_flipbook_normal(Material m, float4 uv, float t, float2 dx, float2 dy) {
    uint map = m.textures[MATERIAL_MAP_NORMAL];
    float2 xy = lerp(particle_flipbook_texel(map, uv.xy, dx, dy).xy, particle_flipbook_texel(map, uv.zw, dx, dy).xy, t) * 2.0 - 1.0;
    return float3(xy * m.normal_scale, sqrt(max(1.0 - dot(xy, xy), 0.0)));
}

// The normal of what a particle draws turned toward the eye: a quad, a
// ribbon or a mesh is seen from either side.
float3 particle_facing(float3 normal, float3 eye) {
    float3 n = particle_unit(normal, eye);
    return dot(n, eye) < 0.0 ? -n : n;
}

// How a sprite fades where it meets what is behind it and the camera
// (Particle_Info.soft), at view depth `depth` over the opaque depth `scene`.
float particle_soft(uint slot, float scene, float depth) {
    float soft = particle_emitters[slot].look.y;
    if (!(soft > 0.0)) return 1.0;
    float fade = saturate((depth - frame.camera_position.w) / soft);
    if (!depth_empty(scene)) fade *= saturate((depth_distance(scene) - depth) / soft);
    return fade;
}
#endif
