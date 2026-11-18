#include "native.slang"
//! per surface program
//! variant hw MIRAI_HW_RT=1
#include "raster.slang"
#include "lighting.slang"
#include <extension_hooks.slang>

struct Overlay_Params { uint overlay_material; uint blend; uint light_budget; uint pad; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Overlay_Params> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

struct Stage_Output { [[vk::location(0)]] float4 out_color : SV_Target0; };
[shader("fragment")]
Stage_Output main(Raster_Input input, float4 pixel_position : SV_Position) {
    Stage_Output output;
    Material base = fragment_material(input);
    if (base.alpha_mode == ALPHA_BLEND || !fragment_mask_covers(input, frame.texturing.x)) discard;
    Material overlay = material_row(params.overlay_material);
    float3 view = to_eye(input.in_world);
    float3 normal = fragment_surface_normal(input, overlay, view, frame.texturing.x);
    float3 vertex_normal = normalize(input.in_normal);
    float4 tangent = input.in_tangent;
    if (dot(vertex_normal, view) < 0.0) {
        vertex_normal = -vertex_normal;
        tangent = -tangent;
    }
    Material_Sample values = material_sample(overlay, fragment_footprint(fragment_instance(material_context(input.in_world, normal, vertex_normal, tangent, input.in_uv, input.in_uv1, float2(frame.texturing.x), false), input), input), float3(1), float3(0), normal);
    if (overlay.program_id != 0u) normal = fragment_facing(normal, view);
    if (overlay.alpha_mode == ALPHA_MASK && values.alpha < overlay.alpha_cutoff) discard;
    float alpha = saturate(values.alpha);
    // Multiply filters what is under it by the color of its surface, whatever light reaches it.
    if (params.blend == 2u) {
        output.out_color = float4(lerp(float3(1), values.base_color, alpha), alpha);
        return output;
    }
    Shading surface = shading_surface(input.in_world, normal, view, values.base_color, values.metallic, values.roughness, values.f0, values.f90);
    shading_layers(surface, values.layers, values.metallic);
    float bias = view_bias(eye_distance(input.in_world));
    float3 color = direct_lighting(surface, bias, params.light_budget);
    // Indirect light as composite.comp gives it to the surface under the layer;
    // a layer has no traced reflection, so the probes answer for all of its lobe.
    Indirect light = indirect_lobes(input.in_world, normal, view, surface, INDIRECT_DIFFUSE | INDIRECT_SPECULAR | (surface.coat > 0.0 ? INDIRECT_COAT : 0u), values.occlusion);
    color += indirect_compose(surface, light);
    color = finite_or_zero(color + emission_render_units(sample_emission(values, dot(values.layers.coat_normal, view)), values.emission_relative));
    if (params.blend == 1u) color *= alpha;
    output.out_color = float4(color, alpha);
    return output;
}
