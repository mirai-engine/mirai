// Blended surfaces, as the forward pass and the per-pixel glass pass light
// them. Transmission turns a surface from a coat that covers part of what is
// behind it into glass: it diffuses nothing, reflects the evaluated surface's
// Fresnel and filters the rest. Its material's fixed IOR refracts the volume.
// The layers of its material lie over it as over an opaque base.
#ifndef MIRAI_GLASS_SLANG
#define MIRAI_GLASS_SLANG
#include "lighting.slang"

struct Glass {
    float3 position;
    float3 normal;     // shading normal, facing the viewer
    float3 view;       // towards the viewer
    float3 base_color;
    float alpha;
    float metallic;
    float roughness;
    float3 emission;
    float occlusion;
    float3 f0;
    float f90;
    Material_Layers layers;
};

// The surface as the lights see it, with its layers: it diffuses, and lets
// through diffusely, what its transmission and coverage leave.
Shading glass_shading(Material m, Glass g) {
    float covered = g.alpha * (1.0 - m.transmission);
    Shading s = shading_make(g.position, g.normal, g.view, diffuse_reflectance(g.base_color, g.metallic) * covered, g.f0, float3(g.f90), g.roughness);
    shading_layers(s, g.layers, g.metallic);
    s.transmit *= covered;
    return s;
}

// What the surface lets through of the light that reaches it from behind:
// where it covers, what its base does not reflect, by its color, under what
// its layers leave of it.
float3 glass_through(Material m, Glass g, Shading s) {
    return surface_filter(m, g.base_color, g.alpha, environment_reflectance(s), shading_through(s));
}

// The same for a solid as deep as its material says.
float3 glass_filter(Material m, Glass g) {
    float3 through = glass_through(m, g, glass_shading(m, g));
    return material_solid(m) ? through * material_absorption(m, m.thickness) : through;
}

#ifdef MIRAI_RASTER_SLANG
Glass fragment_glass(Fragment f, float3 position) {
    Glass g;
    g.position = position;
    g.normal = f.normal;
    g.view = f.to_camera;
    g.base_color = clamp(f.values.base_color, 0.0, 1.0);
    g.alpha = f.values.alpha;
    g.metallic = f.values.metallic;
    g.roughness = f.values.roughness;
    g.emission = f.values.emission;
    g.occlusion = f.values.occlusion;
    g.f0 = f.values.f0;
    g.f90 = f.values.f90;
    g.layers = f.values.layers;
    return g;
}
#endif

// Light the surface `s` (glass_shading) sends to the viewer by itself: direct
// light with shadow rays, the probe volume for the indirect part, and its
// emission. reflection is what a traced ray found for the share `traced` of
// the specular lobe of its base; its coat reflects the probe volume. A
// surface that reflects less than `faint` does not read the probes for its
// specular lobes; their share comes in between that and twice as much, so no
// edge shows where the reflectance of a pane crosses it.
float3 glass_light(Material m, Glass g, Shading s, float3 reflection, float traced, float faint, uint light_budget) {
    float bias = view_bias(eye_distance(g.position));
    float3 color = direct_lighting(s, bias, light_budget);
    if (shading_transmits(s)) color += direct_lighting(shading_back(s), bias, light_budget);
    float3 specular = specular_albedo(s);
    float shown = faint > 0.0 ? smoothstep(faint, 2.0 * faint, max(specular.r, max(specular.g, specular.b))) : 1.0;
    bool diffuse = max(s.diffuse.r, max(s.diffuse.g, s.diffuse.b)) > 0.0 || s.fuzz > 0.0;
    uint wants = (diffuse ? INDIRECT_DIFFUSE : 0u) | (traced < 1.0 && shown > 0.0 ? INDIRECT_SPECULAR : 0u) | (s.coat > 0.0 && shown > 0.0 ? INDIRECT_COAT : 0u);
    Indirect light = indirect_lobes(g.position, g.normal, g.view, s, wants, g.occlusion);
    light.radiance *= shown;
    light.coat_radiance *= shown;
    light.traced = reflection;
    light.traced_share = traced;
    color += indirect_compose(s, light);
    return color + g.emission * lerp(g.alpha, 1.0, m.transmission);
}

// What a solid with a scatter color sends towards the eye from `path` of it
// along direction from origin, on top of what it lets through of what lies
// behind: the light around that reaches it inside, dimmed by the way through
// the solid down from its top, times the share it scatters of what it stops
// on that path. The light is taken at one point, half way along the path or
// along the distance its attenuation is given for, whichever is nearer. The
// sun in it, with the shadows of what stands in its way, is the shafts of fog.
// top: the height of the top over the point when the caller knows it, as a
// flat top it entered through or found over the camera; below SOLID_TOP_UNKNOWN,
// the top of the box of the solid.
#define SOLID_TOP_UNKNOWN -1e29
float3 solid_scatter(Material m, uint instance, float3 origin, float3 direction, float path, float top) {
    float3 scatter = materials[m.row].volume.scatter;
    if (!any(scatter > 0.0) || !(path > 0.0)) return float3(0.0);
    float3 at = origin + direction * (0.5 * min(path, max(m.attenuation_distance, 1.0)));
    float under;
    if (top > SOLID_TOP_UNKNOWN) {
        under = max(top - at.y, 0.0);
    } else {
        under = max(instances[instance].bounds_max.y - at.y, 0.0);
    }
    float3 light = 0.5 * sky_irradiance(float3(0.0, 1.0, 0.0)) * material_absorption(m, under);
    return scatter * light * (1.0 - material_absorption(m, path));
}

#endif
