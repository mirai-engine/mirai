#include "native.slang"
#include "particles.slang"
#include "media_grid.slang"

struct Params_Block { uint volume; uint pass; uint2 pad; Media_Grid media; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("vertex")]
float4 main(uint vertex_id : SV_VulkanVertexID) : SV_Position {
    Particle_Grid_Row grid = particle_grid_row_at(particle_volume_at(params.volume).grid);
    uint face = vertex_id / 6u, corner = vertex_id % 6u;
    uint axis = face / 2u, u = (axis + 1u) % 3u, v = (axis + 2u) % 3u;
    float3 cube = float3(0.0);
    cube[axis] = float(face & 1u);
    cube[u] = float(corner == 1u || corner == 3u || corner == 4u);
    cube[v] = float(corner >= 2u && corner != 3u);
    if ((face & 1u) == 0u) cube[u] = 1.0 - cube[u];
    float4 clip = view_clip(grid.corner + cube * float3(grid.cells) * grid.cell_size);
    // The fragment clips the march at the scene and glass depths.
    clip.z = clip.w;
    return clip;
}
