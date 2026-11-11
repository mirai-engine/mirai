#include "native.slang"
// The modes of inspection that show what other passes left (render/debug_views.odin),
// over the display target composite wrote: the share of light the shadows of
// the sun and the blocks of shadows of the other lights let through, the traced reflections after and before their filter
// and how many local lights reach each pixel. A mode the frame cannot show
// leaves the view black.
#include "lighting.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block {
    uint mode;
    uint available;
    uint lights_scale;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0); // the buffer of the mode
#define GBUFFER_NORMAL SLOT_PASS1
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_display : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);

// From dark blue through green and yellow to red as x goes from 0 to 1.
float3 heat(float x) {
    x = saturate(x);
    return saturate(float3(1.5 - abs(4.0 * x - 3.0), 1.5 - abs(4.0 * x - 2.0), 1.5 - abs(4.0 * x - 1.0)));
}

// The local lights of the tree from root whose light reaches a point and is
// above the horizon of its surface, up to `cap`.
uint lights_reaching(float3 position, float3 normal, uint root, uint cap) {
    uint pending[LIGHT_TREE_DEPTH];
    uint depth = 0u;
    uint at = root;
    uint count = 0u;
    [loop]
    while (frame.light_nodes > 0u) {
        Light_Node node = light_nodes[at];
        float distance_squared;
        if (node_reaches(node, position, normal, distance_squared)) {
            if ((node.flags & LIGHT_NODE_LEAF) != 0u) {
                float3 direction;
                float distance;
                if (luminance(light_contribution(lights[node.child], position, normal, direction, distance)) > 0.0) count++;
                if (count >= cap) break;
            } else if (depth < LIGHT_TREE_DEPTH && light_node_opens(node, at)) {
                pending[depth] = node.child;
                depth++;
                at++;
                continue;
            }
        }
        if (depth == 0u) break;
        depth--;
        at = pending[depth];
    }
    return count;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    if (any(p >= int2(frame.resolution))) return;
    if (params.available == 0u) { out_display[p] = float4(0.0, 0.0, 0.0, 1.0); return; }
    float depth = g_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth)) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    float3 color = out_display[p].rgb;
    switch (params.mode) {
    // The part of the light with nothing in the way that got there (direct_samples.comp).
    case DEBUG_SHADOWS: {
        uint width, height;
        source.GetDimensions(width, height);
        float part = source.Load(int3(p * int2(width, height) / int2(frame.resolution), 0)).a;
        color = float3(part >= 1.5 ? part - 2.0 : part);
        break;
    }
    case DEBUG_REFLECTIONS: case DEBUG_REFLECTIONS_RAW: color = source.Load(int3(p, 0)).rgb; break;
    case DEBUG_LIGHTS: {
        Pixel pixel = pixel_at(p, uv, depth);
        float3 normal = gbuffer_normal(p);
        uint count = lights_reaching(pixel.position, normal, 0u, params.lights_scale);
        if (frame.shadowless_lights.x != 0u && count < params.lights_scale) count += lights_reaching(pixel.position, normal, frame.shadowless_lights.x, params.lights_scale - count);
        color = count == 0u ? float3(0.03) : heat(float(count) / float(params.lights_scale));
        break;
    }
    default: break;
    }
    out_display[p] = float4(finite_or_zero(color), 1.0);
}
