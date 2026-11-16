// A shape of the demo for the deform plugin: bulges that travel along the
// axis, as what a hose swallows. values.x is how long a bulge is, as a share
// of the mesh, and values.y how many travel at a time.
#include "programs/plugins/deform/deform.slang"

float3 deform_shape(float3 p, Deform_Shape shape) {
    float height = deform_height(shape, p);
    float3 radial = deform_radial(shape, p);
    float radius = length(radial);
    if (radius < 1e-5) return p;
    float count = max(shape.values.y, 1.0);
    // From the middle of the nearest bulge, in shares of the mesh.
    float from_bulge = (frac(height * count - shape.phase) - 0.5) / count;
    float reach = max(shape.values.x, 1e-3);
    float swell = exp(-from_bulge * from_bulge / (reach * reach));
    // Both ends stay as they are.
    float held = shape.pin > 0.0 ? smoothstep(0.0, shape.pin, height) * smoothstep(0.0, shape.pin, 1.0 - height) : 1.0;
    return p + radial / radius * (shape.amplitude * swell * held);
}
