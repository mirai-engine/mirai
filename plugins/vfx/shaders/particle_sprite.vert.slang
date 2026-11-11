//! per vfx program
#include "native.slang"
// A quad per particle of the list an emitter draws, facing the camera, along
// its velocity or flat on the ground. A ribbon joins each particle to the next
// one of its list in the same ribbon, along the curve through them: a quad
// per piece of each segment (Particle_State.pieces), placed on the cubic that
// leaves each end along the mean of the directions to its neighbours. The
// program of the emitter has the last word on what it shows.
#define PARTICLE_STATES_READ
#include "particle_programs.slang"

struct Params_Block { uint emitter; uint pass; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

struct Stage_Output {
    float4 position : SV_Position;
    [[vk::location(0)]] float4 out_color : TEXCOORD0;
    [[vk::location(1)]] float3 out_light : TEXCOORD1;
    [[vk::location(2)]] float4 out_uv : TEXCOORD2;   // two frames of the flipbook
    [[vk::location(3)]] float2 out_blend_depth : TEXCOORD3; // between them, and the view depth
    [[vk::location(4)]] nointerpolation float out_seed : TEXCOORD4;
    [[vk::location(5)]] float3 out_world : TEXCOORD5;
    [[vk::location(6)]] nointerpolation float4 out_data0 : TEXCOORD6; // what the particle gives its material
    [[vk::location(7)]] nointerpolation float4 out_data1 : TEXCOORD7;
    [[vk::location(8)]] nointerpolation float4 out_data2 : TEXCOORD8;
    [[vk::location(9)]] nointerpolation float4 out_data3 : TEXCOORD9;
    [[vk::location(10)]] nointerpolation uint out_given : TEXCOORD10;
    [[vk::location(11)]] nointerpolation float2 out_random_radius : TEXCOORD11;
};

float2 flipbook_uv(Particle_Emitter e, float2 corner, float frame_index) {
    float frames = float(e.flipbook.x * e.flipbook.y);
    float f = mod(frame_index, max(frames, 1.0));
    float column = mod(f, float(e.flipbook.x));
    float row = floor(f / float(e.flipbook.x));
    return (corner + float2(column, row)) / float2(e.flipbook.xy);
}

[shader("vertex")]
Stage_Output main(uint vertex_id : SV_VulkanVertexID, uint instance_id : SV_VulkanInstanceID) {
    Stage_Output output;
    Particle_Emitter e = particle_emitters[params.emitter];
    float2 corner = float2(float(vertex_id & 1u), float(vertex_id >> 1u));
    float2 c = corner * 2.0 - 1.0;
    bool ribbon = e.kinds.y == PARTICLE_RENDER_RIBBON;
    float3 world;
    float2 uv = float2(corner.x, 1.0 - corner.y);
    Particle p;
    Particle_Look look;
    uint index;
    float half_size;
    float3 light;
    if (ribbon) {
        // The segment of the instance: the last whose quads start at or before it.
        uint alive = min(particle_states[params.emitter].alive, min(e.range.y, PARTICLE_SORT_MAX));
        uint starts = 3u * e.program.y + e.range.x;
        uint low = 0u, high = max(alive, 1u) - 1u;
        while (high - low > 1u) {
            uint middle = (low + high) >> 1u;
            if (particle_lists[starts + middle] <= instance_id) low = middle; else high = middle;
        }
        uint segment = low;
        uint first = particle_lists[starts + segment];
        uint pieces = max(particle_pieces(particles[particle_drawn(params.emitter, segment)]), 1u);
        float along_t = float(instance_id - first + (vertex_id >> 1u)) / float(pieces);
        index = particle_drawn(params.emitter, segment);
        uint next = particle_drawn(params.emitter, segment + 1u);
        p = particles[index];
        Particle q = particles[next];
        uint id = particle_ribbon(p);
        // The last of a ribbon and the first of the next are not joined.
        if (particle_ribbon(q) != id) {
            output = (Stage_Output)0;
            output.position = float4(2.0, 2.0, 2.0, 1.0);
            return output;
        }
        float3 a = particle_world(params.emitter, p.position);
        float3 b = particle_world(params.emitter, q.position);
        float3 ta = b - a, tb = b - a;
        if (segment > 0u) {
            Particle before = particles[particle_drawn(params.emitter, segment - 1u)];
            if (particle_ribbon(before) == id) ta = ribbon_tangent(particle_world(params.emitter, before.position), a, b);
        }
        if (segment + 2u < alive) {
            Particle after = particles[particle_drawn(params.emitter, segment + 2u)];
            if (particle_ribbon(after) == id) tb = ribbon_tangent(a, b, particle_world(params.emitter, after.position));
        }
        // Hermite, each end leaving along its direction scaled by the chord.
        float chord = length(b - a);
        float3 m0 = (length(ta) > 1e-6 ? normalize(ta) : float3(0.0)) * chord;
        float3 m1 = (length(tb) > 1e-6 ? normalize(tb) : float3(0.0)) * chord;
        float u = along_t, u2 = along_t * along_t, u3 = u2 * along_t;
        float3 center = (2.0 * u3 - 3.0 * u2 + 1.0) * a + (u3 - 2.0 * u2 + u) * m0 + (3.0 * u2 - 2.0 * u3) * b + (u3 - u2) * m1;
        float3 along = (6.0 * u2 - 6.0 * u) * a + (3.0 * u2 - 4.0 * u + 1.0) * m0 + (6.0 * u - 6.0 * u2) * b + (3.0 * u2 - 2.0 * u) * m1;
        if (length(along) <= 1e-6) along = b - a;
        // What both ends show, as the frame kept it: no program runs per vertex.
        Particle_Look la = particle_ribbon_look(params.emitter, index);
        Particle_Look lb = particle_ribbon_look(params.emitter, next);
        look = along_t < 0.5 ? la : lb;
        look.color = lerp(la.color, lb.color, along_t);
        look.size = lerp(la.size, lb.size, along_t);
        half_size = look.size * 0.5;
        float3 side = cross(along, to_eye(center));
        side = length(side) > 1e-6 ? normalize(side) : frame.view[0].xyz;
        world = center + side * c.x * half_size;
        uv = float2(corner.x, saturate(lerp(p.age / max(p.lifetime, 1e-5), q.age / max(q.lifetime, 1e-5), along_t)));
        light = (e.range.w & PARTICLE_FLAG_LIT) != 0u ? lerp(particle_light(p), particle_light(q), along_t) : emission_render_units(float3(1.0), (e.range.w & PARTICLE_FLAG_RELATIVE) != 0u);
    } else {
        index = particle_drawn(params.emitter, instance_id);
        p = particles[index];
        look = particle_program_look(params.emitter, index, p);
        float3 center = particle_world(params.emitter, p.position);
        float3 to_camera = to_eye(center);
        half_size = look.size * 0.5;
        float3 right = frame.view[0].xyz;
        float3 up = frame.view[1].xyz;
        float s = sin(p.rotation), co = cos(p.rotation);
        float2 extent = float2(half_size, half_size);
        if (e.kinds.y == PARTICLE_RENDER_VELOCITY) {
            float3 velocity = particle_world_vector(params.emitter, p.velocity);
            float3 axis = velocity - to_camera * dot(velocity, to_camera);
            if (length(axis) > 1e-5) {
                up = normalize(axis);
                right = normalize(cross(up, to_camera));
                extent.y = half_size + length(velocity) * e.look.x * 0.5;
                s = 0.0; co = 1.0;
            }
        } else if (e.kinds.y == PARTICLE_RENDER_HORIZONTAL) {
            right = float3(1.0, 0.0, 0.0);
            up = float3(0.0, 0.0, -1.0);
        }
        float3 r = right * co + up * s;
        float3 u = up * co - right * s;
        world = center + r * c.x * extent.x + u * c.y * extent.y;
        // Unlit, its color is a luminance in nits, or what the exposed image shows.
        light = (e.range.w & PARTICLE_FLAG_LIT) != 0u ? particle_light(p) : emission_render_units(float3(1.0), (e.range.w & PARTICLE_FLAG_RELATIVE) != 0u);
    }
    output.position = view_clip(world);
    output.out_color = look.color;
    output.out_light = light;
    float frame_index = floor(look.frame);
    output.out_uv = float4(flipbook_uv(e, uv, frame_index), flipbook_uv(e, uv, frame_index + 1.0));
    output.out_blend_depth = float2(look.frame - frame_index, dot(world - frame.camera_position.xyz, frame.camera_forward.xyz));
    output.out_seed = float(p.seed & 1023u) * 0.37;
    output.out_world = world;
    output.out_data0 = look.data[0]; output.out_data1 = look.data[1]; output.out_data2 = look.data[2]; output.out_data3 = look.data[3];
    output.out_given = look.given;
    output.out_random_radius = float2(look.random, half_size);
    return output;
}
