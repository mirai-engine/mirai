#include "native.slang"
// The depth of the Surface program of each pixel of the visibility target
// (visibility_program_depth; 0 for a material without one): the resolve of
// each program draws where this depth is its own, so the pixels of the others
// are rejected before its fragments run. A pixel without a triangle keeps the
// depth the pass clears to, which no program has.
#include "visibility.slang"

// programs: the Surface programs the renderer has, plus one; a program past them resolves as its row.
struct Params_Block { uint programs; uint pad0; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] StructuredBuffer<uint2> visible : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<uint> visibility : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

[shader("fragment")]
float main(float4 pixel : SV_Position) : SV_Depth {
    uint id = visibility.Load(int3(int2(pixel.xy), 0));
    if (id == 0u) discard;
    uint2 entry = visible[visibility_entry(id)];
    Instance inst = scene_instance(entry.x);
    Mesh mesh = meshes[instance_mesh(inst)];
    uint program = materials[material_of(inst, cluster_material(mesh, cluster_at(entry.y)))].shared.program_id;
    return visibility_program_depth(program < params.programs ? program : 0u);
}
