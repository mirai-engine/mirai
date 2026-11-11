//! mirai needs nested_views
#include "native.slang"
// The fog over the lit image (fog.fog_record): what lies behind it dimmed by
// what it lets through, and the light it turns towards the eye added, read
// from the grid and the slices past it at the depth of each pixel. What
// nothing was drawn on takes them all, to the end of the view. What lies in
// volumes that take the light of the sun is dimmed first by how much of it
// reaches it. With glass in view it runs on each side of the nearest layer:
// behind it, over the opaque scene, the fog from the layer on, which the glass
// lets through; in front, over the lit glass, the fog from the eye to it.
#define FOG_VOLUMES_SLOT SLOT_PASS3
#include "fog_volumes.slang"
#include "depth.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> image : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture3D<float4> seen : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> glass_depth : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);

// Below this share of the light let through from the eye to the glass, the
// fog behind it is laid as if this much were: what is behind is not seen.
#define FOG_FRONT_LEAST 1e-3
// Of what an rgba16f image holds.
#define FOG_IMAGE_MOST 65000.0

float4 fog_seen_at(float2 uv, float depth, bool empty) { return media_seen(seen, fog_grid(), uv, depth, empty); }

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(frame.resolution))) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    float layer = fog.side != FOG_SIDE_ALL ? glass_depth.Load(int3(p, 0)).r : 0.0;
    float4 color = image[p];
    if (fog.side == FOG_SIDE_FRONT) {
        if (!(layer > 0.0)) return;
        float4 front = fog_seen_at(uv, layer, false);
        image[p] = float4(color.rgb * front.a + front.rgb, color.a);
        return;
    }
    float depth = linear_depth.Load(int3(p, 0)).r;
    float4 fog_seen = fog_seen_at(uv, depth_distance(depth), depth_empty(depth));
    if (layer > 0.0) {
        // What lies from the eye to the glass goes over it: of the fog to the depth, the part past it.
        float4 front = fog_seen_at(uv, layer, false);
        float through = 1.0 / max(front.a, FOG_FRONT_LEAST);
        fog_seen = float4(max(fog_seen.rgb - front.rgb, 0.0) * through, min(fog_seen.a * through, 1.0));
    }
    if (fog.shade != 0u && !depth_empty(depth)) {
        float3 position = position_from_depth(uv, depth_distance(depth));
        color.rgb *= fog_shade(position, frame.sun_direction.w > 0.5 ? frame.sun_direction.xyz : float3(0.0, 1.0, 0.0), fog_dry_at(position));
    }
    image[p] = float4(min(color.rgb * fog_seen.a + fog_seen.rgb, FOG_IMAGE_MOST), color.a);
}
