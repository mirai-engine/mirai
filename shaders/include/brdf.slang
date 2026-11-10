// The reflectance of a point (OpenPBR): a metallic-roughness base, Lambert
// diffuse plus a GGX specular lobe that may be anisotropic, under a coat and
// a fuzz, and the light a thin base lets through from its other side.
// Lighting stays in "Lambert-normalized" units (see lighting.slang): the
// irradiance terms are already divided by pi, so the specular lobe is
// multiplied by pi instead of the diffuse lobe being divided by it.
// Included by scene.slang after the scene table, whose texture table holds the
// split-sum table of the lobe.
#ifndef MIRAI_BRDF_SLANG
#define MIRAI_BRDF_SLANG
#include <shared_constants.slang>

// Below this the highlight of a point light is smaller than a pixel and the
// lobe overflows half floats.
#define MIN_ROUGHNESS 0.045
#define MIN_DIRECT_ROUGHNESS 0.08
// Below this a traced reflection follows the mirror direction alone.
#define MIRROR_ROUGHNESS 0.06
// From this roughness a block of 2x2 pixels can share one reflection ray: the
// lobe is wide enough for the filter to hide it: SHARED_RAY_ROUGHNESS
// (render.REFLECTION_SHARED_ROUGHNESS).
// Share of the tail of the lobe that reflection rays do not sample: the rare
// directions far from the mirror one are most of the noise.
#define LOBE_TAIL_CUT 0.3

// What a point holds besides its base (asset.Material_Layers), as its
// material gives it there; zero weights where it holds none.
struct Material_Layers {
    uint bits;             // MATERIAL_LAYER_*
    float coat;            // the share of the surface the coat covers
    float coat_roughness;
    float coat_ior;
    float3 coat_color;     // what of white light the coat leaves crossing it in and out at normal incidence
    float3 coat_normal;
    float fuzz;
    float3 fuzz_color;
    float fuzz_roughness;
    float anisotropy;
    float3 tangent;        // the direction the specular lobe of the base stretches along, across its normal
    float diffuse_transmission;          // of the light the base scatters, the share that leaves through the other side
    float3 diffuse_transmission_color;
};
Material_Layers material_layers_none() {
    Material_Layers l = (Material_Layers)0;
    l.coat_ior = MATERIAL_DEFAULT_COAT_IOR;
    l.coat_color = float3(1.0);
    l.fuzz_color = float3(1.0);
    l.fuzz_roughness = MATERIAL_DEFAULT_FUZZ_ROUGHNESS;
    l.diffuse_transmission_color = float3(1.0);
    return l;
}

// A surface point as the lights see it. shading_make fills the fields below
// roughness, which every light it adds shares; shading_layers the ones of
// the layers over the base (OpenPBR), which a point without them leaves zero.
struct Shading {
    float3 position;
    float3 normal;     // zero: a point lit from every side alike, which only has a diffuse reflectance
    float3 view;       // towards the eye or the origin of the ray
    float3 diffuse;    // diffuse reflectance
    float3 f0;         // specular reflectance at normal incidence; zero for a diffuse-only point
    float3 f90;        // grazing reflectance; specular factor can remove the lobe
    float roughness; // perceptual
    bool glossy;       // it has a specular lobe
    float alpha;       // of the lobe for direct light
    float nov;
    float2 dfg;        // the split sum of the lobe (dfg_lookup); zero without a specular lobe
    float3 energy;     // what the light that bounces between microfacets adds to the lobe
    float3 mirror;     // the view reflected about the normal, bent along an anisotropic lobe
    uint layers;       // MATERIAL_LAYER_*
    // The anisotropic lobe of the base: its alphas along the tangent and the bitangent.
    float3 tangent;
    float3 bitangent;
    float alpha_t;
    float alpha_b;
    // The coat.
    float coat;           // the share of the surface it covers
    float3 coat_normal;
    float coat_roughness;
    float coat_alpha;     // of its lobe for direct light
    float coat_nov;
    float coat_f0;
    float coat_eta;
    float2 coat_dfg;
    float coat_energy;
    float3 coat_mirror;
    float3 coat_color;
    float3 below_coat;    // weight * (1 - E) * darkening * transmission towards the view: what the base under it sends out
    float3 coat_through;  // its mean transmission towards the light around (indirect_compose)
    // The fuzz.
    float fuzz;           // weight * its albedo at the view: the share of the light under it it takes
    float3 fuzz_color;    // weight * color * that albedo: what it reflects of light from everywhere
    float3 fuzz_normal;
    float3 fuzz_x;        // the frame of its lobe: in the plane of the view and its normal
    float2 fuzz_ltc;      // the inverse transform of its lobe (aInv, bInv)
    // The diffuse transmission: what it sends towards its viewer of light
    // that reaches its other side, as a Lambert reflector facing that side
    // would (shading_back), the layers over it included.
    float3 transmit;
};

