#include "native.slang"
// The depth of the opaque scene around the pixels of the probes of one view
// of the window (render.Depth_Probe), for the CPU: of each cell of the patch
// of a probe, the farthest metres along the view of its pixels, 0 where one
// of them shows nothing. A cell that leaves the view and a probe of another
// view are left as they are.
#include "common.slang"
#include "depth.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block {
    uint count;
    uint view;
    float2 scale;                          // render pixels per pixel of the drawable
    float4 pixels[DEPTH_PROBE_CAPACITY];   // x, y in pixels of the drawable from the corner of the view, z the view
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWStructuredBuffer<float> depths : register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint i = dispatch_id.z;
    uint2 cell = dispatch_id.xy;
    if (i >= params.count || i >= DEPTH_PROBE_CAPACITY || cell.x >= DEPTH_PROBE_CELLS || cell.y >= DEPTH_PROBE_CELLS) return;
    float4 probe = params.pixels[i];
    if (uint(probe.z) != params.view) return;
    int2 size = texture_size(linear_depth, 0);
    float2 low = probe.xy + (float2(cell) - DEPTH_PROBE_CELLS * 0.5) * DEPTH_PROBE_CELL;
    int2 first = int2(floor(low * params.scale));
    int2 last = max(int2(ceil((low + DEPTH_PROBE_CELL) * params.scale)), first + 1);
    if (any(first < 0) || any(last > size)) return;
    float farthest = 0.0;
    bool empty = false;
    for (int y = first.y; y < last.y; y++) {
        for (int x = first.x; x < last.x; x++) {
            float depth = linear_depth.Load(int3(x, y, 0)).r;
            if (depth_empty(depth)) empty = true;
            else farthest = max(farthest, depth_distance(depth));
        }
    }
    depths[(i * DEPTH_PROBE_CELLS + cell.y) * DEPTH_PROBE_CELLS + cell.x] = empty ? 0.0 : farthest;
}
