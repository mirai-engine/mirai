// Direct lighting. Lighting terms are "Lambert-normalized": the irradiance D
// of a light is its intensity times the cosine over the square of the
// distance, the indirect D is the cosine-weighted average of incoming
// radiance, and a surface sends D * shading_response towards the viewer
// (D * albedo for a diffuse one), plus its emission.
//
// A local light is a sphere that glows evenly: its size lights a surface it
// half sets behind, widens its highlights and blurs its shadows. The local
// lights form a tree (render/light_tree.odin) whose groups stand for their
// lights as one sphere as wide as they spread: a point adds up each group
// small enough as it sees it, and opens the others to their children.
#ifndef MIRAI_LIGHTING_SLANG
#define MIRAI_LIGHTING_SLANG
#include "trace.slang"
#include "probe_light.slang"
// A pass with the maps of the view (SUN_SHADOW_SLOT and SHADOW_DATA_SLOT) that
// takes the shadows of direct_lighting from them where they hold the point,
// and traces the rays only where they do not.
#ifdef MIRAI_LIGHT_MAPS
#include "shadow_maps.slang"
#endif

// The irradiance a sphere of light of unit intensity gives a surface, with
// its center `distance` away towards a direction at `cosine` of the normal:
// the cosine over the square of the distance while all of it is above the
// horizon, and what of it is as it sets (Snyder 1996, in the form of Lagarde
// and de Rousiers 2014). Inside the sphere, the light of its surface. No
// light or group of them is narrower than LIGHT_RADIUS_MIN.
float sphere_irradiance(float cosine, float distance, float r) {
    float d2 = max(distance * distance, r * r);
    float sin2 = r * r / d2;
    if (cosine * cosine > sin2) return max(cosine, 0.0) / d2;
    float sine = sqrt(max(1.0 - cosine * cosine, 1e-8));
    float x = sqrt(max(1.0 / sin2 - 1.0, 1e-8));
    float y = clamp(-x * cosine / sine, -1.0, 1.0);
    float s = sine * sqrt(1.0 - y * y);
    float seen = (cosine * acos(y) - x * s) * sin2 + atan(s / x);
    return max(seen, 0.0) / (PI * r * r);
}

// Smooth window so a light's influence ends exactly at its range.
float light_window(float distance, float range) {
    float r = max(distance, 0.0) / max(range, 0.001);
    float r2 = r * r;
    float x = saturate(1.0 - r2 * r2);
    return x * x;
}

// A local light is a sphere, a capsule (a sphere drawn along a segment:
// size.y is half of it, along axis) or a rectangle that glows on the side its
// direction_cone faces (size.y and size.z half its width, along axis, and
// height). Its intensity is what it gives a point far along its axis.
bool light_is_rect(Light light) { return light.direction_cone.w < 0.5 * (LIGHT_POINT + LIGHT_RECT); }
bool light_is_capsule(Light light) { return !light_is_rect(light) && light.size.y > 0.0; }

// The radius of the sphere around its center that holds a light.
float light_extent(Light light) {
    if (light_is_rect(light)) return length(light.size.yz);
    return light.size.x + light.size.y;
}

// The irradiance of a rectangle of unit intensity: what of its area the
// surface sees above its horizon, weighed by the cosines of both (the
// integral along the edges of the part above the horizon, as in Arvo 1995),
// over that area. Far away, the cosines over the square of the distance.
float rect_irradiance(Light light, float3 position, float3 normal) {
    float3 facing = light.direction_cone.xyz;
    float3 center = light.position_range.xyz - position;
    float behind = dot(center, facing);
    if (behind >= 0.0) return 0.0;
    float3 width = light.axis.xyz * light.size.y;
    float3 height = cross(facing, light.axis.xyz) * light.size.z;
    float area = 4.0 * light.size.y * light.size.z;
    float distance2 = dot(center, center);
    if (dot(normal, normal) < 0.5) return -behind * rsqrt(distance2) / max(distance2, area);
    if (area < 1e-4 * distance2) return saturate(dot(normal, center) * rsqrt(distance2)) * (-behind * rsqrt(distance2)) / distance2;
    float3 corners[4] = {center - width - height, center + width - height, center + width + height, center - width + height};
    return polygon_projected_angle(corners, normal) / area;
}

// The irradiance of a capsule of unit intensity: that of its segment, cut
// where it goes under the horizon (Picott 1992), with the falloff of a point
// no closer than its radius. A normal of zero, from every side alike.
float capsule_irradiance(Light light, float3 position, float3 normal) {
    float radius = light.size.x;
    float3 center = light.position_range.xyz - position;
    float3 half_segment = light.axis.xyz * light.size.y;
    float3 l0 = center - half_segment;
    float3 l1 = center + half_segment;
    if (dot(normal, normal) < 0.5) return 2.0 / max(length(l0) * length(l1) + dot(l0, l1), 2.0 * radius * radius);
    float above0 = dot(normal, l0);
    float above1 = dot(normal, l1);
    if (above0 < 0.0 && above1 < 0.0) return 0.0;
    if (above0 < 0.0) l0 = l0 + (l1 - l0) * (above0 / (above0 - above1));
    else if (above1 < 0.0) l1 = l1 + (l0 - l1) * (above1 / (above1 - above0));
    float length0 = max(length(l0), radius);
    float length1 = max(length(l1), radius);
    float along = (dot(normal, l0) / length0 + dot(normal, l1) / length1) / max(length0 * length1 + dot(l0, l1), 2.0 * radius * radius);
    return along * length(l1 - l0) / (2.0 * light.size.y);
}

// Where on a rectangle a point of the plane of the rectangle lies, from -1 to 1 across its width and height.
float2 rect_place(Light light, float3 offset) {
    float3 height = cross(light.direction_cone.xyz, light.axis.xyz);
    return float2(dot(offset, light.axis.xyz) / light.size.y, dot(offset, height) / light.size.z);
}

// Whether a light projects a texture (LIGHT_TEXTURE in its image word).
bool light_projects(Light light) { return (asuint(light.size.w) & LIGHT_TEXTURE) != 0u; }

// The color of a texture of the table at uv, from 0 to 1 across it, blurred
// over `blur` of its width.
float3 light_texture(uint entry, float2 uv, float blur) {
    float2 texels = float2(texture_size(material_textures[mirai_nonuniform(entry)], 0));
    float level = max(log2(max(blur, 1e-6) * max(texels.x, texels.y)), 0.0);
    // The sampler of materials repeats: the edge of the level sampled stays its own.
    float2 shown = max(texels / exp2(ceil(level)), float2(1.0));
    uv = clamp(uv, 0.5 / shown, 1.0 - 0.5 / shown);
    return material_textures[mirai_nonuniform(entry)].SampleLevel(material_sampler, uv, level).rgb;
}

// The color a rectangle shows at a place of it, blurred over `blur` metres of
// it, its image lying across it as across a quad from (0, 1) to (1, 0): the
// texture it projects; or the emission of its material, with its texture,
// over the luminance of the emission without it (the intensity of the light
// gives how bright); or white.
float3 rect_emission(Light light, float2 place, float blur) {
    uint image = asuint(light.size.w);
    if (image == 0u) return float3(1.0);
    float2 uv = 0.5 + 0.5 * float2(place.x, -place.y);
    float spread = blur / (2.0 * max(light.size.y, light.size.z));
    if (light_projects(light)) return light_texture(image & ~LIGHT_TEXTURE, uv, spread);
    Material m = material_row(image);
    float3 emission = m.emission / max(luminance(m.emission), 1e-6);
    if (!material_has(m.textures[MATERIAL_MAP_EMISSION])) return emission;
    return emission * light_texture(m.textures[MATERIAL_MAP_EMISSION], material_map_uv(m, MATERIAL_MAP_EMISSION, uv, uv), spread);
}

// The color a spot that projects a texture sends along `along`, the unit way
// from its center towards a point `distance` away: its texture lies across
// the cone as a slide across the beam of a projector, the circle of the cone
// inscribed in it and its width along the right the light keeps, blurred over
// `footprint` metres there.
float3 spot_texture(Light light, float3 along, float distance, float footprint) {
    float3 forward = light.direction_cone.xyz;
    float3 right = unpack_normal(asuint(light.size.z));
    right = normalize(right - forward * dot(right, forward));
    float3 up = cross(right, forward);
    float ahead = max(dot(along, forward), 1e-4);
    float cosine = light.direction_cone.w;
    float width = 2.0 * sqrt(max(1.0 - cosine * cosine, 0.0)) / max(cosine, 1e-4);
    float2 place = float2(dot(along, right), dot(along, up)) * (2.0 / (ahead * width));
    return light_texture(asuint(light.size.w) & ~LIGHT_TEXTURE, 0.5 + 0.5 * float2(place.x, -place.y), footprint / max(width * ahead * distance, 1e-6));
}

