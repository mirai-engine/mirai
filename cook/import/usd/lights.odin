package usd

import "core:math"
import "core:strings"
import importer "mirai:cook/import"
import mm "mirai:std/math"

// UsdLux lights. A light gives the luminance of its surface in nits,
// intensity · 2^exposure · color, divided by its area in the units of the
// stage with normalize; a DistantLight, the illuminance in lux of what faces
// it, which without normalize is that luminance over the disc of the sky its
// angle covers. Mirai keeps candelas for a point or a spot (the luminance
// times the area it shows along its axis, in m²), nits for a rectangle and
// lux for a sun.

// An input of a light, also by its name before UsdLux put it under inputs:.
@(private="file")
light_attribute :: proc(prim:Usd_Prim,name:string) -> (property:Usd_Property,found:bool) {
    property,found=prim.properties[strings.concatenate({"inputs:",name},context.temp_allocator)]
    if !found {property,found=prim.properties[name]}
    return
}

@(private="file")
light_number :: proc(r:^importer.Reader,prim:Usd_Prim,name:string,fallback:f64) -> (value:f64,ok:bool) {
    property,found:=light_attribute(prim,name)
    if !found {return fallback,true}
    values:=usd_numbers(r,property) or_return
    if len(values)!=1 {return fallback,importer.fail(r,.Malformed,"inputs:%s of a USD light needs one number",name)}
    return values[0],true
}

@(private="file")
light_length :: proc(r:^importer.Reader,prim:Usd_Prim,name:string,fallback:f64) -> (value:f64,ok:bool) {
    value=light_number(r,prim,name,fallback) or_return
    if value<0 {return value,importer.fail(r,.Malformed,"inputs:%s of a USD light is negative",name)}
    return value,true
}

@(private="file")
light_flag :: proc(prim:Usd_Prim,name:string) -> bool {
    property,found:=light_attribute(prim,name)
    value:=usd_string(property) if found else ""
    return value=="1" || value=="true"
}

// The light of a SphereLight, DiskLight, RectLight or DistantLight prim.
@(private)
usd_light :: proc(r:^importer.Reader,prim:Usd_Prim) -> (light:importer.Imported_Light,ok:bool) {
    intensity:=light_number(r,prim,"intensity",1) or_return
    exposure:=light_number(r,prim,"exposure",0) or_return
    if intensity<0 {return light,importer.fail(r,.Malformed,"the intensity of a USD light is negative")}
    color:=[3]f32{1,1,1}
    if property,found:=light_attribute(prim,"color");found {
        values:=usd_numbers(r,property) or_return
        if len(values)!=3 {return light,importer.fail(r,.Malformed,"inputs:color of a USD light needs three numbers")}
        color={max(f32(values[0]),0),max(f32(values[1]),0),max(f32(values[2]),0)}
    }
    if light_flag(prim,"enableColorTemperature") {
        kelvin:=light_number(r,prim,"colorTemperature",6500) or_return
        color*=mm.blackbody_linear(f32(kelvin))
    }
    luminance:=intensity*math.pow(2,exposure)
    normalize:=light_flag(prim,"normalize")
    // The scale of the prim in the world: normalize divides by the area it gives the light.
    scale:[3]f64
    for axis in 0..<3 {scale[axis]=math.sqrt(f64(prim.world[0,axis]*prim.world[0,axis]+prim.world[1,axis]*prim.world[1,axis]+prim.world[2,axis]*prim.world[2,axis]))}
    meters:=f64(r.space.meters_per_unit)
    area,shown:f64 // in units of the stage²: of its surface, and as seen along its axis
    spot_radius:f64
    switch prim.type_name {
    case "SphereLight":
        radius:=light_length(r,prim,"radius",0.5) or_return
        world:=radius*max(scale.x,scale.y,scale.z)
        area,shown=4*math.PI*world*world,math.PI*world*world
        light.kind=.Point
        light.radius=0 if light_flag(prim,"treatAsPoint") else f32(radius)
    case "DiskLight":
        radius:=light_length(r,prim,"radius",0.5) or_return
        area=math.PI*radius*radius*scale.x*scale.y
        shown=area
        // Mirai has no disk: the square of its area.
        side:=f32(radius*math.sqrt(f64(math.PI)))
        light.kind=.Rect
        light.size={side,side}
        spot_radius=radius
    case "RectLight":
        width:=light_length(r,prim,"width",1) or_return
        height:=light_length(r,prim,"height",1) or_return
        area=width*height*scale.x*scale.y
        shown=area
        light.kind=.Rect
        light.size={f32(width),f32(height)}
        spot_radius=math.sqrt(width*height/math.PI)
    case "DistantLight":
        angle:=light_length(r,prim,"angle",0.53) or_return
        // The projected solid angle of the disc of the sky the light is.
        half:=clamp(math.to_radians(angle)/2,0,math.PI)
        sine:=math.sin(half)
        disc:=1.0
        if half>0 && half<=math.PI/2 {disc=math.PI*sine*sine} else if half>math.PI/2 {disc=math.PI*(2-sine*sine)}
        light.kind=.Directional
        luminance*=1 if normalize else disc
    }
    if normalize && light.kind!=.Directional && area>0 {luminance/=area}
    cone:=light_number(r,prim,"shaping:cone:angle",90) or_return
    if light.kind!=.Directional && cone<90 {
        if cone<=0 {return light,importer.fail(r,.Malformed,"the cone of a USD light needs an angle above 0°")}
        if prim.type_name=="RectLight" {importer.warn(r,"%s: the cone of a RectLight makes it a spot, a sphere that shows its area",prim.path)}
        softness:=light_number(r,prim,"shaping:cone:softness",0) or_return
        light.kind=.Spot
        light.outer_cone=f32(math.to_radians(cone))
        light.inner_cone=light.outer_cone*f32(1-clamp(softness,0,1))
        if prim.type_name!="SphereLight" {light.radius,light.size=f32(spot_radius),{}}
    } else if prim.type_name=="DiskLight" {
        importer.warn(r,"%s: a DiskLight is a rectangle of its area",prim.path)
    }
    if light.kind==.Point || light.kind==.Spot {luminance*=shown*meters*meters}
    focus:=light_number(r,prim,"shaping:focus",0) or_return
    if focus!=0 {importer.warn(r,"%s: the focus of a USD light is not imported",prim.path)}
    if _,found:=light_attribute(prim,"shaping:ies:file");found {importer.warn(r,"%s: the IES profile of a USD light is not imported",prim.path)}
    // No channel above one: what is above goes to the intensity.
    peak:=max(color.r,color.g,color.b)
    if peak>1 {color/=peak;luminance*=f64(peak)}
    if !(luminance<=f64(max(f32))) {return light,importer.fail(r,.Malformed,"the intensity of a USD light is out of range")}
    light.color=color
    light.intensity=f32(luminance)
    return light,true
}
