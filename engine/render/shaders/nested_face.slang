// The mask of a face a view looks into through a nested view (pass_nested_faces
// in engine/render): the pixels whose ray meets the face from its front before
// anything else are given to the nested view, with the depth of the face. The
// face is found for each ray and not drawn as geometry: it stays whole with the
// eye next to it, where a quad would be cut by the near plane.
#ifndef MIRAI_NESTED_FACE_SLANG
#define MIRAI_NESTED_FACE_SLANG
#include "scene.slang"

struct Nested_Face_Output {
    [[vk::location(0)]] float4 out_motion : SV_Target0;
    [[vk::location(1)]] float out_depth : SV_Target1;
    float depth : SV_Depth;
};

// Where the ray of a pixel meets the plane of a face, whose height above it is
// dot(plane.xyz, p) + plane.w: false from behind the face or when the ray goes
// away from it.
bool nested_face_crossing(float4 pixel, float4 plane, out float3 crossing) {
    float2 uv = pixel.xy * frame.inv_resolution;
    float3 origin = view_origin(uv);
    float3 ray = view_ray(uv);
    float height = dot(plane.xyz, origin) + plane.w;
    float approach = dot(plane.xyz, ray);
    crossing = origin + ray * (-height / approach);
    return height > 0.0 && approach < 0.0;
}

// The pixel of a face at crossing, given to the nested view index.
Nested_Face_Output nested_face_output(float3 crossing, uint index) {
    float4 clip = view_clip(crossing);
    Nested_Face_Output output;
    output.out_motion = float4(0.0, 0.0, 0.0, 1.0 + float(index));
    output.out_depth = 0.0;
    // A face nearer than the near plane is still in front of everything drawn.
    output.depth = clip.w > 0.0 ? saturate(clip.z / clip.w) : 1.0;
    return output;
}

#endif
