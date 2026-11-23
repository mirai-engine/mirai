// A material evaluated at a rasterized fragment: what the G-buffer and the
// translucent pass share. Fragment shaders only.
#ifndef MIRAI_RASTER_SLANG
#define MIRAI_RASTER_SLANG
#include "material_raster.slang"
#include "depth.slang"

struct Raster_Input {
    [[vk::location(0)]] float3 in_normal : TEXCOORD0;
    [[vk::location(1)]] float3 in_color : TEXCOORD1;
    [[vk::location(2)]] nointerpolation float3 in_emission : TEXCOORD2;
    [[vk::location(3)]] float4 in_clip : TEXCOORD3;
    [[vk::location(4)]] float4 in_prev_clip : TEXCOORD4;
    [[vk::location(5)]] float3 in_world : TEXCOORD5;
    [[vk::location(6)]] nointerpolation uint in_flags : TEXCOORD6;
    [[vk::location(7)]] float2 in_uv : TEXCOORD7;
    [[vk::location(8)]] nointerpolation uint in_material : TEXCOORD8;
    [[vk::location(9)]] nointerpolation uint in_instance : TEXCOORD9;
    [[vk::location(10)]] float2 in_uv1 : TEXCOORD10;
    [[vk::location(11)]] float4 in_tangent : TEXCOORD11; // xyz in the world, w the sign of the bitangent
    [[vk::location(12)]] nointerpolation uint in_surface : TEXCOORD12; // of a far mesh: its roughness and metallic
    [[vk::location(13)]] float4 in_vertex_color : TEXCOORD13; // of the mesh, as data for a program; in_color has it for the others
#ifdef MIRAI_VISIBILITY
    [[vk::location(14)]] nointerpolation uint in_first : TEXCOORD14; // the first triangle of the draw among those listed (raster_lists.slang)
#endif
};

float fragment_depth(Raster_Input input) { return dot(input.in_world - frame.camera_position.xyz, frame.camera_forward.xyz); }

// The input of a fragment with the side of its triangle it shows: a stage
// sets it before it evaluates the material. The winding of an instance that
// mirrors its mesh: the raster of the view and the resolve turn its triangles
// back; a draw by the list of its mesh says so in its flags (gbuffer.vert).
Raster_Input raster_facing(Raster_Input input, bool front) {
    if (front == ((input.in_flags & RASTER_FLAG_TURNED) != 0u)) input.in_flags |= RASTER_FLAG_BACK;
    return input;
}
bool raster_back(Raster_Input input) { return (input.in_flags & RASTER_FLAG_BACK) != 0u; }

// A shading normal that turns away from the viewer, as a map, a program or a
// smooth normal near a silhouette can leave it, is brought back to the silhouette.
float3 fragment_facing(float3 normal, float3 to_camera) {
    float facing = dot(normal, to_camera);
    return facing < 0.0 ? normalize(normal - to_camera * (facing - 1e-3)) : normal;
}

// Whether a surface shows its viewer the far side of its interpolated normal.
// The side is where that normal points, not how the triangle winds: a sheet
// seen from both sides whose model gives it normals of its own (the leaves
// and the grass that point up or around their plant) is lit by them on both
// of its faces.
bool fragment_turned(Raster_Input input, float3 to_camera) { return dot(input.in_normal, to_camera) < 0.0; }

// Programs see the same input normal in shading and coverage, including the
// far side of a surface and the material's independently transformed normal
// map. The normal map turns the frame of the near side, as its baker had it;
// the far side turns all of it around.
float3 fragment_surface_normal(Raster_Input input, Material material, float3 to_camera, float bias) {
    bool turned = fragment_turned(input, to_camera);
    if (material_has(material.textures[MATERIAL_MAP_NORMAL])) {
        float3 mapped = tangent_frame_normal(input.in_normal, input.in_tangent, material_map_normal(material, input.in_uv, input.in_uv1, float2(bias), false));
        return fragment_facing(turned ? -mapped : mapped, to_camera);
    }
    float3 n = normalize(input.in_normal);
    return turned ? -n : n;
}

// The footprint of a fragment in the world. A quad is of one primitive, so a
// branch on its material keeps the derivatives; a resolved one
// (MATERIAL_GRADIENTS) has those of its triangle.
Mirai_Surface_Context fragment_footprint(Mirai_Surface_Context ctx, Raster_Input input) {
#ifdef MATERIAL_GRADIENTS
    ctx.position_dx = material_world_gradients[0]; ctx.position_dy = material_world_gradients[1];
#else
    ctx.position_dx = ddx(input.in_world); ctx.position_dy = ddy(input.in_world);
#endif
    return ctx;
}

// The instance of a fragment and the color of its mesh there. The studio
// (MIRAI_RASTER_STUDIO) draws vertices of its own, without the instances of
// a scene.
Mirai_Surface_Context fragment_instance(Mirai_Surface_Context ctx, Raster_Input input) {
#ifdef MIRAI_RASTER_STUDIO
    ctx.vertex_color = input.in_vertex_color;
    return ctx;
#else
    return material_context_instance(ctx, input.in_instance, input.in_vertex_color);
#endif
}

// The material of a fragment, as its instance shows it.
Material fragment_material(Raster_Input input) {
#ifdef MIRAI_RASTER_STUDIO
    return material_row(input.in_material);
#else
    return material_row(input.in_material, material_values_of(input.in_instance));
#endif
}

