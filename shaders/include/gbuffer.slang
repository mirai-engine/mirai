// The G-buffer as the passes after the geometry read it: each target is
// encoded by gbuffer.frag and decoded here alone. A pass defines the slots
// it binds the targets it reads to before it includes this:
//   GBUFFER_ALBEDO   RGBA8 sRGB: base color, a metallic
//   GBUFFER_NORMAL   RGBA16F: xy the shading normal (octahedral), z its
//                    roughness widened by specular antialiasing, w its
//                    MATERIAL_LAYER_* bits, GBUFFER_TRACE_COAT and
//                    GBUFFER_EMISSION_RELATIVE
//   GBUFFER_EMISSION RGBA16F: emission in render units, a ambient occlusion
// The other targets of the G-buffer are bound for every pass: the motion
// target is pixel_views (rg the motion of the pixel, b the roughness traced
// reflections decide by, a 1 + its nested view) and the reflectance target
// surface_specular (pixel_reflectance), and while an instance with layers is
// in sight, the layers target gbuffer_layers_target. The linear depth keeps
// its own decoders (depth_* of common.slang).
#ifndef MIRAI_GBUFFER_SLANG
#define MIRAI_GBUFFER_SLANG
#include "scene.slang"

float4 gbuffer_normal_pack(float3 normal, float roughness, uint layers) {
    return float4(oct_encode(normal), roughness, float(layers));
}
float3 gbuffer_normal_unpack(float4 texel) { return oct_decode(texel.xy); }
// The layer bits are a whole number below 2048, exact in a half float.
uint gbuffer_bits_unpack(float4 texel) { return uint(texel.w + 0.5); }

// The bits of the normal target besides the layers of the material
// (MATERIAL_LAYER_*): the traced reflection of the pixel is the one of its coat.
#define GBUFFER_TRACE_COAT 32u
// Its emission is relative to the exposure (EMISSION_RELATIVE): it shows in
// the image, but neither lights the scene nor is metered.
#define GBUFFER_EMISSION_RELATIVE 64u
// A layer of glass that is a back face of the solid the camera is in: the view leaves the solid there.
#define GBUFFER_GLASS_EXIT 128u

