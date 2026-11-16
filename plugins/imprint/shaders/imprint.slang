//! mirai vfx Imprint
//! resource imprint grid
//! resource stamps channel
//! resource fluid grid
//! stage stamp over imprint
//! parameter recover {"default":0,"min":0,"max":1}
//! parameter compaction_fade {"default":0,"min":0,"max":8}
//! parameter hardness {"default":0.4,"min":0,"max":1}
//! parameter berm_width {"default":0.5,"min":0,"max":2}
//! parameter fluid_deposit {"default":0,"min":-4,"max":4}
//! parameter wet_fade {"default":0.05,"min":0,"max":8}
//! parameter relax {"default":0.5,"min":0,"max":1}
//! parameter repose {"default":0.8,"min":0,"max":8}
// Snow, mud or sand that keeps where bodies pass: the height of the ground
// over its rest on the cells of the grid imprint, flat along y, that follows
// the view (imprint.IMPRINT_GRID). Its layer 0, which a
// Particle_World_Texture hands to the vertices and the materials:
//
//   x  metres over the rest of the ground: under 0 where it was pressed,
//      over 0 on a rim or where a fluid left something
//   y  how pressed it is, 0 to 1: the material shows it flattened
//   z  how wet a fluid left it, 0 to 1
//
// Each step the stamps of the channel stamps press it: a rut sweeps a disc
// from where it was the step before, a print is an oval along where it
// points; each sinks the ground to its depth there, never up, and raises
// the share berm of that depth in a rim around it over the ground that was
// not pressed. The ground fills back at recover metres a second (snow that
// falls, sand the wind moves) and loses its pressing by compaction_fade. A
// fluid of the grid fluid (Fluid) raises it by fluid_deposit metres a second
// for each unit of its density (less than 0 carves it) and wets it. Where
// the ground stands steeper than repose (metres a metre) against the mean of
// the four cells around, each step it slides relax of the excess back, as
// sand and snow do past their angle of repose: the walls of a print stay,
// softened, and the edges of a rut stay smooth between the vertices.
namespace Imprint {
struct Parameters {
    float recover;         // metres a second the ground goes back to rest
    float compaction_fade; // of how pressed it is, a second
    float hardness;        // of the edge of a stamp: 1 a wall, 0 a bowl
    float berm_width;      // of a rim, a share of the radius of its stamp
    float fluid_deposit;   // metres a second a unit of density of the fluid raises the ground
    float wet_fade;        // of the wetness, a second
    float relax;           // of what stands past repose, what slides back each step
    float repose;          // the steepest slope that stays, metres a metre
};
struct Attributes { float unused; };

static const float IMPRINT_HEIGHT_MAX = 8.0; // metres the field keeps either way: a deposit that runs on stays finite

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

// How far a point is from the segment from a to b.
float segment_distance(float2 u, float2 a, float2 b) {
    float2 ua = u - a, ba = b - a;
    float h = saturate(dot(ua, ba) / max(dot(ba, ba), 1e-12));
    return length(ua - ba * h);
}

void stamp(Mirai_Vfx_Cell cell, Parameters p) {
    float dt = cell.ctx.delta_time;
    Mirai_Vfx_Grid g = mirai_vfx_grid(cell.ctx, imprint);
    float4 here = mirai_vfx_grid_load(cell.ctx, imprint, cell.index, 0u);
    float around = 0.0;
    for (uint side = 0u; side < 4u; side++) {
        int3 step = side < 2u ? int3(side == 0u ? 1 : -1, 0, 0) : int3(0, 0, side == 2u ? 1 : -1);
        around += 0.25 * mirai_vfx_grid_load(cell.ctx, imprint, cell.index + step, 0u).x;
    }
    float excess = around - here.x;
    float height = here.x + saturate(p.relax) * sign(excess) * max(abs(excess) - p.repose * g.cell_size, 0.0);
    float pressed = here.y * exp(-p.compaction_fade * dt);
    float wet = here.z * exp(-p.wet_fade * dt);
    float fill = p.recover * dt;
    height = height < 0.0 ? min(height + fill, 0.0) : max(height - fill, 0.0);
    float rim = 0.0;
    uint count = mirai_vfx_channel_count(cell.ctx, stamps);
    for (uint i = 0u; i < count; i++) {
        Mirai_Vfx_Birth b = mirai_vfx_channel_birth(cell.ctx, stamps, i);
        float radius = max(b.size, 1e-3);
        float depth = max(b.values.x, 0.0);
        // How far the cell is from the stamp, in radii: 1 at its edge.
        float reach;
        if (b.values.z > 0.5) {
            float2 forward = dot(b.velocity.xz, b.velocity.xz) > 1e-8 ? normalize(b.velocity.xz) : float2(0.0, -1.0);
            float2 d = cell.position.xz - b.position.xz;
            float along = dot(d, forward) / max(0.5 * b.values.w, radius);
            float across = dot(d, float2(forward.y, -forward.x)) / radius;
            reach = length(float2(along, across));
        } else {
            float2 now = b.position.xz, before = now - b.velocity.xz * dt;
            reach = segment_distance(cell.position.xz, before, now) / radius;
        }
        float inside = 1.0 - smoothstep(saturate(p.hardness), 1.0, reach);
        if (inside > 0.0) {
            height = min(height, -depth * inside);
            pressed = max(pressed, inside);
        }
        float t = (reach - 1.0) / max(p.berm_width, 1e-3);
        if (t > -0.25 && t < 1.0) rim = max(rim, depth * b.values.y * 4.0 * saturate(t) * (1.0 - t));
    }
    // A rim rises over the ground that was not pressed, never into a print.
    if (height >= 0.0) height = max(height, rim);
    Mirai_Vfx_Grid f = mirai_vfx_grid(cell.ctx, fluid);
    if (f.valid && f.cells.y == 1) {
        // On the plane of the fluid, which may lie at another height.
        float3 at = cell.position;
        at.y += (float(f.first.y) + 0.5) * f.cell_size - (float(g.first.y) + 0.5) * g.cell_size;
        float density = saturate(mirai_vfx_grid_sample(cell.ctx, fluid, at, 0u).z);
        height += p.fluid_deposit * density * dt;
        wet = max(wet, density);
    }
    mirai_vfx_grid_store(cell, 0u, float4(clamp(height, -IMPRINT_HEIGHT_MAX, IMPRINT_HEIGHT_MAX), saturate(pressed), saturate(wet), 0.0));
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
