#include "native.slang"
// The draw of each blended instance of a view, in the order the view draws
// them (render.translucent_draws_record), as rhi.Draw_Indexed_Indirect over
// the meshes drawn whole: the levels its cut can take (instance_clusters),
// whose vertices gbuffer.vert takes or collapses one by one, or nothing where
// the depth pyramid of this frame hides its box or its mesh is not listed.
//
// And of each drawn, the lights its points take, decided once for a cell of
// the world with every normal (light_cells.slang): the list of the lights
// that cast no shadows in a block of out_lists and the cut of those with
// shadows in cuts, a block each. The cell is its box, its block that of its
// entry; one whose box reaches more than a block holds is split into cells
// along its sides, whose blocks come from the TRANSLUCENT_CELLS of the view
// after those of the entries and are listed by the second pass (cells), a
// thread each. translucent.frag finds the cells of an instance in entries.
//! constant cells MIRAI_TRANSLUCENT_CELLS
#define LIGHT_LISTS_WRITTEN
#include "cut.slang"
#include "pyramid.slang"
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

// cells: the first block of the cells, after those of the entries; split: the
// second pass runs, and those that reach more than a block holds are split.
struct Params_Block { uint count; uint hiz_levels; uint occlusion; uint cells; uint split; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The instance of each entry, in the order the view draws them.
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint> drawn : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> hiz : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] RWStructuredBuffer<uint> draws : register(MIRAI_REGISTER(u, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("r32ui")]] RWTexture2D<uint> out_lists : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// Of each block, TRANSLUCENT_CUT_WORDS: how many nodes, or LIGHT_LIST_WALK, then the nodes.
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> cuts : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
// Of each instance of the scene, the cells it was drawn with last
// (translucent_cells_word): its first block and how many cells along each side.
[[vk::binding(SLOT_PASS5, 0)]] RWStructuredBuffer<uint2> entries : register(MIRAI_REGISTER(u, SLOT_PASS5), space0);
// The cells handed to the second pass, the first word counting them: each the entry and the cell in it.
[[vk::binding(SLOT_PASS6, 0)]] RWStructuredBuffer<uint2> cell_jobs : register(MIRAI_REGISTER(u, SLOT_PASS6), space0);
#include "light_cells.slang"

// Lists the lights of the cell of the thread in `block`; false where either
// takes more than a block holds.
bool block_lights(uint block) {
    cell.middle = 0.5 * (cell.low + cell.high);
    cell.radius = 0.5 * length(cell.high - cell.low);
    uint listed;
    bool fits = frame.shadowless_lights == 0u || cell_list(light_list_block(block), listed);
    uint count;
    uint first = block * TRANSLUCENT_CUT_WORDS;
    bool cut = cell_cut(LIGHT_CUT_MAX, count);
    cuts[first] = cut ? count : LIGHT_LIST_WALK;
    if (cut) {
        for (uint i = 0u; i < count; i++) cuts[first + 1u + i] = cell_cut_nodes[i];
    }
    return fits && cut;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    if (MIRAI_TRANSLUCENT_CELLS) {
        uint j = dispatch_id.x;
        if (j >= min(cell_jobs[0].x, TRANSLUCENT_CELLS)) return;
        uint2 job = cell_jobs[1u + j];
        uint index = drawn[job.x];
        Instance inst = scene_instance(index);
        uint3 sides = translucent_cells_sides(entries[index].y);
        uint3 at = uint3(job.y % sides.x, (job.y / sides.x) % sides.y, job.y / (sides.x * sides.y));
        float3 extent = inst.bounds_max.xyz - inst.bounds_min.xyz;
        // Loose by a little past its sides: a point on the border of two cells is in either.
        float3 loose = extent * 1e-3 + 1e-4;
        cell.low = inst.bounds_min.xyz + extent * float3(at) / float3(sides) - loose;
        cell.high = inst.bounds_min.xyz + extent * float3(at + 1u) / float3(sides) + loose;
        cell.normal_low = float3(-1.0);
        cell.normal_high = float3(1.0);
        block_lights(params.cells + j);
        return;
    }
    uint k = dispatch_id.x;
    if (k >= params.count) return;
    uint index = drawn[k];
    Instance inst = scene_instance(index);
    Mesh mesh = meshes[instance_mesh(inst)];
    bool hidden = params.occlusion != 0u && pyramid_hides(hiz, params.hiz_levels, inst.bounds_min.xyz, inst.bounds_max.xyz,
        frame.view_proj_unjittered, frame.camera_position.xyz, frame.depth_plane);
    uint2 clusters = instance_clusters(view_detail(), inst, mesh);
    bool shown = !hidden && mesh.draw_first != INVALID;
    uint at = k * 5u;
    draws[at] = shown ? clusters.y * CLUSTER_DRAW_VERTICES : 0u;
    draws[at + 1u] = 1u;
    draws[at + 2u] = shown ? mesh.draw_first + clusters.x * CLUSTER_DRAW_VERTICES : 0u;
    draws[at + 3u] = 0u;
    draws[at + 4u] = index;
    entries[index] = uint2(k, translucent_cells_word(uint3(1u)));
    if (!shown) return;
    cell.low = inst.bounds_min.xyz;
    cell.high = inst.bounds_max.xyz;
    cell.normal_low = float3(-1.0);
    cell.normal_high = float3(1.0);
    if (block_lights(k) || params.split == 0u) return;
    // Split along each side by its share of the longest, which takes TRANSLUCENT_CELL_SPLIT.
    float3 extent = inst.bounds_max.xyz - inst.bounds_min.xyz;
    float longest = max(extent.x, max(extent.y, extent.z));
    if (!(longest > 0.0)) return;
    uint3 sides = uint3(clamp(ceil(float(TRANSLUCENT_CELL_SPLIT) * extent / longest), 1.0, float(TRANSLUCENT_CELL_SPLIT)));
    uint count = sides.x * sides.y * sides.z;
    uint first;
    InterlockedAdd(cell_jobs[0].x, count, first);
    if (first + count > TRANSLUCENT_CELLS) return;
    for (uint i = 0u; i < count; i++) cell_jobs[1u + first + i] = uint2(k, i);
    entries[index] = uint2(params.cells + first, translucent_cells_word(sides));
}