// 1 - noh^2 is taken as |n x h|^2: near the peak of a sharp lobe, 1 - noh^2
// rounds away what the lobe is made of, and a highlight of glass bands.
float ggx_distribution(float3 n, float3 h, float alpha) {
    float a2 = alpha * alpha;
    float noh = saturate(dot(n, h));
    float3 across = cross(n, h);
    float d = dot(across, across) + noh * noh * a2;
    return a2 / (PI * d * d);
}

// Height-correlated Smith visibility (Heitz 2014); includes 1 / (4 NoL NoV).
float ggx_visibility(float nol, float nov, float alpha) {
    float a2 = alpha * alpha;
    float gv = nol * sqrt(nov * nov * (1.0 - a2) + a2);
    float gl = nov * sqrt(nol * nol * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-5);
}

// A microfacet normal of the GGX lobe among those the viewer can see
// (Heitz 2018), in the frame whose z is the surface normal. view points
// towards the viewer; u are two random numbers. alpha: along x and y of the
// frame, which an anisotropic lobe stretches differently.
float3 sample_visible_normal(float3 view, float2 alpha, float2 u) {
    float3 vh = normalize(float3(alpha.x * view.x, alpha.y * view.y, view.z));
    float length2 = vh.x * vh.x + vh.y * vh.y;
    float3 t1 = length2 > 0.0 ? float3(-vh.y, vh.x, 0.0) * rsqrt(length2) : float3(1.0, 0.0, 0.0);
    float3 t2 = cross(vh, t1);
    float r = sqrt(u.x);
    float phi = 2.0 * PI * u.y;
    float p1 = r * cos(phi);
    float p2 = r * sin(phi);
    float s = 0.5 * (1.0 + vh.z);
    p2 = (1.0 - s) * sqrt(max(1.0 - p1 * p1, 0.0)) + s * p2;
    float3 nh = p1 * t1 + p2 * t2 + sqrt(max(1.0 - p1 * p1 - p2 * p2, 0.0)) * vh;
    return normalize(float3(alpha.x * nh.x, alpha.y * nh.y, max(nh.z, 0.0)));
}
float3 sample_visible_normal(float3 view, float alpha, float2 u) { return sample_visible_normal(view, float2(alpha), u); }

float3 fresnel_schlick(float3 f0, float3 f90, float voh) {
    float x = clamp(1.0 - voh, 0.0, 1.0);
    float x2 = x * x;
    return f0 + (f90 - f0) * (x2 * x2 * x);
}

float3 fresnel_schlick(float3 f0, float f90, float voh) { return fresnel_schlick(f0, float3(f90), voh); }

// F0 and the grazing reflectance of a surface in a target of 8 bits per
// channel: the color is stored as sRGB by the target, and alpha keeps f90.
float4 specular_pack(float3 f0, float f90) { return float4(saturate(f0), saturate(f90)); }
float4 specular_unpack(float4 texel) { return texel; }
float diffuse_remaining(float3 reflectance) { return 1.0 - saturate(max(reflectance.r, max(reflectance.g, reflectance.b))); }

// Smith's masking of the GGX lobe: the share of its microfacets a direction
// at cosine `cosine` of the normal sees.
float smith_masking(float cosine, float alpha) {
    float a2 = alpha * alpha;
    return 2.0 * cosine / max(cosine + sqrt(a2 + (1.0 - a2) * cosine * cosine), 1e-6);
}

// The split-sum table of the specular lobe (Karis 2013): for a view at cosine
// nov of the normal and a perceptual roughness, x is the share of F0 and y
// that of F90 the lobe reflects, with Schlick's Fresnel, of light that comes
// evenly from the whole hemisphere. x + y is its directional albedo with a
// Fresnel of one: what it keeps without the light that bounces between
// microfacets. render builds it once (dfg.comp) into the entry DFG_TEXTURE of
// the texture table, DFG_SIZE texels a side from 0 to 1 on each axis.
#define DFG_SAMPLES 512u

