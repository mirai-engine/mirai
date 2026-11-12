// A quad facing the eye a far instance of foliage is drawn on, and what its
// fragments need: the three frames of its type to blend, and how much of it
// shows where its mesh fades out and where it fades out itself. It leans in
// the wind as its mesh does.
#include "foliage_impostor.slang"
#include "foliage_sway.slang"

static const float2 IMPOSTOR_CORNERS[6] = {float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)};

// A placement turned about its place so that its up leans by `lean`, radians
// along x and z of the world.
void impostor_lean(float2 lean, inout float4 world[3], inout float4 inverse[3]) {
    float angle = length(lean);
    if (!(angle > 1e-5)) return;
    float3 k = float3(lean.y, 0.0, -lean.x) / angle;
    float c = cos(angle), s = sin(angle), t = 1.0 - c;
    float3x3 r = float3x3(t * k.x * k.x + c, t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y,
                          t * k.x * k.y + s * k.z, t * k.y * k.y + c, t * k.y * k.z - s * k.x,
                          t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c);
    float3 a0 = world[0].xyz, a1 = world[1].xyz, a2 = world[2].xyz;
    world[0].xyz = r[0].x * a0 + r[0].y * a1 + r[0].z * a2;
    world[1].xyz = r[1].x * a0 + r[1].y * a1 + r[1].z * a2;
    world[2].xyz = r[2].x * a0 + r[2].y * a1 + r[2].z * a2;
    float3 place = float3(world[0].w, world[1].w, world[2].w);
    for (uint i = 0u; i < 3u; i++) {
        inverse[i].xyz = mul(r, inverse[i].xyz);
        inverse[i].w = -dot(inverse[i].xyz, place);
    }
}

[shader("vertex")]
Impostor_Varyings main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Impostor_Varyings o = (Impostor_Varyings)0;
    Impostor_Instance inst = impostor_instances[instance_id];
    Impostor_Row row = impostor_rows[inst.row];
    float4 world[3], inverse[3];
    batch_instance_placement(inst.position + impostor_params.anchor.xyz, inst.rotation, inst.scale, world, inverse);
    float3 low, high;
    box_transformed(world, row.low.xyz, row.high.xyz, low, high);
    float appear = box_faded(low, high, row.low.w, row.high.w);
    float gone = box_faded(low, high, row.far.x, row.far.y);
    // Where its mesh is whole, or past where it is gone, nothing is drawn.
    o.position = float4(2.0, 2.0, 2.0, 1.0);
    if (appear <= 0.0 || gone >= 1.0) return o;
    // It leans whole about where it stands, as the top of its mesh leans in the wind there.
    if (row.far.z > 0.0) {
        float3 pivot = float3(world[0].w, world[1].w, world[2].w);
        float4 wind = wind_at(frame.foliage_wind.wind, pivot);
        impostor_lean(foliage_wind_lean(wind.xyz, wind.w, 1.0, row.far.z, foliage_wave(pivot, frame.origin.xyz), frame.time.x), world, inverse);
    }
    float3 center = transform_point(world, row.sphere.xyz);
    float scale = max(length(float3(world[0].x, world[1].x, world[2].x)), length(float3(world[0].y, world[1].y, world[2].y)));
    float radius = row.sphere.w * scale;
    // Toward the eye, or against the direction a parallel view looks along.
    bool point = frame.eye.w > 0.5;
    float3 toward = point ? frame.eye.xyz - center : frame.eye.xyz;
    float distance = length(toward);
    toward = distance > 1e-6 ? toward / distance : float3(0.0, 1.0, 0.0);
    float3 right, up;
    impostor_axes(toward, right, up);
    // The quad through the centre holds the outline of the sphere seen from the eye.
    float reach = point ? radius * distance / sqrt(max(distance * distance - radius * radius, 1e-4 * radius * radius)) : radius;
    float2 corner = IMPOSTOR_CORNERS[vertex_id % 6u];
    float3 placed = center + (right * corner.x + up * corner.y) * reach;
    o.position = view_clip(placed);
    o.local = transform_point(inverse, placed);
    o.eye = point ? float4(transform_point(inverse, frame.eye.xyz), 1.0) : float4(normalize(transform_vector(inverse, -frame.eye.xyz)), 0.0);
    // The three frames around the direction it is seen from: the triangle of
    // the cell of the grid that holds it, with its barycentric weights.
    uint n = max(row.frames.z, 2u);
    float2 g = (impostor_fold(normalize(transform_vector(inverse, toward))) * 0.5 + 0.5) * float(n - 1u);
    float2 cell = clamp(floor(g), 0.0, float(n - 2u));
    float2 f = saturate(g - cell);
    uint2 base = uint2(cell);
    uint3 frames;
    float3 weights;
    if (f.x + f.y < 1.0) {
        frames = uint3(base.x | base.y << 16u, (base.x + 1u) | base.y << 16u, base.x | (base.y + 1u) << 16u);
        weights = float3(1.0 - f.x - f.y, f.x, f.y);
    } else {
        frames = uint3((base.x + 1u) | (base.y + 1u) << 16u, base.x | (base.y + 1u) << 16u, (base.x + 1u) | base.y << 16u);
        weights = float3(f.x + f.y - 1.0, 1.0 - f.x, 1.0 - f.y);
    }
    // The level of the textures whose texel is the size of a pixel there.
    float pixel = frame.footprint.x + frame.footprint.y * max(distance - radius, 0.0);
    float texel = 2.0 * radius / float(max(row.frames.w, 1u));
    o.frames = uint4(frames, inst.row);
    o.weights = float4(weights, log2(max(pixel / max(texel, 1e-6), 1.0)));
    o.fades = float2(appear, gone);
    o.world0 = world[0];
    o.world1 = world[1];
    o.world2 = world[2];
    return o;
}
