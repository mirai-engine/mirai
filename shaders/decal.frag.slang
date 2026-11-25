#include "native.slang"
//! per surface program decal
// What a decal changes of the surface under it (render/decals.odin), into the
// decal targets of the view before the resolve applies them (decal_buffer.slang):
// its material is evaluated and never lit. Each target blends premultiplied
// with the coverage (opacity times alpha) of what the decal writes there, and
// zero where it writes nothing (asset.Decal_Writes): its base color; the
// difference of its shading normal from its smooth normal; its roughness,
// metallic and occlusion; its emission, in render units.
//
// emissive: the view has the emission target, while a decal emits.
// quiet: off the feedback turn of the program, texture feedback is skipped.
//! variant emissive MIRAI_DECAL_EMISSIVE=1
//! constant quiet MIRAI_TEXTURE_FEEDBACK_QUIET
#define MIRAI_MATERIAL_NO_LAYERS true
#define MIRAI_TEXTURE_FEEDBACK
#include "raster.slang"

struct Stage_Output {
    [[vk::location(0)]] float4 color : SV_Target0;
    [[vk::location(1)]] float4 normal : SV_Target1;
    [[vk::location(2)]] float4 surface : SV_Target2;
#ifdef MIRAI_DECAL_EMISSIVE
    [[vk::location(3)]] float4 emission : SV_Target3;
#endif
};

[shader("fragment")]
[earlydepthstencil]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position, bool front_facing : SV_IsFrontFace) {
    input = raster_facing(input, front_facing);
    Instance inst = scene_instance(input.in_instance);
    Material material = material_row(input.in_material, inst.material_values);
    if (!material_decal(material) || material.two_sided == 0u && raster_back(input)) discard;
    float3 to_camera = to_eye(input.in_world);
    Fragment f = fragment_evaluate(input, material, inst, 0.0);
    float covered = saturate(f.values.alpha);
    if (!(covered > 0.0)) discard;
    uint writes = material_decal_writes(material);
    float3 smooth = normalize(input.in_normal);
    if (fragment_turned(input, to_camera)) smooth = -smooth;
    Stage_Output output = (Stage_Output)0;
    if ((writes & DECAL_WRITE_COLOR) != 0u) output.color = float4(saturate(f.values.base_color), 1.0) * covered;
    if ((writes & DECAL_WRITE_NORMAL) != 0u) output.normal = float4(f.normal - smooth, 1.0) * covered;
    if ((writes & DECAL_WRITE_SURFACE) != 0u) output.surface = float4(f.material_roughness, f.values.metallic, f.values.occlusion, 1.0) * covered;
#ifdef MIRAI_DECAL_EMISSIVE
    if ((writes & DECAL_WRITE_EMISSION) != 0u) output.emission = float4(finite_or_zero(f.values.emission), 1.0) * covered;
#endif
    return output;
}
