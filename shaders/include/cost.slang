// The count of a frame of a view by mesh and by material (render/cost.odin):
// the variants `cost` of the cull and the raster add to it where they count
// the totals of the frame (cull_stats.slang), and cost_pixels.comp the pixels
// of the visibility target. Its first words say how many rows of meshes and
// of materials it has (COST_FIRST_ROW); a row is COST_ROW_WORDS, a word for
// each count (COST_*), those of the meshes first. Only the frame of a request
// runs them.
#ifndef MIRAI_COST_SLANG
#define MIRAI_COST_SLANG
[[vk::binding(SLOT_PASS8, 0)]] RWStructuredBuffer<uint> cost : register(MIRAI_REGISTER(u, SLOT_PASS8), space0);

// The row of a mesh, and of a material; INVALID past those of the count.
uint cost_mesh_row(uint mesh) { return mesh < cost[0] ? mesh : INVALID; }
uint cost_material_row(uint material) { return material < cost[1] ? cost[0] + material : INVALID; }

void cost_row_add(uint row, uint field, uint value) {
    if (row != INVALID && value != 0u) InterlockedAdd(cost[COST_FIRST_ROW + row * COST_ROW_WORDS + field], value);
}

// The mesh of an instance of the scene or of a batch, without placing it.
uint cost_instance_mesh(uint index) { return instance_mesh(instance_batched(index) ? batch_row(batch_of(index)) : instances[index]); }

// Adds to a count of a mesh and of a material (INVALID: none).
void cost_add(uint mesh, uint material, uint field, uint value) {
    cost_row_add(cost_mesh_row(mesh), field, value);
    cost_row_add(cost_material_row(material), field, value);
}
#endif