// The color a diffuse surface gets from a rectangle: what it shows around the
// point of it nearest the surface, blurred over as much of it as the distance
// spreads the light it sends there.
float3 rect_diffuse_color(Light light, float3 position) {
    if (asuint(light.size.w) == 0u) return float3(1.0);
    float3 offset = position - light.position_range.xyz;
    float apart = dot(offset, light.direction_cone.xyz);
    float2 place = clamp(rect_place(light, offset - light.direction_cone.xyz * apart), -1.0, 1.0);
    float3 nearest = light.axis.xyz * (place.x * light.size.y) + cross(light.direction_cone.xyz, light.axis.xyz) * (place.y * light.size.z);
    // Off its edge, more of it, farther, shares the light.
    float away = length(offset - nearest);
    return rect_emission(light, place * saturate(1.0 - 0.25 * (away - abs(apart)) / max(light.size.y, light.size.z)), away + 0.05 * max(light.size.y, light.size.z));
}

// What a light gives a point whose surface has that normal, with nothing in
// its way, and the direction and distance to its center. A normal of zero
// takes the light from every side alike. The color of a light that shows an
// image is that of its image there (rect_diffuse_color, spot_texture),
// blurred over `footprint` metres, the width of the place the point stands
// for (0: as sharp as its texture): every pass that lights with a light takes
// its color here.
float3 light_contribution(Light light, float3 position, float3 normal, out float3 direction, out float distance, float footprint = 0.0) {
    float3 delta = light.position_range.xyz - position;
    distance = length(delta);
    direction = delta / max(distance, 1e-6);
    if (distance >= light.position_range.w) return float3(0.0);
    if (light_is_rect(light)) {
        float shape = rect_irradiance(light, position, normal);
        if (!(shape > 0.0)) return float3(0.0);
        return light.color_intensity.rgb * rect_diffuse_color(light, position) * (light.color_intensity.w * shape * light_window(distance, light.position_range.w));
    }
    float cone = 1.0;
    float3 color = light.color_intensity.rgb;
    if (light.direction_cone.w > -1.5) {
        // Spot lights fade out between LIGHT_SPOT_FULL of the half-angle and its edge.
        float cos_outer = light.direction_cone.w;
        float cos_inner = cos(acos(cos_outer) * LIGHT_SPOT_FULL);
        cone = smoothstep(cos_outer, cos_inner, dot(-direction, light.direction_cone.xyz));
        if (cone <= 0.0) return float3(0.0);
        if (light_projects(light)) color *= spot_texture(light, -direction, distance, footprint);
    }
    if (light_is_capsule(light)) return color * (light.color_intensity.w * cone * capsule_irradiance(light, position, normal) * light_window(distance, light.position_range.w));
    float cosine = dot(normal, normal) > 0.5 ? dot(normal, direction) : 1.0;
    return color * (light.color_intensity.w * cone * sphere_irradiance(cosine, distance, light.size.x) * light_window(distance, light.position_range.w));
}

// The unshadowed radiance a light sends from the point towards its viewer:
// its irradiance by the response of the surface, whose highlights come from
// the point of the light nearest the mirror direction of each lobe (Karis
// 2013): of the disc of a sphere, the segment of a capsule widened by its
// radius, or the rectangle, whose texture colors a highlight where it comes
// from.
float3 light_radiance(Light light, Shading s, out float3 direction, out float distance) {
    float3 diffuse, specular;
    light_lobes(light, s, diffuse, specular, direction, distance);
    return diffuse + specular;
}

// light_radiance in the share of each lobe: what the diffuse responses send
// and what the specular ones do.
void light_lobes(Light light, Shading s, out float3 diffuse, out float3 specular, out float3 direction, out float distance) {
    float3 irradiance = light_contribution(light, s.position, s.normal, direction, distance, shading_footprint(s));
    light_lobes_of(light, s, irradiance, direction, distance, diffuse, specular);
}
// The same from what light_contribution gave the point: the irradiance, the
// direction and the distance.
void light_lobes_of(Light light, Shading s, float3 irradiance, float3 direction, float distance, out float3 diffuse, out float3 specular) {
    diffuse = float3(0.0);
    specular = float3(0.0);
    if (!(luminance(irradiance) > 0.0)) return;
    if (s.medium || (!s.glossy && s.layers == 0u)) {
        diffuse = irradiance * shading_response(s, direction);
        return;
    }
    Highlight base = highlight_at(direction), coat = highlight_at(direction);
    if (light_is_rect(light) || light_is_capsule(light)) {
        base = light_highlight(light, s.position, s.mirror, s.alpha, distance);
        if (s.coat > 0.0) coat = light_highlight(light, s.position, s.coat_mirror, s.coat_alpha, distance);
    } else if (distance > 0.0) {
        sphere_highlights(s, direction * distance, light.size.x, base, coat);
    }
    float3 d, sp;
    shading_lobes(s, direction, base, coat, d, sp);
    diffuse = irradiance * d;
    specular = irradiance * sp;
}
void light_lobes(Light light, Shading s, out float3 diffuse, out float3 specular) {
    float3 direction;
    float distance;
    light_lobes(light, s, diffuse, specular, direction, distance);
}

// Where the highlight of a lobe (its mirror direction and alpha) comes from
// on a capsule or a rectangle, from the point at `position`: the direction
// (unit), what of its energy it keeps, and for a rectangle with an image,
// the color of the image there over the color its diffuse light took.
Highlight light_highlight(Light light, float3 position, float3 mirror, float alpha, float distance) {
    Highlight h = highlight_at(float3(0.0, 1.0, 0.0));
    float3 center = light.position_range.xyz - position;
    if (light_is_rect(light)) {
        float3 facing = light.direction_cone.xyz;
        float into = dot(mirror, facing);
        float3 on_plane = into < -1e-4 ? mirror * (dot(center, facing) / into) : mirror * distance;
        on_plane -= facing * dot(on_plane - center, facing);
        float2 place = clamp(rect_place(light, on_plane - center), -1.0, 1.0);
        float3 height = cross(facing, light.axis.xyz);
        float3 nearest = center + light.axis.xyz * (place.x * light.size.y) + height * (place.y * light.size.z);
        float far = length(nearest);
        h.towards = nearest / max(far, 1e-6);
        float size = 2.0 * sqrt(light.size.y * light.size.z / PI);
        h.keep = highlight_keep(alpha, size, far);
        // The color of the rectangle where the highlight comes from, blurred by the lobe.
        if (asuint(light.size.w) != 0u) h.tint = rect_emission(light, place, far * alpha + 0.05 * size) / max(rect_diffuse_color(light, position), float3(1e-4));
        return h;
    }
    float radius = light.size.x;
    float3 half_segment = light.axis.xyz * light.size.y;
    float3 l0 = center - half_segment;
    float3 segment = 2.0 * half_segment;
    float along = dot(mirror, segment);
    float t = saturate((dot(mirror, l0) * along - dot(l0, segment)) / max(dot(segment, segment) - along * along, 1e-8));
    float3 nearest = l0 + segment * t;
    float far = length(nearest);
    h.towards = sphere_highlight(mirror, nearest, radius);
    h.keep = highlight_keep(alpha, radius, far) * sqrt(highlight_keep(alpha, 2.0 * light.size.y, far));
    return h;
}

// How far a shadow ray goes towards a point of a light `far` away: short of
// the box around its sphere, so that a lamp that holds it casts no shadow of
// it and the ray does not look among the triangles of the lamp; short of the
// plane of a rectangle, so that the surface that shows it casts none.
static const float LIGHT_CLEARANCE = 1.75;
float light_reach(Light light, float far) {
    if (light_is_rect(light)) return max(far - 0.02, 0.0);
    return max(far - LIGHT_CLEARANCE * light.size.x - 0.02, 0.0);
}

// From a point, towards where on a capsule or a rectangle its one hard shadow
// ray goes: the point of it nearest the normal of the surface out to the
// light, above its horizon whenever any of the light is.
float3 light_aim(Light light, float3 position, float3 normal) {
    float3 center = light.position_range.xyz - position;
    float3 out_there = normal * length(center);
    if (light_is_rect(light)) {
        float3 facing = light.direction_cone.xyz;
        float2 place = clamp(rect_place(light, out_there - center - facing * dot(out_there - center, facing)), -1.0, 1.0);
        return center + light.axis.xyz * (place.x * light.size.y) + cross(facing, light.axis.xyz) * (place.y * light.size.z);
    }
    float along = clamp(dot(out_there - center, light.axis.xyz), -light.size.y, light.size.y);
    return center + light.axis.xyz * along;
}

// The shadow ray to the sun: to the point `k` of sixteen across its disc,
// `radius` radians wide (its fraction: how far out in its ring), turned by
// `spin`, as light_point lays out the disc of a sphere.
float3 sun_ray(float k, float spin, float radius) {
    float3 across, up;
    make_basis(frame.sun_direction.xyz, across, up);
    float angle = spin + floor(k) * 2.3999632;
    float2 disc = sqrt(k / 16.0) * float2(cos(angle), sin(angle)) * radius;
    return normalize(frame.sun_direction.xyz + across * disc.x + up * disc.y);
}

