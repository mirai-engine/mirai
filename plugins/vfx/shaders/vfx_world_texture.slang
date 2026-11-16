// What a texture of the world of the vfx plugin holds at a point of the world
// (relative to the origin of the frame, as ctx.world_position): a layer of a
// grid flat along y with a Particle_World_Texture, by the name of the grid,
// between its cells by a cubic B-spline. Zero outside its region, and without
// it. For Surface programs: vfx_world_texture("fluid", ctx.world_position).
// By UV over the region, as a material samples the render target a grid
// writes: vfx_world_texture_uv("fluid", ctx.uv0).
#ifndef VFX_WORLD_TEXTURE_SLANG
#define VFX_WORLD_TEXTURE_SLANG
#define vfx_world_texture(name, position) vfx_world_texture_named(uint(getStringHash(name)), position)
#define vfx_world_texture_uv(name, uv) vfx_world_texture_uv_named(uint(getStringHash(name)), uv)

// A texture between its texels by a cubic B-spline, in four bilinear samples: a grid a few
// metres across seen up close shows no edge at the cells, as it does linear between them.
float4 vfx_world_texture_smooth(uint texture, float2 uv) {
#ifdef MIRAI_MATERIAL_REFLECTION
    return float4(0.0);
#else
    if (!material_has(texture)) return float4(0.0);
    float2 size = float2(texture_size(material_textures[mirai_nonuniform(texture)], 0));
    float2 st = uv * size - 0.5;
    float2 cell = floor(st);
    float2 f = st - cell;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 near = (cell - 0.5 + w1 / g0) / size;
    float2 far = (cell + 1.5 + w3 / g1) / size;
    return g0.y * (g0.x * mirai_sample_texture_level(texture, near, 0.0) + g1.x * mirai_sample_texture_level(texture, float2(far.x, near.y), 0.0))
        + g1.y * (g0.x * mirai_sample_texture_level(texture, float2(near.x, far.y), 0.0) + g1.x * mirai_sample_texture_level(texture, far, 0.0));
#endif
}
float4 vfx_world_texture_named(uint name, float3 position) {
#ifdef MIRAI_MATERIAL_REFLECTION
    return float4(0.0);
#else
    if (name == 0u) return float4(0.0);
    for (uint i = 0u; i < 4u; i++) {
        if (frame.vfx_world.names[i] != name) continue;
        float4 b = frame.vfx_world.bounds[i];
        if (any(position.xz < b.xy) || any(position.xz >= b.zw)) return float4(0.0);
        float4 starts = frame.vfx_world.starts[i / 2u];
        float2 start = (i & 1u) != 0u ? starts.zw : starts.xy;
        return vfx_world_texture_smooth(frame.vfx_world.textures[i], start + (position.xz - b.xy) / (b.zw - b.xy));
    }
    return float4(0.0);
#endif
}
// (0, 0) is the start of the first cell of the region and (1, 1) the end of
// its last; bilinear between cells and repeating.
float4 vfx_world_texture_uv_named(uint name, float2 uv) {
#ifdef MIRAI_MATERIAL_REFLECTION
    return float4(0.0);
#else
    if (name == 0u) return float4(0.0);
    for (uint i = 0u; i < 4u; i++) {
        if (frame.vfx_world.names[i] != name) continue;
        uint texture = frame.vfx_world.textures[i];
        if (!material_has(texture)) return float4(0.0);
        float4 starts = frame.vfx_world.starts[i / 2u];
        float2 start = (i & 1u) != 0u ? starts.zw : starts.xy;
        return mirai_sample_texture_level(texture, start + uv, 0.0);
    }
    return float4(0.0);
#endif
}
#endif
