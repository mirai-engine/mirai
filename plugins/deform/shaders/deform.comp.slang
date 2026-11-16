// The shapes of deform.Deform_Kind.
#include "deform.slang"

#define DEFORM_WAVE 0u
#define DEFORM_SWAY 1u
#define DEFORM_TWIST 2u
#define DEFORM_RIPPLE 3u

float3 deform_shape(float3 p, Deform_Shape shape) {
    float along = deform_along(shape, p);
    float extent = deform_extent(shape);
    float height = deform_height(shape, p);
    float held = deform_held(shape, height);
    float waves = along / max(shape.wavelength, 1e-4);
    switch (shape.kind) {
    case DEFORM_WAVE: {
        // A second, shorter wave that crosses the first keeps the surface from repeating.
        float across = dot(p - shape.center, cross(shape.axis, shape.direction)) / max(shape.wavelength, 1e-4);
        float wave = sin(DEFORM_TURN * (waves - shape.phase)) + 0.3 * sin(DEFORM_TURN * (1.9 * waves + 0.8 * across - 1.6 * shape.phase));
        return p + shape.direction * (shape.amplitude * held * wave);
    }
    case DEFORM_SWAY: {
        // What stands along the axis leans with the wind and swings around that lean, more the higher it is.
        float lean = shape.amplitude * (0.5 + 0.35 * sin(DEFORM_TURN * shape.phase) + 0.15 * sin(DEFORM_TURN * (2.7 * shape.phase + 0.2)));
        float bend = lean * height * height * held;
        // It keeps its length: what leans comes down.
        float drop = bend * bend / max(2.0 * height * extent, 1e-4);
        return p + shape.direction * bend - shape.axis * drop;
    }
    case DEFORM_TWIST: {
        float angle = shape.amplitude * height * held * cos(DEFORM_TURN * shape.phase);
        float3 radial = deform_radial(shape, p);
        return shape.center + shape.axis * along + radial * cos(angle) + cross(shape.axis, radial) * sin(angle);
    }
    default: {
        // Rings that leave the axis and move the surface along it, dying towards the rim.
        float radius = length(deform_radial(shape, p));
        float rim = 0.5 * length(shape.size - abs(shape.axis) * dot(abs(shape.axis), shape.size));
        float still = shape.pin > 0.0 ? 1.0 - smoothstep(1.0 - shape.pin, 1.0, radius / max(rim, 1e-5)) : 1.0;
        float wave = sin(DEFORM_TURN * (radius / max(shape.wavelength, 1e-4) - shape.phase));
        return p + shape.axis * (shape.amplitude * still * wave);
    }
    }
}