// From a point, towards the point of a light, `k` of sixteen (its fraction:
// where in its cell), its shadow rays go to, turned by `spin`: of the disc a
// sphere shows the point, along the segment of a capsule and across the disc
// of its radius, or across a rectangle in a 4x4 grid, on the diagonal of
// each cell: points spread over the cells made its shadows boil.
float3 light_point(Light light, float3 position, float k, float spin) {
    float3 center = light.position_range.xyz - position;
    if (light_is_rect(light)) {
        uint cell = min(uint(k), 15u);
        float2 inside = (float2(cell & 3u, cell >> 2u) + frac(k)) * 0.5 - 1.0;
        float3 height = cross(light.direction_cone.xyz, light.axis.xyz);
        return center + light.axis.xyz * (inside.x * light.size.y) + height * (inside.y * light.size.z);
    }
    if (light_is_capsule(light)) center += light.axis.xyz * (light.size.y * (k / 8.0 - 1.0));
    float3 across, up;
    make_basis(normalize(center), across, up);
    float spin_k = spin + floor(k) * 2.3999632;
    float2 disc = sqrt((light_is_capsule(light) ? frac(k * 0.618034) : k) / 16.0) * float2(cos(spin_k), sin(spin_k)) * light.size.x;
    return center + across * disc.x + up * disc.y;
}

// The same for a group of the tree: one sphere as bright as its lights
// together, at their center and as wide as they spread. Its lights lie
// nearer and farther than its center, where the window of their range
// bends: the mean of the window at two points a deviation either side, each
// halfway between the windows of its shortest and its longest range.
// `doubt` bounds how far that may be from the light of its lights: the
// curvature of the falloff and the cosine across their spread; all of it
// where they straddle the horizon of the surface, whose side each of them is
// on the group does not know; and how much the window changes between its
// nearest light by its longest range and its farthest by its shortest, which
// can be all of the light of a group whose center is beyond the range of
// some of its lights and not of others. By the directions they face, it is
// node_aims, and may err as far as the most or the least it could be: a
// group of spots that face alike, seen from well within or well outside of
// their cones, stands for them.
// The widths of a node (Gpu_Light_Node.widths): how far past its cone its
// light fades out, and how far around its own axis each of its lights shines
// whole.
float node_falloff(Light_Node node) { return float(node.widths & 0xFFFFu) * (PI / 65535.0); }
float node_inner(Light_Node node) { return float(node.widths >> 16u) * (PI / 65535.0); }

// How much of the light of a node reaches a point by the directions its
// lights face, at most: 1 within the cone they shine whole in, past it
// fading out as a cosine over node_falloff, and 0 beyond that (Conty
// Estevez and Kulla 2018; pbrt-v4), with the angle the sphere of the node
// spans from the point taken in its favor. A spot fades so to the edge of
// its cone; a rectangle as a cosine; a point lights every way.
float node_aim_past(float beyond, float falloff) {
    if (beyond >= falloff) return 0.0;
    return cos(beyond * (0.5 * PI) / max(falloff, 1e-4));
}
float node_aim(Light_Node node, float3 position) {
    if (node.cone.w >= PI - 1e-3) return 1.0;
    float3 away = position - node.center_radius.xyz;
    float distance = length(away);
    float radius = node.center_radius.w;
    if (distance <= radius) return 1.0;
    float theta = acos(clamp(dot(node.cone.xyz, away / distance), -1.0, 1.0));
    return node_aim_past(max(theta - node.cone.w - asin(radius / distance), 0.0), node_falloff(node));
}
// What of the light of a group reaches a point by the directions its lights
// face, as node_aim gives it at most (`most`) and at least (`least`): the
// axis of each of its lights lies within the cone less the narrowest
// half-angle they shine whole in (node_inner), and each shines whole within
// that of its own axis, with the angle the sphere spans taken against it;
// inside the sphere, none. Returns it as a light whose cone lies halfway
// between the narrowest and the cone of the group, fading out over what
// lies between them too, seen from the root mean square of the angles to
// its lights, within those bounds.
float node_aims(Light_Node node, float3 position, out float most, out float least) {
    most = 1.0;
    least = 1.0;
    float inner = min(node_inner(node), node.cone.w);
    if (node.cone.w >= PI - 1e-3 && inner >= PI - 1e-2) return 1.0;
    float3 away = position - node.center_radius.xyz;
    float distance = length(away);
    float radius = node.center_radius.w;
    float falloff = node_falloff(node);
    if (distance <= radius) {
        least = 0.0;
        return 0.5;
    }
    float theta = acos(clamp(dot(node.cone.xyz, away / distance), -1.0, 1.0));
    float sphere = asin(radius / distance);
    if (node.cone.w < PI - 1e-3) most = node_aim_past(max(theta - node.cone.w - sphere, 0.0), falloff);
    least = node_aim_past(max(theta + sphere + node.cone.w - 2.0 * inner, 0.0), falloff);
    // Its lights lie around the direction of its center by about the angle of their spread.
    float around = asin(min(node.spread / distance, 1.0));
    float middle = node_aim_past(max(sqrt(theta * theta + around * around) - 0.5 * (node.cone.w + inner), 0.0), falloff + (node.cone.w - inner));
    return clamp(middle, least, most);
}

// What of a sphere of `radius` whose center lies `distance` along `delta`
// rises above the horizon of the normal, at most: all of it while the
// normal lies within its angle, else the cosine of the angle from the normal
// to the sphere less the angle the sphere spans (the clamped cosine of a
// difference of pbrt-v4). A normal of zero, a point of a medium: all of it.
float node_rising(float3 normal, float3 delta, float distance, float radius) {
    if (dot(normal, normal) < 0.5) return 1.0;
    float cosine = dot(delta, normal) / max(distance, 1e-6);
    float sine_sphere = min(radius / max(distance, 1e-6), 1.0);
    float cosine_sphere = sqrt(1.0 - sine_sphere * sine_sphere);
    if (cosine > cosine_sphere) return 1.0;
    return saturate(cosine * cosine_sphere + sqrt(saturate(1.0 - cosine * cosine)) * sine_sphere);
}

float node_window(Light_Node node, float distance) {
    return 0.5 * (light_window(distance, node.range_low) + light_window(distance, node.range_high));
}
// How much the window of a group changes from its nearest light by its
// longest range to its farthest by its shortest, from 0 to 1.
float node_bend(Light_Node node, float distance) {
    return light_window(distance - node.center_radius.w, node.range_high) - light_window(distance + node.center_radius.w, node.range_low);
}
float3 group_contribution(Light_Node node, float3 position, float3 normal, out float3 direction, out float distance, out float doubt) {
    float3 delta = node.center_radius.xyz - position;
    distance = length(delta);
    direction = delta / max(distance, 1e-6);
    float most, least;
    float aim = node_aims(node, position, most, least);
    float cosine = dot(normal, normal) > 0.5 ? dot(normal, direction) : 1.0;
    float deviation = node.spread * 0.57735027;
    float window = 0.5 * (node_window(node, distance - deviation) + node_window(node, distance + deviation));
    float3 unaimed = node.power_reach.rgb * sphere_irradiance(cosine, distance, node.spread);
    float3 light = unaimed * aim;
    float spread = node.spread / max(distance, 1e-6);
    float bend = node_bend(node, distance);
    float horizon = saturate(1.0 - abs(cosine) / max(spread, 1e-6));
    doubt = luminance(light) * ((3.0 * spread * spread + horizon) * window + 0.5 * bend) + luminance(unaimed) * max(most - aim, aim - least) * window;
    return light * window;
}

// What a node of the tree gives a point: a leaf, its light; a group, as above.
float3 node_contribution(Light_Node node, float3 position, float3 normal, out float3 direction, out float distance) {
    if ((node.flags & LIGHT_NODE_LEAF) != 0u) return light_contribution(lights[node.child], position, normal, direction, distance);
    float doubt;
    return group_contribution(node, position, normal, direction, distance, doubt);
}

// Unshadowed radiance a node sends from the point towards its viewer.
float3 node_radiance(Light_Node node, Shading s, out float3 direction, out float distance) {
    if ((node.flags & LIGHT_NODE_LEAF) != 0u) return light_radiance(lights[node.child], s, direction, distance);
    float3 irradiance = node_contribution(node, s.position, s.normal, direction, distance);
    if (!(luminance(irradiance) > 0.0)) return float3(0.0);
    return irradiance * shading_response(s, direction, distance, node.spread);
}

// Which share of their light the lights of a walk give: all of it, what the
// probes gather (Light_Node.indirect) or what media scatter (scattering).
#define LIGHT_SHARE_ALL 0u
#define LIGHT_SHARE_BOUNCED 1u
#define LIGHT_SHARE_SCATTERED 2u
float node_share(Light_Node node, uint share) {
    return share == LIGHT_SHARE_BOUNCED ? node.indirect : share == LIGHT_SHARE_SCATTERED ? node.scattering : 1.0;
}

