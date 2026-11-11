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
// and traces the rays only where they do not; with SHADOW_TINT_SLOT, the glass
// on the way from the tint the maps keep of it.
#ifdef MIRAI_LIGHT_MAPS
#include "shadow_maps.slang"
#endif

// No light is smaller than this, metres: closer to its center a point gets
// the light of its surface.
static const float LIGHT_RADIUS_MIN = 0.01;

// The irradiance a sphere of light of unit intensity gives a surface, with
// its center `distance` away towards a direction at `cosine` of the normal:
// the cosine over the square of the distance while all of it is above the
// horizon, and what of it is as it sets (Snyder 1996, in the form of Lagarde
// and de Rousiers 2014). Inside the sphere, the light of its surface.
float sphere_irradiance(float cosine, float distance, float radius) {
    float r = max(radius, LIGHT_RADIUS_MIN);
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
    return max(light.size.x, LIGHT_RADIUS_MIN) + light.size.y;
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
    float radius = max(light.size.x, LIGHT_RADIUS_MIN);
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

// The color a rectangle shows at a place of it, blurred over `blur` metres of
// it: the emission of its material, whose texture lies across it as across a
// quad from (0, 1) to (1, 0), over the luminance of the emission of the
// material without its texture (the intensity of the light gives how bright),
// or white.
float3 rect_emission(Light light, float2 place, float blur) {
    uint row = asuint(light.size.w);
    if (row == 0u) return float3(1.0);
    Material m = material_row(row);
    float3 emission = m.emission / max(luminance(m.emission), 1e-6);
    if (!material_has(m.textures[MATERIAL_MAP_EMISSION])) return emission;
    float2 uv = material_map_uv(m, MATERIAL_MAP_EMISSION, 0.5 + 0.5 * float2(place.x, -place.y), 0.5 + 0.5 * float2(place.x, -place.y));
    float2 texels = float2(texture_size(material_textures[mirai_nonuniform(m.textures[MATERIAL_MAP_EMISSION])], 0));
    float level = max(log2(max(blur / (2.0 * max(light.size.y, light.size.z)), 1e-6) * max(texels.x, texels.y)), 0.0);
    // The sampler of materials repeats: the edge of the level sampled stays its own.
    float2 shown = max(texels / exp2(ceil(level)), float2(1.0));
    uv = clamp(uv, 0.5 / shown, 1.0 - 0.5 / shown);
    return emission * material_textures[mirai_nonuniform(m.textures[MATERIAL_MAP_EMISSION])].SampleLevel(material_sampler, uv, level).rgb;
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
// takes the light from every side alike.
float3 light_contribution(Light light, float3 position, float3 normal, out float3 direction, out float distance) {
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
    if (light.direction_cone.w > -1.5) {
        // Spot lights fade out between 80% of the half-angle and its edge.
        float cos_outer = light.direction_cone.w;
        float cos_inner = cos(acos(cos_outer) * 0.8);
        cone = smoothstep(cos_outer, cos_inner, dot(-direction, light.direction_cone.xyz));
        if (cone <= 0.0) return float3(0.0);
    }
    if (light_is_capsule(light)) return light.color_intensity.rgb * (light.color_intensity.w * cone * capsule_irradiance(light, position, normal) * light_window(distance, light.position_range.w));
    float cosine = dot(normal, normal) > 0.5 ? dot(normal, direction) : 1.0;
    return light.color_intensity.rgb * (light.color_intensity.w * cone * sphere_irradiance(cosine, distance, light.size.x) * light_window(distance, light.position_range.w));
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
    diffuse = float3(0.0);
    specular = float3(0.0);
    float3 irradiance = light_contribution(light, s.position, s.normal, direction, distance);
    if (!(luminance(irradiance) > 0.0)) return;
    if (!s.glossy && s.layers == 0u) {
        diffuse = irradiance * s.diffuse;
        return;
    }
    Highlight base = highlight_at(direction), coat = highlight_at(direction);
    if (light_is_rect(light) || light_is_capsule(light)) {
        base = light_highlight(light, s.position, s.mirror, s.alpha, distance);
        if (s.coat > 0.0) coat = light_highlight(light, s.position, s.coat_mirror, s.coat_alpha, distance);
    } else if (light.size.x > 0.0 && distance > 0.0) {
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
    h.towards = radius > 0.0 ? sphere_highlight(mirror, nearest, radius) : nearest / max(far, 1e-6);
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
// bends: the mean of the window at two points a deviation either side.
// `doubt` bounds how far that may be from the light of its lights: the
// curvature of the falloff and the cosine across their spread; all of it
// where they straddle the horizon of the surface, whose side each of them is
// on the group does not know; and how much the window changes between its
// nearest and farthest light, which can be all of the light of a group whose
// center is beyond the range of its lights and its nearest light is not.
// How much of the light of a node reaches a point by the directions its
// lights face: 1 within the cone that holds them, past it fading out over
// how far beyond it they shine, and 0 beyond that (Conty Estevez and Kulla
// 2018), with the angle the sphere of the node spans from the point taken in
// its favor. A spot fades so to the edge of its cone; a rectangle as a
// cosine; a point lights every way.
float node_aim(Light_Node node, float3 position) {
    if (node.cone.w >= PI - 1e-3) return 1.0;
    float3 away = position - node.center_radius.xyz;
    float distance = length(away);
    float radius = node.center_radius.w;
    if (distance <= radius) return 1.0;
    float theta = acos(clamp(dot(node.cone.xyz, away / distance), -1.0, 1.0));
    float beyond = max(theta - node.cone.w - asin(radius / distance), 0.0);
    if (beyond >= node.emission) return 0.0;
    return cos(beyond * (0.5 * PI) / max(node.emission, 1e-4));
}

float3 group_contribution(Light_Node node, float3 position, float3 normal, out float3 direction, out float distance, out float doubt) {
    float3 delta = node.center_radius.xyz - position;
    distance = length(delta);
    direction = delta / max(distance, 1e-6);
    float aim = node_aim(node, position);
    float cosine = dot(normal, normal) > 0.5 ? dot(normal, direction) : 1.0;
    float deviation = node.spread * 0.57735027;
    float window = 0.5 * (light_window(distance - deviation, node.range) + light_window(distance + deviation, node.range));
    float3 light = node.power_reach.rgb * (aim * sphere_irradiance(cosine, distance, node.spread));
    float spread = node.spread / max(distance, 1e-6);
    float bend = light_window(distance - node.center_radius.w, node.range) - light_window(distance + node.center_radius.w, node.range);
    float horizon = saturate(1.0 - abs(cosine) / max(spread, 1e-6));
    doubt = luminance(light) * ((3.0 * spread * spread + horizon) * window + 0.5 * bend);
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

// Whether any light of a node reaches a point, is not wholly under the
// horizon of its surface and faces it.
bool node_reaches(Light_Node node, float3 position, float3 normal, out float distance_squared) {
    float3 delta = node.center_radius.xyz - position;
    distance_squared = dot(delta, delta);
    return distance_squared < node.power_reach.w * node.power_reach.w && dot(delta, normal) > -node.center_radius.w && node_aim(node, position) > 0.0;
}

// Whether a walk goes down from the node at `at` to its children: a group
// whose children come after it in the tree, as its depth-first order puts
// them (render/light_tree.odin). Every step of a walk then goes further on,
// and a node that leads back ends the walk there instead of looping.
bool light_node_opens(Light_Node node, uint at) {
    return (node.flags & LIGHT_NODE_LEAF) == 0u && node.child > at && node.child < frame.light_nodes;
}

// Whether a light stands for the emission of an instance: one of the lights
// lies inside its bounds, which are not much larger than the sphere of that
// light, as the globe of a lamp around the light that gives its light.
static const float EMITTER_LIGHT_SIZES = 2.0;
bool light_stands_for(uint instance) {
    if (frame.light_nodes == 0u) return false;
    Instance inst = scene_instance(instance);
    float3 low = inst.bounds_min.xyz;
    float3 high = inst.bounds_max.xyz;
    float extent = 0.5 * max(high.x - low.x, max(high.y - low.y, high.z - low.z));
    uint pending[LIGHT_TREE_DEPTH];
    uint depth = 0u;
    uint at = 0u;
    [loop]
    while (true) {
        Light_Node node = light_nodes[at];
        float3 away = clamp(node.center_radius.xyz, low, high) - node.center_radius.xyz;
        if (dot(away, away) <= node.center_radius.w * node.center_radius.w) {
            if ((node.flags & LIGHT_NODE_LEAF) != 0u) {
                Light light = lights[node.child];
                if (all(light.position_range.xyz >= low) && all(light.position_range.xyz <= high) && extent <= EMITTER_LIGHT_SIZES * light_extent(light)) return true;
            } else if (depth < LIGHT_TREE_DEPTH && light_node_opens(node, at)) {
                pending[depth] = node.child;
                depth++;
                at++;
                continue;
            }
        }
        if (depth == 0u) break;
        depth--;
        at = pending[depth];
    }
    return false;
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

// The light the local lights give a point, roughly: groups smaller than
// ESTIMATE_GROUPED of their distance stand for their lights, larger than
// ESTIMATE_OPENED their children do, and in between both, so that it changes
// smoothly from a point to the next. It sets how much a group of the finer
// sum may err. `root`: the tree it walks, that of the lights with shadows
// (0) or that of those without (frame.shadowless_lights.x).
static const float ESTIMATE_GROUPED = 0.5;
static const float ESTIMATE_OPENED = 1.0;
float lights_estimate(float3 position, float3 normal, uint root = 0u) {
    uint pending[LIGHT_TREE_DEPTH];
    float pending_weight[LIGHT_TREE_DEPTH];
    uint depth = 0u;
    uint at = root;
    float weight = 1.0;
    float total = 0.0;
    [loop]
    while (true) {
        Light_Node node = light_nodes[at];
        float distance_squared;
        if (node_reaches(node, position, normal, distance_squared)) {
            float opened = (node.flags & LIGHT_NODE_LEAF) != 0u ? 0.0 : smoothstep(ESTIMATE_GROUPED, ESTIMATE_OPENED, node.center_radius.w * rsqrt(max(distance_squared, 1e-12)));
            if (opened < 1.0) {
                float3 direction;
                float distance;
                total += luminance(node_contribution(node, position, normal, direction, distance)) * (weight * (1.0 - opened));
            }
            if (opened > 0.0 && depth < LIGHT_TREE_DEPTH && light_node_opens(node, at)) {
                weight *= opened;
                pending[depth] = node.child;
                pending_weight[depth] = weight;
                depth++;
                at++;
                continue;
            }
        }
        if (depth == 0u) break;
        depth--;
        at = pending[depth];
        weight = pending_weight[depth];
    }
    return total;
}

// The light the local lights send from the point towards its viewer, with
// nothing in their way: the tree opened as far as the point needs. `total`
// is roughly how much light reaches it, what a group may err against;
// without it the tree says. `root`: the tree of the lights with shadows (0)
// or that of those without (shadowless_lighting).
float3 local_lighting(Shading s, float total, uint root = 0u) {
    float3 result = float3(0.0);
    if (frame.light_nodes == 0u) return result;
    if (!(total > 0.0)) total = lights_estimate(s.position, s.normal, root);
    total = max(total, 1e-8);
    uint pending[LIGHT_TREE_DEPTH];
    float pending_weight[LIGHT_TREE_DEPTH];
    uint depth = 0u;
    uint at = root;
    float weight = 1.0;
    [loop]
    while (true) {
        Light_Node node = light_nodes[at];
        float distance_squared;
        if (node_reaches(node, s.position, s.normal, distance_squared)) {
            float3 direction;
            float distance;
            float opened = 1.0;
            float3 irradiance = float3(0.0);
            if ((node.flags & LIGHT_NODE_LEAF) != 0u) {
                result += light_radiance(lights[node.child], s, direction, distance) * weight;
                opened = 0.0;
            } else if ((node.flags & LIGHT_NODE_SPOT) == 0u) {
                opened = smoothstep(GROUP_NEAR, GROUP_INSIDE, node.center_radius.w * rsqrt(max(distance_squared, 1e-12)));
                if (opened < 1.0) {
                    float doubt;
                    irradiance = group_contribution(node, s.position, s.normal, direction, distance, doubt);
                    opened = max(opened, smoothstep(LIGHTS_GROUPED, LIGHTS_OPENED, doubt / total));
                    // The falloff bends up: over lights spread around the
                    // center its mean is above its value there, by about the
                    // square of the spread over the distance, which is small
                    // in a group that stands for its lights here.
                    irradiance *= 1.0 + node.spread * node.spread / max(distance * distance, 1e-8);
                }
            }
            if (opened < 1.0 && luminance(irradiance) > 0.0) result += irradiance * shading_response(s, direction, distance, node.spread) * (weight * (1.0 - opened));
            if (opened > 0.0 && depth < LIGHT_TREE_DEPTH && light_node_opens(node, at)) {
                weight *= opened;
                pending[depth] = node.child;
                pending_weight[depth] = weight;
                depth++;
                at++;
                continue;
            }
        }
        if (depth == 0u) break;
        depth--;
        at = pending[depth];
        weight = pending_weight[depth];
    }
    return result;
}

// The light the local lights that cast no shadows send from the point
// towards its viewer: whatever stands in their way, with no rays and out of
// the budgets of shadows. `total`: roughly how much light of the others
// reaches it; what a group may err against adds theirs.
float3 shadowless_lighting(Shading s, float total) {
    uint root = frame.shadowless_lights.x;
    if (root == 0u) return float3(0.0);
    return local_lighting(s, max(total, 0.0) + lights_estimate(s.position, s.normal, root), root);
}

// Whether a node is one of the lights that cast no shadows.
bool light_node_shadowless(uint at) {
    return at >= frame.shadowless_lights.x && at < frame.shadowless_lights.y;
}

// How much a node of a cut needs to open to its children: the brighter and
// the wider as the point sees it, the more. -2: it does not reach the point;
// -1: a leaf, which does not open. A group that holds a spot opens first.
float cut_need(uint index, float3 position, float3 normal) {
    Light_Node node = light_nodes[index];
    float distance_squared;
    if (!node_reaches(node, position, normal, distance_squared)) return -2.0;
    if (!light_node_opens(node, index)) return -1.0;
    if ((node.flags & LIGHT_NODE_SPOT) != 0u) return 3e38;
    float distance = sqrt(distance_squared);
    float radius = node.center_radius.w;
    float rising = saturate((dot(node.center_radius.xyz - position, normal) + radius) / max(distance, 1e-6));
    return luminance(node.power_reach.rgb) * node_aim(node, position) * rising / max(distance_squared, radius * radius) * min(radius / max(distance, 1e-6), 1.0);
}

// The nodes a point lights through a shadow ray each: every light that
// reaches the point while they fit in `budget`, and otherwise groups that
// stand for them, half as many: from the root, the node that most needs it
// opens to its children while there is room. Every light that reaches the
// point is under one of the nodes, and a leaf among them is a light alone.
uint light_cut(float3 position, float3 normal, uint budget, inout uint cut[LIGHT_CUT_MAX]) {
    budget = min(budget, LIGHT_CUT_MAX);
    if (frame.light_nodes == 0u || budget == 0u) return 0u;
    uint count = 0u;
    {
        uint pending[LIGHT_TREE_DEPTH];
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
            if (node_reaches(node, position, normal, distance_squared)) {
                if ((node.flags & LIGHT_NODE_LEAF) == 0u) {
                    float radius = node.center_radius.w;
                    float distance = sqrt(distance_squared);
                    if (distance + radius <= 0.9 * node.range && dot(node.center_radius.xyz - position, normal) >= radius) {
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
                        pending[depth] = near_first ? node.child : at + 1u;
                        depth++;
                        at = near_first ? at + 1u : node.child;
                        continue;
                    }
                }
                if (count == budget) {
                    fits = false;
                    break;
                }
                cut[count] = at;
                count++;
            }
            if (depth == 0u) break;
            depth--;
            at = pending[depth];
        }
        if (fits) return count;
    }
    // More lights reach the point than the budget: groups stand for them,
    // half as many, their rays spread over their lights by the blocks.
    budget = max(budget / 2u, 1u);
    float need[LIGHT_CUT_MAX];
    float root = cut_need(0u, position, normal);
    if (root < -1.5) return 0u;
    cut[0] = 0u;
    need[0] = root;
    count = 1u;
    [loop]
    while (true) {
        uint neediest = LIGHT_CUT_MAX;
        float most = -0.5;
        for (uint i = 0u; i < count; i++) {
            if (need[i] > most) {
                most = need[i];
                neediest = i;
            }
        }
        if (neediest == LIGHT_CUT_MAX) break;
        uint first = cut[neediest] + 1u;
        uint second = light_nodes[cut[neediest]].child;
        float a = cut_need(first, position, normal);
        float b = cut_need(second, position, normal);
        if (a > -1.5 && b > -1.5) {
            if (count >= budget) break;
            cut[neediest] = first;
            need[neediest] = a;
            cut[count] = second;
            need[count] = b;
            count++;
        } else if (a > -1.5 || b > -1.5) {
            cut[neediest] = a > -1.5 ? first : second;
            need[neediest] = max(a, b);
        } else {
            count--;
            cut[neediest] = cut[count];
            need[neediest] = need[count];
        }
    }
    return count;
}

// The leaf under a node that `pick`, from 0 to 1, falls on when each light
// takes a share about as large as the light it gives the point: as bright as
// its group, over the square of the distance to it, by the cosine of its
// sphere and in the window of its range. The center of a group can lie
// inside the lamp of its brightest light: its shadow rays go to a light. A
// normal of zero is a point of a medium, which takes light from every side.
// A group a walk does not open (light_node_opens) is where it ends.
float node_weight(Light_Node node, float3 position, float3 normal) {
    float3 delta = node.center_radius.xyz - position;
    float distance = length(delta);
    float rising = dot(normal, normal) > 0.5 ? saturate((dot(delta, normal) + node.center_radius.w) / max(distance, 1e-6)) : 1.0;
    return luminance(node.power_reach.rgb) * node_aim(node, position) * rising * light_window(distance, node.range + node.center_radius.w) / max(distance * distance, node.spread * node.spread + 1e-4);
}
uint node_light(uint at, float pick, float3 position, float3 normal, out float chance_of) {
    chance_of = 1.0;
    [loop]
    while (true) {
        Light_Node node = light_nodes[at];
        if (!light_node_opens(node, at)) return at;
        float first = node_weight(light_nodes[at + 1u], position, normal);
        float second = node_weight(light_nodes[node.child], position, normal);
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
    // irradiance and direction.
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

// The lights direct_lighting adds up.
#define LIGHTS_SUN 1u
#define LIGHTS_LOCAL 2u
#define LIGHTS_EXTENSION 4u
#define LIGHTS_ALL 7u

// The direct light a point reflects towards its viewer: the sun, the local
// lights and those of extensions, each through its shadow ray. The local
// lights are the nodes of the cut of the point, at most `budget`: the lights
// that reach it one by one while they fit, and groups for the far ones when
// they do not; those that cast no shadows add their light without rays. A
// shadow ray stops at the surface of a light, so a lamp that holds its light
// casts no shadow of it. The rays of the lights of extensions go to
// `extension_point` of them (mirai_extension_light): the center unless the
// caller averages points over frames.
//
// Every shadow ray goes through one traversal in the source: a call more
// would be another copy of it in every stage.
float3 direct_lighting(Shading s, float bias, uint budget, uint which = LIGHTS_ALL, float2 extension_point = float2(-1.0, 0.0)) {
    float3 origin = offset_origin(s.position, s.normal, bias);
    uint cut[LIGHT_CUT_MAX];
    uint local_items = (which & LIGHTS_LOCAL) != 0u ? light_cut(s.position, s.normal, budget, cut) : 0u;
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
            if (frame.sun_direction.w < 0.5) continue;
            float cosine = dot(s.normal, frame.sun_direction.xyz);
            if (cosine <= 0.0) continue;
            radiance = sun_light(s.position) * cosine * shading_response(s, frame.sun_direction.xyz);
            if (luminance(radiance) <= light_cutoff()) continue;
            direction = frame.sun_direction.xyz;
            reach = sun_reach(origin, direction);
#ifdef MIRAI_LIGHT_MAPS
            mapped = sun_shadow_seen(s.position, s.normal);
#ifdef SHADOW_TINT_SLOT
            Shadow_Map tinted;
            if (mapped > 0.0 && sun_map_of(s.position, tinted)) radiance *= shadow_tint(tinted, s.position);
#endif
#endif
        } else if (item <= local_items) {
            Light_Node node = light_nodes[cut[item - 1u]];
            float distance;
            radiance = node_radiance(node, s, direction, distance);
            if (luminance(radiance) <= light_cutoff()) continue;
            if ((node.flags & LIGHT_NODE_LEAF) == 0u) {
                // A group: the ray goes to the light in the middle of its share.
                float chance;
                Light_Node target = light_nodes[node_light(cut[item - 1u], 0.5, s.position, s.normal, chance)];
                float3 toward = target.center_radius.xyz - s.position;
                distance = length(toward);
                direction = toward / max(distance, 1e-6);
                node = target;
            }
            Light aimed = lights[node.child];
            if (light_is_rect(aimed) || light_is_capsule(aimed)) {
                float3 toward = light_aim(aimed, s.position, s.normal);
                distance = length(toward);
                direction = toward / max(distance, 1e-6);
            }
            reach = light_reach(aimed, distance);
#ifdef MIRAI_LIGHT_MAPS
            mapped = light_shadow_seen(node.child, s.position, s.normal, light_extent(aimed));
#ifdef SHADOW_TINT_SLOT
            Shadow_Map tinted;
            if (mapped > 0.0 && light_map_of(node.child, s.position, tinted)) radiance *= shadow_tint(tinted, s.position);
#endif
#endif
        }
#ifdef MIRAI_HOOK_LIGHTS
        float3 from = origin;
        float3 beyond_origin = float3(0.0), beyond_direction = float3(0.0);
        float beyond_reach = 0.0;
        if (item > local_items) {
            Extension_Light light;
            if (!mirai_extension_light(item - 1u - local_items, origin, s.normal, extension_point, light)) continue;
            // A point asked for is a point of the light: its own response, as the reference takes it.
            radiance = extension_point.x >= 0.0 ? light.irradiance * shading_response(s, light.direction) : extension_radiance(s, light);
            if (luminance(radiance) <= light_cutoff()) continue;
            direction = light.direction;
            reach = light.reach;
            beyond_origin = light.beyond_origin;
            beyond_direction = light.beyond_direction;
            beyond_reach = light.beyond_reach;
        }
#ifdef MIRAI_SHADOW_FILTER_POINTS
        filters_begin();
#endif
        float3 through = float3(1.0);
        for (uint segment = 0u; segment < 2u && mapped < 0.0; segment++) {
            through *= trace_transmission(from, direction, reach, item <= local_items);
            if (segment != 0u || beyond_reach <= 0.0 || max(through.r, max(through.g, through.b)) <= 0.0) break;
            from = beyond_origin;
            direction = beyond_direction;
            reach = beyond_reach;
        }
        if (mapped >= 0.0) through = float3(mapped);
        if (item > local_items) extension += radiance * through;
        else
#else
#ifdef MIRAI_SHADOW_FILTER_POINTS
        filters_begin();
#endif
        float3 through = mapped >= 0.0 ? float3(mapped) : trace_transmission(origin, direction, reach);
#endif
#ifdef MIRAI_SHADOW_FILTER_POINTS
        filters_weigh(radiance);
#endif
        if (item == 0u) sun = radiance * through;
        else local += radiance * through;
    }
    if ((which & LIGHTS_LOCAL) != 0u) local += shadowless_lighting(s, 0.0);
#ifdef MIRAI_HOOK_LIGHTS
    return sun + local + extension;
#else
    return sun + local;
#endif
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
// (the remaining bounces).
float3 shade_hit(Surface s, float3 ray_dir, float hit_distance, uint light_budget) {
    float3 n = hit_normal(s, ray_dir);
    Shading point = shading_diffuse(s.position, n, s.albedo);
    float3 radiance = s.emission + direct_lighting(point, hit_bias(hit_distance), light_budget) + s.albedo * sample_probes(s.position, n, -ray_dir, hit_distance);
    // A thin surface that lets light through: the light of its other side.
    float3 through = surface_transmit(s);
    if (max(through.r, max(through.g, through.b)) > 0.0) {
        Shading back = shading_diffuse(s.position, -n, through);
        radiance += direct_lighting(back, hit_bias(hit_distance), light_budget) + through * sample_probes(s.position, -n, -ray_dir, hit_distance);
    }
    return radiance;
}

// The same radiance from the probe volume alone, which holds the direct light
// of the surfaces around too: no shadow rays, and no sharp shadows either.
float3 shade_hit_cached(Surface s, float3 ray_dir, float hit_distance) {
    float3 n = hit_normal(s, ray_dir);
    float3 radiance = s.emission + s.albedo * sample_probes(s.position, n, -ray_dir, hit_distance);
    float3 through = surface_transmit(s);
    if (max(through.r, max(through.g, through.b)) > 0.0) radiance += through * sample_probes(s.position, -n, -ray_dir, hit_distance);
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
        if (lights) radiance += direct_lighting(back, hit_bias(hit_distance), light_budget);
        radiance += point.transmit * sample_probes(s.position, -n, -ray_dir, hit_distance);
    }
    // What a surface that reflects little would add is not worth the lookup;
    // it comes in gradually, so no edge shows where a floor starts to shine.
    float3 specular = specular_albedo(point);
    float shown = smoothstep(0.1, 0.2, max(specular.r, max(specular.g, specular.b)));
    Probe_Directions directions = probe_directions(n);
    if (shown > 0.0) {
        directions.at[PROBE_SPECULAR] = dominant_direction(point);
        directions.wants |= 1u << PROBE_SPECULAR;
        if (point.coat > 0.0) {
            directions.at[PROBE_COAT] = coat_dominant_direction(point);
            directions.wants |= 1u << PROBE_COAT;
        }
    }
    float3 around[PROBE_READS];
    sample_probes_around(s.position, n, -ray_dir, directions, around, hit_distance);
    Indirect light = indirect_make(around[PROBE_DIFFUSE], around[PROBE_SPECULAR] * shown, 1.0);
    light.coat_radiance = around[PROBE_COAT] * shown;
    return radiance + indirect_compose(point, light);
}

#endif
