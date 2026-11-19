#include "native.slang"
// The squares of the pages of the pool a round of the maps of the shadows
// draws (shadow_maps.slang), before the raster of its clusters
// (vis_raster.vert shadow): of each word of a list of the buffer of the pages
// from params.list, its page of the pool (with SHADOW_JOB_HELD where the
// cache holds it this frame), for shadow_map.frag to clear or copy: the part
// of it the round draws (shadow_page_part), or its tile in the layer of what
// sways, which lies where the page lies in the pool, scaled; of the atlas
// (params.moving 1), none of a page that waits, which keeps what it last
// composed.
#include "shadow_maps.slang"
#define SHADOW_PAGES_SLOT SLOT_PASS3
#include "shadow_cull.slang"

struct Shadow_Vertex {
    float4 position : SV_Position;
    // 1 where the page of the atlas takes that of the cache, 0 where the cache
    // holds nothing of it this frame and it is cleared.
    [[vk::location(0)]] nointerpolation float held : HELD;
};

[shader("vertex")]
Shadow_Vertex main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Shadow_Vertex output;
    output.position = float4(2.0, 2.0, 2.0, 1.0);
    output.held = 0.0;
    if (vertex_id >= 6u) return output;
    float2 at = float2(vertex_id == 1u || vertex_id >= 4u ? 1.0 : 0.0, vertex_id == 2u || vertex_id == 3u || vertex_id == 5u ? 0.0 : 1.0);
    uint word = shadow_pages[params.list + instance_id];
    if (params.moving == 1u && (word & SHADOW_ENTRY_POOL) < SHADOW_POOL_PAGES && (shadow_pages[shadow_cost_word(word & SHADOW_ENTRY_POOL)] & SHADOW_COST_WAITS) != 0u) return output;
    uint2 corner = shadow_pool_corner(word & SHADOW_ENTRY_POOL);
    output.held = (word & SHADOW_JOB_HELD) != 0u ? 1.0 : 0.0;
    uint4 part = shadow_page_part(word & SHADOW_ENTRY_POOL);
    float4 rect = float4(float2(corner + part.xy), float2(corner + part.zw));
    float2 texel = lerp(rect.xy, rect.zw, at);
    output.position = float4(2.0 * texel.x / float(SHADOW_POOL) - 1.0, 1.0 - 2.0 * texel.y / float(frame.sun_maps.z), 0.0, 1.0);
    return output;
}