// Whether any light of a node reaches a point, is not wholly under the
// horizon of its surface, faces it and gives some of the share of its light
// the walk takes (LIGHT_SHARE_*).
bool node_reaches(Light_Node node, float3 position, float3 normal, out float distance_squared, uint share = LIGHT_SHARE_ALL) {
    float3 delta = node.center_radius.xyz - position;
    distance_squared = dot(delta, delta);
    return distance_squared < node.power_reach.w * node.power_reach.w && dot(delta, normal) > -node.center_radius.w && node_share(node, share) > 0.0 && node_aim(node, position) > 0.0;
}

// Whether a walk goes down from the node at `at` to its children: a group
// whose children come after it in the tree, as its depth-first order puts
// them (render/light_tree.odin). Every step of a walk then goes further on,
// and a node that leads back ends the walk there instead of looping.
bool light_node_opens(Light_Node node, uint at) {
    return (node.flags & LIGHT_NODE_LEAF) == 0u && node.child > at && node.child < frame.light_nodes;
}

static const float EMITTER_LIGHT_SIZES = 2.0;

// The groups a walk down the tree of the lights has yet to open, of a
// thread: one for every walk down it, which none nests (light_walk).
static uint light_pending[LIGHT_TREE_DEPTH];

// One of the lights of the tree from root lies inside the box from low to
// high, at most `extent` from its center each way.
bool light_stands_for_under(uint root, float3 low, float3 high, float extent) {
    uint depth = 0u;
    uint at = root;
    [loop]
    while (true) {
        Light_Node node = light_nodes[at];
        float3 away = clamp(node.center_radius.xyz, low, high) - node.center_radius.xyz;
        if (dot(away, away) <= node.center_radius.w * node.center_radius.w) {
            if ((node.flags & LIGHT_NODE_LEAF) != 0u) {
                Light light = lights[node.child];
                if (all(light.position_range.xyz >= low) && all(light.position_range.xyz <= high) && extent <= EMITTER_LIGHT_SIZES * light_extent(light)) return true;
            } else if (depth < LIGHT_TREE_DEPTH && light_node_opens(node, at)) {
                light_pending[depth] = node.child;
                depth++;
                at++;
                continue;
            }
        }
        if (depth == 0u) break;
        depth--;
        at = light_pending[depth];
    }
    return false;
}

// Whether a light stands for the emission of an instance: one of the lights
// lies inside its bounds, which are not much larger than the sphere of that
// light, as the globe of a lamp around the light that gives its light.
bool light_stands_for(uint instance) {
    if (frame.light_nodes == 0u) return false;
    Instance inst = scene_instance(instance);
    float3 low = inst.bounds_min.xyz;
    float3 high = inst.bounds_max.xyz;
    float extent = 0.5 * max(high.x - low.x, max(high.y - low.y, high.z - low.z));
    if (light_stands_for_under(0u, low, high, extent)) return true;
    return frame.shadowless_lights != 0u && light_stands_for_under(frame.shadowless_lights, low, high, extent);
}

// Whether a ray that gathers light met the globe of a light (light_stands_for
// an instance that emits): to such a ray the globe is that light, which the
// direct light of what it reaches takes already, and it brings back nothing.
// Its emission would count the light twice; so would what its surface
// reflects, which sits at the sphere of its light and reflects that light
// whole. Both come from a small bright spot that the rays seldom meet, as a
// spot that comes and goes.
bool hit_on_light(Surface s, uint instance) {
    return any(s.emission > float3(0.0)) && light_stands_for(instance);
}

// A group stands for its lights alone while what it may err is small
// against all the light the point gets: below LIGHTS_GROUPED of it, it
// stands for them; above LIGHTS_OPENED its children do; in between both do,
// in shares that change smoothly, so that nothing shows where a point passes
// from one to the other. A group the point is close to against its size
// opens whatever its light: its center says little of where its lights are.
static const float LIGHTS_GROUPED = 0.05;
static const float LIGHTS_OPENED = 0.065;
static const float GROUP_NEAR = 0.6;
static const float GROUP_INSIDE = 1.0;

// How much a group that reaches a point needs to open to its children: the
// brighter and the wider as the point sees it, the more. `share`: by that
// share of its light (LIGHT_SHARE_*).
float node_need(Light_Node node, float distance_squared, float3 position, float3 normal, uint share) {
    float distance = sqrt(distance_squared);
    float radius = node.center_radius.w;
    float rising = node_rising(normal, node.center_radius.xyz - position, distance, radius);
    return luminance(node.power_reach.rgb) * node_share(node, share) * node_aim(node, position) * rising / max(distance_squared, radius * radius) * min(radius / max(distance, 1e-6), 1.0);
}

// A walk of the tree visits at most LIGHT_WALK_MAX nodes. It holds the
// groups it means to open; `ordered`, it opens first the one whose light is
// most at stake (node_need by what of it is left to its children), and once
// it would pass that many, each group it holds stands for its lights. Its
// cost then stops growing with how many lights reach a point, and what it
// gives a point depends on nothing but the lights and the point. Each group
// it opens visits two nodes for the one it held, so it never holds more than
// half. Where few lights reach a point the order does not matter, as every
// group it holds opens: a walk first opens the last group it held, with no
// needs to weigh, and only one cut short (`cut`) starts again in order.
static const uint LIGHT_WALK_MAX = 64u;
static const uint LIGHT_WALK_HELD = LIGHT_WALK_MAX / 2u;
struct Light_Walk {
    uint at[LIGHT_WALK_HELD];
    float weight[LIGHT_WALK_HELD]; // what of the light of the group is left to its children
    float need[LIGHT_WALK_HELD];   // ordered only
    uint held;
    uint visits;
    bool ordered;
    bool cut; // it had more to open than it could
};
// The walk of a thread, which every call that walks takes in turn: none
// nests. The arrays of a function are local memory once for each place it is
// inlined, and a driver keeps the local memory of the largest stage for every
// thread the GPU holds, so the walks and cuts of a stage share theirs.
static Light_Walk light_walk;
void light_walk_begin(bool ordered) {
    light_walk.held = 0u;
    light_walk.visits = 0u;
    light_walk.ordered = ordered;
    light_walk.cut = false;
}
void light_walk_hold(uint at, float weight, float need) {
    if (light_walk.held >= LIGHT_WALK_HELD) {
        light_walk.cut = true;
        return;
    }
    light_walk.at[light_walk.held] = at;
    light_walk.weight[light_walk.held] = weight;
    light_walk.need[light_walk.held] = need;
    light_walk.held++;
}
// Takes the group to open next out of the walk: false when none is left or
// opening it would pass LIGHT_WALK_MAX visits.
bool light_walk_next(out uint at, out float weight) {
    at = 0u;
    weight = 0.0;
    if (light_walk.held == 0u) return false;
    if (light_walk.visits + 2u > LIGHT_WALK_MAX) {
        light_walk.cut = true;
        return false;
    }
    uint neediest = light_walk.held - 1u;
    if (light_walk.ordered) {
        for (uint i = 0u; i + 1u < light_walk.held; i++) {
            if (light_walk.need[i] > light_walk.need[neediest]) neediest = i;
        }
    }
    at = light_walk.at[neediest];
    weight = light_walk.weight[neediest];
    light_walk.held--;
    light_walk.at[neediest] = light_walk.at[light_walk.held];
    light_walk.weight[neediest] = light_walk.weight[light_walk.held];
    light_walk.need[neediest] = light_walk.need[light_walk.held];
    return true;
}