// The layers target (RGBA32 uint), while some instance with layers is in
// sight: its 128 bits in this order, from the low bits of x up, each value
// in as many bits as it says: the normal of the coat (octahedral, 11 per
// axis), the tangent (octahedral, 9 per axis), the weight, roughness and IOR
// ((ior - 1) / 2) of the coat (7, 7 and 6), the amount of anisotropy (6), the
// weight and roughness of the fuzz (6 each), the weight of the diffuse
// transmission (6), and the colors of the coat (4, 5, 5), of the fuzz and of
// the diffuse transmission (5 per channel each), as their square roots.
uint gbuffer_unorm(float value, uint bits) { return uint(round(saturate(value) * float((1u << bits) - 1u))); }
// `bits` of `value` at bit `at` of the 128, which may cross from one word into the next.
void gbuffer_put(inout uint4 v, inout uint at, uint value, uint bits) {
    uint word = at >> 5u, shift = at & 31u;
    v[word] |= value << shift;
    if (shift + bits > 32u) v[word + 1u] |= value >> (32u - shift);
    at += bits;
}
uint gbuffer_take(uint4 v, inout uint at, uint bits) {
    uint word = at >> 5u, shift = at & 31u;
    uint value = v[word] >> shift;
    if (shift + bits > 32u) value |= v[word + 1u] << (32u - shift);
    at += bits;
    return value & ((1u << bits) - 1u);
}
void gbuffer_put_unorm(inout uint4 v, inout uint at, float value, uint bits) { gbuffer_put(v, at, gbuffer_unorm(value, bits), bits); }
float gbuffer_take_unorm(uint4 v, inout uint at, uint bits) { return float(gbuffer_take(v, at, bits)) / float((1u << bits) - 1u); }
void gbuffer_put_oct(inout uint4 v, inout uint at, float3 n, uint bits) {
    float2 p = oct_encode(n) * 0.5 + 0.5;
    gbuffer_put_unorm(v, at, p.x, bits);
    gbuffer_put_unorm(v, at, p.y, bits);
}
float3 gbuffer_take_oct(uint4 v, inout uint at, uint bits) {
    float x = gbuffer_take_unorm(v, at, bits);
    float y = gbuffer_take_unorm(v, at, bits);
    return oct_decode(float2(x, y) * 2.0 - 1.0);
}
void gbuffer_put_color(inout uint4 v, inout uint at, float3 color, uint3 bits) {
    float3 root = sqrt(saturate(color));
    gbuffer_put_unorm(v, at, root.r, bits.x);
    gbuffer_put_unorm(v, at, root.g, bits.y);
    gbuffer_put_unorm(v, at, root.b, bits.z);
}
float3 gbuffer_take_color(uint4 v, inout uint at, uint3 bits) {
    float3 root;
    root.r = gbuffer_take_unorm(v, at, bits.x);
    root.g = gbuffer_take_unorm(v, at, bits.y);
    root.b = gbuffer_take_unorm(v, at, bits.z);
    return root * root;
}
uint4 gbuffer_layers_pack(Material_Layers l) {
    uint4 v = uint4(0u);
    uint at = 0u;
    gbuffer_put_oct(v, at, l.coat_normal, 11u);
    gbuffer_put_oct(v, at, l.tangent, 9u);
    gbuffer_put_unorm(v, at, l.coat, 7u);
    gbuffer_put_unorm(v, at, l.coat_roughness, 7u);
    gbuffer_put_unorm(v, at, (l.coat_ior - 1.0) * 0.5, 6u);
    gbuffer_put_unorm(v, at, l.anisotropy, 6u);
    gbuffer_put_unorm(v, at, l.fuzz, 6u);
    gbuffer_put_unorm(v, at, l.fuzz_roughness, 6u);
    gbuffer_put_unorm(v, at, l.diffuse_transmission, 6u);
    gbuffer_put_color(v, at, l.coat_color, uint3(4u, 5u, 5u));
    gbuffer_put_color(v, at, l.fuzz_color, uint3(5u, 5u, 5u));
    gbuffer_put_color(v, at, l.diffuse_transmission_color, uint3(5u, 5u, 5u));
    return v;
}
Material_Layers gbuffer_layers_unpack(uint4 v, uint bits) {
    Material_Layers l = material_layers_none();
    uint held = MATERIAL_LAYER_COAT | MATERIAL_LAYER_FUZZ | MATERIAL_LAYER_ANISOTROPY | MATERIAL_LAYER_DIFFUSE_TRANSMISSION;
    l.bits = bits & (held | MATERIAL_LAYER_UNLIT);
    if ((l.bits & held) == 0u) return l;
    uint at = 0u;
    l.coat_normal = gbuffer_take_oct(v, at, 11u);
    l.tangent = gbuffer_take_oct(v, at, 9u);
    l.coat = gbuffer_take_unorm(v, at, 7u);
    l.coat_roughness = gbuffer_take_unorm(v, at, 7u);
    l.coat_ior = 1.0 + 2.0 * gbuffer_take_unorm(v, at, 6u);
    l.anisotropy = gbuffer_take_unorm(v, at, 6u);
    l.fuzz = gbuffer_take_unorm(v, at, 6u);
    l.fuzz_roughness = gbuffer_take_unorm(v, at, 6u);
    l.diffuse_transmission = gbuffer_take_unorm(v, at, 6u);
    l.coat_color = gbuffer_take_color(v, at, uint3(4u, 5u, 5u));
    l.fuzz_color = gbuffer_take_color(v, at, uint3(5u, 5u, 5u));
    l.diffuse_transmission_color = gbuffer_take_color(v, at, uint3(5u, 5u, 5u));
    if ((bits & MATERIAL_LAYER_COAT) == 0u) l.coat = 0.0;
    if ((bits & MATERIAL_LAYER_ANISOTROPY) == 0u) l.anisotropy = 0.0;
    if ((bits & MATERIAL_LAYER_FUZZ) == 0u) l.fuzz = 0.0;
    if ((bits & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) == 0u) l.diffuse_transmission = 0.0;
    return l;
}
[[vk::binding(SLOT_LAYERS, 0)]] Texture2D<uint4> gbuffer_layers_target : register(MIRAI_REGISTER(t, SLOT_LAYERS), space0);
// The layers of the pixel `p` whose normal target holds `bits`: the unlit bit
// alone without the others, or a pass that reads none.
Material_Layers gbuffer_layers(int2 p, uint bits) {
    Material_Layers l = material_layers_none();
    l.bits = bits & MATERIAL_LAYER_UNLIT;
    // A pass that runs while no instance with layers is in sight reads none:
    // its shading of them folds away, and with it what it would hold.
#ifndef MIRAI_GBUFFER_NO_LAYERS
    if ((bits & (MATERIAL_LAYER_COAT | MATERIAL_LAYER_FUZZ | MATERIAL_LAYER_ANISOTROPY | MATERIAL_LAYER_DIFFUSE_TRANSMISSION)) != 0u) l = gbuffer_layers_unpack(gbuffer_layers_target.Load(int3(p, 0)), bits);
#endif
    return l;
}

