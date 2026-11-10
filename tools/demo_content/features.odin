package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import decals "plugins:decals/runtime"

// A scene for each feature of rendering that is a plugin, each one a small
// set that shows what the feature does: decals/decals.scene and the others
// below, with the images they use.

DECAL_SIZE :: 512

@(private)
Decal_Image :: enum {Arrow,Ring,Splat,Stripes}

// An image of DECAL_SIZE made from the coverage and the color `shade` gives each texel, between -1 and 1.
@(private)
write_decal_image :: proc(o:^Out,name:string,shade:proc(x,y:f32) -> [4]f32) -> base.Asset_Id {
    id:=asset.content_id(PROJECT,"texture",name)
    pixels:=make([]u8,DECAL_SIZE*DECAL_SIZE*4,context.temp_allocator)
    for y in 0..<DECAL_SIZE {
        for x in 0..<DECAL_SIZE {
            // The samples of a texel reach into its neighbors: the edges of the shapes stay smooth when the image is magnified.
            sum:[4]f32
            for sample in 0..<16 {
                sx:=(f32(x)-0.25+0.5*f32(sample&3))/DECAL_SIZE*2-1
                sy:=(f32(y)-0.25+0.5*f32(sample>>2))/DECAL_SIZE*2-1
                c:=shade(sx,sy)
                sum+={c.r*c.a,c.g*c.a,c.b*c.a,c.a}
            }
            at:=(y*DECAL_SIZE+x)*4
            alpha:=sum.a/16
            color:=alpha>1e-4?sum.rgb/sum.a:[3]f32{1,1,1}
            pixels[at],pixels[at+1],pixels[at+2]=u8(clamp(color.r,0,1)*255+0.5),u8(clamp(color.g,0,1)*255+0.5),u8(clamp(color.b,0,1)*255+0.5)
            pixels[at+3]=u8(clamp(alpha,0,1)*255+0.5)
        }
    }
    file:=fmt.tprintf("assets/decals/%s.tex",name)
    asset.content_check(&o.content,file,asset.texture_save(path(o,file),&o.content.types,{id=id,width=DECAL_SIZE,height=DECAL_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
    return id
}

@(private)
hash01 :: proc "contextless" (x,y:i32) -> f32 {
    h:=u32(x)*374761393+u32(y)*668265263
    h=(h~(h>>13))*1274126177
    return f32((h~(h>>16))&0xffff)/65535
}

// Smooth noise between 0 and 1.
@(private)
noise01 :: proc "contextless" (x,y:f32) -> f32 {
    ix,iy:=i32(math.floor(x)),i32(math.floor(y))
    fx,fy:=x-f32(ix),y-f32(iy)
    fx,fy=fx*fx*(3-2*fx),fy*fy*(3-2*fy)
    a,b:=hash01(ix,iy)*(1-fx)+hash01(ix+1,iy)*fx,hash01(ix,iy+1)*(1-fx)+hash01(ix+1,iy+1)*fx
    return a*(1-fy)+b*fy
}

@(private)
write_decal_images :: proc(o:^Out) -> (images:[Decal_Image]base.Asset_Id) {
    // An arrow that points up the image.
    images[.Arrow]=write_decal_image(o,"decal_arrow",proc(x,y:f32) -> [4]f32 {
        head:=y<-0.1 && abs(x)<(y+0.9)*0.75
        shaft:=y>=-0.1 && y<0.85 && abs(x)<0.22
        return {1,1,1,head || shaft?1:0}
    })
    // Two rings and the marks of a dial between them.
    images[.Ring]=write_decal_image(o,"decal_ring",proc(x,y:f32) -> [4]f32 {
        r:=math.sqrt(x*x+y*y)
        angle:=math.atan2(y,x)
        ring:=abs(r-0.86)<0.035 || abs(r-0.6)<0.02
        marks:=r>0.64 && r<0.82 && abs(math.mod(angle+math.PI,math.PI/6)-math.PI/12)<0.035/max(r,0.1)
        core:=r<0.18 || (r<0.5 && (abs(x)<0.03 || abs(y)<0.03))
        return {1,1,1,ring || marks || core?1:0}
    })
    // A stain with an uneven edge and drops around it.
    images[.Splat]=write_decal_image(o,"decal_splat",proc(x,y:f32) -> [4]f32 {
        r:=math.sqrt(x*x+y*y)
        angle:=math.atan2(y,x)
        edge:=0.5+0.22*noise01(angle*2.2+7,1.5)+0.1*noise01(angle*7+3,9.5)
        drops:=noise01(x*9+20,y*9+40)>0.83 && r<0.95
        shade:=0.75+0.25*noise01(x*6,y*6)
        return {shade,shade,shade,r<edge || drops?1:0}
    })
    // Warning stripes, with the paint worn in places.
    images[.Stripes]=write_decal_image(o,"decal_stripes",proc(x,y:f32) -> [4]f32 {
        band:=math.mod(x+y+4,0.5)<0.25
        worn:=noise01(x*14+5,y*14+11)*0.6+noise01(x*40,y*40)*0.4
        color:=band?[3]f32{1,0.78,0.05}:[3]f32{0.03,0.03,0.03}
        return {color.r,color.g,color.b,abs(x)<0.97 && abs(y)<0.97 && worn>0.22?1:0}
    })
    return
}

// What the scenes of the features share: a sky, a sun and where the player
// starts, the sun and the sky in the units of the scene, and the EV their
// views take over the meter.
@(private)
feature_scene_begin :: proc(s:^asset.Scene_Builder,o:^Out,name:string,sky:Sky,sun_color:[3]f32,sun:f32,towards:[3]f32,u:Light_Units,exposure:f32=0) {
    asset.builder_init(s,&o.content,asset.content_id(PROJECT,"scene",name))
    environment,turn,to_sun,disc:=sky_of(o,sky,towards,u,sun)
    meter:=render.EXPOSURE_DEFAULT
    meter.compensation=exposure
    sky_set(s,&environment,turn,meter)
    sun:=render.Sun{color=sun_color,illuminance=lux(u,sun),disc=disc}
    sun_entity:=asset.builder_entity(s,"Sun",{position={0,10,0}})
    pose:=sun_pose(to_sun,{0,10,0})
    asset.builder_set(s,sun_entity,pose)
    asset.builder_set(s,sun_entity,sun)
}

// The folder under assets/ of a scene of feature_scene_end: its name, but for
// the scenes that share an area.
@(private)
scene_area :: proc(name:string) -> string {
    switch name {
    case "church_fog":                  return "church"
    case "night":                       return "lights"
    case "portal_chamber","portal_lab": return "portals"
    }
    return name
}

@(private)
feature_scene_end :: proc(s:^asset.Scene_Builder,o:^Out,name:string) {
    defer asset.builder_destroy(s)
    file:=fmt.tprintf("assets/%s/%s.scene",scene_area(name),name)
    asset.builder_save(s,path(o,file))
}

// An entity with a rotation besides its place and its size.
@(private)
placed :: proc(s:^asset.Scene_Builder,name:string,position:[3]f32,rotation:mm.Quat,scale:[3]f32,parent:base.Entity_Id=0) -> base.Entity_Id {
    return asset.builder_entity(s,name,{position,rotation,scale},parent)
}

@(private)
shape :: proc(s:^asset.Scene_Builder,id:base.Entity_Id,kind:render.Shape,material:string) {
    mesh:=render.Mesh_Renderer{shape=kind}
    mesh.materials[0]=game.material_asset(material)
    asset.builder_set(s,id,mesh)
}

@(private)
decal :: proc(s:^asset.Scene_Builder,name:string,position:[3]f32,rotation:mm.Quat,size:[3]f32,value:decals.Decal) {
    value:=value
    asset.builder_set(s,placed(s,name,position,rotation,size),value)
}

// A yard with markings on its floor, stains, a glowing dial on a wall and
// decals that go over steps and corners.
write_decals_scene :: proc(o:^Out) {
    images:=write_decal_images(o)
    s:asset.Scene_Builder
    feature_scene_begin(&s,o,"decals",.Day,{1,0.93,0.82},2.2,{0.5,0.7,0.45},LAMPLIT)
    slab(&s,o,"Floor",{0,-0.25,0},{24,0.5,24},"Cobblestone")
    slab(&s,o,"Wall north",{0,2,-8},{24,4,0.5},"Bricks")
    slab(&s,o,"Wall east",{8,2,0},{0.5,4,16},"Bricks")
    solid(&s,asset.builder_entity(&s,"Step low",{position={-3,0.15,-4},scale={4,0.3,3}}),"Matte paint")
    solid(&s,asset.builder_entity(&s,"Step high",{position={-3,0.45,-5},scale={4,0.3,1.5}}),"Matte paint")
    solid(&s,asset.builder_entity(&s,"Crate",{position={3.5,0.6,-3},scale={1.2,1.2,1.2}}),"Planks")
    shape(&s,asset.builder_entity(&s,"Ball",{position={5.2,0.7,0.5},scale={1.4,1.4,1.4}}),.Sphere,"Polished metal")
    shape(&s,asset.builder_entity(&s,"Column",{position={-6,1.5,1},scale={0.9,3,0.9}}),.Cylinder,"Satin paint")
    lamp:=render.Point_Light{color={1,0.8,0.55},intensity=candela(LAMPLIT,10),range=12,radius=0.1}
    asset.builder_set(&s,asset.builder_entity(&s,"Lamp",{position={-5,3,-5.5}}),lamp)
    cool:=render.Point_Light{color={0.5,0.75,1},intensity=candela(LAMPLIT,7),range=10,radius=0.1}
    asset.builder_set(&s,asset.builder_entity(&s,"Lamp cool",{position={6,2.5,-6}}),cool)

    flat:=mm.Quat(1)
    on_north:=mm.quat_axis_angle({1,0,0},math.PI/2)   // its axis out of the north wall
    on_east:=mm.quat_axis_angle({0,0,1},math.PI/2)    // its axis out of the east wall
    // Markings on the floor: a lane of arrows towards the steps and warning stripes before them.
    for i in 0..<4 {
        decal(&s,fmt.tprintf("Arrow %d",i+1),{0.6,0,4.2-f32(i)*1.9},flat,{1.1,0.6,1.5},{color={0.95,0.95,0.9,0.9},texture=images[.Arrow],fade=0.4})
    }
    decal(&s,"Stripes",{-3,0.2,-2.2},flat,{4.2,0.9,0.7},{color={1,1,1,0.95},texture=images[.Stripes],fade=0.4})
    // A dial that glows on the wall and another on the floor, which the crate stands on.
    decal(&s,"Dial wall",{1.5,2.1,-7.75},on_north,{2.6,0.6,2.6},{color={0.1,0.25,0.3,0.85},texture=images[.Ring],emission=nits(LAMPLIT,{0.2,2.4,3.2}),fade=0.3})
    decal(&s,"Dial floor",{3.5,0,-3},flat,{3.4,2.4,3.4},{color={0.35,0.1,0.02,0.9},texture=images[.Ring],emission=nits(LAMPLIT,{3.0,1.1,0.15}),fade=0.25,order=1})
    // Stains: one that runs down the steps, one over the ball and the floor under it, one on the east wall.
    decal(&s,"Stain steps",{-3.4,0.3,-4.3},flat,{2.6,1.4,3.2},{color={0.32,0.02,0.02,0.92},texture=images[.Splat],fade=0.2})
    decal(&s,"Stain ball",{5.7,0.6,0.9},flat,{2.4,2.2,2.4},{color={0.05,0.3,0.08,0.9},texture=images[.Splat],fade=0.5})
    decal(&s,"Stain wall",{7.75,1.6,2},on_east,{2.2,0.6,2.2},{color={0.02,0.05,0.25,0.9},texture=images[.Splat],fade=0.3})
    // A plain decal, without an image: a band of paint around the column.
    decal(&s,"Band",{-6,1.2,1},flat,{1.2,0.35,1.2},{color={0.9,0.15,0.1,0.85}})
    // Two decals over each other: the higher order is on top.
    decal(&s,"Under",{-0.8,0,-0.6},mm.quat_axis_angle({0,1,0},0.5),{2,0.5,2},{color={0.1,0.2,0.6,0.9},texture=images[.Splat],fade=0.4})
    decal(&s,"Over",{-0.5,0,-0.3},mm.quat_axis_angle({0,1,0},-0.4),{1.3,0.5,1.3},{color={1,0.85,0.1,1},texture=images[.Arrow],fade=0.4,order=2})
    spawn_point(&s,{0,0,7})
    feature_scene_end(&s,o,"decals")
}

write_feature_scenes :: proc(o:^Out) {
    meshes:=write_feature_meshes(o)
    if !o.content.failed {write_decals_scene(o)}
    if !o.content.failed {write_deform_scene(o,meshes)}
    if !o.content.failed {write_monitors_scene(o,meshes)}
    if !o.content.failed {write_portals_scene(o,meshes)}
    if !o.content.failed {write_portal_lab_scene(o)}
    if !o.content.failed {write_church_scene(o,meshes,"church",false)}
    if !o.content.failed {write_church_scene(o,meshes,"church_fog",true)}
}
