#include "native.slang"
// Marks the probes a change of the light reaches (a light that moved,
// switched or changed, an object that moved or changed its glow): spheres
// (center, radius) that the scene listed since the volume last looked. A
// probe sees the surfaces of its cell and the next, so a sphere reaches the
// probes within its radius and two cells, and keeps them awake for
// params.awake frames: traced while what their rays read settles. It keeps
// how near it is to the nearest change (Probe.offset.w: 1 at its center, 0
// where it stops reaching), and ddgi_select.comp traces the nearest first:
// what a change changes most is near it.
#define PROBES_WRITABLE
#include "scene.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint count; uint frame_number; uint total; uint awake; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<float4> changes : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint index = dispatch_id.x;
    if (index >= params.total) return;
    uint cascade;
    int3 cell = probe_slot_cell(index, cascade);
    float spacing = probe_spacing(cascade);
    float3 position = probe_cell_position(cascade, cell);
    float nearness = 0.0;
    for (uint i = 0u; i < params.count; i++) {
        float4 change = changes[i];
        float reach = change.w + 2.0 * spacing;
        nearness = max(nearness, 1.0 - length(position - change.xyz) / reach);
    }
    if (!(nearness > 0.0)) return;
    // Near a change it woke before, it keeps the nearer.
    Probe probe = probes[index];
    bool awake = probe.frames.z > params.frame_number;
    probes[index].offset.w = awake ? max(probe.offset.w, nearness) : nearness;
    probes[index].frames.z = max(probe.frames.z, params.frame_number + params.awake);
}