// The integral of the table at one texel, over directions of the visible
// normals of the lobe (Heitz 2018), whose estimate of the lobe with its
// cosine is the masking of the light over that of the view.
float2 dfg_integrate(float nov, float roughness) {
    float alpha = roughness * roughness;
    float3 view = float3(sqrt(saturate(1.0 - nov * nov)), 0.0, nov);
    float2 sum = float2(0.0);
    for (uint i = 0u; i < DFG_SAMPLES; i++) {
        float2 u = float2((float(i) + 0.5) / float(DFG_SAMPLES), float(reversebits(i)) * 2.3283064365386963e-10);
        float3 h = sample_visible_normal(view, alpha, u);
        float voh = saturate(dot(view, h));
        float nol = 2.0 * voh * h.z - view.z;
        if (nol <= 0.0) continue;
        float weight = ggx_visibility(nol, nov, alpha) * 4.0 * nol * nov / smith_masking(nov, alpha);
        float x = 1.0 - voh;
        float schlick = x * x * x * x * x;
        sum += float2(1.0 - schlick, schlick) * weight;
    }
    return sum / float(DFG_SAMPLES);
}

float2 dfg_lookup(float nov, float roughness) {
    float2 uv = (saturate(float2(nov, roughness)) * (DFG_SIZE - 1.0) + 0.5) / DFG_SIZE;
    return material_textures[DFG_TEXTURE].SampleLevel(linear_sampler, uv, 0.0).rg;
}

// What the specular lobe reflects of light that comes evenly from around it,
// the light that bounces between its microfacets included.
float3 environment_reflectance(Shading s) { return (s.f0 * s.dfg.x + s.f90 * s.dfg.y) * s.energy; }
// What the specular lobe of the base leaves to what it covers, the diffuse
// lobe and the diffuse transmission, for every light alike: one minus its
// directional albedo at the view (the albedo scaling of OpenPBR).
float base_diffuse_share(Shading s) { return diffuse_remaining(environment_reflectance(s)); }

float3 diffuse_reflectance(float3 base_color, float metallic) { return base_color * (1.0 - metallic); }
// The F0 of the default dielectric: the specular color and factor of the
// default material at its IOR.
float3 default_dielectric_f0() {
    float ratio = (MATERIAL_DEFAULT_IOR - 1.0) / (MATERIAL_DEFAULT_IOR + 1.0);
    return MATERIAL_DEFAULT_SPECULAR_COLOR * (MATERIAL_DEFAULT_SPECULAR_FACTOR * ratio * ratio);
}
float3 specular_f0(float3 base_color, float metallic) { return lerp(default_dielectric_f0(), base_color, metallic); }

// Reflectance of a surface seen as a diffuse reflector, for the bounces
// behind the first hit: its specular lobe is folded into its albedo so the
// energy it reflects is not lost.
float3 bounce_albedo(float3 base_color, float metallic) {
    return min(diffuse_reflectance(base_color, metallic) + specular_f0(base_color, metallic), float3(1.0));
}

Shading shading_make(float3 position, float3 normal, float3 view, float3 diffuse, float3 f0, float3 f90, float roughness) {
    Shading s = (Shading)0;
    s.position = position;
    s.normal = normal;
    s.view = view;
    s.diffuse = diffuse;
    s.f0 = f0;
    s.f90 = f90;
    s.roughness = roughness;
    s.glossy = max(max(f0.r, max(f0.g, f0.b)), max(f90.r, max(f90.g, f90.b))) > 0.0 && dot(normal, normal) > 0.5;
    float lobe = max(roughness, MIN_DIRECT_ROUGHNESS);
    s.alpha = lobe * lobe;
    s.nov = max(dot(normal, view), 1e-4);
    s.dfg = s.glossy ? dfg_lookup(s.nov, roughness) : float2(0.0);
    // A single-scattering lobe loses the light that bounces between
    // microfacets; rough metals get it back (Kulla and Conty, as in Filament).
    s.energy = s.glossy ? 1.0 + f0 * (1.0 / max(s.dfg.x + s.dfg.y, 1e-3) - 1.0) : float3(1.0);
    s.mirror = reflect(-view, normal);
    s.coat_color = float3(1.0);
    s.coat_through = float3(1.0);
    return s;
}

Shading shading_diffuse(float3 position, float3 normal, float3 albedo) {
    return shading_make(position, normal, normal, albedo, float3(0.0), float3(0.0), 1.0);
}

