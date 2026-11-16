//! mirai surface Water_Surface
//! parameter tint {"default":[1,1,1],"min":0,"max":1,"color":true}
//! parameter roughness {"default":0.02,"min":0,"max":1}
//! parameter detail {"default":1,"min":0,"max":4}
#include "water.slang"
namespace Water_Surface {
struct Parameters {float3 tint;float roughness;float detail;};
// The surface of the water of the plugin water: a glass the small waves bend
// (water.slang, the same the caustics follow). tint filters what is seen
// through it. On a river the waves drift with its flow, which the blue of
// the vertex color being 0 says its red and green carry (river.odin): two
// copies of them carried by the flow half a turn apart, each faded out as it
// starts again, so they drift without being stretched.
static const float FLOW_REACH = 8.0; // m/s, water.FLOW_REACH
static const float FLOW_TURN = 2.0;  // s a copy drifts before it starts again
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float2 place=water_detail_place(ctx.world_position.xz,ctx.origin);
    float2 slope=water_detail_slope(place,ctx.time);
    if (ctx.vertex_color.b < 0.5) {
        float2 flow=(ctx.vertex_color.rg*2.0-1.0)*FLOW_REACH;
        float a=frac(ctx.time/FLOW_TURN), b=frac(ctx.time/FLOW_TURN+0.5);
        float2 first=water_detail_slope(place-flow*(a*FLOW_TURN),ctx.time);
        float2 second=water_detail_slope(place-flow*(b*FLOW_TURN),ctx.time);
        slope=lerp(first,second,abs(2.0*a-1.0));
    }
    slope*=p.detail;
    float3 bent=normalize(float3(-slope.x,1.0,-slope.y));
    s.normal=normalize(ctx.normal+bent-float3(0.0,1.0,0.0));
    s.base_color=p.tint;
    s.roughness=p.roughness;
    return s;
}
}
