#include "native.slang"
// The visibility of a view (visibility.vert): of each pixel the nearest
// triangle, as its instance and its primitive (geometry.slang), which
// gbuffer_visible.frag draws, and its linear depth, which the depth pyramid
// between the phases reads. The fade of its instance and the mask of its
// material leave it where gbuffer.frag would: the mask as the rasterizer
// samples it, from the triangle at the pixel (visible_input.slang).
#define MATERIAL_GRADIENTS
#include "raster.slang"
#include "visible_input.slang"
#include "trace.slang"

struct Stage_Input {
    [[vk::location(0)]] nointerpolation uint3 in_ids : TEXCOORD0;
    [[vk::location(1)]] float3 in_bary_depth : TEXCOORD1;
};
struct Stage_Output {
    // The instance and the primitive; INVALID where none is.
    [[vk::location(0)]] uint2 hit : SV_Target0;
    [[vk::location(1)]] float depth : SV_Target1;
};

[shader("fragment")]
Stage_Output main(Stage_Input input, float4 pixel_position : SV_Position) {
    uint index = input.in_ids.x;
    Instance inst = scene_instance(index);
    // The fade of gbuffer.vert, in its steps.
    float fade = view_body_fade(inst.meta.w);
    if (instance_batched(index)) fade = max(fade, batch_faded(batch_row(batch_of(index)), inst.bounds_min.xyz, inst.bounds_max.xyz));
    if (fade > 0.0 && fade_pixel_left(uint2(pixel_position.xy), float(uint(saturate(fade) * 65535.0 + 0.5)) / 65535.0)) discard;
    Mesh mesh = meshes[instance_mesh(inst)];
    uint primitive = (((input.in_ids.y - mesh.cluster_word) / CLUSTER_WORDS) << PRIMITIVE_TRIANGLE_BITS) | input.in_ids.z;
    if ((inst.meta.w & INSTANCE_FLAG_ALPHA_TESTED) != 0u) {
        Material m = material_row(material_of(inst, mesh_primitive_material(mesh, primitive)), inst.material_values);
        if (m.alpha_mode != ALPHA_OPAQUE) {
            // A program is evaluated by its own stages alone (it is here only
            // before the program list is made): its mask as a ray reads it.
            bool covered = m.program_id != 0u ? hit_covers(index, primitive, input.in_bary_depth.xy, input.in_bary_depth.z, BLEND_PASSES) : fragment_mask_covers(visible_input(index, primitive, pixel_position.xy), frame.texturing.x);
            if (!covered) discard;
        }
    }
    Stage_Output output;
    output.hit = uint2(index, primitive);
    output.depth = input.in_bary_depth.z;
    return output;
}