Shading shading_surface(float3 position, float3 normal, float3 view, float3 base_color, float metallic, float roughness, float3 f0, float f90) {
    return shading_make(position, normal, view, diffuse_reflectance(base_color, metallic), f0, float3(f90), roughness);
}

Shading shading_surface(float3 position, float3 normal, float3 view, float3 base_color, float metallic, float roughness) {
    return shading_surface(position, normal, view, base_color, metallic, roughness, specular_f0(base_color, metallic), 1.0);
}

// ---------------------------------------------------------------- layers (OpenPBR)

// The directional albedo of the internal reflection of a smooth dielectric
// of relative index eta for light from everywhere (the fit of the OpenPBR
// specification, for eta from 1 to 3).
float dielectric_internal_albedo(float eta) {
    return log((10893.0 * eta - 1438.2) / (-774.4 * eta * eta + 10212.0 * eta + 1.0));
}

// What the coat leaves of light that crosses it once at cosine `mu` of its
// normal outside it: its color is the transmittance in and out at normal
// incidence, and the path inside grows as the refracted ray tilts.
float3 coat_transmission(float3 color, float mu, float eta) {
    float inside = sqrt(max(1.0 - (1.0 - mu * mu) / (eta * eta), 1e-4));
    return pow(max(color, float3(1e-4)), float3(0.5 / inside));
}

// The fuzz lobe of Zeltner, Burley and Chiang (2022, "Practical Multiple-
// Scattering Sheen Using Linearly Transformed Cosines"), as OpenPBR takes it:
// its directional albedo and the inverse transform of its LTC, fits in the
// cosine of the view and the roughness (MaterialX, Apache-2.0).
float fuzz_albedo(float x, float y) {
    float s = y * (0.0206607 + 1.58491 * y) / (0.0379424 + y * (1.32227 + y));
    float m = y * (-0.193854 + y * (-1.14885 + y * (1.7932 - 0.95943 * y * y))) / (0.046391 + y);
    float o = y * (0.000654023 + (-0.0207818 + 0.119681 * y) * y) / (1.26264 + y * (-1.92021 + y));
    float d = (x - m) / s;
    return exp(-0.5 * d * d) / (s * sqrt(2.0 * PI)) + o;
}
float2 fuzz_ltc(float x, float y) {
    float a = (2.58126 * x + 0.813703 * y) * y / (1.0 + 0.310327 * x * x + 2.60994 * x * y);
    float b = sqrt(1.0 - x) * (y - 1.0) * y * y * y / (0.0000254053 + 1.71228 * x - 1.71506 * x * y + 1.34174 * y * y);
    return float2(a, b);
}

