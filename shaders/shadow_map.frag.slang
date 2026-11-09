#include "native.slang"
//! variant tested MIRAI_SHADOW_TESTED=1
// The depth alone of shadow_map.vert. tested: of a masked or blended
// material, only where it is there, as a shadow ray asks it (hit_covers).
#ifdef MIRAI_SHADOW_TESTED
#include "trace.slang"
[shader("fragment")]
void main([[vk::location(0)]] nointerpolation uint2 place : PLACE, [[vk::location(1)]] float2 bary : BARY, [[vk::location(2)]] nointerpolation float reach : REACH) {
    if (!hit_covers(place.x, place.y, bary, reach, BLEND_PASSES)) discard;
}
#else
[shader("fragment")]
void main() {}
#endif
