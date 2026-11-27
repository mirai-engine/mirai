#ifndef MIRAI_UI_SHAPE_SLANG
#define MIRAI_UI_SHAPE_SLANG

struct Ui_Shape {
    float4 bounds;
    float4 radii;  // of the corners; of an ellipse: the turn its arc starts at and whether its ends are round
    float4 fill;
    float4 fill2;
    float4 stroke;
    float4 params; // stroke width, kind, shadow sigma or the part of the turn an arc covers, gradient direction
};

float ui_rounded_distance(float2 p, float4 bounds, float4 radii) {
    float2 half_size = max(bounds.zw * 0.5, float2(1e-4));
    float2 q = p - bounds.xy - half_size;
    float radius = q.y < 0.0 ? (q.x < 0.0 ? radii.x : radii.y) : (q.x < 0.0 ? radii.w : radii.z);
    radius = clamp(radius, 0.0, min(half_size.x, half_size.y));
    float2 d = abs(q) - half_size + radius;
    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

float ui_ellipse_distance(float2 p, float4 bounds) {
    float2 radius = max(bounds.zw * 0.5, float2(1e-4));
    float2 q = (p - bounds.xy - radius) / radius;
    float len = length(q);
    return len < 1e-4 ? -min(radius.x, radius.y) : (len - 1.0) * len / max(length(q / radius), 1e-4);
}

float ui_erf(float x) {
    float a = abs(x);
    float t = 1.0 / (1.0 + 0.3275911 * a);
    float polynomial = (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t;
    return sign(x) * (1.0 - polynomial * exp(-a * a));
}

float ui_shadow_coverage(float2 p, Ui_Shape shape) {
    float sigma = max(shape.params.z, 0.5);
    float inv_sigma = 0.70710678118 / sigma;
    float top = max(shape.bounds.y, p.y - sigma * 3.0);
    float bottom = min(shape.bounds.y + shape.bounds.w, p.y + sigma * 3.0);
    if (bottom <= top) return 0.0;
    float step_y = (bottom - top) / 8.0;
    float coverage = 0.0;
    [loop] for (int i = 0; i < 8; ++i) {
        float y = top + (float(i) + 0.5) * step_y;
        float2 extent = float2(shape.bounds.x, shape.bounds.x + shape.bounds.z);
        float4 r = min(max(shape.radii, float4(0.0)), float4(min(shape.bounds.z, shape.bounds.w) * 0.5));
        float left_radius = y < shape.bounds.y + shape.bounds.w * 0.5 ? r.x : r.w;
        float right_radius = y < shape.bounds.y + shape.bounds.w * 0.5 ? r.y : r.z;
        float edge_y = min(y - shape.bounds.y, shape.bounds.y + shape.bounds.w - y);
        float left_d = max(left_radius - edge_y, 0.0);
        float right_d = max(right_radius - edge_y, 0.0);
        extent.x += left_radius - sqrt(max(left_radius * left_radius - left_d * left_d, 0.0));
        extent.y -= right_radius - sqrt(max(right_radius * right_radius - right_d * right_d, 0.0));
        float x_integral = 0.5 * (ui_erf((extent.y - p.x) * inv_sigma) - ui_erf((extent.x - p.x) * inv_sigma));
        float dy = (y - p.y) / sigma;
        coverage += x_integral * exp(-0.5 * dy * dy) * step_y / (2.50662827463 * sigma);
    }
    return saturate(coverage);
}

// How far around from the middle of the arc of a shape p is, in turns from -0.5
// to 0.5, and half the turn the arc covers. An arc starts radii.x turns
// clockwise from the top of its bounds and covers params.z of a turn;
// negative: counterclockwise.
float2 ui_arc_place(float2 p, Ui_Shape shape) {
    float2 d = p - (shape.bounds.xy + shape.bounds.zw * 0.5);
    float middle = shape.radii.x + shape.params.z * 0.5;
    return float2(frac(atan2(d.x, -d.y) / 6.28318531 - middle + 0.5) - 0.5, abs(shape.params.z) * 0.5);
}

// The coverage of the sector an arc keeps (all of it when params.z covers no
// turn or a whole one), with the edges as soft as aa.
float ui_arc_coverage(float2 p, Ui_Shape shape, float aa) {
    float sweep = abs(shape.params.z);
    if (sweep <= 0.0 || sweep >= 1.0) return 1.0;
    float2 place = ui_arc_place(p, shape);
    float along = length(p - (shape.bounds.xy + shape.bounds.zw * 0.5));
    return saturate(0.5 + (place.y - abs(place.x)) * 6.28318531 * along / aa);
}

// A ring of stroke width params.x cut to its arc, its ends round (radii.y).
float4 ui_round_arc_color(float2 p, Ui_Shape shape) {
    float2 d = p - (shape.bounds.xy + shape.bounds.zw * 0.5);
    float width = shape.params.x;
    float radius = min(shape.bounds.z, shape.bounds.w) * 0.5 - width * 0.5;
    float2 place = ui_arc_place(p, shape);
    float distance = abs(length(d) - radius) - width * 0.5;
    if (abs(place.x) > place.y) {
        float end = (shape.radii.x + shape.params.z * 0.5 + sign(place.x) * place.y) * 6.28318531;
        distance = length(d - radius * float2(sin(end), -cos(end))) - width * 0.5;
    }
    float aa = max(fwidth(distance), 1e-4);
    return float4(shape.stroke.rgb, shape.stroke.a * saturate(0.5 - distance / aa));
}

float4 ui_shape_color(float2 p, Ui_Shape shape) {
    if (shape.params.y > 1.5) return float4(shape.fill.rgb, shape.fill.a * ui_shadow_coverage(p, shape));
    if (shape.params.y > 0.5 && shape.radii.y > 0.5) return ui_round_arc_color(p, shape);
    float distance = shape.params.y > 0.5 ? ui_ellipse_distance(p, shape.bounds) : ui_rounded_distance(p, shape.bounds, shape.radii);
    float aa = max(fwidth(distance), 1e-4);
    float outer = saturate(0.5 - distance / aa);
    float amount = shape.params.w < 0.5 ? 0.0 : saturate(shape.params.w < 1.5 ? (p.y - shape.bounds.y) / max(shape.bounds.w, 1e-4) : (p.x - shape.bounds.x) / max(shape.bounds.z, 1e-4));
    float4 fill = lerp(shape.fill, shape.fill2, amount);
    float inner = saturate(0.5 - (distance + max(shape.params.x, 0.0)) / aa);
    float border = saturate((outer - inner) / max(outer, 1e-6)) * shape.stroke.a;
    float arc = ui_arc_coverage(p, shape, aa);
    float alpha = (border + fill.a * (1.0 - border)) * outer * arc;
    float3 premultiplied = (shape.stroke.rgb * border + fill.rgb * fill.a * (1.0 - border)) * outer * arc;
    return float4(alpha > 1e-6 ? premultiplied / alpha : float3(0.0), alpha);
}
#endif
