#include "native.slang"

struct Stage_Input {
    [[vk::location(0)]] float4 in_color : TEXCOORD0;
};
struct Stage_Output {
    [[vk::location(0)]] float4 out_color : SV_Target0;
};
[shader("fragment")]
Stage_Output main(Stage_Input input) {
    Stage_Output output;
    output.out_color = input.in_color;
    return output;
}
