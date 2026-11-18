//! mirai surface Terrain_Layers
//! parameter control {"kind":"texture"}
//! parameter normal {"kind":"texture"}
//! parameter paint {"kind":"texture","srgb":true}
//! parameter layers {"kind":"texture"}
//! parameter piece {"default":[2,2,0,1],"min":0,"max":100000}
//! parameter palette {"default":[0,1,2,3],"min":0,"max":31}
//! parameter rows {"default":[1,0,0,0],"min":0,"max":32}
#include "terrain_projection.slang"
#include "terrain_surface.slang"
namespace Terrain_Layers {
// The terrain plugin fills these: the maps of each piece (control, normal and
// paint, terrain.Surface_Maps) and piece, their size in texels, 1 in z for a
// piece of a Volume, which carries the weights of the four layers of its
// palette in uv0 and uv1 instead, and the metres of a texel in w; layers, the
// table of the layers of its source, of rows layers. uv0 is the place over
// the maps, in texels.
struct Parameters {
    uint control;uint normal;uint paint;uint layers;
    float4 piece;float4 palette;float4 rows;
};
// A repeat of a layer covers fewer pixels than this where its far tiling has
// taken over; it begins to over the octave before.
static const float FAR_PIXELS = 96.0;

// A texture laid along a projection at scale repeats a metre, shifted by
// offset repeats, filtered by the footprint of the point.
float4 projected(Mirai_Surface_Context ctx, uint index, Projection p, float scale, float2 offset) {
    float2 shift = float2(origin_phase(ctx.origin, p.u * scale), origin_phase(ctx.origin, p.v * scale));
    float2 uv = shift + float2(dot(ctx.world_position, p.u), dot(ctx.world_position, p.v)) * scale + offset;
    float widen = ctx.ray ? scale : scale * exp2(ctx.lod);
    float2 dx = float2(dot(ctx.position_dx, p.u), dot(ctx.position_dx, p.v)) * widen;
    float2 dy = float2(dot(ctx.position_dy, p.u), dot(ctx.position_dy, p.v)) * widen;
    return mirai_sample_texture_grad(index, uv, dx, dy);
}

// The base color (its alpha the height) and the normal map of a layer along
// a projection at one scale. With detile, a slow noise of the world (a
// feature every few repeats) runs through bands, each with a shift of the
// repeats of its own; a point blends the shifts of the two bands it lies
// between, the higher texel (alpha) first: no repeat lines up with the next.
void tiled(Mirai_Surface_Context ctx, Terrain_Layer l, Projection p, float scale, out float4 c, out float4 n) {
    if (l.detile <= 0.0) {
        c = projected(ctx, l.color, p, scale, float2(0.0));
        n = l.normal_strength > 0.0 ? projected(ctx, l.normal, p, scale, float2(0.0)) : float4(0.5, 0.5, 1.0, 1.0);
        return;
    }
    float k = mirai_noise(ctx, 4.0 / scale) * 8.0;
    int band = int(floor(k));
    float2 a = float2(mirai_cell_value(int3(band, 1, 0)), mirai_cell_value(int3(band, 2, 0))) * l.detile;
    float2 b = float2(mirai_cell_value(int3(band + 1, 1, 0)), mirai_cell_value(int3(band + 1, 2, 0))) * l.detile;
    float4 ca = projected(ctx, l.color, p, scale, a), cb = projected(ctx, l.color, p, scale, b);
    float t = smoothstep(0.2, 0.8, k - float(band) + 0.5 * (cb.a - ca.a));
    c = lerp(ca, cb, t);
    n = l.normal_strength > 0.0 ? lerp(projected(ctx, l.normal, p, scale, a), projected(ctx, l.normal, p, scale, b), t) : float4(0.5, 0.5, 1.0, 1.0);
}

// The base color and the normal in the world of a layer: each projection
// turns its normal map onto the surface (whiteout); far away its far tiling
// takes over from its tiling, over an octave of the footprint.
void layer_read(Mirai_Surface_Context ctx, Terrain_Layer l, float3 n, float3 weights, out float4 c, out float3 bent) {
    c = float4(0.0);
    bent = float3(0.0);
    float near = 1.0 / max(l.tiling, 1e-6);
    float footprint = max(length(ctx.position_dx), length(ctx.position_dy));
    float far = l.far_tiling > 0.0 ? saturate(log2(FAR_PIXELS * footprint * near) + 1.0) : 0.0;
    for (int which = 0; which < 3; which++) {
        float w = weights[which];
        if (w <= 0.0) continue;
        Projection p = projection(which, n);
        float4 color = float4(0.0), map = float4(0.0);
        if (far < 1.0) {
            float4 a, b;
            tiled(ctx, l, p, near, a, b);
            color += (1.0 - far) * a; map += (1.0 - far) * b;
        }
        if (far > 0.0) {
            float4 a, b;
            tiled(ctx, l, p, 1.0 / l.far_tiling, a, b);
            color += far * a; map += far * b;
        }
        c += w * color;
        float3 t = float3(0.0, 0.0, 1.0);
        if (l.normal_strength > 0.0) {
            float2 xy = (map.rg * 2.0 - 1.0) * l.normal_strength;
            t = float3(xy, sqrt(saturate(1.0 - dot(xy, xy))));
        }
        float3 r = float3(t.x + dot(n, p.u), t.y + dot(n, p.up), abs(t.z) * dot(n, p.axis));
        bent += w * (r.x * p.u + r.y * p.up + r.z * p.axis);
    }
}

// A normal of the space of the object in the world.
float3 object_normal(Mirai_Surface_Context ctx, float3 n) {
    float3 w = n.x * ctx.object_x / max(dot(ctx.object_x, ctx.object_x), 1e-30) + n.y * ctx.object_y / max(dot(ctx.object_y, ctx.object_y), 1e-30) + n.z * ctx.object_z / max(dot(ctx.object_z, ctx.object_z), 1e-30);
    return dot(w, w) > 1e-30 ? normalize(w) : ctx.normal;
}

Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    Terrain_Mix mix;
    float3 n = ctx.normal;
    float4 paint = float4(1.0, 1.0, 1.0, float(PAINT_ROUGHNESS_NEUTRAL) / 255.0);
    bool hole = false;
    if (p.piece.z > 0.5 || p.control == 0xffffffffu) {
        // A piece of a Volume: the layers of its palette, their weights in its vertices.
        float4 w = max(float4(ctx.uv0, ctx.uv1), float4(0.0));
        float total = w.x + w.y + w.z + w.w;
        w = total > 0.0 ? w / total : float4(1.0, 0.0, 0.0, 0.0);
        for (int i = 0; i < 4; i++) { mix.layers[i] = uint(p.palette[i] + 0.5); mix.weights[i] = w[i]; }
    } else {
        float2 size = max(p.piece.xy, float2(1.0));
        mix = terrain_weights_at(p.control, size, ctx.uv0, hole);
        // The maps along the footprint of the point, in texels of metres piece.w.
        float2 uv = (ctx.uv0 + 0.5) / size;
        float2 dx = mirai_object_vector(ctx, ctx.position_dx).xz / (max(p.piece.w, 1e-6) * size);
        float2 dy = mirai_object_vector(ctx, ctx.position_dy).xz / (max(p.piece.w, 1e-6) * size);
        n = object_normal(ctx, mirai_sample_texture_grad(p.normal, uv, dx, dy).rgb * 2.0 - 1.0);
        if (p.paint != 0xffffffffu) paint = mirai_sample_texture_grad(p.paint, uv, dx, dy);
    }
    // Over a hole the material cuts the surface (terrain_layers_holed.mat); an opaque one keeps it.
    s.alpha = hole ? 0.0 : 1.0;
    float3 weights = projection_weights(p.piece.z > 0.5 ? ctx.vertex_normal : n, ctx.ray);
    float3 albedo[4];
    float3 bent[4];
    Terrain_Layer layer[4];
    float4 blend = float4(0.0);
    for (int i = 0; i < 4; i++) {
        albedo[i] = float3(0.0);
        bent[i] = n;
        if (mix.weights[i] <= 0.0) continue;
        layer[i] = terrain_layer(p.layers, mix.layers[i], p.rows.x);
        float4 c;
        layer_read(ctx, layer[i], n, weights, c, bent[i]);
        float shade = 1.0;
        if (layer[i].variation > 0.0) shade = lerp(1.0, 0.75 + 0.5 * (0.6 * mirai_noise(ctx, 31.0) + 0.4 * mirai_noise(ctx, 97.0)), layer[i].variation);
        albedo[i] = c.rgb * layer[i].tint * shade;
        // The alpha of the base color map is the height of the layer: where
        // layers meet the higher texels show through.
        blend[i] = mix.weights[i] * exp2(5.0 * layer[i].height_blend * c.a);
    }
    float sum = blend.x + blend.y + blend.z + blend.w;
    blend = sum > 0.0 ? blend / sum : float4(1.0, 0.0, 0.0, 0.0);
    float3 color = float3(0.0);
    float3 normal = float3(0.0);
    float roughness = 0.0;
    float metallic = 0.0;
    for (int i = 0; i < 4; i++) {
        if (blend[i] <= 0.0 || mix.weights[i] <= 0.0) continue;
        color += albedo[i] * blend[i];
        normal += bent[i] * blend[i];
        roughness += layer[i].roughness * blend[i];
        metallic += layer[i].metallic * blend[i];
    }
    s.normal = normalize(dot(normal, normal) > 1e-12 ? normal : n);
    // The colors of a Mesh source and what is painted tint the layers, as they tint a material.
    s.base_color = color * ctx.vertex_color.rgb * paint.rgb;
    s.roughness = saturate(roughness + (paint.a * 255.0 - float(PAINT_ROUGHNESS_NEUTRAL)) / (255.0 - float(PAINT_ROUGHNESS_NEUTRAL)));
    s.metallic = metallic;
    return s;
}
}