#ifdef GBUFFER_NORMAL
[[vk::binding(GBUFFER_NORMAL, 0)]] Texture2D<float4> gbuffer_normal_target : register(MIRAI_REGISTER(t, GBUFFER_NORMAL), space0);
float3 gbuffer_normal(int2 p) { return gbuffer_normal_unpack(gbuffer_normal_target.Load(int3(p, 0))); }
// The shading normal in xyz and its roughness in w.
float4 gbuffer_normal_roughness(int2 p) {
    float4 texel = gbuffer_normal_target.Load(int3(p, 0));
    return float4(gbuffer_normal_unpack(texel), texel.z);
}
#endif
#ifdef GBUFFER_ALBEDO
[[vk::binding(GBUFFER_ALBEDO, 0)]] Texture2D<float4> gbuffer_albedo_target : register(MIRAI_REGISTER(t, GBUFFER_ALBEDO), space0);
#endif
#ifdef GBUFFER_EMISSION
[[vk::binding(GBUFFER_EMISSION, 0)]] Texture2D<float4> gbuffer_emission_target : register(MIRAI_REGISTER(t, GBUFFER_EMISSION), space0);
#endif

// A pixel of the G-buffer.
struct Gbuffer_Pixel {
    float3 base_color;
    float metallic;
    float3 normal;
    float roughness;  // widened by specular antialiasing
    float3 f0;
    float f90;        // the grazing reflectance of its specular lobe
    float3 emission;  // render units
    float occlusion;
    uint bits;        // MATERIAL_LAYER_*, GBUFFER_TRACE_COAT and GBUFFER_EMISSION_RELATIVE
    Material_Layers layers;
};

#if defined(GBUFFER_ALBEDO) && defined(GBUFFER_NORMAL)
// stored: the reflectance target holds what each pixel reflects. Without
// GBUFFER_EMISSION, the pixel has no emission and no occlusion.
Gbuffer_Pixel gbuffer_read(int2 p, bool stored) {
    Gbuffer_Pixel g;
    float4 albedo = gbuffer_albedo_target.Load(int3(p, 0));
    float4 normal = gbuffer_normal_target.Load(int3(p, 0));
    g.base_color = albedo.rgb;
    g.metallic = albedo.a;
    g.normal = gbuffer_normal_unpack(normal);
    g.roughness = normal.z;
    g.bits = gbuffer_bits_unpack(normal);
    g.layers = gbuffer_layers(p, g.bits);
    float4 specular = pixel_reflectance(p, albedo, stored);
    g.f0 = specular.rgb;
    g.f90 = specular.a;
#ifdef GBUFFER_EMISSION
    float4 emission = gbuffer_emission_target.Load(int3(p, 0));
    g.emission = emission.rgb;
    g.occlusion = emission.a;
#else
    g.emission = float3(0.0);
    g.occlusion = 1.0;
#endif
    return g;
}
Gbuffer_Pixel gbuffer_read(int2 p) { return gbuffer_read(p, (frame.flags & FRAME_FLAG_REFLECTANCE) != 0u); }
#endif

// The emission of a pixel that shows in the image but lights nothing and is
// not metered (GBUFFER_EMISSION_RELATIVE); zero for a physical one.
float3 gbuffer_relative_emission(Gbuffer_Pixel g) { return (g.bits & GBUFFER_EMISSION_RELATIVE) != 0u ? g.emission : float3(0.0); }
#if defined(GBUFFER_NORMAL) && defined(GBUFFER_EMISSION)
// A pixel's emission by how it is measured: physical, light that lights the
// scene and that a meter counts, or relative to the exposure, which a meter
// takes away from what the pixel shows and counts as nothing.
float3 gbuffer_relative_emission(int2 p) {
    if ((gbuffer_bits_unpack(gbuffer_normal_target.Load(int3(p, 0))) & GBUFFER_EMISSION_RELATIVE) == 0u) return float3(0.0);
    return gbuffer_emission_target.Load(int3(p, 0)).rgb;
}
float3 gbuffer_physical_emission(int2 p) {
    if ((gbuffer_bits_unpack(gbuffer_normal_target.Load(int3(p, 0))) & GBUFFER_EMISSION_RELATIVE) != 0u) return float3(0.0);
    return gbuffer_emission_target.Load(int3(p, 0)).rgb;
}
#endif

// The point of a pixel as the lights see it, with its layers.
Shading gbuffer_shading(Gbuffer_Pixel g, Pixel pixel) {
    Shading s = shading_surface(pixel.position, g.normal, -pixel.view, g.base_color, g.metallic, g.roughness, g.f0, g.f90);
    shading_layers(s, g.layers, g.metallic);
    return s;
}

#endif
