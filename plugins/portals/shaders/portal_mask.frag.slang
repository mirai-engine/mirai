#include "native.slang"
// The pixels of a view that look through a portal (nested_face.slang). Their
// depth becomes that of the opening, so that nothing of this side behind it is
// drawn over what the portal shows.
#include "nested_face.slang"
#include "portal.slang"

struct Params_Block { uint gate; uint index; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("fragment")]
Nested_Face_Output main(float4 pixel : SV_Position) {
    Portal_Gate gate = frame.portals.gates[params.gate];
    float3 crossing;
    if (!nested_face_crossing(pixel, gate.to_local[2], crossing)) discard;
    if (!portal_open(gate, portal_point(gate, crossing))) discard;
    return nested_face_output(crossing, params.index);
}
