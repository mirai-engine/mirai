// A quad facing the eye a far instance of foliage is drawn on, one for each
// instance the cull kept, and what its fragments need: the three frames of
// its type to blend, and how much of it shows where its mesh fades out and
// where it fades out itself.
#include "foliage_impostor.slang"

static const float2 IMPOSTOR_CORNERS[6] = {float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)};

[[vk::binding(SLOT_PASS1, 0)]] StructuredBuffer<uint> impostor_visible : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);

[shader("vertex")]
Impostor_Varyings main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Impostor_Varyings o = (Impostor_Varyings)0;
    o.position = float4(2.0, 2.0, 2.0, 1.0);
    Impostor_Instance inst = impostor_instances[impostor_visible[instance_id]];
    uint row_index = impostor_row_index(inst.row);
    Impostor_Row row = impostor_rows[row_index];
    Impostor_Shape s;
    if (!impostor_shape(inst, row, s)) return o;
    // Toward the eye, or against the direction a parallel view looks along.
    bool point = frame.eye.w > 0.5;
    float3 toward = point ? frame.eye.xyz - s.center : frame.eye.xyz;
    float distance = length(toward);
    toward = distance > 1e-6 ? toward / distance : float3(0.0, 1.0, 0.0);
    float3 right, up;
    impostor_axes(toward, right, up);
    // The quad through the centre holds the outline of the sphere seen from the eye.
    float radius = s.radius;
    float reach = point ? radius * distance / sqrt(max(distance * distance - radius * radius, 1e-4 * radius * radius)) : radius;
    float2 corner = IMPOSTOR_CORNERS[vertex_id % 6u];
    float3 placed = s.center + (right * corner.x + up * corner.y) * reach;
    o.position = view_clip(placed);
    o.local = transform_point(s.inverse, placed);
    o.eye = point ? float4(transform_point(s.inverse, frame.eye.xyz), 1.0) : float4(normalize(transform_vector(s.inverse, -frame.eye.xyz)), 0.0);
    // The three frames around the direction it is seen from: the triangle of
    // the cell of the grid that holds it, with its barycentric weights.
    uint n = max(row.frames.w & 0xffffu, 2u);
    float2 g = (impostor_fold(normalize(transform_vector(s.inverse, toward))) * 0.5 + 0.5) * float(n - 1u);
    float2 cell = clamp(floor(g), 0.0, float(n - 2u));
    float2 f = saturate(g - cell);
    uint2 base = uint2(cell);
    uint3 frames;
    float3 weights;
    if (f.x + f.y < 1.0) {
        frames = uint3(base.x | base.y << 16u, (base.x + 1u) | base.y << 16u, base.x | (base.y + 1u) << 16u);
        weights = float3(1.0 - f.x - f.y, f.x, f.y);
    } else {
        frames = uint3((base.x + 1u) | (base.y + 1u) << 16u, base.x | (base.y + 1u) << 16u, (base.x + 1u) | base.y << 16u);
        weights = float3(f.x + f.y - 1.0, 1.0 - f.x, 1.0 - f.y);
    }
    // The level of the textures whose texel is the size of a pixel there.
    float pixel = frame.footprint.x + frame.footprint.y * max(distance - radius, 0.0);
    float texel = 2.0 * radius / float(max(row.frames.w >> 16u, 1u));
    o.frames = uint4(frames, row_index);
    o.weights = float4(weights, log2(max(pixel / max(texel, 1e-6), 1.0)));
    o.fades = float2(s.appear, s.gone);
    o.world0 = s.world[0];
    o.world1 = s.world[1];
    o.world2 = s.world[2];
    o.color = inst.color;
    return o;
}
