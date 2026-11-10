package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import importer "mirai:cook/import"
import "mirai:core"
import render "mirai:engine/render"
import mm "mirai:std/math"

// The skies of the demo: images of the whole sky in source/textures, from
// the HDRIs of Poly Haven (CC0) by Greg Zaal and Dimitrios Savva at 4096 x
// 2048. Day is kloofendal_48d_partly_cloudy_puresky as it was shot, with its
// sun painted out (the Sun of the scene gives it); the others are tone mapped.
Sky :: enum u8 {Day,Sunset,Overcast,Night}

@(private)
Sky_Image :: struct {
    file:string,
    sun:[2]f32,  // where its sun is: across the image, and down it from the zenith, both 0 to 1
    disc:bool,   // its sun is in sight: that of the scene is drawn over it
    light:[3]f32, // what multiplies the image: the luminance of its white, in the units of the scene
    per_lux:f32,  // an image as it was shot: the nits of its 1 for each lux of the sun of the scene, the ratio of the sun painted out of it to its sky
}

@(private)
SKIES :: [Sky]Sky_Image{
    .Day={"sky_day.hdr",{0.6013,0.2306},true,0,0.2226271},
    .Sunset={"sky_sunset.jpg",{0.6318,0.4622},true,1.1,0},
    .Overcast={"sky_overcast.jpg",{0.5906,0.3745},false,0.8,0},
    // The glow of the towns under it is warm: the night of the demo is blue.
    .Night={"sky_night.jpg",{0.6225,0.4951},false,{0.22,0.34,0.7},0},
}

// The units the lights of a scene are set in. The demo set its lights in a
// unit where a white surface that faces a light of 1 shows 1, and one factor
// for each scene, nits per unit, turns all of them into physical units alike:
// its sun, sky, lamps and what glows keep how they compare.
Light_Units :: struct {nits:f32}

// A lamp of 1 in candela: a lamp of 12 is a strong one of 600 cd.
LAMP :: f32(50)
// A scene its lamps light, by day or by night: its lamps keep plausible
// candela, and its sun and sky are as dim next to them as the demo has them.
// By day that is the light of dusk, which the meter of the camera exposes
// like a noon.
LAMPLIT :: Light_Units{nits=LAMP/math.PI}
// The sun of a clear noon, lux.
NOON :: f32(100000)
// A scene the sun alone lights, whose sun is `sun`: it gives the lux of noon.
daylight :: proc(sun:f32) -> Light_Units {return {nits=NOON/(math.PI*sun)}}

// A sun, lux, or a lamp, candela: a white surface that faces it (a metre
// away) shows pi nits a lux.
lux :: proc(u:Light_Units,value:f32) -> f32 {return value*u.nits*math.PI}
candela :: lux
// A luminance, nits: a sky, a background, what glows.
nits :: proc{nits_rgb,nits_one}
nits_rgb :: proc(u:Light_Units,value:[3]f32) -> [3]f32 {return value*u.nits}
nits_one :: proc(u:Light_Units,value:f32) -> f32 {return value*u.nits}

// The Sky of a scene and how much its entity turns around the vertical so
// that the sun of its image has the heading of `towards`, and where the sun of
// the scene then is: at that heading, as high as the image has it. A sky
// without a sun in sight leaves the sun where the scene asked for it and says
// not to draw it. sun: that of the scene, in its units.
sky_of :: proc(o:^Out,sky:Sky,towards:[3]f32,u:Light_Units,sun:f32) -> (environment:render.Sky,turn:f32,to_sun:[3]f32,disc:bool) {
    images:=SKIES
    image:=images[sky]
    heading:=math.atan2(towards.z,towards.x)
    texture:=imported_id(o,fmt.tprintf("source/textures/%s",image.file),asset.KIND_TEXTURE,filepath.stem(image.file))
    turned:=2*math.PI*(image.sun.x-0.5)-heading
    turn=math.atan2(math.sin(turned),math.cos(turned))
    environment={luminance=image.per_lux>0?image.per_lux*lux(u,sun):nits(u,image.light),image=texture,air=render.AIR_DEFAULT}
    to_sun=linalg.normalize(towards)
    if image.disc {
        height:=(0.5-image.sun.y)*math.PI
        to_sun={math.cos(height)*math.cos(heading),math.sin(height),math.cos(height)*math.sin(heading)}
    }
    return environment,turn,to_sun,image.disc
}

// The pose of a sun that shines from a direction: its -Z away from it.
sun_pose :: proc(to_sun:[3]f32,position:[3]f32={}) -> core.Transform {
    return {position,mm.quat_between([3]f32{0,0,1},linalg.normalize(to_sun)),{1,1,1}}
}