// The light the local lights give a point, roughly: groups smaller than
// ESTIMATE_GROUPED of their distance stand for their lights, larger than
// ESTIMATE_OPENED their children do, and in between both, so that it changes
// smoothly from a point to the next; so too by how much their window bends
// (node_bend), where some of their lights reach the point and others not.
// It sets how much a group of the finer sum may err. `root`: the tree it
// walks, that of the lights with shadows (0) or that of those without
// (frame.shadowless_lights). `share`: each by that share of its light
// (LIGHT_SHARE_*).
static const float ESTIMATE_GROUPED = 0.5;
static const float ESTIMATE_OPENED = 1.0;
// How far a group whose center lies that far from a point opens for its estimate.
float estimate_opened(Light_Node node, float distance_squared) {
    return smoothstep(ESTIMATE_GROUPED, ESTIMATE_OPENED, max(node.center_radius.w * rsqrt(max(distance_squared, 1e-12)), node_bend(node, sqrt(distance_squared))));
}
// What a node adds to the estimate of a point as it stands for its lights,
// and in `opened` the share of it its children add instead. `stands`: a
// group that stands for its lights whatever the point makes of it.
float estimate_node(Light_Node node, float3 position, float3 normal, uint share, bool stands, out float opened, out float distance_squared) {
    opened = 0.0;
    if (!node_reaches(node, position, normal, distance_squared, share)) return 0.0;
    if (!stands && (node.flags & LIGHT_NODE_LEAF) == 0u) opened = estimate_opened(node, distance_squared);
    if (!(opened < 1.0)) return 0.0;
    float3 direction;
    float distance;
    return luminance(node_contribution(node, position, normal, direction, distance)) * ((1.0 - opened) * node_share(node, share));
}
float estimate_visit(uint at, float weight, float3 position, float3 normal, uint share) {
    light_walk.visits++;
    Light_Node node = light_nodes[at];
    float opened, distance_squared;
    float total = weight * estimate_node(node, position, normal, share, false, opened, distance_squared);
    if (opened > 0.0 && light_node_opens(node, at)) light_walk_hold(at, weight * opened, light_walk.ordered ? weight * opened * node_need(node, distance_squared, position, normal, share) : 0.0);
    return total;
}
float lights_estimate_walk(float3 position, float3 normal, uint root, uint share) {
    float total = estimate_visit(root, 1.0, position, normal, share);
    uint at;
    float weight;
    [loop]
    while (light_walk_next(at, weight)) {
        total += estimate_visit(at + 1u, weight, position, normal, share);
        total += estimate_visit(light_nodes[at].child, weight, position, normal, share);
    }
    if (!light_walk.ordered) return total;
    for (uint i = 0u; i < light_walk.held; i++) {
        Light_Node node = light_nodes[light_walk.at[i]];
        float3 direction;
        float distance;
        total += luminance(node_contribution(node, position, normal, direction, distance)) * (light_walk.weight[i] * node_share(node, share));
    }
    return total;
}
float lights_estimate(float3 position, float3 normal, uint root = 0u, uint share = LIGHT_SHARE_ALL) {
    float total = 0.0;
    // One walk in the code: the second, in order, only after one cut short.
    [loop]
    for (uint ordered = 0u; ordered < 2u; ordered++) {
        light_walk_begin(ordered != 0u);
        total = lights_estimate_walk(position, normal, root, share);
        if (!light_walk.cut) break;
    }
    return total;
}

// What a group sends from the point towards its viewer as one light, and
// `doubt`, as group_contribution. The falloff bends up: over lights spread
// around the center its mean is above its value there, by about the square
// of the spread over the distance, which is small in a group that stands for
// its lights here.
float3 group_radiance(Light_Node node, Shading s, out float doubt) {
    float3 direction;
    float distance;
    float3 irradiance = group_contribution(node, s.position, s.normal, direction, distance, doubt);
    return group_radiance_of(node, s, irradiance, direction, distance);
}
// The same from what group_contribution gave the point.
float3 group_radiance_of(Light_Node node, Shading s, float3 irradiance, float3 direction, float distance) {
    if (!(luminance(irradiance) > 0.0)) return float3(0.0);
    irradiance *= 1.0 + node.spread * node.spread / max(distance * distance, 1e-8);
    return irradiance * shading_response(s, direction, distance, node.spread);
}

// The light the local lights send from the point towards its viewer, with
// nothing in their way: the tree opened as far as the point needs, within a
// walk. `total` is roughly how much light reaches it, what a group may err
// against; without it the tree says. `root`: the tree of the lights with
// shadows (0) or that of those without (shadowless_lighting). `share`: each
// by that share of its light (LIGHT_SHARE_*).
// What a node sends from the point as it stands for its lights, and in
// `opened` the share of it its children send instead. `stands`: a group
// that stands for its lights whatever its doubt.
float3 local_node(Light_Node node, Shading s, float total, uint share, bool stands, out float opened, out float distance_squared) {
    opened = 0.0;
    if (!node_reaches(node, s.position, s.normal, distance_squared, share)) return float3(0.0);
    float shared = node_share(node, share);
    if ((node.flags & LIGHT_NODE_LEAF) != 0u) {
        float3 direction;
        float distance;
        return light_radiance(lights[node.child], s, direction, distance) * shared;
    }
    if (!stands) opened = smoothstep(GROUP_NEAR, GROUP_INSIDE, node.center_radius.w * rsqrt(max(distance_squared, 1e-12)));
    if (!(opened < 1.0)) return float3(0.0);
    float doubt;
    float3 radiance = group_radiance(node, s, doubt);
    if (!stands) opened = max(opened, smoothstep(LIGHTS_GROUPED, LIGHTS_OPENED, doubt / total));
    return radiance * ((1.0 - opened) * shared);
}
float3 local_visit(uint at, float weight, Shading s, float total, uint share) {
    light_walk.visits++;
    Light_Node node = light_nodes[at];
    float opened, distance_squared;
    float3 radiance = weight * local_node(node, s, total, share, false, opened, distance_squared);
    if (opened > 0.0 && light_node_opens(node, at)) light_walk_hold(at, weight * opened, light_walk.ordered ? weight * opened * node_need(node, distance_squared, s.position, s.normal, share) : 0.0);
    return radiance;
}
float3 local_lighting_walk(Shading s, float total, uint root, uint share) {
    float3 result = local_visit(root, 1.0, s, total, share);
    uint at;
    float weight;
    [loop]
    while (light_walk_next(at, weight)) {
        result += local_visit(at + 1u, weight, s, total, share);
        result += local_visit(light_nodes[at].child, weight, s, total, share);
    }
    if (!light_walk.ordered) return result;
    for (uint i = 0u; i < light_walk.held; i++) {
        Light_Node node = light_nodes[light_walk.at[i]];
        float doubt;
        result += group_radiance(node, s, doubt) * (light_walk.weight[i] * node_share(node, share));
    }
    return result;
}
float3 local_lighting_of(Shading s, float total, uint root, uint share) {
    total = max(total, 1e-8);
    float3 result = float3(0.0);
    [loop]
    for (uint ordered = 0u; ordered < 2u; ordered++) {
        light_walk_begin(ordered != 0u);
        result = local_lighting_walk(s, total, root, share);
        if (!light_walk.cut) break;
    }
    return result;
}
float3 local_lighting(Shading s, float total, uint root = 0u, uint share = LIGHT_SHARE_ALL) {
    if (frame.light_nodes == 0u) return float3(0.0);
    if (!(total > 0.0)) total = lights_estimate(s.position, s.normal, root, share);
    return local_lighting_of(s, total, root, share);
}

// The light the local lights that cast no shadows send from the point
// towards its viewer: whatever stands in their way, with no rays and out of
// the budgets of shadows. `known`: the light of the others that reaches it,
// as lights_estimate sums it, which a group may err against with theirs.
// `share`: as for local_lighting.
float3 shadowless_lighting(Shading s, float known, uint share = LIGHT_SHARE_ALL) {
    uint root = frame.shadowless_lights;
    if (root == 0u) return float3(0.0);
    float total = max(known, 0.0) + lights_estimate(s.position, s.normal, root, share);
    return local_lighting_of(s, total, root, share);
}

// Whether a node is one of the lights that cast no shadows.
bool light_node_shadowless(uint at) {
    return frame.shadowless_lights != 0u && at >= frame.shadowless_lights;
}

// How much a node of a cut needs to open to its children (node_need). -2: it
// does not reach the point or gives none of the share of its light; -1: a
// leaf, which does not open.
float cut_need(uint index, float3 position, float3 normal, uint share) {
    Light_Node node = light_nodes[index];
    float distance_squared;
    if (!node_reaches(node, position, normal, distance_squared, share)) return -2.0;
    if (!light_node_opens(node, index)) return -1.0;
    return node_need(node, distance_squared, position, normal, share);
}

