#include "native.slang"
// A map of a viewmodel before its layer is drawn (render/foreground.odin):
// the farthest depth over its square of the atlas.
[shader("fragment")]
float main(float4 pixel : SV_Position) : SV_Depth {
    return 0.0;
}
