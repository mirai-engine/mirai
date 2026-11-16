// What the lighting approximates, which the tests compare it with: the light
// of the sun and of every local light through rays of their own.
#ifndef MIRAI_REFERENCE_SLANG
#define MIRAI_REFERENCE_SLANG

// A shadow ray of the reference, whose filters carry `weight` times what they let through.
float3 reference_ray(float3 origin, float3 direction, float reach, float3 weight) {
#ifdef MIRAI_SHADOW_FILTER_POINTS
    if (MIRAI_COLORED_SHADOWS) filters_begin();
#endif
    float3 through = trace_transmission(origin, direction, reach);
#ifdef MIRAI_SHADOW_FILTER_POINTS
    if (MIRAI_COLORED_SHADOWS) filters_weigh(weight);
#endif
    return through;
}

// What the sun and every local light send a point through rays of its own to
// `points` points of their discs, spread over them and turned at random every
// frame: the light of their sizes. A light that casts no shadows traces none. With sixteen points there is so little
// noise from a frame to the next that their mean after tone mapping is the
// mean of the light; with fewer, the mean over frames still is.
// `sun_radius`: angular radius of the sun, radians.
float3 reference_lighting(Shading s, float bias, float sun_radius, uint points, inout uint seed) {
    float3 origin = offset_origin(s.position, s.normal, bias);
    float3 result = float3(0.0);
    float share = 1.0 / float(points);
    float sun_cosine = dot(s.normal, frame.sun_direction.xyz);
    if (frame.sun_direction.w >= 0.5 && sun_cosine > 0.0) {
        float3 t, b;
        make_basis(frame.sun_direction.xyz, t, b);
        float turn = random01(seed) * 2.0 * PI;
        float shift = random01(seed);
        float3 scale = sun_light(s.position) * sun_cosine * shading_response(s, frame.sun_direction.xyz) * share;
        float3 through = float3(0.0);
        for (uint k = 0u; k < points; k++) {
            float spin = turn + float(k) * 2.3999632;
            float2 disc = sqrt((float(k) + shift) * share) * float2(cos(spin), sin(spin)) * sun_radius;
            float3 ray = normalize(frame.sun_direction.xyz + t * disc.x + b * disc.y);
            through += reference_ray(origin, ray, sun_reach(origin, ray), scale);
        }
        result += scale * through;
    }
    for (uint at = 0u; at < frame.light_nodes; at++) {
        Light_Node node = light_nodes[at];
        if ((node.flags & LIGHT_NODE_LEAF) == 0u) continue;
        Light light = lights[node.child];
        float3 direction;
        float distance;
        float3 irradiance = light_contribution(light, s.position, s.normal, direction, distance);
        if (luminance(irradiance) <= 0.0) continue;
        // A capsule or a rectangle: each point its share of the light, with
        // its own falloff, cosines, color and response, which is what their
        // approximations stand for.
        bool shaped = light_is_rect(light) || light_is_capsule(light);
        bool shadows = !light_node_shadowless(at);
        float3 center = light.position_range.xyz - s.position;
        // Points of the disc the sphere shows the point.
        float3 t, b;
        make_basis(direction, t, b);
        float turn = random01(seed) * 2.0 * PI;
        float shift = random01(seed);
        // What multiplies the light through the rays.
        float3 scale = shaped ? light.color_intensity.rgb * (light.color_intensity.w * light_window(distance, light.position_range.w) * share) : irradiance * shading_response(s, direction, distance, light.size.x) * share;
        float3 through = float3(0.0);
        for (uint k = 0u; k < points; k++) {
            float3 toward;
            float3 weight = float3(1.0);
            if (shaped) {
                // light_point lays out sixteen points of a light.
                toward = light_point(light, s.position, (float(k) + shift) * (16.0 * share), turn);
                float3 unit = normalize(toward);
                if (light_is_rect(light)) {
                    float facing = -dot(unit, light.direction_cone.xyz);
                    weight = rect_emission(light, rect_place(light, toward - center), 0.0) * (saturate(dot(s.normal, unit)) * saturate(facing) / max(dot(toward, toward), 1e-8)) * shading_response(s, unit);
                } else {
                    float3 along = center + light.axis.xyz * (light.size.y * ((float(k) + shift) * (2.0 * share) - 1.0));
                    float apart = length(along);
                    weight = sphere_irradiance(dot(s.normal, along / apart), apart, light.size.x) * shading_response(s, along / apart, apart, light.size.x);
                }
                if (!(luminance(weight) > 0.0)) continue;
            } else {
                float spin = turn + float(k) * 2.3999632;
                float2 disc = sqrt((float(k) + shift) * share) * float2(cos(spin), sin(spin)) * light.size.x;
                toward = direction * distance + t * disc.x + b * disc.y;
            }
            float far = length(toward);
            if (shadows) through += weight * reference_ray(origin, toward / max(far, 1e-6), shaped ? light_reach(light, far) : max(far - LIGHT_CLEARANCE * light.size.x - 0.02, 0.0), scale * weight);
            else through += weight;
        }
        result += scale * through;
    }
    return result;
}

#endif