// The nodes a point lights through a shadow ray each: every light that
// reaches the point while they fit in `budget`, and otherwise groups that
// stand for them, half as many: from the root, the node that most needs it
// opens to its children while there is room. Every light that reaches the
// point is under one of the nodes, and a leaf among them is a light alone.
// `share`: only lights that give some of that share of their light.
// The nodes of the last cut of a thread (light_cut) and, while it is made,
// how much each needs to open (cut_need): one cut at a time (light_walk).
static uint light_cut_nodes[LIGHT_CUT_MAX];
static float light_cut_needs[LIGHT_CUT_MAX];
uint light_cut(float3 position, float3 normal, uint budget, uint share = LIGHT_SHARE_ALL) {
    budget = min(budget, LIGHT_CUT_MAX);
    if (frame.light_nodes == 0u || budget == 0u) return 0u;
    uint count = 0u;
    {
        uint depth = 0u;
        uint at = 0u;
        // Lights known to reach the point: those of a group wholly within
        // their range and above the horizon. More than the budget of them
        // and the search stops at once.
        uint known = 0u;
        bool fits = true;
        [loop]
        while (true) {
            Light_Node node = light_nodes[at];
            float distance_squared;
            if (node_reaches(node, position, normal, distance_squared, share)) {
                if ((node.flags & LIGHT_NODE_LEAF) == 0u) {
                    float radius = node.center_radius.w;
                    float distance = sqrt(distance_squared);
                    if (distance + radius <= 0.9 * node.range_low && dot(node.center_radius.xyz - position, normal) >= radius) {
                        known += node.flags >> LIGHT_NODE_COUNT_SHIFT;
                        if (count + known > budget) {
                            fits = false;
                            break;
                        }
                    }
                    if (depth < LIGHT_TREE_DEPTH && light_node_opens(node, at)) {
                        // The nearer child first: a crowd of lights shows sooner.
                        float3 first = light_nodes[at + 1u].center_radius.xyz - position;
                        float3 second = light_nodes[node.child].center_radius.xyz - position;
                        bool near_first = dot(first, first) <= dot(second, second);
                        light_pending[depth] = near_first ? node.child : at + 1u;
                        depth++;
                        at = near_first ? at + 1u : node.child;
                        continue;
                    }
                }
                if (count == budget) {
                    fits = false;
                    break;
                }
                light_cut_nodes[count] = at;
                count++;
            }
            if (depth == 0u) break;
            depth--;
            at = light_pending[depth];
        }
        if (fits) return count;
    }
    // More lights reach the point than the budget: groups stand for them,
    // half as many, their rays spread over their lights by the blocks.
    budget = max(budget / 2u, 1u);
    float root = cut_need(0u, position, normal, share);
    if (root < -1.5) return 0u;
    light_cut_nodes[0] = 0u;
    light_cut_needs[0] = root;
    count = 1u;
    [loop]
    while (true) {
        uint neediest = LIGHT_CUT_MAX;
        float most = -0.5;
        for (uint i = 0u; i < count; i++) {
            if (light_cut_needs[i] > most) {
                most = light_cut_needs[i];
                neediest = i;
            }
        }
        if (neediest == LIGHT_CUT_MAX) break;
        uint first = light_cut_nodes[neediest] + 1u;
        uint second = light_nodes[light_cut_nodes[neediest]].child;
        float a = cut_need(first, position, normal, share);
        float b = cut_need(second, position, normal, share);
        if (a > -1.5 && b > -1.5) {
            if (count >= budget) break;
            light_cut_nodes[neediest] = first;
            light_cut_needs[neediest] = a;
            light_cut_nodes[count] = second;
            light_cut_needs[count] = b;
            count++;
        } else if (a > -1.5 || b > -1.5) {
            light_cut_nodes[neediest] = a > -1.5 ? first : second;
            light_cut_needs[neediest] = max(a, b);
        } else {
            count--;
            light_cut_nodes[neediest] = light_cut_nodes[count];
            light_cut_needs[neediest] = light_cut_needs[count];
        }
    }
    return count;
}

// The cone of a light for light_weight_at: none; a rectangle, which lights
// the side its axis faces; or a spot, which fades between two cosines.
#define LIGHT_CONE_NONE 0u
#define LIGHT_CONE_RECT 1u
#define LIGHT_CONE_SPOT 2u

// About what a light gives a point with that normal, with nothing in its way,
// to choose among lights by: its power over the square of the distance, no
// nearer than the radius of the sphere that holds it, by the share of that
// sphere above the horizon of the surface (all of it for a point of a medium,
// whose normal is zero), by its cone and by the window of its range. None
// only where it gives nothing. The samples of the grid of the lights
// (light_weight) and the walks of the tree (node_weight) weigh a light so.
float light_weight_at(float3 center, float range, float power, float extent, uint cone, float3 axis, float2 cosines, float3 position, float3 normal) {
    float3 to = center - position;
    float d2 = dot(to, to);
    if (d2 >= range * range) return 0.0;
    float inverse = rsqrt(max(d2, 1e-12));
    float facing = dot(normal, normal) > 0.5 ? saturate((dot(normal, to) + extent) * inverse) : 1.0;
    if (!(facing > 0.0)) return 0.0;
    float shown = 1.0;
    if (cone != LIGHT_CONE_NONE) {
        float along = -dot(to, axis) * inverse;
        if (cone == LIGHT_CONE_RECT) {
            if (!(along > 0.0)) return 0.0;
            shown = saturate(along + extent * inverse);
        } else {
            shown = smoothstep(cosines.x, cosines.y, along);
            if (!(shown > 0.0)) return 0.0;
        }
    }
    return power * facing * shown * light_window(d2 * inverse, range) / max(d2, extent * extent);
}

// light_weight_at of a light: a spot fades from LIGHT_SPOT_FULL of its angle out, as its
// light does (light_contribution).
float light_weight_of(Light l, float3 position, float3 normal) {
    bool rect = light_is_rect(l);
    bool spot = !rect && l.direction_cone.w > 0.5 * LIGHT_POINT;
    float2 cosines = spot ? float2(l.direction_cone.w, cos(acos(l.direction_cone.w) * LIGHT_SPOT_FULL)) : float2(0.0);
    uint cone = rect ? LIGHT_CONE_RECT : spot ? LIGHT_CONE_SPOT : LIGHT_CONE_NONE;
    return light_weight_at(l.position_range.xyz, l.position_range.w, luminance(l.color_intensity.rgb) * l.color_intensity.w, light_extent(l), cone, l.direction_cone.xyz, cosines, position, normal);
}

// The leaf under a node that `pick`, from 0 to 1, falls on when each light
// takes a share about as large as the light it gives the point: a light as
// light_weight_of weighs it; a group as bright as its lights, over the square
// of the distance to it, by the cosine of its sphere and in the window of its
// range. The center of a group can lie inside the lamp of its brightest
// light: its shadow rays go to a light. A normal of zero is a point of a
// medium, which takes light from every side. A group a walk does not open
// (light_node_opens) is where it ends. `share`: LIGHT_SHARE_*, the share of
// their light it weighs; a light of none is never where it ends.
float node_weight(Light_Node node, float3 position, float3 normal, uint share = LIGHT_SHARE_ALL) {
    float shared = node_share(node, share);
    if (!(shared > 0.0)) return 0.0;
    if ((node.flags & LIGHT_NODE_LEAF) != 0u) return light_weight_of(lights[node.child], position, normal) * shared;
    float3 delta = node.center_radius.xyz - position;
    float distance = length(delta);
    float rising = node_rising(normal, delta, distance, node.center_radius.w);
    return luminance(node.power_reach.rgb) * shared * node_aim(node, position) * rising * light_window(distance, node.range_high + node.center_radius.w) / max(distance * distance, node.spread * node.spread + 1e-4);
}
uint node_light(uint at, float pick, float3 position, float3 normal, out float chance_of, uint share = LIGHT_SHARE_ALL) {
    chance_of = 1.0;
    [loop]
    while (true) {
        Light_Node node = light_nodes[at];
        if (!light_node_opens(node, at)) return at;
        float first = node_weight(light_nodes[at + 1u], position, normal, share);
        float second = node_weight(light_nodes[node.child], position, normal, share);
        float chance = first + second > 0.0 ? first / (first + second) : 0.5;
        if (pick < chance) {
            pick = pick / max(chance, 1e-6);
            chance_of *= chance;
            at = at + 1u;
        } else {
            pick = saturate((pick - chance) / max(1.0 - chance, 1e-6));
            chance_of *= 1.0 - chance;
            at = node.child;
        }
    }
    return at;
}

// Surface offset for secondary rays. Camera-visible surfaces scale it with
// their distance to the eye that sees them (depth precision, and coarse raster
// LODs while traced geometry is always level 0); ray hits scale it with the
// hit distance so camera-independent results (probes) never depend on where
// the camera is.
float view_bias(float distance) {
    return 0.01 + 0.0015 * distance;
}
float hit_bias(float hit_distance) {
    return 0.01 + 0.0005 * hit_distance;
}
float3 offset_origin(float3 position, float3 normal, float bias) {
    return position + normal * bias;
}

// Light that would add less than LIGHT_CUTOFF once exposed as the view
// (frame.exposure) is not worth its shadow ray: glass, which reflects a light
// only inside its highlight, traces almost none. In render units it would cut
// the light of a room after a light hundreds of times stronger anywhere in
// the scene lowered the light scale: the probes lost the lamp of the room.
static const float LIGHT_CUTOFF = 1e-4;
float light_cutoff() { return frame.exposure > 0.0 ? LIGHT_CUTOFF / frame.exposure : LIGHT_CUTOFF; }

#ifdef MIRAI_HOOK_LIGHTS
// A light an extension adds at a point, the one its shadow ray leaves from:
// what it sends to the surface with nothing in its way (color, intensity,
// cosine and attenuation, and the share of it the extension lets through),
// where it comes from, and the ray, or the two rays one after the other, to a
// point of it that say what stands in its way.
struct Extension_Light {
    float3 irradiance;
    float3 direction;      // unit, towards the light as the surface sees it
    float reach;           // how far the shadow ray goes along it
    float3 beyond_origin;  // a second ray, traced when beyond_reach is above 0
    float3 beyond_direction;
    float beyond_reach;
    float radius;          // how far from its center the light comes from, metres at its distance: it opens the penumbra
    // A light of one of the kinds of the scene, where the surface sees it, and
    // the share of it the extension lets through: its lobes are those of
    // light_lobes, as on its own side. Without it (the sun behind a portal),
    // irradiance and direction. Shaped or not, the light_shares of shape are
    // those of the light.
    bool shaped;
    Light shape;
    float share;
};
// The light hooks of the generation (extension_hooks.slang). They trace nothing.
// `point`: the point of the light the shadow ray goes to, `x` of sixteen (its
// fraction: where in its cell) and `y` how its disc is turned, as light_point
// takes them; x below 0, its center.
uint mirai_extension_light_count();
bool mirai_extension_light(uint index, float3 position, float3 normal, float2 point, out Extension_Light light);

