//! mirai vfx Transform_Probe
//! resource target transform
//! moves
// Births 0..2 sample target via mirai_vfx_transform_at(t = 0, 0.5, 1); births
// 3 and 4 read current and previous from mirai_vfx_transform. Position goes in
// position, scale in velocity, rotation (xyzw) in (age, size, rotation, spin)
// offset by 10 so size stays positive, and birth index in seed. Unbound sits
// at ctx.origin with rotation -2.
namespace Transform_Probe {
struct Parameters { float unused; };
struct Attributes { uint slot; };

void sample(Mirai_Vfx_Context ctx, uint slot, inout Mirai_Vfx_Particle particle) {
    particle.lifetime = 100.0;
    Mirai_Vfx_Transform tr = slot <= 2u
        ? mirai_vfx_transform_at(ctx, target, float(slot) * 0.5)
        : mirai_vfx_transform(ctx, target);
    if (!tr.valid) {
        particle.position = ctx.origin;
        particle.velocity = float3(0.0);
        particle.rotation = -2.0;
        particle.spin = float(slot);
        return;
    }
    float3 pos = slot == 4u ? tr.previous_position : tr.position;
    float3 scl = slot == 4u ? tr.previous_scale : tr.scale;
    float4 rot = slot == 4u ? tr.previous_rotation : tr.rotation;
    particle.position = pos;
    particle.velocity = scl;
    particle.age = 10.0 + rot.x;
    particle.size = 10.0 + rot.y;
    particle.rotation = 10.0 + rot.z;
    particle.spin = 10.0 + rot.w;
    particle.seed = slot;
}

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.slot = ctx.birth;
    sample(ctx, a.slot, particle);
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    sample(ctx, a.slot, particle);
}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
