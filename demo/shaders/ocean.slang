//! mirai surface Ocean
//! parameter color {"default":[0.01,0.075,0.11],"min":0,"max":1,"color":true,"group":"Color"}
//! parameter crest_color {"default":[0.05,0.3,0.32],"min":0,"max":1,"color":true,"group":"Color"}
//! parameter roughness {"default":0.06,"min":0.045,"max":1,"group":"Surface"}
//! parameter speed {"default":1,"min":0,"max":20,"group":"Waves"}
//! parameter frequency {"default":1.4,"min":0.001,"max":100,"group":"Waves"}
//! parameter normal_strength {"default":0.2,"min":0,"max":2,"group":"Surface"}
//! parameter foam {"default":0.25,"min":0,"max":1,"group":"Color"}
namespace Ocean {
struct Parameters {float3 color;float roughness;float3 crest_color;float speed;float frequency;float normal_strength;float foam;};
// The short waves the geometry does not have: the slope and the height of a
// sum of sines that run in different directions, each one shorter than the
// one before and as much faster as water of that length is. x is relative to
// the origin, in radians of the first one, and each takes what the origin
// adds to its phase from its steps (origin.slang). dx and dy are x and z of
// the steps to the next pixel, in metres: a ripple fades out from four steps
// across its length to two, where it would alias, and variance is the
// variance of the slope it leaves out, which widens the lobe instead (Toksvig).
float2 ripples(float2 x, int3 origin, float scale, float t, int octaves, float2 dx, float2 dy, out float height, out float variance) {
    float2 slope=float2(0);height=0;variance=0;
    float frequency=1,weight=1,total=0,angle=0.4;
    for (int i=0;i<octaves;i++) {
        float2 direction=float2(cos(angle),sin(angle));
        float across=max(abs(dot(dx,direction)),abs(dot(dy,direction)));
        float seen=saturate(6.2831853/(frequency*scale*max(2.0*across,1e-6))-1.0);
        float shift=origin_phase(origin,float3(direction.x,0,direction.y)*(frequency*scale/6.2831853))*6.2831853;
        float phase=shift+dot(direction,x)*frequency+t*sqrt(frequency)*1.7;
        slope+=direction*(seen*weight*cos(phase));height+=seen*weight*sin(phase);
        variance+=0.5*weight*weight*(1.0-seen*seen);
        total+=weight;frequency*=1.83;weight*=0.78;angle+=2.399963;
    }
    height/=total;variance/=total*total;
    return slope/total;
}
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    // A ray gathers the surface over a footprint: the shortest ripples average out.
    float height,variance;
    float2 slope=ripples(ctx.world_position.xz*p.frequency,ctx.origin,p.frequency,ctx.time*p.speed,ctx.ray?3:6,ctx.position_dx.xz,ctx.position_dy.xz,height,variance)*p.normal_strength;
    s.normal=normalize(ctx.normal+float3(-slope.x,0,-slope.y));
    // Light crosses the thin water of a crest: steep and high water is lighter,
    // and the steepest of it breaks into foam.
    float crest=saturate((1.0-saturate(s.normal.y))*5.0+max(height,0.0)*0.35);
    float foam=p.foam*smoothstep(0.5,1.0,saturate((1.0-saturate(ctx.normal.y))*8.0+height*0.5+0.25));
    s.base_color=lerp(lerp(p.color,p.crest_color,crest),float3(0.86,0.92,0.93),foam);
    float alpha=p.roughness*p.roughness;
    float wide=sqrt(sqrt(min(alpha*alpha+2.0*variance*p.normal_strength*p.normal_strength,1.0)));
    s.roughness=lerp(wide,0.55,foam);s.specular_ior=1.333;
    return s;
}
}