// What a surface reflects towards its viewer of a light of extensions asked
// for its center, diffuse and specular.
void extension_lobes(Shading s, Extension_Light light, out float3 diffuse, out float3 specular) {
    if (light.shaped) {
        light_lobes(light.shape, s, diffuse, specular);
        diffuse *= light.share;
        specular *= light.share;
        return;
    }
    shading_lobes(s, light.direction, highlight_at(light.direction), highlight_at(light.direction), diffuse, specular);
    diffuse *= light.irradiance;
    specular *= light.irradiance;
}
float3 extension_radiance(Shading s, Extension_Light light) {
    float3 diffuse, specular;
    extension_lobes(s, light, diffuse, specular);
    return diffuse + specular;
}
#endif

// The lights direct_lighting adds up; LIGHTS_BOUNCED: each by the share of
// its light the probes gather (frame.sun_shares, Light_Node.indirect, and
// light_shares of the shape of a light of extensions); LIGHTS_SCATTERED: by
// the share media scatter; LIGHTS_CHANGES: and whether what the point gets
// of the sun and the local lights may have changed since the frame before;
// LIGHTS_THROUGH: the point is the other side of a thin surface that lets
// light through (shading_back, its diffuse what it lets through): where the
// sun or a light is hidden from it, what of it comes through the thin
// surfaces that let light through in the way, each taken as one of its kind
// (trace_through), so that a leaf under leaves gets a share that falls with
// each leaf above, and none under anything else.
#define LIGHTS_SUN 1u
#define LIGHTS_LOCAL 2u
#define LIGHTS_EXTENSION 4u
#define LIGHTS_ALL 7u
#define LIGHTS_BOUNCED 8u
#define LIGHTS_SCATTERED 16u
#define LIGHTS_CHANGES 32u
#define LIGHTS_THROUGH 64u

// The share of a light that reaches the other side of a thin surface that
// the maps see `seen` of (mapped), or that they do not hold: through the thin
// surfaces that let light through in the way, each leaving `each`
// (trace_through). With the maps, the ray opens only what they hide and only
// where it crossed such a surface: where it met nothing, what hides the light
// from the maps is what the ray passed beside (the edge of a penumbra).
float3 light_through(float seen, bool mapped, float3 origin, float3 direction, float reach, float3 each) {
    uint crossed;
    float3 through = trace_through(origin, direction, reach, each, crossed);
    if (!mapped) return through;
    return seen + (1.0 - seen) * (crossed != 0u ? through : float3(0.0));
}

// Whether a light that moved since the frame before (light_moved) reaches
// the point where it is now.
bool lights_moved_near(float3 position) {
    if ((frame.moved.z & MOVED_LIGHTS_ALL) != 0u) return true;
    for (uint i = 0u; i < frame.moved.y; i++) {
        float4 place = lights[frame.moved_lights[i / 4u][i % 4u]].position_range;
        float3 to = place.xyz - position;
        if (dot(to, to) < place.w * place.w) return true;
    }
    return false;
}

// Where the shadow ray of node `at` of a cut goes from a point: to the light
// of a leaf, or of a group to the light in the middle of its share; to the
// point of a rectangle or a capsule the point aims at, else to its center.
// Gives that light, the direction and how far the ray goes.
uint cut_ray(uint at, float3 position, float3 normal, uint share, out float3 direction, out float reach) {
    Light_Node node = light_nodes[at];
    if ((node.flags & LIGHT_NODE_LEAF) == 0u) {
        float chance;
        node = light_nodes[node_light(at, 0.5, position, normal, chance, share)];
    }
    Light aimed = lights[node.child];
    float3 toward = light_is_rect(aimed) || light_is_capsule(aimed) ? light_aim(aimed, position, normal) : aimed.position_range.xyz - position;
    float distance = length(toward);
    direction = toward / max(distance, 1e-6);
    reach = light_reach(aimed, distance);
    return node.child;
}

// Whether what direct_lighting gives a point with LIGHTS_CHANGES may have
// changed since the frame before, by the same tests on the same rays, without
// taking its light: for a pass that keeps the light of a point that did not
// change. It tests every node of the cut, also those whose light it would
// leave out.
bool lights_changed(float3 position, float3 normal, float bias, uint budget, uint which) {
    if (all(frame.moved.xyz == 0u)) return false;
    float3 origin = offset_origin(position, normal, bias);
    if ((which & LIGHTS_SUN) != 0u && frame.sun_direction.w > 0.5) {
        if ((frame.moved.z & MOVED_SUN) != 0u || occluder_changed(origin, frame.sun_direction.xyz, sun_reach(origin, frame.sun_direction.xyz), INVALID, FLT_MAX)) return true;
    }
    if ((which & LIGHTS_LOCAL) == 0u) return false;
    if (lights_moved_near(position)) return true;
    if (frame.moved.x == 0u) return false;
    uint share = (which & LIGHTS_BOUNCED) != 0u ? LIGHT_SHARE_BOUNCED : (which & LIGHTS_SCATTERED) != 0u ? LIGHT_SHARE_SCATTERED : LIGHT_SHARE_ALL;
    uint count = light_cut(position, normal, budget, share);
    for (uint i = 0u; i < count; i++) {
        float3 direction;
        float reach;
        cut_ray(light_cut_nodes[i], position, normal, share, direction, reach);
        if (occluder_changed(origin, direction, reach, INVALID, FLT_MAX)) return true;
    }
    return false;
}

