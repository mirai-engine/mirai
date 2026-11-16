//! mirai vfx Orbit
//! parameter speed {"default":2,"min":-50,"max":50}
//! parameter rise {"default":0,"min":-20,"max":20}
//! parameter twinkle {"default":0,"min":0,"max":1}
namespace Orbit {
// Each particle turns about the axis of its emitter at speed radians per
// second, keeping the distance it started at and climbing rise metres per
// second. twinkle dims each one in its own rhythm.
struct Parameters {float speed;float rise;float twinkle;};
// Where it is about the axis: distance, angle and height.
struct Attributes {float radius;float angle;float height;};

void frame_of(float3 axis, out float3 x, out float3 z) {
    x = normalize(cross(axis, abs(axis.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0)));
    z = cross(x, axis);
}

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    float3 offset = particle.position - ctx.origin;
    a.height = dot(offset, ctx.axis);
    float3 across = offset - ctx.axis * a.height;
    float3 x, z;
    frame_of(ctx.axis, x, z);
    a.radius = length(across);
    a.angle = atan2(dot(across, z), dot(across, x));
}

// The velocity that takes it where its orbit is at the end of the step: the
// forces of the effect move it from there.
void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.angle += p.speed * ctx.delta_time;
    a.height += p.rise * ctx.delta_time;
    float3 x, z;
    frame_of(ctx.axis, x, z);
    float3 target = ctx.origin + ctx.axis * a.height + (x * cos(a.angle) + z * sin(a.angle)) * a.radius;
    particle.velocity = (target - particle.position) / max(ctx.delta_time, 1e-5);
}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {
    uint seed = particle.seed;
    float rhythm = 3.0 + 4.0 * mirai_vfx_random(seed);
    visual.color.rgb *= 1.0 - p.twinkle * (0.5 + 0.5 * sin(ctx.time * rhythm + a.angle));
}
}
