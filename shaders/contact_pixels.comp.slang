#include "native.slang"
// The light of the probe volume at each pixel from the points of contact.comp
// and contact_light.comp around it on its surface, on its side of the opening of a nested view: the
// contact occlusion over the 4x4 points around it, which hold each turn of
// their pattern once, and the light over the 2x2 nearest, as a bilinear
// filter, or over the 4x4 where none of those is on it; a pixel with no point
// of its surface around (a wire thinner than a point) takes the light of the
// nearest point. It leaves the irradiance by its contact occlusion and the light around the
// specular lobe, packed (light_pack), for the composition.
#include "lighting.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// scale: the pixels across a point, 1 or 2.
struct Params_Block { uint scale; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
#define GBUFFER_NORMAL SLOT_PASS0
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
// What contact.comp and contact_light.comp left at each point.
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> contact_in : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> irradiance_in : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> specular_in : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
// x: the irradiance by the contact occlusion; y: the light around the specular lobe.
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rg32f")]] RWTexture2D<float2> out_indirect : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

// The points a group of pixels takes, from the first of the 4x4 around its
// first pixel: the position of each and on which side of the opening of a
// nested view it is (0: none there), its normal and contact occlusion, and its
// irradiance and specular light.
#define CONTACT_TILE 11
groupshared float4 tile_points[CONTACT_TILE * CONTACT_TILE];
groupshared float4 tile_normals[CONTACT_TILE * CONTACT_TILE];
groupshared float3 tile_irradiance[CONTACT_TILE * CONTACT_TILE];
groupshared float3 tile_specular[CONTACT_TILE * CONTACT_TILE];
int2 contact_first(int2 p, int scale) { return scale == 1 ? p - 2 : (p - 3) >> 1; }

// How much a point of the tile weighs for a pixel at `position` with normal
// `n`, `apart` pixels away, where a pixel is `width` metres wide: 0 off its
// surface or on the other side of the opening of a nested view.
float contact_weight(int i, float3 position, float3 n, float depth, float width, int2 apart) {
    float4 point = tile_points[i];
    if (point.w == 0.0 || !depth_same_side(point.w, depth)) return 0.0;
    float facing = dot(tile_normals[i].xyz, n);
    if (facing < 0.5) return 0.0;
    float facing2 = facing * facing;
    facing2 *= facing2;
    return exp(-abs(dot(point.xyz - position, n)) / (width * float(max(apart.x, apart.y) + 1))) * facing2 * facing2;
}

float2 contact_pixel(int2 p, float depth, int2 corner, int tile, int scale) {
    float3 position = pixel_at(p, (float2(p) + 0.5) * frame.inv_resolution, depth).position;
    float3 n = gbuffer_normal(p);
    float width = frame.footprint.x + frame.footprint.y * depth_distance(depth);
    int2 first = contact_first(p, scale);
    float contact = 0.0, weights = 0.0;
    [loop]
    for (int y = 0; y < 4; y++) {
        [loop]
        for (int x = 0; x < 4; x++) {
            int2 q = first + int2(x, y);
            int i = (q.x - corner.x) + (q.y - corner.y) * tile;
            float w = contact_weight(i, position, n, depth, width, abs(q * scale - p));
            contact += tile_normals[i].w * w;
            weights += w;
        }
    }
    contact = weights > 0.0 ? contact / weights : 1.0;
    // The light bilinearly from the 2x2 points around, a point on the pixel of each.
    int2 low = p / scale;
    float2 f = float2(p - low * scale) / float(scale);
    float3 irradiance = float3(0.0), specular = float3(0.0);
    float near = 0.0;
    for (uint k = 0u; k < 4u; k++) {
        int2 o = int2(int(k & 1u), int(k >> 1u));
        float b = (o.x != 0 ? f.x : 1.0 - f.x) * (o.y != 0 ? f.y : 1.0 - f.y);
        if (b <= 0.0) continue;
        int2 q = low + o;
        int i = (q.x - corner.x) + (q.y - corner.y) * tile;
        b *= contact_weight(i, position, n, depth, width, abs(q * scale - p));
        irradiance += tile_irradiance[i] * b;
        specular += tile_specular[i] * b;
        near += b;
    }
    // Else from the 4x4 points around of its surface, or the nearest of any.
    if (near <= 0.0) {
        int nearest = -1;
        int best = 1 << 20;
        [loop]
        for (int y = 0; y < 4; y++) {
            for (int x = 0; x < 4; x++) {
                int2 q = first + int2(x, y);
                int i = (q.x - corner.x) + (q.y - corner.y) * tile;
                int2 apart = abs(q * scale - p);
                float w = contact_weight(i, position, n, depth, width, apart);
                irradiance += tile_irradiance[i] * w;
                specular += tile_specular[i] * w;
                near += w;
                if (tile_points[i].w != 0.0 && apart.x + apart.y < best) {
                    best = apart.x + apart.y;
                    nearest = i;
                }
            }
        }
        if (near <= 0.0 && nearest >= 0) {
            irradiance = tile_irradiance[nearest];
            specular = tile_specular[nearest];
            near = 1.0;
        }
    }
    near = max(near, 1e-20);
    return float2(light_pack(irradiance / near * contact), light_pack(specular / near));
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID, uint index : SV_GroupIndex) {
    int2 at = int2(group.xy) * int2(MIRAI_GROUP_X, MIRAI_GROUP_Y) + int2(local.xy);
    int scale = int(params.scale);
    int2 points = (int2(frame.resolution) + scale - 1) / scale;
    // 8 pixels take 11 points with a point for each, and 8 with one for each 2x2.
    int tile = scale == 1 ? CONTACT_TILE : 8;
    int2 corner = contact_first(int2(group.xy) * int2(MIRAI_GROUP_X, MIRAI_GROUP_Y), scale);
    for (uint i = index; i < uint(tile * tile); i += uint(MIRAI_GROUP_X * MIRAI_GROUP_Y)) {
        int2 q = corner + int2(int(i % uint(tile)), int(i / uint(tile)));
        float4 point = float4(0.0), normal = float4(0.0);
        float3 irradiance = float3(0.0), specular = float3(0.0);
        if (all(q >= 0) && all(q < points)) {
            int2 source = q * scale;
            float d = g_depth.Load(int3(source, 0)).r;
            if (!depth_empty(d)) {
                point = float4(pixel_at(source, (float2(source) + 0.5) * frame.inv_resolution, d).position, d < 0.0 ? -1.0 : 1.0);
                normal = float4(gbuffer_normal(source), contact_in.Load(int3(q, 0)).r);
                irradiance = irradiance_in.Load(int3(q, 0)).rgb;
                specular = specular_in.Load(int3(q, 0)).rgb;
            }
        }
        tile_points[i] = point;
        tile_normals[i] = normal;
        tile_irradiance[i] = irradiance;
        tile_specular[i] = specular;
    }
    GroupMemoryBarrierWithGroupSync();
    if (any(at >= int2(frame.resolution))) return;
    float depth = g_depth.Load(int3(at, 0)).r;
    out_indirect[at] = depth_empty(depth) ? float2(0.0) : contact_pixel(at, depth, corner, tile, scale);
}
