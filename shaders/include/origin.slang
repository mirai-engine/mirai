// What the origin of the render (render/origin.odin) adds to a place of the
// world, for what a shader makes of the place itself: a wave, a pattern, a
// texture laid over the world, a lattice of noise. A place a shader sees is
// relative to the origin, which comes in whole steps of ORIGIN_STEP
// (Frame_Data.origin, Mirai_Surface_Context.origin); what it adds to
// something periodic is found from those steps by integers, exact however far
// from the centre of the world it is, where a float of the place would have
// lost it.
#ifndef MIRAI_ORIGIN_SLANG
#define MIRAI_ORIGIN_SLANG
#include <shared_constants.slang>

// What `steps` steps of the origin add to a wave of `cycles` cycles a metre,
// in turns of 32 bits: the whole cycles of a step drop out, and what is left
// of one, times the steps, wraps.
uint origin_turns_fixed(int steps, float cycles) {
    float per_step = cycles * ORIGIN_STEP;
    return uint(steps) * uint((per_step - floor(per_step)) * 4294967296.0);
}

// 0 to 1, in the 24 bits a float holds.
float origin_turns_float(uint turns) { return float(turns >> 8u) * (1.0 / 16777216.0); }

// The phase, in turns from 0 to 1, that the origin adds to a plane wave of
// `cycles` cycles a metre along each axis: the wave at a place of the world
// is at the place relative to the origin plus this.
float origin_phase(int3 origin, float3 cycles) {
    return origin_turns_float(origin_turns_fixed(origin.x, cycles.x) + origin_turns_fixed(origin.y, cycles.y) + origin_turns_fixed(origin.z, cycles.z));
}

// What the origin adds to a pattern that repeats every `period` metres along
// each axis: the origin modulo the period, from 0 to it.
float3 origin_wrap(int3 origin, float3 period) {
    float3 cycles = 1.0 / period;
    return float3(origin_turns_float(origin_turns_fixed(origin.x, cycles.x)), origin_turns_float(origin_turns_fixed(origin.y, cycles.y)),
                  origin_turns_float(origin_turns_fixed(origin.z, cycles.z))) * period;
}

// Where the origin is on a lattice of `scale` cells a metre along each axis:
// its cell and how far into it. A place relative to the origin is in the cell
// whole + floor(part + place * scale) of the world, whose numbers wrap as the
// integers of a hash of them do.
void origin_lattice(int3 origin, float3 scale, out int3 whole, out float3 part) {
    for (int axis = 0; axis < 3; axis++) {
        float per_step = scale[axis] * ORIGIN_STEP;
        float cells = floor(per_step);
        uint turns = origin_turns_fixed(origin[axis], scale[axis]);
        part[axis] = origin_turns_float(turns);
        // The whole cells of what is left of a step, times the steps, are a whole number the float comes near.
        float left = float(origin[axis]) * (per_step - cells) - float(turns) * (1.0 / 4294967296.0);
        whole[axis] = int(uint(origin[axis]) * uint(int(cells)) + uint(int(round(left))));
    }
}

#endif
