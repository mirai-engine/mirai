//! mirai vfx Bone_Probe
//! resource body bones
//! moves
// The particle a birth starts sits on the bone of body of its number, moving
// as it moves, and keeps in rotation its parent (-1 for a root), in spin the
// number, in size the scale of the bone along y and in age the z of its turn;
// past the bones, or without them, it sits at the emitter with rotation -2:
// what the tests of the plugin check of bones.
namespace Bone_Probe {
struct Parameters { float unused; };
struct Attributes { uint bone; };

void sit(Mirai_Vfx_Context ctx, uint bone, inout Mirai_Vfx_Particle particle) {
    Mirai_Vfx_Bone b = mirai_vfx_bone(ctx, body, bone);
    particle.spin = float(bone);
    particle.lifetime = 100.0;
    if (!b.valid) {
        particle.position = ctx.origin;
        particle.velocity = float3(0.0);
        particle.rotation = -2.0;
        return;
    }
    particle.position = b.position;
    particle.velocity = b.velocity;
    particle.rotation = b.parent == 0xFFFFFFFFu ? -1.0 : float(b.parent);
    particle.size = b.scale.y;
    particle.age = 1.0 + b.rotation.z;
}

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    a.bone = ctx.birth;
    sit(ctx, a.bone, particle);
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    sit(ctx, a.bone, particle);
}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