// The layers of a point over its base: fuzz over a coat over the base, each
// reflecting its own lobe and leaving the rest of the light to the one under
// it (albedo scaling, which keeps the energy whatever the light). What a
// layer takes depends on the view alone, but the transmission of the coat
// towards a light: direct and indirect light compose the same way.
// metallic: of the base, which the darkening of the coat depends on.
void shading_layers(inout Shading s, Material_Layers layers, float metallic) {
    s.layers = layers.bits;
    if ((layers.bits & MATERIAL_LAYER_UNLIT) != 0u) {
        s.diffuse = float3(0.0);
        s.f0 = float3(0.0);
        s.f90 = float3(0.0);
        s.glossy = false;
        s.dfg = float2(0.0);
        s.energy = float3(1.0);
        return;
    }
    if ((layers.bits & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) != 0u && layers.diffuse_transmission > 0.0) {
        // Of the light the dielectric base scatters, the weight leaves through
        // the other side of a thin surface filtered by the color, and the rest
        // is reflected (KHR_materials_diffuse_transmission): light from there
        // crosses the specular interface as the diffuse lobe does.
        float weight = saturate(layers.diffuse_transmission);
        s.transmit = weight * saturate(layers.diffuse_transmission_color) * (1.0 - metallic);
        s.diffuse *= 1.0 - weight;
    } else {
        s.layers &= ~MATERIAL_LAYER_DIFFUSE_TRANSMISSION;
    }
    if ((layers.bits & MATERIAL_LAYER_ANISOTROPY) != 0u && s.glossy && layers.anisotropy > 0.0) {
        // OpenPBR: the mean square of the two alphas is that of the lobe.
        float a = saturate(layers.anisotropy);
        s.tangent = normalize(layers.tangent - s.normal * dot(s.normal, layers.tangent));
        s.bitangent = cross(s.normal, s.tangent);
        s.alpha_t = s.alpha * sqrt(2.0 / (1.0 + (1.0 - a) * (1.0 - a)));
        s.alpha_b = max((1.0 - a) * s.alpha_t, 1e-4);
        // The lobe the view sees is as wide as its alphas along the view:
        // its albedo is that of an even lobe of that width.
        float2 across = float2(dot(s.view, s.tangent), dot(s.view, s.bitangent));
        float spread = dot(across, across);
        float roughness = s.roughness;
        if (spread > 1e-8) {
            float rough2 = s.roughness * s.roughness;
            float t = rough2 * s.alpha_t / s.alpha, b = rough2 * s.alpha_b / s.alpha;
            roughness = sqrt(sqrt((t * t * across.x * across.x + b * b * across.y * across.y) / spread));
        }
        s.dfg = dfg_lookup(s.nov, saturate(roughness));
        s.energy = 1.0 + s.f0 * (1.0 / max(s.dfg.x + s.dfg.y, 1e-3) - 1.0);
        // The light around it comes from a reflection bent towards the
        // direction it stretches along (Revie 2011, as in Filament).
        float3 grooves = cross(s.bitangent, s.view);
        float3 bent = normalize(lerp(s.normal, cross(grooves, s.bitangent), a * saturate(5.0 * s.roughness)));
        s.mirror = reflect(-s.view, bent);
    } else {
        s.layers &= ~MATERIAL_LAYER_ANISOTROPY;
    }
    if ((layers.bits & MATERIAL_LAYER_COAT) != 0u && layers.coat > 0.0) {
        s.coat = saturate(layers.coat);
        s.coat_normal = layers.coat_normal;
        s.coat_roughness = clamp(layers.coat_roughness, MIN_ROUGHNESS, 1.0);
        float lobe = max(s.coat_roughness, MIN_DIRECT_ROUGHNESS);
        s.coat_alpha = lobe * lobe;
        s.coat_nov = max(dot(s.coat_normal, s.view), 1e-4);
        s.coat_eta = max(layers.coat_ior, 1.0 + 1e-3);
        float ratio = (s.coat_eta - 1.0) / (s.coat_eta + 1.0);
        s.coat_f0 = ratio * ratio;
        s.coat_dfg = dfg_lookup(s.coat_nov, s.coat_roughness);
        s.coat_energy = 1.0 + s.coat_f0 * (1.0 / max(s.coat_dfg.x + s.coat_dfg.y, 1e-3) - 1.0);
        s.coat_mirror = reflect(-s.view, s.coat_normal);
        s.coat_color = saturate(layers.coat_color);
        float albedo = (s.coat_f0 * s.coat_dfg.x + s.coat_dfg.y) * s.coat_energy;
        // Darkening (OpenPBR): light the base sends up is partly reflected
        // back down by the inside of the coat, and the base takes some of it
        // again. Of a base of normal-incidence albedo E, (1 - K) / (1 - E K)
        // gets out, K the internal reflectance of the coat: that of a smooth
        // interface for a smooth base, of light from everywhere for a rough
        // one (a diffuse base is rough).
        float3 base_albedo = s.f0 + s.diffuse * diffuse_remaining(s.f0);
        float rough_base = lerp(lerp(1.0, s.roughness, saturate(max(s.f0.r, max(s.f0.g, s.f0.b)))), s.roughness, metallic);
        float smooth_k = s.coat_f0 + (1.0 - s.coat_f0) * pow(1.0 - s.coat_nov, 5.0);
        float rough_k = 1.0 - (1.0 - dielectric_internal_albedo(s.coat_eta)) / (s.coat_eta * s.coat_eta);
        float k = lerp(smooth_k, saturate(rough_k), rough_base);
        float3 darkening = (1.0 - k) / max(1.0 - base_albedo * k, float3(1e-4));
        s.below_coat = s.coat * (1.0 - albedo) * darkening * coat_transmission(s.coat_color, s.coat_nov, s.coat_eta);
        // The mean of 1 / mu inside the coat over light from everywhere, by
        // the cosine: 2 eta^2 (1 - sqrt(1 - 1 / eta^2)).
        float path = 2.0 * s.coat_eta * s.coat_eta * (1.0 - sqrt(1.0 - 1.0 / (s.coat_eta * s.coat_eta)));
        s.coat_through = pow(max(s.coat_color, float3(1e-4)), float3(0.5 * path));
    } else {
        s.layers &= ~MATERIAL_LAYER_COAT;
    }
    if ((layers.bits & MATERIAL_LAYER_FUZZ) != 0u && layers.fuzz > 0.0) {
        // Fibers on what is under them: the coat where it covers.
        s.fuzz_normal = s.coat > 0.0 ? normalize(lerp(s.normal, s.coat_normal, s.coat)) : s.normal;
        float mu = clamp(dot(s.fuzz_normal, s.view), 1e-4, 1.0);
        float roughness = clamp(layers.fuzz_roughness, 0.01, 1.0);
        float albedo = saturate(fuzz_albedo(mu, roughness));
        s.fuzz = saturate(layers.fuzz) * albedo;
        s.fuzz_color = s.fuzz * saturate(layers.fuzz_color);
        s.fuzz_ltc = fuzz_ltc(mu, roughness);
        float3 x = s.view - s.fuzz_normal * mu;
        float3 y_axis;
        if (dot(x, x) > 1e-10) s.fuzz_x = normalize(x);
        else make_basis(s.fuzz_normal, s.fuzz_x, y_axis);
    } else {
        s.layers &= ~MATERIAL_LAYER_FUZZ;
    }
    // What the base lets through reaches the viewer under its specular lobe,
    // the coat and the fuzz.
    if ((s.layers & MATERIAL_LAYER_DIFFUSE_TRANSMISSION) != 0u) {
        s.transmit *= base_diffuse_share(s);
        if (s.coat > 0.0) s.transmit *= (1.0 - s.coat) + s.below_coat * s.coat_through;
        if (s.fuzz > 0.0) s.transmit *= 1.0 - s.fuzz;
    }
}

