package importer

import "core:math"
import "core:testing"
import "mirai:asset"

@(test)
specular_glossiness_becomes_metallic_roughness :: proc(t:^testing.T) {
    close :: proc(a,b:f32) -> bool {return abs(a-b)<1e-4}
    testing.expect(t,close(f0_from_ior(1.5),0.04) && close(f0_from_ior(1),0))
    testing.expect(t,!ior_valid(0) && ior_valid(1) && ior_valid(1.5) && !ior_valid(0.5) && !ior_valid(-1) && !ior_valid(math.nan_f32()))

    // An index of refraction of 0 is no mode of a material: a surface that came with it is converted too.
    Zero :: struct {base,specular:[3]f32,factor,roughness:f32,mapped:bool,metallic:f32,color:[3]f32}
    zeros:=[?]Zero{
        {base={1,1,1},specular={1,1,1},factor=1,roughness=0.25,metallic=1,color={1,1,1}},              // a mirror at every angle: a metal
        {base={0.5,0.25,0.125},specular={1,1,1},factor=0.04,roughness=0.75,metallic=0,color={0.5,0.25,0.125}}, // the reflectance of a plastic
        {base={0.5,0.5,0.5},specular={1,1,1},factor=1,roughness=0.5,mapped=true,metallic=0,color={0.5,0.5,0.5}},  // a specular map cannot be converted
    }
    for zero in zeros {
        given:=asset.MATERIAL_DEFAULTS
        given.ior,given.base_color,given.specular_color,given.specular_factor,given.roughness,given.opacity=0,zero.base,zero.specular,zero.factor,zero.roughness,0.5
        if zero.mapped {given.maps.specular.texture={7,7}}
        testing.expect(t,!asset.material_check({info=&given}),"a material does not hold an index of refraction of 0")
        ior_zero_convert(&given,zero.mapped)
        testing.expect(t,asset.material_check({info=&given}) && given.ior==DIELECTRIC_IOR && given.specular_factor==1 && given.specular_color==[3]f32{1,1,1} && given.maps.specular.texture=={})
        testing.expectf(t,close(given.metallic,zero.metallic) && close(given.roughness,zero.roughness) && close(given.opacity,0.5),"%v",given.metallic)
        testing.expectf(t,close(given.base_color.r,zero.color.r) && close(given.base_color.g,zero.color.g) && close(given.base_color.b,zero.color.b),"%v",given.base_color)
    }

    // The defaults of the extension are a white mirror: a metal.
    info:=asset.MATERIAL_DEFAULTS
    specular_glossiness(&info,{diffuse={1,1,1,1},specular={1,1,1},glossiness=1})
    testing.expect(t,close(info.metallic,1) && close(info.roughness,0) && close(info.base_color.r,1),"a white specular is a metal")

    // The reflectance of a dielectric leaves the diffuse color as the base.
    info=asset.MATERIAL_DEFAULTS
    specular_glossiness(&info,{diffuse={0.5,0.25,0.125,0.75},specular={0.04,0.04,0.04},glossiness=0.25})
    testing.expect(t,close(info.metallic,0) && close(info.roughness,0.75) && close(info.opacity,0.75),"a plastic stays a dielectric")
    testing.expect(t,close(info.base_color.r,0.5) && close(info.base_color.g,0.25) && close(info.base_color.b,0.125))

    // A specular that a texture varies stays a dielectric with the diffuse color.
    info=asset.MATERIAL_DEFAULTS
    specular_glossiness(&info,{diffuse={0.5,0.5,0.5,1},specular={1,1,1},glossiness=0.5,textured=true})
    testing.expect(t,info.metallic==0 && info.base_color==[3]f32{0.5,0.5,0.5} && close(info.roughness,0.5))
    testing.expect(t,asset.material_check({info=&info}))
}
