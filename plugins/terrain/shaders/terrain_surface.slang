//! mirai constant WEIGHT_FULL int ../runtime/layers.odin
//! mirai constant WEIGHT_LAYER_BITS int ../runtime/layers.odin
//! mirai constant WEIGHT_VALUES_SHIFT int ../runtime/layers.odin
//! mirai constant WEIGHT_HOLE_BIT int ../runtime/layers.odin
//! mirai constant PAINT_ROUGHNESS_NEUTRAL int ../runtime/paint.odin
// What a piece of a terrain shows between its vertices (terrain.Surface_Maps):
// the weights of the layers of each of its samples with the hole of each
// cell, its normal and its paint, read texel by texel and blended between the
// four around a point, and the table of the layers of its source
// (terrain.layers_table), a row of LAYERS_TEXELS texels each. None of them
// streams: Terrain_Layers, Terrain_Weights and terrain_displace.comp load them
// texel by texel alike, and a stage without the program API defines
// TERRAIN_TEXEL.
#ifndef TERRAIN_SURFACE_SLANG
#define TERRAIN_SURFACE_SLANG
#include <constants/plugins/terrain.slang>
#ifndef TERRAIN_TEXEL
#define TERRAIN_TEXEL(texture, texel) mirai_load_texture(texture, texel)
#endif

// The four bytes of a texel of a map, as the terrain wrote them.
uint terrain_word(float4 texel) {
    uint4 b = uint4(round(saturate(texel) * 255.0));
    return b.x | (b.y << 8u) | (b.z << 16u) | (b.w << 24u);
}

// The layers that weigh most at a point, their weights adding up to 1, from
// the heaviest; a layer past count has no weight.
struct Terrain_Mix {
    uint layers[4];
    float weights[4];
};

// The texel of a map of size texels at the low corner of the four around
// texel coordinates at, and where at lies between them.
int2 terrain_corner(float2 size, float2 at, out float2 f) {
    float2 p = clamp(at, float2(0.0), size - 1.0);
    int2 low = int2(min(floor(p), max(size - 2.0, float2(0.0))));
    f = p - float2(low);
    return low;
}

// A map of a piece of size texels at texel coordinates at, bilinear between
// its four texels around, as the weights are.
float4 terrain_map_at(uint map, float2 size, float2 at) {
    float2 f;
    int2 low = terrain_corner(size, at, f);
    int2 last = int2(size) - 1;
    float4 a = TERRAIN_TEXEL(map, low), b = TERRAIN_TEXEL(map, min(low + int2(1, 0), last));
    float4 c = TERRAIN_TEXEL(map, min(low + int2(0, 1), last)), d = TERRAIN_TEXEL(map, min(low + 1, last));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

// The weights of the layers at texel coordinates at over a control map of
// size texels, bilinear between its four texels around, and whether the cell
// at is in is a hole. The three layers of each texel are twelve candidates;
// each takes the weight of the later ones of its layer, then the four
// heaviest are kept. Every index is a constant once the loops unroll, so the
// candidates stay in registers.
Terrain_Mix terrain_weights_at(uint control, float2 size, float2 at, out bool hole) {
    float2 f;
    int2 low = terrain_corner(size, at, f);
    uint layers[12];
    float weights[12];
    uint mask = (1u << uint(WEIGHT_LAYER_BITS)) - 1u;
    hole = false;
    [ForceUnroll]
    for (int corner = 0; corner < 4; corner++) {
        int2 offset = int2(corner & 1, corner >> 1);
        float share = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y) / float(WEIGHT_FULL);
        uint word = terrain_word(TERRAIN_TEXEL(control, min(low + offset, int2(size) - 1)));
        if (corner == 0) hole = (word >> uint(WEIGHT_HOLE_BIT) & 1u) != 0u;
        float first = float(word >> uint(WEIGHT_VALUES_SHIFT) & 255u), second = float(word >> uint(WEIGHT_VALUES_SHIFT + 8) & 255u);
        layers[3 * corner] = word & mask;
        layers[3 * corner + 1] = word >> uint(WEIGHT_LAYER_BITS) & mask;
        layers[3 * corner + 2] = word >> uint(2 * WEIGHT_LAYER_BITS) & mask;
        weights[3 * corner] = share * first;
        weights[3 * corner + 1] = share * second;
        weights[3 * corner + 2] = share * max(float(WEIGHT_FULL) - first - second, 0.0);
    }
    [ForceUnroll]
    for (int i = 0; i < 11; i++) {
        [ForceUnroll]
        for (int j = i + 1; j < 12; j++) {
            bool same = layers[j] == layers[i] && weights[i] > 0.0;
            weights[i] += same ? weights[j] : 0.0;
            weights[j] = same ? 0.0 : weights[j];
        }
    }
    Terrain_Mix m;
    float total = 0.0;
    [ForceUnroll]
    for (int slot = 0; slot < 4; slot++) {
        float best = -1.0;
        uint layer = 0u;
        int pick = 0;
        [ForceUnroll]
        for (int i = 0; i < 12; i++) {
            bool heavier = weights[i] > best;
            best = heavier ? weights[i] : best;
            layer = heavier ? layers[i] : layer;
            pick = heavier ? i : pick;
        }
        [ForceUnroll]
        for (int i = 0; i < 12; i++) weights[i] = pick == i ? -1.0 : weights[i];
        m.layers[slot] = layer;
        m.weights[slot] = max(best, 0.0);
        total += m.weights[slot];
    }
    [ForceUnroll]
    for (int slot = 0; slot < 4; slot++) m.weights[slot] = total > 0.0 ? m.weights[slot] / total : (slot == 0 ? 1.0 : 0.0);
    return m;
}

// A layer of the table of its source (terrain.layers_table).
struct Terrain_Layer {
    uint color;            // its base color map, the alpha its height; INVALID: none
    uint normal;           // its normal map
    float3 tint;           // the base color of its material
    float roughness;
    float metallic;
    float height_blend;
    float detile;
    float variation;
    float tiling;          // metres of a repeat
    float far_tiling;      // far away; 0: tiling
    float normal_strength; // 0 without a normal map
    float displacement;    // metres from its lowest texel to its highest
};
Terrain_Layer terrain_layer(uint table, uint layer) {
    int y = int(layer);
    Terrain_Layer l;
    l.color = terrain_word(TERRAIN_TEXEL(table, int2(0, y)));
    l.normal = terrain_word(TERRAIN_TEXEL(table, int2(1, y)));
    float4 values = TERRAIN_TEXEL(table, int2(2, y));
    l.tint = values.rgb;
    l.roughness = values.a;
    float4 more = TERRAIN_TEXEL(table, int2(3, y));
    l.metallic = more.x; l.height_blend = more.y; l.detile = more.z; l.variation = more.w;
    l.tiling = asfloat(terrain_word(TERRAIN_TEXEL(table, int2(4, y))));
    l.far_tiling = asfloat(terrain_word(TERRAIN_TEXEL(table, int2(5, y))));
    l.normal_strength = asfloat(terrain_word(TERRAIN_TEXEL(table, int2(6, y))));
    l.displacement = asfloat(terrain_word(TERRAIN_TEXEL(table, int2(7, y))));
    return l;
}
#endif
