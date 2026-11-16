// The light of previews: the analytic studio shared by material spheres and
// GPU geometry thumbnails, and the sun and the sky of a scene.
#ifndef MIRAI_STUDIO_SLANG
#define MIRAI_STUDIO_SLANG
#include "material_raster.slang"
#include "display.slang"

// The key light gives a white surface that faces it 0.65: a key of 1000 lux,
// a bright room, by which the emission of a material shows in nits.
#define STUDIO_UNITS_PER_NIT (0.65 * PI / 1000.0)

// The exposure a meter gives the studio, a gray world under the key: middle
// gray shows as 0.18 and a white surface that faces the key as 1.
#define STUDIO_EXPOSURE (1.0 / 0.65)

// The light of the studio around a lobe: an even gray and the reflections of
// its key and fill lights, as sharp as the lobe.
float3 studio_light(float3 reflected, float3 key, float3 fill, float roughness) {
    float spread = lerp(100.0, 2.0, roughness);
    return float3(0.12) + float3(2.0) * pow(max(dot(reflected, key), 0.0), spread) + float3(0.3, 0.4, 0.6) * pow(max(dot(reflected, fill), 0.0), spread);
}

float preview_alpha(Material material, Material_Sample values) { return material.alpha_mode == ALPHA_BLEND ? saturate(values.alpha) : 1.0; }

// The surface a preview lights: with its layers, and its diffuse by what it covers and lets through.
Shading preview_surface(float3 position, float3 normal, float3 view, Material material, Material_Sample values) {
    Shading surface = shading_surface(position, normal, view, values.base_color, values.metallic, values.roughness, values.f0, values.f90);
    shading_layers(surface, values.layers, values.metallic);
    surface.diffuse *= preview_alpha(material, values) * (1.0 - material.transmission);
    return surface;
}

// What a preview adds of the emission of its material, in its radiance.
float3 preview_emission(Material material, Material_Sample values) {
    return values.emission * lerp(preview_alpha(material, values), 1.0, material.transmission);
}

// An emission in the radiance of the studio: nits by its key light, and a
// relative emission as the value the studio's exposure shows.
float3 studio_emission(float3 emission, bool relative) {
    return emission * (relative ? 1.0 / STUDIO_EXPOSURE : STUDIO_UNITS_PER_NIT);
}

// values.emission: in the radiance of the studio (studio_emission).
float3 studio_radiance(float3 position, float3 normal, float3 view, Material material, Material_Sample values) {
    Shading surface = preview_surface(position, normal, view, material, values);
    float3 right = normalize(cross(float3(0, 1, 0), view));
    float3 up = cross(view, right);
    float3 key = normalize(right * -0.6 + up * 0.7 + view * 0.8);
    float3 fill = normalize(right * 0.8 + view * 0.5);
    float3 radiance = shading_response(surface, key) * max(dot(normal, key), 0.0) * 0.65;
    radiance += shading_response(surface, fill) * max(dot(normal, fill), 0.0) * float3(0.18, 0.22, 0.3);
    Indirect light = indirect_make(float3(0.15), studio_light(surface.mirror, key, fill, values.roughness), values.occlusion);
    light.back_irradiance = light.irradiance;
    if (surface.coat > 0.0) light.coat_radiance = studio_light(surface.coat_mirror, key, fill, surface.coat_roughness);
    radiance += indirect_compose(surface, light);
    return finite_or_zero(radiance + preview_emission(material, values));
}

// The sun and the sky of the frame as they light a scene, without shadows.
// values.emission: in render units, as fragment_evaluate leaves it.
float3 outdoor_radiance(float3 position, float3 normal, float3 view, Material material, Material_Sample values) {
    Shading surface = preview_surface(position, normal, view, material, values);
    float3 radiance = float3(0.0);
    if (frame.sun_direction.w > 0.5) radiance += sun_light(position) * max(dot(normal, frame.sun_direction.xyz), 0.0) * shading_response(surface, frame.sun_direction.xyz);
    // A thin surface lets the sun behind it through.
    if (frame.sun_direction.w > 0.5) radiance += sun_light(position) * max(dot(-normal, frame.sun_direction.xyz), 0.0) * surface.transmit;
    Indirect light = indirect_make(sky_irradiance(normal), sky_radiance(surface.mirror, values.roughness), values.occlusion);
    light.back_irradiance = sky_irradiance(-normal);
    if (surface.coat > 0.0) light.coat_radiance = sky_radiance(surface.coat_mirror, surface.coat_roughness);
    radiance += indirect_compose(surface, light);
    return finite_or_zero(radiance + preview_emission(material, values));
}

// What a preview shows of the radiance of the studio, encoded for the display.
float3 studio_display(float3 radiance) { return preview_encode(radiance * STUDIO_EXPOSURE); }
#endif
