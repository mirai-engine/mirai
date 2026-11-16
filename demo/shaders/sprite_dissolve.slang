//! mirai surface Sprite_Dissolve
//! parameter cool {"default":[0.15,0.55,1],"min":0,"max":1,"color":true}
//! parameter warm {"default":[1,0.3,0.85],"min":0,"max":1,"color":true}
//! parameter glow {"default":1.5,"min":0,"max":16}
//! parameter edge {"default":0.12,"min":0,"max":0.5}
// A sprite that burns away from its rim as its particle dissolves (the x of
// its first data, 0 to 1), glowing along the edge that eats it, in a color
// from cool to warm by the y of that data, tinted and faded by the color of
// its particle. Without the data of a particle, a whole disc of cool.
namespace Sprite_Dissolve {
struct Parameters {float3 cool;float glow;float3 warm;float edge;};

float hash(float2 cell) { return frac(sin(dot(cell, float2(12.9898, 78.233))) * 43758.5453); }

// Value noise over the sprite, smooth between cells.
float noise(float2 uv) {
    float2 cell = floor(uv);
    float2 f = frac(uv);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash(cell), hash(cell + float2(1.0, 0.0)), f.x), lerp(hash(cell + float2(0.0, 1.0)), hash(cell + float2(1.0, 1.0)), f.x), f.y);
}

Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    float4 data = (ctx.particle_given & 1u) != 0u ? ctx.particle_data[0] : float4(0.0);
    float2 c = ctx.uv0 * 2.0 - 1.0;
    float ragged = length(c) + (noise(ctx.uv0 * 6.0 + data.y * 17.0) - 0.5) * 0.4;
    float left = 1.0 - data.x;
    float inside = 1.0 - smoothstep(left - 0.04, left, ragged);
    float rim = smoothstep(left - p.edge - 0.04, left - 0.02, ragged) * inside;
    s.unlit = true;
    s.base_color = float3(0.0);
    s.emission = lerp(p.cool, p.warm, data.y) * p.glow * (0.25 + 3.0 * rim) * ctx.vertex_color.rgb;
    s.alpha = inside * ctx.vertex_color.a;
    return s;
}
}
