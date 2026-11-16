package importer

import "core:math"
import "mirai:asset"

// The conversions between the ways sources describe a surface and the
// metallic-roughness material of the engine, for every format.

// The reflectance at normal incidence of a dielectric of this index of refraction.
f0_from_ior :: proc "contextless" (ior:f32) -> f32 {
    ratio:=(ior-1)/(ior+1)
    return ratio*ratio
}

// What a material can hold as its index of refraction: 1 and above.
ior_valid :: proc "contextless" (ior:f32) -> bool {
    return ior-ior==0 && ior>=1
}

// A source whose index of refraction is 0, the specular-glossiness mode of
// KHR_materials_ior, reflects its specular color at every angle: it is
// converted as such a surface (specular_glossiness) and takes the index of a
// common dielectric, without its specular maps. textured: it had one.
ior_zero_convert :: proc(info:^asset.Material_Info,textured:bool) {
    specular:=info.specular_color*info.specular_factor
    specular_glossiness(info,{diffuse={info.base_color.r,info.base_color.g,info.base_color.b,info.opacity},specular=specular,glossiness=1-info.roughness,textured=textured})
    info.ior,info.specular_factor,info.specular_color=DIELECTRIC_IOR,1,{1,1,1}
    info.maps.specular,info.maps.specular_color=asset.MATERIAL_MAP_DEFAULT,asset.MATERIAL_MAP_DEFAULT
}

DIELECTRIC_IOR :: f32(1.5)

Specular_Glossiness :: struct {
    diffuse:[4]f32,  // linear color and opacity
    specular:[3]f32, // reflectance at normal incidence, linear
    glossiness:f32,
    textured:bool,   // a texture varies specular and glossiness over the surface
}

// A specular-glossiness surface as metallic-roughness. The factors alone
// solve how metallic it is from how bright its diffuse and its specular are,
// as the converter of the Khronos Group does; a surface whose specular comes
// from a texture cannot be converted texel by texel and stays a dielectric
// with the diffuse color, which the reader reports.
specular_glossiness :: proc(info:^asset.Material_Info,sg:Specular_Glossiness) {
    info.opacity=clamp(sg.diffuse.a,0,1)
    info.roughness=clamp(1-sg.glossiness,0,1)
    diffuse:=[3]f32{clamp(sg.diffuse.r,0,1),clamp(sg.diffuse.g,0,1),clamp(sg.diffuse.b,0,1)}
    if sg.textured {
        info.base_color,info.metallic=diffuse,0
        return
    }
    specular:=[3]f32{clamp(sg.specular.r,0,1),clamp(sg.specular.g,0,1),clamp(sg.specular.b,0,1)}
    dielectric:=f0_from_ior(DIELECTRIC_IOR)
    remaining:=1-max(specular.r,specular.g,specular.b)
    metallic:=solve_metallic(brightness(diffuse),brightness(specular),remaining,dielectric)
    from_diffuse:=diffuse*(remaining/(1-dielectric)/max(1-metallic,1e-6))
    from_specular:=(specular-dielectric*(1-metallic))*(1/max(metallic,1e-6))
    base:=math.lerp(from_diffuse,from_specular,metallic*metallic)
    info.base_color={clamp(base.r,0,1),clamp(base.g,0,1),clamp(base.b,0,1)}
    info.metallic=metallic
}

@(private="file")
brightness :: proc "contextless" (color:[3]f32) -> f32 {
    return math.sqrt(0.299*color.r*color.r+0.587*color.g*color.g+0.114*color.b*color.b)
}

@(private="file")
solve_metallic :: proc "contextless" (diffuse,specular,remaining,dielectric:f32) -> f32 {
    if specular<dielectric {return 0}
    a:=dielectric
    b:=diffuse*remaining/(1-dielectric)+specular-2*dielectric
    c:=dielectric-specular
    root:=math.sqrt(max(b*b-4*a*c,0))
    return clamp((-b+root)/(2*a),0,1)
}
