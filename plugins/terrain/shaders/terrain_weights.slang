//! mirai surface Terrain_Weights
//! parameter control {"kind":"texture"}
//! parameter piece {"default":[2,2,0,1],"min":0,"max":100000}
//! parameter palette {"default":[0,1,2,3],"min":0,"max":31}
//! parameter inspect {"default":[1,0,0,0],"min":0,"max":32}
#include "terrain_surface.slang"
namespace Terrain_Weights {
// The weights of the layers of a terrain as the editor inspects them, read as
// Terrain_Layers reads them, rules included: inspect.x 1, a color for each
// layer; 2, the layer inspect.y from black to white. control, piece and
// palette are those the piece gives Terrain_Layers.
struct Parameters {
    uint control;
    float4 piece;
    float4 palette;
    float4 inspect;
};
// A color of its own for each layer, apart from those of the layers beside it.
float3 layer_color(uint layer) {
    float hue = frac(float(layer) * 0.618034);
    return saturate(abs(frac(hue + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0) * 0.75 + 0.15;
}
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    Terrain_Mix mix;
    if (p.piece.z > 0.5 || p.control == 0xffffffffu) {
        float4 w = max(float4(ctx.uv0, ctx.uv1), float4(0.0));
        float total = w.x + w.y + w.z + w.w;
        w = total > 0.0 ? w / total : float4(1.0, 0.0, 0.0, 0.0);
        for (int i = 0; i < 4; i++) { mix.layers[i] = uint(p.palette[i] + 0.5); mix.weights[i] = w[i]; }
    } else {
        bool hole;
        mix = terrain_weights_at(p.control, max(p.piece.xy, float2(1.0)), ctx.uv0, hole);
    }
    float3 shown = float3(0.0);
    uint chosen = uint(clamp(p.inspect.y + 0.5, 0.0, 31.0));
    for (int i = 0; i < 4; i++) {
        if (p.inspect.x < 1.5) shown += mix.weights[i] * layer_color(mix.layers[i]);
        else if (mix.layers[i] == chosen) shown += float3(mix.weights[i]);
    }
    s.base_color = shown;
    s.roughness = 1.0;
    s.metallic = 0.0;
    return s;
}
}