// The direct light a point reflects towards its viewer: the sun, the local
// lights and those of extensions, each through its shadow ray. The local
// lights are the nodes of the cut of the point, at most `budget`: the lights
// that reach it one by one while they fit, and groups for the far ones when
// they do not; those that cast no shadows add their light without rays. A
// shadow ray stops at the surface of a light, so a lamp that holds its light
// casts no shadow of it. A point the vertex hook moved by `swayed` from where
// it rests (pixel_rest) sends its rays from there. The rays of the lights of extensions go to
// `extension_point` of them (mirai_extension_light): the center unless the
// caller averages points over frames. A point of a medium (shading_medium)
// sends the light of each by its phase function. `changed`, with
// LIGHTS_CHANGES: also whether a light that reaches the point moved, or what
// casts shadows changed on the way of a shadow ray (occluder_changed).
//
// Every shadow ray goes through one traversal in the source: a call more
// would be another copy of it in every stage.
float3 direct_lighting(Shading s, float bias, uint budget, uint which, float2 extension_point, inout bool changed, float3 swayed = float3(0.0)) {
    // Its rays leave from where the point rests: what they meet rests there.
    float3 rest = s.position - swayed;
    float3 origin = offset_origin(rest, s.normal, bias);
    uint share = (which & LIGHTS_BOUNCED) != 0u ? LIGHT_SHARE_BOUNCED : (which & LIGHTS_SCATTERED) != 0u ? LIGHT_SHARE_SCATTERED : LIGHT_SHARE_ALL;
    bool changes = (which & LIGHTS_CHANGES) != 0u;
    float sun_share = share == LIGHT_SHARE_BOUNCED ? frame.sun_shares.x : share == LIGHT_SHARE_SCATTERED ? frame.sun_shares.y : 1.0;
    uint local_items = (which & LIGHTS_LOCAL) != 0u ? light_cut(s.position, s.normal, budget, share) : 0u;
    uint items = 1u + local_items;
#ifdef MIRAI_HOOK_LIGHTS
    if ((which & LIGHTS_EXTENSION) != 0u) items += mirai_extension_light_count();
    float3 extension = float3(0.0);
#endif
    float3 sun = float3(0.0);
    float3 local = float3(0.0);
    // Item 0 is the sun; the local lights follow, then those of extensions.
    for (uint item = (which & LIGHTS_SUN) != 0u ? 0u : 1u; item < items; item++) {
        float3 radiance = float3(0.0);
        float3 direction = float3(0.0, 1.0, 0.0);
        float reach = 0.0;
        float mapped = -1.0;
        if (item == 0u) {
            if (frame.sun_direction.w < 0.5 || !(sun_share > 0.0)) continue;
            float cosine = dot(s.normal, s.normal) > 0.5 ? dot(s.normal, frame.sun_direction.xyz) : 1.0;
            if (cosine <= 0.0) continue;
            radiance = sun_light(s.position) * (cosine * sun_share) * shading_response(s, frame.sun_direction.xyz);
            if (luminance(radiance) <= light_cutoff()) continue;
            direction = frame.sun_direction.xyz;
            reach = sun_reach(origin, direction);
            if (changes) changed = changed || (frame.moved.z & MOVED_SUN) != 0u || occluder_changed(origin, direction, reach, INVALID, FLT_MAX);
#ifdef MIRAI_LIGHT_MAPS
            mapped = sun_shadow_seen(s.position, s.normal, s.across, true, swayed);
#endif
        } else if (item <= local_items) {
            Light_Node node = light_nodes[light_cut_nodes[item - 1u]];
            float distance;
            radiance = node_radiance(node, s, direction, distance) * node_share(node, share);
            if (luminance(radiance) <= light_cutoff()) continue;
            uint aimed = cut_ray(light_cut_nodes[item - 1u], rest, s.normal, share, direction, reach);
            if (changes) changed = changed || occluder_changed(origin, direction, reach, INVALID, FLT_MAX);
#ifdef MIRAI_LIGHT_MAPS
            mapped = light_shadow_seen(aimed, s.position, s.normal, light_extent(lights[aimed]), s.across, swayed);
#endif
        }
        // The other side of a thin surface: its ray, where the maps hide the light or tell nothing, is that of light_through.
        bool thin = (which & LIGHTS_THROUGH) != 0u && item <= local_items;
#ifdef MIRAI_HOOK_LIGHTS
        float3 from = origin;
        float3 beyond_origin = float3(0.0), beyond_direction = float3(0.0);
        float beyond_reach = 0.0;
        if (item > local_items) {
            Extension_Light light;
            if (!mirai_extension_light(item - 1u - local_items, origin, s.normal, extension_point, light)) continue;
            // A point asked for is a point of the light: its own response, as the reference takes it.
            radiance = extension_point.x >= 0.0 ? light.irradiance * shading_response(s, light.direction) : extension_radiance(s, light);
            if (share != LIGHT_SHARE_ALL) radiance *= share == LIGHT_SHARE_BOUNCED ? light_shares(light.shape).x : light_shares(light.shape).y;
            if (luminance(radiance) <= light_cutoff()) continue;
            direction = light.direction;
            reach = light.reach;
            beyond_origin = light.beyond_origin;
            beyond_direction = light.beyond_direction;
            beyond_reach = light.beyond_reach;
        }
        float through = 1.0;
        for (uint segment = 0u; segment < 2u && mapped < 0.0 && !thin; segment++) {
            if (!trace_visible(from, direction, reach, item <= local_items)) through = 0.0;
            if (segment != 0u || beyond_reach <= 0.0 || through <= 0.0) break;
            from = beyond_origin;
            direction = beyond_direction;
            reach = beyond_reach;
        }
        if (mapped >= 0.0 || thin) through = mapped;
        if (item > local_items) {
            extension += radiance * through;
            continue;
        }
#else
        float through = mapped >= 0.0 || thin ? mapped : float(trace_visible(origin, direction, reach));
#endif
        if (thin && through < 1.0) radiance *= light_through(through, mapped >= 0.0, origin, direction, reach, s.diffuse);
        else radiance *= through;
        if (item == 0u) sun = radiance;
        else local += radiance;
    }
    if ((which & LIGHTS_LOCAL) != 0u) {
        // What the others brought, over what the surface reflects of it: the
        // light the groups of those without shadows may err against.
        float3 known = sun + local;
#ifdef MIRAI_HOOK_LIGHTS
        known += extension;
#endif
        local += shadowless_lighting(s, luminance(known) / luminance(max(s.diffuse + specular_albedo(s), float3(0.02))), share);
        if (changes) changed = changed || lights_moved_near(s.position);
    }
#ifdef MIRAI_HOOK_LIGHTS
    return sun + local + extension;
#else
    return sun + local;
#endif
}
float3 direct_lighting(Shading s, float bias, uint budget, uint which = LIGHTS_ALL, float2 extension_point = float2(-1.0, 0.0), float3 swayed = float3(0.0)) {
    bool changed = false;
    return direct_lighting(s, bias, budget, which & ~LIGHTS_CHANGES, extension_point, changed, swayed);
}

// The normal of a hit, facing the ray: the side of its triangle the ray
// arrived at decides it, since an interpolated normal can face along a ray
// that grazes a curved surface, and turning it would light the surface from
// behind.
float3 hit_normal(Surface s, float3 ray_dir) {
    float3 side = dot(s.geometric_normal, s.normal) < 0.0 ? -s.geometric_normal : s.geometric_normal;
    return dot(side, ray_dir) > 0.0 ? -s.normal : s.normal;
}

// Radiance leaving a hit point towards the ray origin: emission plus diffuse
// reflection of the sun, the local lights of its cut and the probe volume
// (the remaining bounces). `gathered`: as a probe gathers it, each light by
// the share of it the probes gather and the volume as it holds it; else as a
// view sees it, the volume by frame.indirect.
float3 shade_hit(Surface s, float3 ray_dir, float hit_distance, uint light_budget, bool gathered = false) {
    float3 n = hit_normal(s, ray_dir);
    uint which = gathered ? LIGHTS_ALL | LIGHTS_BOUNCED : LIGHTS_ALL;
    float around = gathered ? 1.0 : frame.indirect;
    Shading point = shading_diffuse(s.position, n, s.albedo);
    float3 radiance = s.emission + direct_lighting(point, hit_bias(hit_distance), light_budget, which) + s.albedo * (sample_probes(s.position, n, -ray_dir, hit_distance) * around);
    // A thin surface that lets light through: the light of its other side.
    float3 through = surface_transmit(s);
    if (max(through.r, max(through.g, through.b)) > 0.0) {
        Shading back = shading_diffuse(s.position, -n, through);
        radiance += direct_lighting(back, hit_bias(hit_distance), light_budget, which | LIGHTS_THROUGH) + through * (sample_probes(s.position, -n, -ray_dir, hit_distance) * around);
    }
    return radiance;
}

// The same radiance from the probe volume alone, which holds the direct light
// of the surfaces around too: no shadow rays, and no sharp shadows either.
float3 shade_hit_cached(Surface s, float3 ray_dir, float hit_distance) {
    float3 n = hit_normal(s, ray_dir);
    float3 radiance = s.emission + s.albedo * (sample_probes(s.position, n, -ray_dir, hit_distance) * frame.indirect);
    float3 through = surface_transmit(s);
    if (max(through.r, max(through.g, through.b)) > 0.0) radiance += through * (sample_probes(s.position, -n, -ray_dir, hit_distance) * frame.indirect);
    return radiance;
}

// The radiance of a hit as the glossy surface it is, for a reflection sharp
// enough to show the difference: its specular lobe reflects the lights and
// what the probe volume holds around its mirror direction, where shade_hit
// folds it into a diffuse albedo. Without `lights` the direct light comes
// from the probe volume too, as in shade_hit_cached.
float3 shade_hit_glossy(Surface s, float3 ray_dir, float hit_distance, uint light_budget, bool lights) {
    float3 n = hit_normal(s, ray_dir);
    float3 radiance = s.emission;
    Shading point = surface_shading(s, n, -ray_dir);
    // Seen at a grazing angle, the footprint of the ray stretches along the
    // surface past the relief it hits: one sample of that relief catches the
    // highlights of the lights as sparks rather than their mean, so the gloss
    // of the lights fades out there; the probes keep what they reflect.
    Shading lit = point;
    float facing = smoothstep(0.02, 0.15, dot(n, -ray_dir));
    lit.f0 *= facing;
    lit.f90 *= facing;
    if (lights) radiance += direct_lighting(lit, hit_bias(hit_distance), light_budget);
    if (shading_transmits(point)) {
        Shading back = shading_back(point);
        if (lights) radiance += direct_lighting(back, hit_bias(hit_distance), light_budget, LIGHTS_ALL | LIGHTS_THROUGH);
        radiance += point.transmit * (sample_probes(s.position, -n, -ray_dir, hit_distance) * frame.indirect);
    }
    // What a surface that reflects little would add is not worth the lookup;
    // it comes in gradually, so no edge shows where a floor starts to shine.
    float3 specular = specular_albedo(point);
    float shown = smoothstep(0.1, 0.2, max(specular.r, max(specular.g, specular.b)));
    Probe_Directions directions = probe_directions(n);
    if (shown > 0.0) {
        directions.at[PROBE_SPECULAR] = dominant_direction(point);
        directions.rough[PROBE_SPECULAR] = point.roughness;
        directions.wants |= 1u << PROBE_SPECULAR;
        if (point.coat > 0.0) {
            directions.at[PROBE_COAT] = coat_dominant_direction(point);
            directions.rough[PROBE_COAT] = point.coat_roughness;
            directions.wants |= 1u << PROBE_COAT;
        }
    }
    float4 around[PROBE_READS];
    sample_probes_around(s.position, n, -ray_dir, directions, around, hit_distance);
    Indirect light = indirect_make(around[PROBE_DIFFUSE].rgb * frame.indirect, probe_specular(around[PROBE_SPECULAR], directions.at[PROBE_SPECULAR], point.roughness) * (shown * frame.indirect), 1.0);
    light.coat_radiance = probe_specular(around[PROBE_COAT], directions.at[PROBE_COAT], point.coat_roughness) * (shown * frame.indirect);
    return radiance + indirect_compose(point, light);
}

#endif
