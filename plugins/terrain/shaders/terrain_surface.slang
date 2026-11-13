//! mirai constant LAYERS_TEXELS int ../runtime/layers.odin
//! mirai constant WEIGHT_FULL int ../runtime/layers.odin
//! mirai constant WEIGHT_LAYER_BITS int ../runtime/layers.odin
//! mirai constant WEIGHT_VALUES_SHIFT int ../runtime/layers.odin
//! mirai constant WEIGHT_HOLE_BIT int ../runtime/layers.odin
//! mirai constant PAINT_ROUGHNESS_NEUTRAL int ../runtime/paint.odin
// What a piece of a terrain shows between its vertices (terrain.Surface_Maps):
// the weights of the layers of each of its samples with the hole of each
// cell, read texel by texel and blended between the four around a point, and
// the table of the layers of its source (terrain.layers_table), a row of
// LAYERS_TEXELS texels each. Terrain_Layers, Terrain_Weights and
// terrain_displace.comp read them alike; a stage without a sampler defines
// TERRAIN_TEXEL with a load.
#ifndef TERRAIN_SURFACE_SLANG
#define TERRAIN_SURFACE_SLANG
#include <constants/plugins/terrain.slang>
#ifndef TERRAIN_TEXEL
#define TERRAIN_TEXEL(texture, texel, size) mirai_sample_texture_level(texture, (float2(texel) + 0.5) / (size), 0.0)
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

// Adds the weight of a layer to what eight slots hold: to its own slot, or
// in place of the lightest when it weighs more.
void terrain_mix_add(inout uint layers[8], inout float weights[8], uint layer, float weight) {
    if (weight <= 0.0) return;
    int lightest = 0;
    for (int i = 0; i < 8; i++) {
        if (weights[i] > 0.0 && layers[i] == layer) { weights[i] += weight; return; }
        if (weights[i] < weights[lightest]) lightest = i;
    }
    if (weight > weights[lightest]) { layers[lightest] = layer; weights[lightest] = weight; }
}

// The four heaviest of eight slots, normalized.
Terrain_Mix terrain_mix_top(uint layers[8], float weights[8]) {
    Terrain_Mix m;
    float total = 0.0;
    for (int slot = 0; slot < 4; slot++) {
        int best = 0;
        for (int i = 1; i < 8; i++) {if (weights[i] > weights[best]) best = i;}
        m.layers[slot] = layers[best];
        m.weights[slot] = max(weights[best], 0.0);
        total += m.weights[slot];
        weights[best] = -1.0;
    }
    for (int slot = 0; slot < 4; slot++) m.weights[slot] = total > 0.0 ? m.weights[slot] / total : (slot == 0 ? 1.0 : 0.0);
    return m;
}

// The weights of the layers at texel coordinates at over a control map of
// size texels, bilinear between its four texels around, and whether the cell
// at is in is a hole.
Terrain_Mix terrain_weights_at(uint control, float2 size, float2 at, out bool hole) {
    float2 p = clamp(at, float2(0.0), size - 1.0);
    int2 low = int2(min(floor(p), max(size - 2.0, float2(0.0))));
    float2 f = p - float2(low);
    uint layers[8];
    float weights[8];
    for (int i = 0; i < 8; i++) { layers[i] = 0u; weights[i] = 0.0; }
    hole = false;
    for (int corner = 0; corner < 4; corner++) {
        int2 offset = int2(corner & 1, corner >> 1);
        float share = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);
        uint word = terrain_word(TERRAIN_TEXEL(control, min(low + offset, int2(size) - 1), size));
        if (corner == 0) hole = (word >> uint(WEIGHT_HOLE_BIT) & 1u) != 0u;
        uint mask = (1u << uint(WEIGHT_LAYER_BITS)) - 1u;
        float first = float(word >> uint(WEIGHT_VALUES_SHIFT) & 255u), second = float(word >> uint(WEIGHT_VALUES_SHIFT + 8) & 255u);
        terrain_mix_add(layers, weights, word & mask, share * first / float(WEIGHT_FULL));
        terrain_mix_add(layers, weights, word >> uint(WEIGHT_LAYER_BITS) & mask, share * second / float(WEIGHT_FULL));
        terrain_mix_add(layers, weights, word >> uint(2 * WEIGHT_LAYER_BITS) & mask, share * (float(WEIGHT_FULL) - first - second) / float(WEIGHT_FULL));
    }
    return terrain_mix_top(layers, weights);
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
Terrain_Layer terrain_layer(uint table, uint layer, float rows) {
    float2 size = float2(float(LAYERS_TEXELS), max(rows, 1.0));
    int y = int(layer);
    Terrain_Layer l;
    l.color = terrain_word(TERRAIN_TEXEL(table, int2(0, y), size));
    l.normal = terrain_word(TERRAIN_TEXEL(table, int2(1, y), size));
    float4 values = TERRAIN_TEXEL(table, int2(2, y), size);
    l.tint = values.rgb;
    l.roughness = values.a;
    float4 more = TERRAIN_TEXEL(table, int2(3, y), size);
    l.metallic = more.x; l.height_blend = more.y; l.detile = more.z; l.variation = more.w;
    l.tiling = asfloat(terrain_word(TERRAIN_TEXEL(table, int2(4, y), size)));
    l.far_tiling = asfloat(terrain_word(TERRAIN_TEXEL(table, int2(5, y), size)));
    l.normal_strength = asfloat(terrain_word(TERRAIN_TEXEL(table, int2(6, y), size)));
    l.displacement = asfloat(terrain_word(TERRAIN_TEXEL(table, int2(7, y), size)));
    return l;
}
#endif
