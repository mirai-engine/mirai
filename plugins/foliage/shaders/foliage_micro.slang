// The micro foliage of a world (foliage.Foliage_Micro): what the Micro layers
// of the graphs place on the ground, scattered on the GPU. A tile is a cell
// of a graph and a layer; when it changes, foliage_micro_gen.comp writes the
// instances that stand into its slot of the buffer of the world, once, and
// each view culls them (foliage_micro_cull.comp) and draws those it keeps
// with the mesh of their layer (foliage_micro.vert).
#ifndef FOLIAGE_MICRO_SLANG
#define FOLIAGE_MICRO_SLANG
#include "native.slang"
#include "scene.slang"

// An instance (foliage.Micro_Instance), in the space of its cell: the frame
// of its graph from the corner of the cell.
struct Micro_Instance {
    uint place;  // x | z << 16, unorm16 across the cell
    float height;
    uint normal; // of the ground under it, octahedral, snorm16 x | z << 16
    uint slot;
};

// A slot of the buffer (foliage.Micro_Slot): where its tile is and what it holds.
struct Micro_Slot {
    float4 world[3]; // from the space of its cell into the world, relative to the origin
    uint4 info;      // x: its first instance, y: how many it holds at most, z: its look, w: 1 once generated
    float4 cell;     // x: metres across its cell; y: the seed of its instances
};

// A look (foliage.Micro_Look_Row): how the instances of a layer are drawn.
struct Micro_Look {
    float4 sphere;   // the centre of its mesh and its radius
    float4 scale;    // across, lowest and highest; along y times across, lowest and highest
    float4 turn;     // x: a turn around y of up to this, y: a lean of up to this, z: how much it leans with the ground
    float4 offset;   // along its y, lowest and highest; z: its sway (foliage.sway_amount), w: its flutter
    float4 distance; // from the eye: x where it starts to shrink away, y where it is gone (0: never)
    uint4 mesh;      // x: its mesh, y: its clusters, z: the first of its instances among those visible, w: how many fit there
};

#define MICRO_NOT_GENERATED 0u

uint micro_hash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

float micro_unit(uint h) { return float(h >> 8u) * (1.0 / 16777216.0); }

uint micro_snorm16(float v) { return uint(int(round(clamp(v, -1.0, 1.0) * 32767.0)) & 0xffff); }
float micro_snorm16_value(uint v) { return clamp(float(int(v << 16u) >> 16) / 32767.0, -1.0, 1.0); }

uint micro_normal_pack(float3 n) {
    float2 p = n.xz / (abs(n.x) + abs(n.y) + abs(n.z));
    if (n.y < 0.0) p = (1.0 - abs(p.yx)) * select(p >= 0.0, float2(1.0), float2(-1.0));
    return micro_snorm16(p.x) | micro_snorm16(p.y) << 16u;
}

float3 micro_normal_unpack(uint v) {
    float2 p = float2(micro_snorm16_value(v & 0xffffu), micro_snorm16_value(v >> 16u));
    float3 n = float3(p.x, 1.0 - abs(p.x) - abs(p.y), p.y);
    if (n.y < 0.0) n.xz = (1.0 - abs(n.zx)) * select(n.xz >= 0.0, float2(1.0), float2(-1.0));
    return normalize(n);
}

// A turn of `angle` radians about a unit axis, as rows.
float3x3 micro_turn(float3 axis, float angle) {
    float c = cos(angle), s = sin(angle), t = 1.0 - c;
    return float3x3(t * axis.x * axis.x + c, t * axis.x * axis.y - s * axis.z, t * axis.x * axis.z + s * axis.y,
                    t * axis.x * axis.y + s * axis.z, t * axis.y * axis.y + c, t * axis.y * axis.z - s * axis.x,
                    t * axis.x * axis.z - s * axis.y, t * axis.y * axis.z + s * axis.x, t * axis.z * axis.z + c);
}

// Where an instance stands in the world and how it is placed there: its
// transform as rows, the place it stands at, and how much of its size it
// keeps as it shrinks away far from the eye (0: gone). Its turn, lean, size
// and offset come from where it stands, as the pcg layers place theirs
// (pcg.placed_of): a turn about y, a lean, then the slope of the ground.
struct Micro_Place {
    float4 world[3];
    float3 pivot;
    float scale; // the largest of its axes
    float kept;
};

Micro_Place micro_place(Micro_Instance inst, Micro_Slot slot, Micro_Look look) {
    Micro_Place m;
    float across = slot.cell.x;
    float3 local = float3(float(inst.place & 0xffffu) / 65535.0 * across, inst.height, float(inst.place >> 16u) / 65535.0 * across);
    uint h0 = micro_hash(inst.place ^ asuint(slot.cell.y));
    uint h1 = micro_hash(h0), h2 = micro_hash(h1), h3 = micro_hash(h2), h4 = micro_hash(h3), h5 = micro_hash(h4);
    float3 normal = micro_normal_unpack(inst.normal);
    float3x3 yaw = micro_turn(float3(0.0, 1.0, 0.0), micro_unit(h0) * look.turn.x);
    float side = micro_unit(h1) * 6.2831853;
    float3x3 lean = micro_turn(float3(cos(side), 0.0, sin(side)), micro_unit(h2) * look.turn.y);
    float3 up = float3(0.0, 1.0, 0.0);
    float3 toward = normalize(lerp(up, normal, saturate(look.turn.z)));
    float3 axis = cross(up, toward);
    float sine = length(axis);
    float3x3 slope = sine > 1e-5 ? micro_turn(axis / sine, atan2(sine, dot(up, toward))) : float3x3(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);
    float3x3 r = mul(slope, mul(lean, yaw));
    float s = lerp(look.scale.x, look.scale.y, micro_unit(h3));
    float3 size = float3(s, s * lerp(look.scale.z, look.scale.w, micro_unit(h4)), s);
    float3 offset = mul(r, float3(0.0, lerp(look.offset.x, look.offset.y, micro_unit(h5)), 0.0));
    float4 cell_rows[3] = {float4(r[0] * size, local.x + offset.x), float4(r[1] * size, local.y + offset.y), float4(r[2] * size, local.z + offset.z)};
    for (uint i = 0u; i < 3u; i++) {
        float4 row = slot.world[i];
        m.world[i] = float4(row.x * cell_rows[0].xyz + row.y * cell_rows[1].xyz + row.z * cell_rows[2].xyz, row.x * cell_rows[0].w + row.y * cell_rows[1].w + row.z * cell_rows[2].w + row.w);
    }
    m.pivot = transform_point(slot.world, local);
    m.scale = max(max(length(float3(m.world[0].x, m.world[1].x, m.world[2].x)), length(float3(m.world[0].y, m.world[1].y, m.world[2].y))), length(float3(m.world[0].z, m.world[1].z, m.world[2].z)));
    m.kept = 1.0;
    if (look.distance.y > 0.0) {
        float d = length(m.pivot - frame.camera_position.xyz);
        m.kept = saturate((look.distance.y - d) / max(look.distance.y - look.distance.x, 1e-3));
    }
    return m;
}
#endif