// Coverage for object masks. Opaque geometry needs no texture fetch; masked
// surfaces are cut by their mask map as the scene is, and empty blend
// fragments contribute no selection silhouette.
bool fragment_mask_covers(Raster_Input input, float mip_bias) {
    Material material = fragment_material(input);
    if (material.alpha_mode == ALPHA_OPAQUE) return true;
    if (material.alpha_mode == ALPHA_MASK) return material_covers(material, material_mask(material, input.in_uv, input.in_uv1, float2(mip_bias), false));
    float alpha;
    if (material.program_id == 0u) {
        alpha = material_base_color(material, input.in_uv, input.in_uv1, float2(mip_bias), input.in_color, false).a;
    } else {
        float3 view = to_eye(input.in_world);
        float3 normal = fragment_surface_normal(input, material, view, mip_bias);
        alpha = material_alpha(material, fragment_footprint(fragment_instance(material_context(input.in_world, normal, input.in_uv, input.in_uv1, float2(mip_bias), false), input), input), input.in_color, input.in_emission);
    }
    return alpha > 0.001;
}

// Whether a surface at this linear depth is behind a glass layer (0: there is none).
bool behind_layer(float depth, float layer) { return layer > 0.0 && depth > layer * 1.0001 + 1e-4; }

bool fragment_blended(Raster_Input input, Material m) {
    return material_blended(m) && (!material_solid(m) || !raster_back(input));
}

bool fragment_forward(Raster_Input input, Material m, bool overflow) {
    return fragment_blended(input, m) && (m.transmission > 0.0) == overflow;
}

bool fragment_forward(Raster_Input input, Material m, float opaque, bool overflow) {
    return fragment_forward(input, m, overflow)
        && (depth_empty(opaque) || fragment_depth(input) < depth_distance(opaque));
}

struct Fragment {
    Material material;
    Material_Sample values;   // roughness widened by specular antialiasing, the coat's too
    float3 normal;            // shading normal, facing the viewer
    float3 to_camera;
    float material_roughness; // before that widening
};

// The context a material is evaluated with at a fragment, but for what its
// instance gives; normal: the input normal, under its normal map.
Mirai_Surface_Context fragment_surface_context(Raster_Input input, Material material, float3 to_camera, out float3 normal) {
    float bias = frame.texturing.x;
    normal = fragment_surface_normal(input, material, to_camera, bias);
    // The surface as it faces the viewer: its far side turns its whole frame around.
    float3 vertex_normal = normalize(input.in_normal);
    float4 tangent = input.in_tangent;
    if (fragment_turned(input, to_camera)) {
        vertex_normal = -vertex_normal;
        tangent = -tangent;
#ifdef MATERIAL_GRADIENTS
        // The derivatives of the normal turn with it (mirai_vertex_normal).
        material_normal_gradients[0] = -material_normal_gradients[0];
        material_normal_gradients[1] = -material_normal_gradients[1];
#endif
    }
    return material_context(input.in_world, normal, vertex_normal, tangent, input.in_uv, input.in_uv1, float2(bias), false);
}
Mirai_Surface_Context fragment_context(Raster_Input input, Material material, float3 to_camera, out float3 normal) {
    return fragment_footprint(fragment_instance(fragment_surface_context(input, material, to_camera, normal), input), input);
}
// The same of a fragment whose instance and material its stage decoded.
Mirai_Surface_Context fragment_context(Raster_Input input, Instance inst, Material material, float3 to_camera, out float3 normal) {
    return fragment_footprint(material_context_instance(fragment_surface_context(input, material, to_camera, normal), inst, input.in_vertex_color), input);
}

// The context of a point a pass draws over the opaque scene: the depth the
// G-buffer holds behind it.
Mirai_Surface_Context material_context_over(Mirai_Surface_Context ctx, float opaque) {
    if (!depth_empty(opaque)) ctx.scene_depth = depth_distance(opaque);
    return ctx;
}

// The material of a fragment in its context (fragment_context), where its
// normal is n.
Fragment fragment_evaluate(Raster_Input input, Material material, float3 to_camera, Mirai_Surface_Context ctx, float3 n) {
    Fragment f;
    f.to_camera = to_camera;
    f.material = material;
    f.values = material_sample(f.material, ctx, input.in_color, input.in_emission, n);
    material_surface_apply(f.values, f.material, input.in_surface);
    if (f.material.program_id != 0u) n = fragment_facing(n, f.to_camera);
    f.normal = n;
    f.values.emission = emission_render_units(sample_emission(f.values, dot(f.values.layers.coat_normal, f.to_camera)), f.values.emission_relative);
    f.material_roughness = f.values.roughness;
    f.values.roughness = specular_antialiasing(n, f.values.roughness);
    if (f.values.layers.coat > 0.0) f.values.layers.coat_roughness = specular_antialiasing(f.values.layers.coat_normal, f.values.layers.coat_roughness);
    return f;
}
// m: its fragment_material; opaque: what the linear depth target of the
// opaque scene holds at the pixel of a fragment drawn over it; 0 for one that
// is not.
Fragment fragment_evaluate(Raster_Input input, Material material, float opaque) {
    float3 to_camera = to_eye(input.in_world);
    float3 n;
    Mirai_Surface_Context ctx = material_context_over(fragment_context(input, material, to_camera, n), opaque);
    return fragment_evaluate(input, material, to_camera, ctx, n);
}
// The same of a fragment whose instance and material its stage decoded.
Fragment fragment_evaluate(Raster_Input input, Material material, Instance inst, float opaque) {
    float3 to_camera = to_eye(input.in_world);
    float3 n;
    Mirai_Surface_Context ctx = material_context_over(fragment_context(input, inst, material, to_camera, n), opaque);
    return fragment_evaluate(input, material, to_camera, ctx, n);
}
Fragment fragment_evaluate(Raster_Input input, float opaque) { return fragment_evaluate(input, fragment_material(input), opaque); }
Fragment fragment_evaluate(Raster_Input input) { return fragment_evaluate(input, 0.0); }

#endif
