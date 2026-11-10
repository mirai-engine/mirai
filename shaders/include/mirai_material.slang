#ifndef MIRAI_MATERIAL_CONTRACT
#define MIRAI_MATERIAL_CONTRACT
#include "origin.slang"
// Shared authoring contract: programs never own render passes or native handles.
struct Mirai_Surface_Context {
    float3 world_position; // relative to the origin of the render, which follows the eye far from the centre of the world
    int3 origin;           // that origin in steps: what it adds to a wave, a pattern or a lattice of the world is in origin.slang
    float3 normal;        // the input normal: the interpolated one under the normal map of the material
    float3 vertex_normal; // the interpolated normal of the surface, facing as normal does
    float4 tangent;       // MikkTSpace tangent of the surface in the world; w the side of its bitangent, w * cross(vertex_normal, tangent)
    float2 uv0;
    float2 uv1;
    float time;
    float previous_time;
    float lod;
    float lod1;
    bool ray;
    // How far world_position moves to the next pixel of the image along x and
    // along y; for a ray, across the width of its cone at the point.
    float3 position_dx;
    float3 position_dy;
    // The color of the mesh at the point, as data (a mask, a blend): white
    // where the mesh has none. It does not multiply the base color of a
    // program, which reads it here.
    float4 vertex_color;
    // The object the point is of, in the world: its pivot, relative to the
    // origin like world_position, and its axes, each as long as its scale
    // along it and square to the others. What has no object (a preview, an
    // effect) has the world for one.
    float3 object_position;
    float3 object_x;
    float3 object_y;
    float3 object_z;
    float3 object_center; // of its bounds in the world, relative to the origin
    float object_radius;  // of the sphere around its bounds
    float3 object_low;    // the corners of the bounds of its mesh in its own space; zero without an object
    float3 object_high;
    // The point in the image of the view: screen from 0 to 1 from its top
    // left corner (for a ray, where the view would draw the point, outside 0
    // to 1 off the image) and screen_size that image in pixels; depth the
    // distance of the point along the view, and scene_depth that of the
    // opaque surface behind it where a pass draws over one (blended
    // surfaces), elsewhere the far end of the view.
    float2 screen;
    float2 screen_size;
    float depth;
    float scene_depth;
    // How wet the object is, 0 dry to 1 soaked, as a plugin gives it; 0
    // without an object. The engine darkens and smooths by it what the
    // material returns: a program reads it only for more (drops, puddles).
    float wet;
    // Where the values the object gives over those of its materials are; 0
    // without them. The engine reads it: a program receives those values in
    // its parameters.
    uint material_values;
    // What the particle that draws the point gives its material, as its
    // program says (Mirai_Vfx_Visual.data), and which of them it gives: bit
    // i for particle_data[i]. None where no particle draws.
    float4 particle_data[4];
    uint particle_given;
    // Its random value, 0 to 1 (Mirai_Vfx_Visual.random), and its radius in
    // metres: half its sprite across. 0 where no particle draws.
    float particle_random;
    float particle_radius;
};
// A vector or a point of the world in the space of the object of ctx, and back.
float3 mirai_object_vector(Mirai_Surface_Context ctx, float3 v) {
    return float3(dot(v, ctx.object_x) / max(dot(ctx.object_x, ctx.object_x), 1e-30), dot(v, ctx.object_y) / max(dot(ctx.object_y, ctx.object_y), 1e-30), dot(v, ctx.object_z) / max(dot(ctx.object_z, ctx.object_z), 1e-30));
}
float3 mirai_object_point(Mirai_Surface_Context ctx, float3 p) { return mirai_object_vector(ctx, p - ctx.object_position); }
float3 mirai_world_vector(Mirai_Surface_Context ctx, float3 v) { return ctx.object_x * v.x + ctx.object_y * v.y + ctx.object_z * v.z; }
float3 mirai_world_point(Mirai_Surface_Context ctx, float3 p) { return ctx.object_position + mirai_world_vector(ctx, p); }
float3 mirai_object_scale(Mirai_Surface_Context ctx) { return float3(length(ctx.object_x), length(ctx.object_y), length(ctx.object_z)); }
// A vertex of what shows a Surface program that moves vertices (`//! vertex`),
// as its function vertex receives it: where the vertex is at rest, or as its
// skin poses it, in the space of the object, with what the mesh gives it, and
// the object in the world as Mirai_Surface_Context has it. time and
// previous_time are 0 unless the program says `//! vertex animated`.
struct Mirai_Vertex_Context {
    float3 position;
    float3 normal;        // unit
    float4 tangent;       // xyz along u, w the side of its bitangent
    float2 uv0;
    float2 uv1;
    float4 vertex_color;  // white where the mesh has none
    float3 world_position; // of position, relative to the origin of the render
    int3 origin;          // that origin in steps (origin.slang)
    float3 object_position;
    float3 object_x;
    float3 object_y;
    float3 object_z;
    float3 object_low;    // the corners of the bounds of its mesh in its own space
    float3 object_high;
    float time;
    float previous_time;
};
// Where the vertex goes, in the space of the object: the function keeps it
// within the reach its program declares of where it was.
struct Mirai_Vertex {
    float3 position;
    float3 normal;
    float4 tangent;
};
Mirai_Vertex mirai_vertex_default(Mirai_Vertex_Context ctx) {
    Mirai_Vertex v;
    v.position = ctx.position; v.normal = ctx.normal; v.tangent = ctx.tangent;
    return v;
}
// A vector or a point of the world in the space of the object of ctx, and back.
float3 mirai_object_vector(Mirai_Vertex_Context ctx, float3 v) {
    return float3(dot(v, ctx.object_x) / max(dot(ctx.object_x, ctx.object_x), 1e-30), dot(v, ctx.object_y) / max(dot(ctx.object_y, ctx.object_y), 1e-30), dot(v, ctx.object_z) / max(dot(ctx.object_z, ctx.object_z), 1e-30));
}
float3 mirai_object_point(Mirai_Vertex_Context ctx, float3 p) { return mirai_object_vector(ctx, p - ctx.object_position); }
float3 mirai_world_vector(Mirai_Vertex_Context ctx, float3 v) { return ctx.object_x * v.x + ctx.object_y * v.y + ctx.object_z * v.z; }
float3 mirai_world_point(Mirai_Vertex_Context ctx, float3 p) { return ctx.object_position + mirai_world_vector(ctx, p); }
// The values of the OpenPBR model at a point. A layer counts where its
// weight is above zero and the material declares it may have it.
struct Mirai_Surface {
    float3 base_color;
    float alpha;
    float3 normal;
    float metallic;
    float roughness;
    float occlusion;
    float3 emission;
    float3 specular_color;
    float specular_factor;
    float specular_ior;        // Fresnel only; the material's fixed IOR refracts its volume
    float specular_anisotropy; // 0 to 1: the specular lobe stretched along specular_tangent
    float3 specular_tangent;   // in the world, across normal
    float coat_weight;         // a clear coat over the base
    float coat_roughness;
    float3 coat_color;         // what of white light it leaves crossing it in and out at normal incidence
    float coat_ior;
    float3 coat_normal;
    float fuzz_weight;         // fibers over the coat and the base
    float3 fuzz_color;
    float fuzz_roughness;
    float diffuse_transmission_weight; // of the light the base scatters, the share that leaves through the other side of a thin surface
    float3 diffuse_transmission_color;
    bool unlit;                // it reflects no light: emission alone
};
// The values of the default material (asset.MATERIAL_DEFAULTS) at the point.
Mirai_Surface mirai_surface_default(Mirai_Surface_Context ctx);
// A coating mixes ordinary PBR attributes, including ray-hit evaluation.
Mirai_Surface mirai_surface_mix(Mirai_Surface a, Mirai_Surface b, float mask) {
    float w=saturate(mask);
    a.base_color=lerp(a.base_color,b.base_color,w);a.alpha=lerp(a.alpha,b.alpha,w);
    a.normal=normalize(lerp(a.normal,b.normal,w));a.metallic=lerp(a.metallic,b.metallic,w);
    a.roughness=lerp(a.roughness,b.roughness,w);a.occlusion=lerp(a.occlusion,b.occlusion,w);
    a.emission=lerp(a.emission,b.emission,w);a.specular_color=lerp(a.specular_color,b.specular_color,w);
    a.specular_factor=lerp(a.specular_factor,b.specular_factor,w);a.specular_ior=lerp(a.specular_ior,b.specular_ior,w);
    a.specular_anisotropy=lerp(a.specular_anisotropy,b.specular_anisotropy,w);a.specular_tangent=normalize(lerp(a.specular_tangent,b.specular_tangent,w));
    a.coat_weight=lerp(a.coat_weight,b.coat_weight,w);a.coat_roughness=lerp(a.coat_roughness,b.coat_roughness,w);a.coat_color=lerp(a.coat_color,b.coat_color,w);
    a.coat_ior=lerp(a.coat_ior,b.coat_ior,w);a.coat_normal=normalize(lerp(a.coat_normal,b.coat_normal,w));
    a.fuzz_weight=lerp(a.fuzz_weight,b.fuzz_weight,w);a.fuzz_color=lerp(a.fuzz_color,b.fuzz_color,w);a.fuzz_roughness=lerp(a.fuzz_roughness,b.fuzz_roughness,w);
    a.diffuse_transmission_weight=lerp(a.diffuse_transmission_weight,b.diffuse_transmission_weight,w);a.diffuse_transmission_color=lerp(a.diffuse_transmission_color,b.diffuse_transmission_color,w);
    a.unlit=w<0.5?a.unlit:b.unlit;
    return a;
}
// Of the pixel an effect writes. color is the image the effect before left,
// exposed before the tonemap; depth, the distance along the view of the
// surface seen there; normal, its normal in the world.
struct Mirai_PostProcess_Context {
    float2 uv;
    float2 resolution;
    float4 color;
    float depth;
    float3 normal;
    float time;
};
// Of the point of a node of a UI that a ui program colors. uv runs 0 to 1
// over the rectangle of the node from its top left corner; size is that
// rectangle in layout units; color, the color of the node in display values
// with straight alpha. The program returns a color like it, which the UI
// cuts to the rounded corners of the node and tints with its scope.
struct Mirai_Ui_Context {
    float2 uv;
    float2 size;
    float4 color;
    float time; // seconds of the world shown
};
// The outline of the game at a point of the image: the Outline of what is
// there, where the editor does not outline it.
struct Mirai_Outline {
    uint style;  // 1 to 15, of Outline_Styles; 0 none
    float depth; // distance along the view of the outlined surface
    bool behind; // another surface is in front of it
};
#ifdef MIRAI_MATERIAL_REFLECTION
Mirai_Surface mirai_surface_default(Mirai_Surface_Context ctx) {Mirai_Surface s=(Mirai_Surface)0;s.normal=ctx.normal;return s;}
float4 mirai_sample_texture(Mirai_Surface_Context ctx, uint index, float2 uv, float lod) {return float4(1);}
float4 mirai_sample_texture(Mirai_PostProcess_Context ctx, uint index, float2 uv, float lod) {return float4(1);}
float4 mirai_sample_texture_level(uint index, float2 uv, float level) {return float4(1);}
float4 mirai_sample_texture_grad(uint index, float2 uv, float2 dx, float2 dy) {return float4(1);}
float4 mirai_sample_texture_projected(Mirai_Surface_Context ctx, uint index, float3 u, float3 v, float metres) {return float4(1);}
float2 mirai_texture_size(uint index) {return float2(1);}
float4 mirai_scene_color(Mirai_PostProcess_Context ctx, float2 uv) {return ctx.color;}
float mirai_scene_depth(Mirai_PostProcess_Context ctx, float2 uv) {return ctx.depth;}
float3 mirai_scene_normal(Mirai_PostProcess_Context ctx, float2 uv) {return ctx.normal;}
Mirai_Outline mirai_outline(Mirai_PostProcess_Context ctx, float2 uv) {return (Mirai_Outline)0;}
#else
float4 mirai_sample_texture(Mirai_Surface_Context ctx, uint index, float2 uv, float lod);
float4 mirai_sample_texture(Mirai_PostProcess_Context ctx, uint index, float2 uv, float lod);
float4 mirai_sample_texture_level(uint index, float2 uv, float level);
float4 mirai_sample_texture_grad(uint index, float2 uv, float2 dx, float2 dy);
// A texture laid over the world: uv = (dot(p,u), dot(p,v)) / metres of one
// repeat, filtered by the footprint of the point, raster or ray, and in any
// branch.
float4 mirai_sample_texture_projected(Mirai_Surface_Context ctx, uint index, float3 u, float3 v, float metres);
// The texels of a texture across and down at its finest resident level: the
// whole texture, since a program keeps every level of its textures.
float2 mirai_texture_size(uint index);
// What an effect reads at any uv of the image, 0 to 1 from the top left
// corner, as ctx holds it for its own pixel.
float4 mirai_scene_color(Mirai_PostProcess_Context ctx, float2 uv);
float mirai_scene_depth(Mirai_PostProcess_Context ctx, float2 uv);
float3 mirai_scene_normal(Mirai_PostProcess_Context ctx, float2 uv);
Mirai_Outline mirai_outline(Mirai_PostProcess_Context ctx, float2 uv);
#endif
#endif
