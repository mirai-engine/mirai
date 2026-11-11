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
};

float fragment_depth(Raster_Input input) { return dot(input.in_world - frame.camera_position.xyz, frame.camera_forward.xyz); }

// A shading normal that turns away from the viewer, as a map or a program can
// leave it, is brought back to the silhouette.
float3 fragment_facing(float3 normal, float3 to_camera) {
    float facing = dot(normal, to_camera);
    return facing < 0.0 ? normalize(normal - to_camera * (facing - 1e-3)) : normal;
}

// Programs see the same input normal in shading and coverage, including
// double-sided facing and the material's independently transformed normal map.
// The normal map turns the frame of the front face, as its baker had it; the
// back face turns all of it around.
float3 fragment_surface_normal(Raster_Input input, Material material, float3 to_camera, float bias) {
    float3 n = normalize(input.in_normal);
    bool back = dot(n, to_camera) < 0.0;
    if (back) n = -n;
    if (material_has(material.textures[MATERIAL_MAP_NORMAL])) {
        float3 mapped = tangent_frame_normal(input.in_normal, input.in_tangent, material_map_normal(material, input.in_uv, input.in_uv1, float2(bias), false));
        n = fragment_facing(back ? -mapped : mapped, to_camera);
    }
    return n;
}

// The footprint of a fragment in the world. A quad is of one primitive, so a
// branch on its material keeps the derivatives.
Mirai_Surface_Context fragment_footprint(Mirai_Surface_Context ctx, Raster_Input input) {
    ctx.position_dx = ddx(input.in_world); ctx.position_dy = ddy(input.in_world);
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
// surfaces use the same alpha/cutoff as the scene, and empty blend fragments
// contribute no selection silhouette.
bool fragment_mask_covers(Raster_Input input, float mip_bias) {
    Material material = fragment_material(input);
    if (material.alpha_mode == ALPHA_OPAQUE) return true;
    float alpha;
    if (material.program_id == 0u) {
        alpha = material_base_color(material, input.in_uv, input.in_uv1, float2(mip_bias), input.in_color, false).a;
    } else {
        float3 view = to_eye(input.in_world);
        float3 normal = fragment_surface_normal(input, material, view, mip_bias);
        alpha = material_alpha(material, fragment_footprint(fragment_instance(material_context(input.in_world, normal, input.in_uv, input.in_uv1, float2(mip_bias), false), input), input), input.in_color, input.in_emission);
    }
    return material.alpha_mode == ALPHA_MASK ? material_covers(material, alpha) : alpha > 0.001;
}

// Whether a surface at this linear depth is behind a glass layer (0: there is none).
bool behind_layer(float depth, float layer) { return layer > 0.0 && depth > layer * 1.0001 + 1e-4; }

// Whether the fragment is a blended surface. The back faces of a solid are
// not: a ray leaves the solid there, and tracing finds where.
bool fragment_blended(Raster_Input input, bool front_facing) {
    Material m = fragment_material(input);
    if (m.alpha_mode != ALPHA_BLEND) return false;
    return !material_solid(m) || front_facing != ((input.in_flags & RASTER_FLAG_MIRRORED) != 0u);
}

// Whether the forward pass draws the fragment: a blended surface behind the
// last layer the glass pass draws per pixel, and before the opaque scene.
// The depth test of that pass, against the depth of the layer, has already
// turned away nearly everything else.
bool fragment_forward(Raster_Input input, bool front_facing, float last_layer, float opaque) {
    float depth = fragment_depth(input);
    return behind_layer(depth, last_layer) && !(!depth_empty(opaque) && depth >= depth_distance(opaque)) && fragment_blended(input, front_facing);
}

struct Fragment {
    Material material;
    Material_Sample values;   // roughness widened by specular antialiasing, the coat's too
    float3 normal;            // shading normal, facing the viewer
    float3 to_camera;
    float material_roughness; // before that widening
    float coat_roughness;     // of the coat before that widening
};

// The context a material is evaluated with at a fragment; normal: the input
// normal, under its normal map.
Mirai_Surface_Context fragment_context(Raster_Input input, Material material, float3 to_camera, out float3 normal) {
    float bias = frame.texturing.x;
    normal = fragment_surface_normal(input, material, to_camera, bias);
    // The surface as it faces the viewer: the back face turns its whole frame around.
    float3 vertex_normal = normalize(input.in_normal);
    float4 tangent = input.in_tangent;
    if (dot(vertex_normal, to_camera) < 0.0) {
        vertex_normal = -vertex_normal;
        tangent = -tangent;
    }
    return fragment_footprint(fragment_instance(material_context(input.in_world, normal, vertex_normal, tangent, input.in_uv, input.in_uv1, float2(bias), false), input), input);
}

// The context of a point a pass draws over the opaque scene: the depth the
// G-buffer holds behind it.
Mirai_Surface_Context material_context_over(Mirai_Surface_Context ctx, float opaque) {
    if (!depth_empty(opaque)) ctx.scene_depth = depth_distance(opaque);
    return ctx;
}

// opaque: what the linear depth target of the opaque scene holds at the
// pixel of a fragment drawn over it; 0 for one that is not.
Fragment fragment_evaluate(Raster_Input input, float opaque) {
    Fragment f;
    f.to_camera = to_eye(input.in_world);
    f.material = fragment_material(input);
    float3 n;
    Mirai_Surface_Context ctx = material_context_over(fragment_context(input, f.material, f.to_camera, n), opaque);
    f.values = material_sample(f.material, ctx, input.in_color, input.in_emission, n);
    material_surface_apply(f.values, f.material, input.in_surface);
    if (f.material.program_id != 0u) n = fragment_facing(n, f.to_camera);
    f.normal = n;
    f.values.emission = emission_render_units(sample_emission(f.values, dot(f.values.layers.coat_normal, f.to_camera)), f.values.emission_relative);
    f.material_roughness = f.values.roughness;
    f.values.roughness = specular_antialiasing(n, f.values.roughness);
    f.coat_roughness = f.values.layers.coat_roughness;
    if (f.values.layers.coat > 0.0) f.values.layers.coat_roughness = specular_antialiasing(f.values.layers.coat_normal, f.values.layers.coat_roughness);
    return f;
}
Fragment fragment_evaluate(Raster_Input input) { return fragment_evaluate(input, 0.0); }

#endif
