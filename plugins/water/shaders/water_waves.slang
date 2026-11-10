// The fluids of a frame of the water and the waves of Gerstner of their
// surfaces: the twin of wave_point and wave_surface of the physics
// (plugins/physics/runtime/sim/fluid_waves.odin), on the terms the CPU makes
// for each body (water.bodies_relative). What the shaders draw, light and
// cut is the surface the bodies float on.
#ifndef WATER_WAVES_SLANG
#define WATER_WAVES_SLANG

static const uint WATER_WAVES = 8u;

// water.Gpu_Body: a fluid or a dry box of the frame.
struct Water_Body {
    float4 to_box[3]; // rows: from the world to its box, whose sides are 1, sheared by its slope
    float4 surface;   // x the height of its still surface at the origin, y 1 for a plane, z 1 for a dry box, w priority
    float4 slope;     // xy m its still surface rises for each metre along x and z
    float4 look;      // x caustics, y 1/m it takes of white light, z the index of refraction of its surface, w its waves
    float4 waves[WATER_WAVES]; // of a plane: physics.Wave_Term k along x and z, amplitude, across
    float4 phases[2];          // of each wave, at the origin and the time of the frame
};

uint water_wave_count(Water_Body b) { return uint(b.look.w); }
// The still surface of a body over x and z of the place of the frame.
float water_still(Water_Body b, float2 xz) { return b.surface.x + dot(b.slope.xy, xz); }
float water_wave_phase(Water_Body b, uint i) { return b.phases[i >> 2u][i & 3u]; }

// What the waves leave of a wave at a point: weight 1, all of it.
struct Water_Point {
    float3 offset; // from the point of the still surface where the water rests
    float3 normal;
    float2x2 j;    // how the place it reaches changes with where it rests
};

// Where the water that rests at p (x and z of the place of the frame) is, with
// each wave scaled by its weight (1 at the physics, less where a mesh is too
// coarse to show it); wave_point.
Water_Point water_wave_point(Water_Body b, float2 p, float weights[WATER_WAVES]) {
    Water_Point w;
    w.offset = float3(0.0);
    w.j = float2x2(1.0, 0.0, 0.0, 1.0);
    float2 slope = float2(0.0);
    uint count = water_wave_count(b);
    for (uint i = 0u; i < count; i++) {
        float4 wave = b.waves[i];
        float amplitude = wave.z * weights[i], across = wave.w * weights[i];
        float theta = dot(wave.xy, p) + water_wave_phase(b, i);
        float s = sin(theta), c = cos(theta);
        float number = length(wave.xy);
        float2 d = wave.xy / number;
        w.offset.x -= across * d.x * s;
        w.offset.z -= across * d.y * s;
        w.offset.y += amplitude * c;
        slope -= amplitude * s * wave.xy;
        float bend = across * number * c;
        w.j[0][0] -= bend * d.x * d.x;
        w.j[0][1] -= bend * d.x * d.y;
        w.j[1][0] -= bend * d.y * d.x;
        w.j[1][1] -= bend * d.y * d.y;
    }
    float3 along_x = float3(w.j[0][0], slope.x, w.j[1][0]);
    float3 along_z = float3(w.j[0][1], slope.y, w.j[1][1]);
    float3 n = cross(along_z, along_x);
    w.normal = dot(n, n) > 1e-20 ? normalize(n) : float3(0.0, 1.0, 0.0);
    return w;
}

Water_Point water_wave_point(Water_Body b, float2 p) {
    float weights[WATER_WAVES] = { 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };
    return water_wave_point(b, p, weights);
}

// The height of the surface of a body over x and z of the place of the frame,
// and its normal: its still surface with its slope, and its waves found back
// by Newton to where the water rests (wave_surface).
float water_surface_at(Water_Body b, float2 xz, out float3 normal) {
    normal = normalize(float3(-b.slope.x, 1.0, -b.slope.y));
    if (water_wave_count(b) == 0u) return water_still(b, xz);
    float2 p = xz;
    for (int k = 0; k < 3; k++) {
        Water_Point w = water_wave_point(b, p);
        float2 miss = p + w.offset.xz - xz;
        float det = w.j[0][0] * w.j[1][1] - w.j[0][1] * w.j[1][0];
        if (!(abs(det) > 1e-6)) break;
        p -= float2(w.j[1][1] * miss.x - w.j[0][1] * miss.y, w.j[0][0] * miss.y - w.j[1][0] * miss.x) / det;
    }
    Water_Point w = water_wave_point(b, p);
    normal = normalize(float3(w.normal.x - b.slope.x * w.normal.y, w.normal.y, w.normal.z - b.slope.y * w.normal.y));
    return water_still(b, xz) + w.offset.y;
}

float water_surface_at(Water_Body b, float2 xz) {
    float3 normal;
    return water_surface_at(b, xz, normal);
}

// How far the waves of a body reach over and under its still surface.
float water_wave_reach(Water_Body b) {
    float reach = 0.0;
    for (uint i = 0u; i < water_wave_count(b); i++) reach += b.waves[i].z;
    return reach;
}
#endif