// The other side of a thin surface as the lights there see it: a Lambert
// reflector of what it transmits, facing away from the side the view is on.
Shading shading_back(Shading s) {
    return shading_diffuse(s.position, -s.normal, s.transmit);
}
bool shading_transmits(Shading s) { return max(s.transmit.r, max(s.transmit.g, s.transmit.b)) > 0.0; }

// What the fuzz reflects towards the viewer of light from `light` (unit), per
// unit of its Lambert-normalized irradiance: the LTC lobe carried back to a
// clamped cosine. It keeps the horizon, so over the hemisphere it adds up to
// the albedo the fit gives.
float3 fuzz_response(Shading s, float3 light) {
    float3 y_axis = cross(s.fuzz_normal, s.fuzz_x);
    float3 w = float3(dot(light, s.fuzz_x), dot(light, y_axis), dot(light, s.fuzz_normal));
    if (w.z <= 0.0) return float3(0.0);
    float3 back = float3(s.fuzz_ltc.x * w.x + s.fuzz_ltc.y * w.z, s.fuzz_ltc.x * w.y, w.z);
    float jacobian = s.fuzz_ltc.x / dot(back, back);
    return s.fuzz_color * (jacobian * jacobian);
}

// The GGX lobe of the base stretched along its tangent: its distribution and
// its height-correlated Smith visibility.
float ggx_anisotropic(Shading s, float3 h, float3 light) {
    float3 hn = float3(dot(h, s.tangent), dot(h, s.bitangent), dot(h, s.normal));
    float a2 = s.alpha_t * s.alpha_b;
    float3 stretched = float3(s.alpha_b * hn.x, s.alpha_t * hn.y, a2 * hn.z);
    float w2 = a2 / dot(stretched, stretched);
    float distribution = a2 * w2 * w2 / PI;
    float nol = saturate(dot(s.normal, light));
    float3 v = float3(s.alpha_t * dot(s.view, s.tangent), s.alpha_b * dot(s.view, s.bitangent), s.nov);
    float3 l = float3(s.alpha_t * dot(light, s.tangent), s.alpha_b * dot(light, s.bitangent), nol);
    float visibility = 0.5 / max(nol * length(v) + s.nov * length(l), 1e-5);
    return distribution * visibility;
}

// Where the highlight of a specular lobe comes from for one light, what of
// its energy it keeps there and the color of the light there over the
// color its diffuse light took (a rectangle with an image).
struct Highlight {
    float3 towards;
    float keep;
    float3 tint;
};
Highlight highlight_at(float3 towards) {
    Highlight h;
    h.towards = towards;
    h.keep = 1.0;
    h.tint = float3(1.0);
    return h;
}

