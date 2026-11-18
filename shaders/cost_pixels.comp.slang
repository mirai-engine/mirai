#include "native.slang"
// The pixels of the visibility target of a view each mesh and each material
// owns (cost.slang), from the visible clusters the cull listed: a thread a
// pixel, and of the lanes of a wave that show the same row, one adds them
// all. Only the frame of a request runs it, after the last round of the view.
#include "visibility.slang"
#include "cost.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

struct Params_Block { uint capacity; uint pad0; uint pad1; uint pad2; }; // of the visible list
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<Visible_Cluster> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<uint> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

// Each lane adds one pixel to its row (INVALID: none), the lanes of a row at once.
void pixels_add(uint row) {
    bool pending = row != INVALID;
    while (pending) {
        uint lead = WaveReadLaneFirst(row);
        if (row == lead) {
            uint lanes = WaveActiveCountBits(true);
            if (WaveIsFirstLane()) cost_row_add(lead, COST_PIXELS, lanes);
            pending = false;
        }
    }
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint mesh = INVALID, material = INVALID;
    if (all(float2(dispatch_id.xy) < frame.resolution)) {
        uint id = visibility.Load(int3(int2(dispatch_id.xy), 0));
        uint entry = id != 0u ? visibility_entry(id) : INVALID;
        if (entry < params.capacity) {
            Visible_Cluster v = visible[entry];
            mesh = cost_mesh_row(cost_instance_mesh(v.instance));
            material = cost_material_row(v.material);
        }
    }
    pixels_add(mesh);
    pixels_add(material);
}
