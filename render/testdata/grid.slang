//! mirai surface Grid
//! parameter color {"default":[0.42,0.42,0.42],"min":0,"max":1,"color":true}
//! parameter line_color {"default":[0.2,0.2,0.2],"min":0,"max":1,"color":true}
//! parameter cell {"default":1,"min":0.01,"max":1000}
//! parameter roughness {"default":0.7,"min":0.045,"max":1}
namespace Grid {
struct Parameters {float3 color;float cell;float3 line_color;float roughness;};
// A neutral surface with lines every `cell` metres of the world and darker
// ones every ten: what shows the scale of something whose own material is
// not there. Each face takes the two axes of the world its normal is most
// across, as a cube is projected. Lines thinner than a pixel fade into
// their share of the cell instead of shimmering.
float lines(float2 place, float2 pixel, float width) {
    float2 distance=abs(frac(place+0.5)-0.5);
    float2 soft=max(pixel,1e-5);
    float2 covered=1.0-smoothstep(width-soft,width+soft,distance);
    float2 share=saturate(2.0*width);
    float2 far=saturate(pixel*2.0-1.0);
    covered=lerp(covered,share,far);
    return max(covered.x,covered.y);
}

Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float cell=max(p.cell,0.01);
    // Relative to the origin, plus what the origin adds to a pattern of ten cells.
    float3 place=(ctx.world_position+origin_wrap(ctx.origin,float3(cell*10.0)))/cell;
    float3 pixel=(abs(ctx.position_dx)+abs(ctx.position_dy))/cell;
    float3 n=abs(ctx.vertex_normal);
    float2 a,da;
    if (n.x>=n.y && n.x>=n.z) {a=place.yz;da=pixel.yz;}
    else if (n.y>=n.z) {a=place.xz;da=pixel.xz;}
    else {a=place.xy;da=pixel.xy;}
    float minor=lines(a,da,0.01);
    float major=lines(a*0.1,da*0.1,0.004);
    float line=max(minor*0.6,major);
    s.base_color=lerp(p.color,p.line_color,line);
    s.roughness=p.roughness;
    return s;
}
}