// The point of a sphere of light at `center`, from the shading point, nearest
// the mirror direction of a lobe: where its highlight comes from (Karis 2013).
float3 sphere_highlight(float3 mirror, float3 center, float radius) {
    float3 across = dot(center, mirror) * mirror - center;
    return normalize(center + across * saturate(radius / max(length(across), 1e-6)));
}

// What of its energy the highlight of a lobe of `alpha` keeps when a light of
// `size` widens it at `distance`: the lobe of a sphere widens in two
// directions, that of a segment in one (the square root of this).
float highlight_keep(float alpha, float size, float distance) {
    float wide = alpha / saturate(alpha + 0.5 * size / distance);
    return wide * wide;
}

// The highlights of the lobes of a point for a sphere of light at `center`.
void sphere_highlights(Shading s, float3 center, float radius, out Highlight base, out Highlight coat) {
    float distance = length(center);
    base = highlight_at(sphere_highlight(s.mirror, center, radius));
    base.keep = highlight_keep(s.alpha, radius, distance);
    coat = base;
    if (s.coat > 0.0) {
        coat.towards = sphere_highlight(s.coat_mirror, center, radius);
        coat.keep = highlight_keep(s.coat_alpha, radius, distance);
    }
}

// The diffuse and the specular radiance a point sends towards its viewer
// per unit of Lambert-normalized irradiance from `light` (unit, towards the
// center of the light): its specular lobes take theirs from where their
// highlights are. The fuzz, a wide lobe, is part of the diffuse one.
void shading_lobes(Shading s, float3 light, Highlight base, Highlight coat, out float3 diffuse, out float3 specular) {
    diffuse = s.diffuse;
    specular = float3(0.0);
    if (s.glossy) {
        diffuse *= base_diffuse_share(s);
        float3 h = normalize(base.towards + s.view);
        float nol = saturate(dot(s.normal, base.towards));
        float3 fresnel = fresnel_schlick(s.f0, s.f90, saturate(dot(s.view, h)));
        float lobe = (s.layers & MATERIAL_LAYER_ANISOTROPY) != 0u ? ggx_anisotropic(s, h, base.towards) : ggx_distribution(s.normal, h, s.alpha) * ggx_visibility(nol, s.nov, s.alpha);
        specular = fresnel * (lobe * base.keep * PI) * s.energy * base.tint;
    }
    if (s.layers == 0u) return;
    if (s.coat > 0.0) {
        float3 below = (1.0 - s.coat) + s.below_coat * coat_transmission(s.coat_color, saturate(dot(s.coat_normal, light)), s.coat_eta);
        diffuse *= below;
        specular *= below;
        float3 h = normalize(coat.towards + s.view);
        float nol = saturate(dot(s.coat_normal, coat.towards));
        float fresnel = s.coat_f0 + (1.0 - s.coat_f0) * pow(1.0 - saturate(dot(s.view, h)), 5.0);
        float lobe = ggx_distribution(s.coat_normal, h, s.coat_alpha) * ggx_visibility(nol, s.coat_nov, s.coat_alpha);
        specular += coat.tint * (s.coat * fresnel * lobe * coat.keep * PI * s.coat_energy);
    }
    if (s.fuzz > 0.0) {
        diffuse = diffuse * (1.0 - s.fuzz) + fuzz_response(s, light);
        specular *= 1.0 - s.fuzz;
    }
}

// Radiance leaving towards s.view per unit of Lambert-normalized irradiance
// from a sphere of light of `radius` whose center lies `distance` along the
// unit `light` (the cosine is part of the irradiance); a radius of zero is a
// direction alone. The highlight of a sphere is that of its point nearest the
// mirror direction, with the lobe widened by its size and lowered to keep its
// energy (Karis 2013).
float3 shading_response(Shading s, float3 light, float distance = 0.0, float radius = 0.0) {
    if (!s.glossy && s.layers == 0u) return s.diffuse;
    Highlight base = highlight_at(light), coat = highlight_at(light);
    if (radius > 0.0 && distance > 0.0) sphere_highlights(s, light * distance, radius, base, coat);
    float3 diffuse, specular;
    shading_lobes(s, light, base, coat, diffuse, specular);
    return diffuse + specular;
}

// Where the light a lobe reflects mostly comes from: the mirror direction,
// leaning towards the normal as the lobe widens.
float3 dominant_direction(Shading s) { return normalize(lerp(s.mirror, s.normal, s.roughness * s.roughness)); }
float3 coat_dominant_direction(Shading s) { return normalize(lerp(s.coat_mirror, s.coat_normal, s.coat_roughness * s.coat_roughness)); }

// What the ambient occlusion of a material leaves of the light around a
// specular lobe (Lagarde and de Rousiers 2014): a smooth lobe seen face on
// gathers from less of the hemisphere than the diffuse one, and keeps more.
float specular_occlusion(float nov, float roughness, float occlusion) {
    float alpha = roughness * roughness;
    return saturate(pow(nov + occlusion, exp2(-16.0 * alpha - 1.0)) - 1.0 + occlusion);
}

// What the lobe of the coat reflects of light that comes evenly from around
// it, its weight included.
float3 coat_reflectance(Shading s) { return float3(s.coat * (s.coat_f0 * s.coat_dfg.x + s.coat_dfg.y) * s.coat_energy); }

// What a point reflects of light that comes evenly from around it as its
// specular lobes (the base and the coat), roughly.
float3 specular_albedo(Shading s) {
    float3 albedo = environment_reflectance(s);
    if (s.coat > 0.0) albedo = albedo * ((1.0 - s.coat) + s.below_coat * s.coat_through) + coat_reflectance(s);
    return s.fuzz > 0.0 ? albedo * (1.0 - s.fuzz) : albedo;
}

// What the layers over the base leave of light that comes from under the base
// and crosses them once towards the viewer, as light through glass does: the
// coat lets through what it does not reflect at the view, by its color, and
// the fuzz what it does not take. The base under it does not send any of it
// back up again, so the coat does not darken it.
float3 shading_through(Shading s) {
    float3 through = float3(1.0);
    if (s.coat > 0.0) {
        float albedo = (s.coat_f0 * s.coat_dfg.x + s.coat_dfg.y) * s.coat_energy;
        through = (1.0 - s.coat) + s.coat * (1.0 - albedo) * coat_transmission(s.coat_color, s.coat_nov, s.coat_eta);
    }
    return s.fuzz > 0.0 ? through * (1.0 - s.fuzz) : through;
}

// The light that reaches a point from around it, as a pass finds it.
struct Indirect {
    float3 irradiance;    // around the normal, in the units of the irradiance of a light
    float3 radiance;      // around dominant_direction, from what holds the light around (the probes, the sky)
    float3 coat_radiance; // the same around coat_dominant_direction
    float3 traced;        // what rays along a lobe found
    float traced_share;   // of the lobe `traced` stands for; the radiance gives the rest
    bool traced_coat;     // the lobe traced is that of the coat, not that of the base
    float occlusion;      // the ambient occlusion of the material
    float3 back_irradiance; // around the opposite of the normal, for what a thin surface lets through (Shading.transmit)
};

Indirect indirect_make(float3 irradiance, float3 radiance, float occlusion) {
    Indirect light;
    light.irradiance = irradiance;
    light.radiance = radiance;
    light.coat_radiance = radiance;
    light.traced = float3(0.0);
    light.traced_share = 0.0;
    light.traced_coat = false;
    light.occlusion = occlusion;
    light.back_irradiance = float3(0.0);
    return light;
}

// What a point sends towards its viewer of the light around it: its diffuse
// lobe reflects the irradiance, with what its specular lobe leaves it
// (base_diffuse_share, as for each light) and the ambient occlusion; its specular lobe, the radiance around its dominant
// direction, with the specular occlusion. The layers over the base take
// their share as they do of each light (shading_lobes), the coat the mean
// of its transmission towards the light around.
float3 indirect_compose(Shading s, Indirect light) {
    float3 reflectance = environment_reflectance(s);
    float3 diffuse = s.diffuse * base_diffuse_share(s) * light.irradiance * light.occlusion;
    float3 around = light.traced_coat ? light.radiance : lerp(light.radiance, light.traced, light.traced_share);
    float3 color = diffuse + reflectance * around * specular_occlusion(s.nov, s.roughness, light.occlusion);
    if (s.layers == 0u) return color;
    if (s.coat > 0.0) {
        float3 coat = light.traced_coat ? lerp(light.coat_radiance, light.traced, light.traced_share) : light.coat_radiance;
        color = color * ((1.0 - s.coat) + s.below_coat * s.coat_through) + coat_reflectance(s) * coat * specular_occlusion(s.coat_nov, s.coat_roughness, light.occlusion);
    }
    if (s.fuzz > 0.0) color = color * (1.0 - s.fuzz) + s.fuzz_color * light.irradiance * light.occlusion;
    return color + s.transmit * light.back_irradiance * light.occlusion;
}

#endif
