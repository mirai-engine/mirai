package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import deform "plugins:deform/runtime"
import monitors "plugins:monitors/runtime"
import portals "plugins:portals/runtime"

// The scenes of the deformable meshes, the monitors and the portals, and the
// meshes they use: fine enough for a deformer to bend them.

@(private)
Feature_Mesh :: struct {
    vertices:[dynamic]asset.Vertex,
    indices:[dynamic]u32,
}

@(private)
rgb :: proc "contextless" (r,g,b:f32) -> u32 {
    return u32(clamp(r,0,1)*255+0.5)|u32(clamp(g,0,1)*255+0.5)<<8|u32(clamp(b,0,1)*255+0.5)<<16|0xff000000
}

@(private)
mesh_point :: proc(m:^Feature_Mesh,position,normal:[3]f32,uv:[2]f32,color:u32) -> u32 {
    append(&m.vertices,asset.Vertex{position=position,normal=mm.normal_pack(linalg.normalize(normal)),uv=uv,uv1=uv,color=color})
    return u32(len(m.vertices)-1)
}

// A sheet in the XY plane with both its faces, from x 0, centered in y.
@(private)
mesh_sheet :: proc(m:^Feature_Mesh,size:[2]f32,columns,rows:int,color:u32) {
    for face in 0..<2 {
        first:=u32(len(m.vertices))
        for r in 0..=rows {
            for c in 0..=columns {
                u,v:=f32(c)/f32(columns),f32(r)/f32(rows)
                mesh_point(m,{u*size.x,(0.5-v)*size.y,0},{0,0,face==0?1:-1},{u,v},color)
            }
        }
        stride:=u32(columns+1)
        for r in 0..<u32(rows) {
            for c in 0..<u32(columns) {
                a:=first+r*stride+c
                b:=a+stride
                if face==0 {append(&m.indices,a,b,b+1,a,b+1,a+1)} else {append(&m.indices,a,b+1,b,a,a+1,b+1)}
            }
        }
    }
}

// A tube along +Y that narrows to its top, in rings a deformer can bend, closed at the top.
@(private)
mesh_stalk :: proc(m:^Feature_Mesh,base:[3]f32,radius_low,radius_high,height:f32,around,rings:int,color:u32) {
    first:=u32(len(m.vertices))
    for ring in 0..=rings {
        v:=f32(ring)/f32(rings)
        radius:=radius_low+(radius_high-radius_low)*v
        for step in 0..=around {
            angle:=2*math.PI*f32(step)/f32(around)
            out:=[3]f32{math.cos(angle),0,math.sin(angle)}
            mesh_point(m,base+out*radius+[3]f32{0,v*height,0},out+[3]f32{0,(radius_low-radius_high)/height,0},{f32(step)/f32(around),1-v},color)
        }
    }
    stride:=u32(around+1)
    for ring in 0..<u32(rings) {
        for step in 0..<u32(around) {
            a:=first+ring*stride+step
            b:=a+stride
            append(&m.indices,a,b,b+1,a,b+1,a+1)
        }
    }
    top:=mesh_point(m,base+[3]f32{0,height,0},{0,1,0},{0.5,0},color)
    for step in 0..<u32(around) {
        a:=first+u32(rings)*stride+step
        append(&m.indices,a,top,a+1)
    }
}

// A column of square section along +Y, in rings a deformer can twist.
@(private)
mesh_post :: proc(m:^Feature_Mesh,half,height:f32,rings:int,color:u32) {
    sides:=[4][3]f32{{1,0,0},{0,0,-1},{-1,0,0},{0,0,1}}
    for normal,side in sides {
        across:=linalg.cross([3]f32{0,1,0},normal)
        first:=u32(len(m.vertices))
        for ring in 0..=rings {
            v:=f32(ring)/f32(rings)
            for edge in 0..<2 {
                mesh_point(m,normal*half+across*(edge==0?-half:half)+[3]f32{0,v*height,0},normal,{(f32(side)+f32(edge))/4,(1-v)*height/(8*half)},color)
            }
        }
        for ring in 0..<u32(rings) {
            a:=first+ring*2
            append(&m.indices,a,a+3,a+2,a,a+1,a+3)
        }
    }
    for cap in 0..<2 {
        y:=cap==0?f32(0):height
        normal:=[3]f32{0,cap==0?-1:1,0}
        a:=mesh_point(m,{-half,y,-half},normal,{0,0},color)
        mesh_point(m,{half,y,-half},normal,{1,0},color)
        mesh_point(m,{half,y,half},normal,{1,1},color)
        mesh_point(m,{-half,y,half},normal,{0,1},color)
        if cap==0 {append(&m.indices,a,a+1,a+2,a,a+2,a+3)} else {append(&m.indices,a,a+2,a+1,a,a+3,a+2)}
    }
}

// What a builder of std/geom makes, placed.
// A box around the origin whose faces have a unit of UV every `tile` metres, whatever its size.
@(private)
mesh_slab :: proc(m:^Feature_Mesh,size:[3]f32,tile:[2]f32,color:u32) {
    faces:=[6][3][3]f32{
        {{0,0,1},{1,0,0},{0,1,0}},{{0,0,-1},{-1,0,0},{0,1,0}},
        {{1,0,0},{0,0,-1},{0,1,0}},{{-1,0,0},{0,0,1},{0,1,0}},
        {{0,1,0},{1,0,0},{0,0,-1}},{{0,-1,0},{1,0,0},{0,0,1}},
    }
    for face in faces {
        normal,across,up:=face[0],face[1],face[2]
        width,height:=abs(linalg.dot(across,size)),abs(linalg.dot(up,size))
        center:=normal*abs(linalg.dot(normal,size))*0.5
        first:=u32(len(m.vertices))
        for corner in ([4][2]f32{{-0.5,-0.5},{0.5,-0.5},{0.5,0.5},{-0.5,0.5}}) {
            mesh_point(m,center+across*corner.x*width+up*corner.y*height,normal,{(corner.x+0.5)*width/tile.x,(0.5-corner.y)*height/tile.y},color)
        }
        append(&m.indices,first,first+1,first+2,first,first+2,first+3)
    }
}

// The shaft of a column a unit wide and a unit tall around the origin, with flutes down its side.
@(private)
mesh_column :: proc(m:^Feature_Mesh,flutes,around:int,depth:f32,color:u32) {
    first:=u32(len(m.vertices))
    for end in 0..<2 {
        for step in 0..=around {
            angle:=2*math.PI*f32(step)/f32(around)
            wave:=0.5+0.5*math.cos(f32(flutes)*angle)
            radius:=0.5*(1-depth*wave*wave)
            slope:=0.5*depth*wave*f32(flutes)*math.sin(f32(flutes)*angle)
            out,along:=[3]f32{math.cos(angle),0,math.sin(angle)},[3]f32{-math.sin(angle),0,math.cos(angle)}
            mesh_point(m,out*radius+[3]f32{0,f32(end)-0.5,0},out*radius-along*slope,{f32(step)/f32(around)*3,1-f32(end)},color)
        }
    }
    stride:=u32(around+1)
    for step in 0..<u32(around) {
        a:=first+step
        b:=a+stride
        append(&m.indices,a,b,b+1,a,b+1,a+1)
    }
    for end in 0..<2 {
        center:=mesh_point(m,{0,f32(end)-0.5,0},{0,end==0?-1:1,0},{0.5,0.5},color)
        rim:=u32(len(m.vertices))
        for step in 0..=around {
            angle:=2*math.PI*f32(step)/f32(around)
            wave:=0.5+0.5*math.cos(f32(flutes)*angle)
            radius:=0.5*(1-depth*wave*wave)
            mesh_point(m,{math.cos(angle)*radius,f32(end)-0.5,math.sin(angle)*radius},{0,end==0?-1:1,0},{0.5+0.5*math.cos(angle),0.5+0.5*math.sin(angle)},color)
        }
        for step in 0..<u32(around) {
            if end==0 {append(&m.indices,center,rim+step,rim+step+1)} else {append(&m.indices,center,rim+step+1,rim+step)}
        }
    }
}

@(private)
mesh_built :: proc(m:^Feature_Mesh,built:^geom.Mesh_Buffer,offset:[3]f32,color:u32) {
    first:=u32(len(m.vertices))
    for position,i in built.positions {mesh_point(m,position+offset,built.normals[i],built.uvs[i],color)}
    for index in built.indices {append(&m.indices,first+index)}
}

@(private)
mesh_write :: proc(o:^Out,name:string,m:^Feature_Mesh) -> base.Asset_Id {
    id:=id_of("mesh",name)
    folder:="blockout"
    switch name {case "blob","flag","hose","membrane","post","reed": folder="deform"}
    file:=fmt.tprintf("assets/%s/%s.mesh",folder,name)
    if !asset.mesh_tangents(&m.vertices,m.indices[:]) {check(o,file,.Out_Of_Memory);return id}
    mesh_write_built(o,file,file,{id=id},{vertices=m.vertices[:],flags={.Has_Colors}},m.indices[:])
    return id
}

@(private)
Feature_Meshes :: struct {flag,reed,tree,post,membrane,blob,column,hose:base.Asset_Id}

@(private)
write_feature_meshes :: proc(o:^Out) -> (meshes:Feature_Meshes) {
    os.make_directory_all(path(o,"assets/blockout"))
    os.make_directory_all(path(o,"assets/deform"))
    scratch:=context.temp_allocator
    white:=rgb(1,1,1)
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_sheet(&m,{2.4,1.4},40,22,white)
        meshes.flag=mesh_write(o,"flag",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_stalk(&m,{0,0,0},0.035,0.01,1.5,6,14,rgb(0.32,0.62,0.2))
        meshes.reed=mesh_write(o,"reed",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_stalk(&m,{0,0,0},0.17,0.08,3.3,12,18,rgb(0.42,0.28,0.17))
        crown:geom.Mesh_Buffer
        geom.mesh_buffer_init(&crown,scratch)
        geom.sphere_build(&crown,1.15,24,14)
        mesh_built(&m,&crown,{0,3.8,0},rgb(0.2,0.5,0.18))
        small:geom.Mesh_Buffer
        geom.mesh_buffer_init(&small,scratch)
        geom.sphere_build(&small,0.75,20,12)
        mesh_built(&m,&small,{0.85,3.2,0.3},rgb(0.24,0.56,0.2))
        mesh_built(&m,&small,{-0.7,3.35,-0.45},rgb(0.17,0.45,0.16))
        meshes.tree=mesh_write(o,"tree",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_post(&m,0.28,3.2,40,white)
        meshes.post=mesh_write(o,"post",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        sheet:geom.Mesh_Buffer
        geom.mesh_buffer_init(&sheet,scratch)
        geom.plane_build(&sheet,{5,5},80,80)
        mesh_built(&m,&sheet,{0,0,0},white)
        meshes.membrane=mesh_write(o,"membrane",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        ball:geom.Mesh_Buffer
        geom.mesh_buffer_init(&ball,scratch)
        geom.sphere_build(&ball,0.6,56,28)
        mesh_built(&m,&ball,{0,0,0},white)
        meshes.blob=mesh_write(o,"blob",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_column(&m,16,192,0.13,white)
        meshes.column=mesh_write(o,"column",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_stalk(&m,{0,0,0},0.13,0.13,3.4,24,96,white)
        meshes.hose=mesh_write(o,"hose",&m)
    }
    return
}

// The folder under assets/ of a material by its name; "" for none known.
@(private)
material_folder :: proc(name:string) -> string {
    switch name {
    case "Bricks":                                                                       return "surfaces/bricks"
    case "Cobblestone":                                                                  return "surfaces/cobblestone"
    case "Glass","Stained glass":                                                        return "surfaces/glass"
    case "Marble":                                                                       return "surfaces/marble"
    case "Brushed steel","Cast metal","Chrome","Grate","Polished metal","Rough metal","Satin metal": return "surfaces/metal"
    case "Neon sign":                                                                    return "surfaces/neon"
    case "Glazed","Lacquer","Matte paint","Satin paint":                                 return "surfaces/paint"
    case "Tiles":                                                                        return "surfaces/tiles"
    case "Pool water":                                                                   return "surfaces/water"
    case "Decking","Planks":                                                             return "surfaces/wood"
    case "Stained glass window":                                                         return "church"
    case "Dig grass","Dig ore","Dig soil":                                               return "dig"
    case "Leaves":                                                                       return "gallery"
    case "Ocean":                                                                        return "ocean"
    }
    return ""
}

// The metres a unit of UV has to cover for a material to show its image at
// its true size: the metres of the image, by how many times the material
// repeats it in a unit.
@(private)
tile_of :: proc(o:^Out,material:string) -> [2]f32 {
    metres:=f32(2)
    switch material {
    case "Bricks":           metres=1
    case "Planks","Decking": metres=1.6
    }
    file:asset.Asset
    folder:=material_folder(material)
    if folder=="" {
        fmt.eprintfln("demo_content: the material %s has no folder",material)
        o.failed=true
        return {metres,metres}
    }
    if asset.asset_load(&file,path(o,fmt.tprintf("assets/%s/%s.mat",folder,material)),context.temp_allocator)!=.None {return {metres,metres}}
    view,error:=asset.material_view(&file,&o.types)
    if error!=.None || view.info.uv_scale.x<=0 || view.info.uv_scale.y<=0 {return {metres,metres}}
    return metres*view.info.uv_scale
}

// A box that shows its material at its true size on every face, that the
// player stands on and walks into. Its mesh is one for its size.
@(private)
slab :: proc(s:^Scene_Out,o:^Out,name:string,position,size:[3]f32,material:string,parent:base.Entity_Id=0) -> base.Entity_Id {
    tile:=tile_of(o,material)
    file:=fmt.tprintf("slab_%dx%dx%d_%dx%d",int(size.x*100+0.5),int(size.y*100+0.5),int(size.z*100+0.5),int(tile.x*100+0.5),int(tile.y*100+0.5))
    mesh,written:=o.slabs[file]
    if !written {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,context.temp_allocator),make([dynamic]u32,context.temp_allocator)}
        mesh_slab(&m,size,tile,rgb(1,1,1))
        mesh=mesh_write(o,file,&m)
        o.slabs[file]=mesh
    }
    id:=entity(s,name,position,{1,1,1},parent)
    model(s,id,mesh,material)
    collider:=phys.collider_box(size*0.5)
    put(s,id,"Collider",&collider)
    return id
}

STONE :: [3]f32{0.85,0.8,0.71}

// A fluted column of stone on its base, under its capital.
@(private)
column :: proc(s:^Scene_Out,meshes:Feature_Meshes,name:string,position:[3]f32,width,height:f32,parent:base.Entity_Id=0) {
    root:=entity(s,name,position,{1,1,1},parent)
    shaft:=entity(s,"Shaft",{0,height*0.5,0},{width,height-0.7,width},root)
    model(s,shaft,meshes.column,"Satin paint")
    tinted(s,shaft,STONE)
    collider:=phys.collider_box({0.5,0.5,0.5})
    put(s,shaft,"Collider",&collider)
    for y,i in ([4]f32{0.1,0.275,height-0.275,height-0.1}) {
        wide:=width*(i==0 || i==3?1.5:1.25)
        block:=entity(s,i<2?"Base":"Capital",{0,y,0},{wide,i==0 || i==3?0.2:0.15,wide},root)
        cube(s,block,"Satin paint")
        tinted(s,block,STONE)
    }
}

@(private)
model :: proc(s:^Scene_Out,id:base.Entity_Id,mesh:base.Asset_Id,material:string) {
    shown:=render.Mesh_Renderer{mesh=mesh}
    shown.materials[0]=game.material_asset(material)
    put(s,id,"Mesh_Renderer",&shown)
}

@(private)
tinted :: proc(s:^Scene_Out,id:base.Entity_Id,color:[3]f32,emission:[3]f32={}) {
    tint:=render.Tint{color={color.r,color.g,color.b,1},emission=emission}
    put(s,id,"Tint",&tint)
}

@(private)
point_light :: proc(s:^Scene_Out,name:string,position,color:[3]f32,intensity,range:f32,parent:base.Entity_Id=0,radius:f32=0.05) {
    light:=render.Point_Light{color=color,intensity=intensity,range=range,radius=radius}
    put(s,entity(s,name,position,{1,1,1},parent),"Point_Light",&light)
}

// A lamp on a post of a scene its lamps light: its light is as wide as its
// globe, which glows; both in the units of the scene.
@(private)
lamp :: proc(s:^Scene_Out,name:string,position,color:[3]f32,intensity,range:f32) {
    root:=entity(s,name,position)
    shape(s,entity(s,"Post",{0,1.6,0},{0.12,3.2,0.12},root),.Cylinder,"Cast metal")
    globe:=entity(s,"Globe",{0,3.62,0},{0.46,0.46,0.46},root)
    shape(s,globe,.Sphere,"Matte paint")
    tinted(s,globe,color,nits(LAMPLIT,color*6))
    point_light(s,"Light",{0,3.62,0},color,candela(LAMPLIT,intensity),range,root,0.23)
}

// A garden where everything that moves is a mesh deformed on the GPU: flags,
// trees and reeds in the wind, posts that twist, a pool of mercury with rings
// and a blob. Their shadows and their reflections follow them.
write_deform_scene :: proc(o:^Out,meshes:Feature_Meshes) {
    s:Scene_Out
    feature_scene_begin(&s,o,"deform",.Sunset,{1,0.62,0.38},3.2,{0.45,0.75,0.5},LAMPLIT)
    slab(&s,o,"Ground",{0,-0.25,0},{30,0.5,30},"Cobblestone")
    slab(&s,o,"Wall",{-3,1.5,-8.5},{14,3,0.5},"Bricks")
    point_light(&s,"Lamp",{0.5,3.2,-1.5},{1,0.85,0.6},9*LAMP,12)

    up,wind:=[3]f32{0,1,0},[3]f32{1,0,0.3}
    colors:=[3][3]f32{{0.85,0.1,0.08},{0.1,0.3,0.8},{0.95,0.75,0.1}}
    for color,i in colors {
        x:=-7+f32(i)*3.2
        shape(&s,entity(&s,fmt.tprintf("Mast %d",i+1),{x,2.2,-6},{0.09,4.4,0.09}),.Cylinder,"Brushed steel")
        flag:=entity(&s,fmt.tprintf("Flag %d",i+1),{x+0.05,3.6,-6})
        model(&s,flag,meshes.flag,"Satin paint")
        tinted(&s,flag,color)
        wave:=deform.Deform{kind=.Wave,axis={1,0,0},direction={0,0,1},amplitude=0.13,wavelength=1.15,speed=0.9,offset=f32(i)*0.31,pin=0.22}
        put(&s,flag,"Deform",&wave)
    }
    trees:=[3][3]f32{{6,0,-5},{9,0,-0.5},{6.5,0,4}}
    for position,i in trees {
        tree:=placed(&s,fmt.tprintf("Tree %d",i+1),position,mm.quat_axis_angle(up,f32(i)*1.9),{1,1,1}*(0.9+0.15*f32(i)))
        model(&s,tree,meshes.tree,"Matte paint")
        sway:=deform.Deform{kind=.Sway,axis=up,direction=wind,amplitude=0.5,speed=0.2,offset=f32(i)*0.37,pin=0.12}
        put(&s,tree,"Deform",&sway)
    }
    for i in 0..<14 {
        angle:=f32(i)*2.4
        reach:=0.35+0.11*f32(i)
        reed:=entity(&s,fmt.tprintf("Reed %d",i+1),{-7+math.cos(angle)*reach,0,3.5+math.sin(angle)*reach},{1,0.8+0.05*f32(i%5),1})
        model(&s,reed,meshes.reed,"Matte paint")
        sway:=deform.Deform{kind=.Sway,axis=up,direction=wind,amplitude=0.42,speed=0.45,offset=f32(i)*0.173,pin=0.1}
        put(&s,reed,"Deform",&sway)
    }
    materials:=[2]string{"Marble","Bricks"}
    for material,i in materials {
        post:=entity(&s,fmt.tprintf("Post %d",i+1),{-4.6+f32(i)*1.7,0,6.2})
        model(&s,post,meshes.post,material)
        twist:=deform.Deform{kind=.Twist,axis=up,amplitude=2.4,speed=0.11,offset=f32(i)*0.5}
        put(&s,post,"Deform",&twist)
    }
    // The pool: a rim, and a sheet of mercury that reflects what stands around it.
    for side in 0..<4 {
        along:=side<2
        sign:=side%2==0?f32(-1):f32(1)
        slab(&s,o,fmt.tprintf("Rim %d",side+1),along?[3]f32{1.5,0.2,-1+sign*2.65}:[3]f32{1.5+sign*2.65,0.2,-1},along?[3]f32{5.6,0.4,0.3}:[3]f32{0.3,0.4,5.6},"Marble")
    }
    pool:=entity(&s,"Mercury",{1.5,0.24,-1})
    model(&s,pool,meshes.membrane,"Chrome")
    rings:=deform.Deform{kind=.Ripple,axis=up,amplitude=0.06,wavelength=0.95,speed=0.55,pin=0.3}
    put(&s,pool,"Deform",&rings)
    shape(&s,entity(&s,"Pedestal",{-3.8,0.45,0.2},{0.9,0.9,0.9}),.Cylinder,"Marble")
    blob:=entity(&s,"Blob",{-3.8,1.55,0.2})
    model(&s,blob,meshes.blob,"Lacquer")
    tinted(&s,blob,{1,0.42,0.08})
    wobble:=deform.Deform{kind=.Wave,axis=up,direction={1,0,0.4},amplitude=0.07,wavelength=0.55,speed=0.7}
    put(&s,blob,"Deform",&wobble)
    // Two hoses up the wall that swallow: an equation of the demo, shaders/pulse.comp.slang.
    for x,i in ([2]f32{2.2,3.2}) {
        hose:=entity(&s,fmt.tprintf("Hose %d",i+1),{x,0,-7.9})
        model(&s,hose,meshes.hose,"Lacquer")
        tinted(&s,hose,i==0?[3]f32{0.1,0.55,0.3}:[3]f32{0.75,0.2,0.5})
        pulse:=deform.Deform{axis=up,amplitude=0.16,speed=i==0?0.35:-0.25,offset=f32(i)*0.4,pin=0.08,values={0.045,i==0?2:3,0,0}}
        base.text_set(pulse.shape[:],"pulse")
        put(&s,hose,"Deform",&pulse)
    }
    spawn_point(&s,{0,0,9})
    feature_scene_end(&s,o,"deform")
}

// Half a turn about Y: what a Rect_Light, which lights toward its -Z, is
// turned by to light toward the +Z of its parent or of `rotation`; the image
// of a Cube so turned faces that side upright.
@(private)
FACE_BACK :: quaternion(w=0,x=0,y=1,z=0)

// A screen: a pane that shows what a camera sees, in a frame, and lights the
// room with it: a light of area as wide as the pane, colored by its image
// (Light_Emission). The pane shows its brightness; its light is as strong
// next to it as the demo has it, that of a pane pi times as bright.
// The pane is thin: the shadow rays stop 2 cm short of the plane of the light.
@(private)
screen :: proc(s:^Scene_Out,name:string,position:[3]f32,rotation:mm.Quat,size:[2]f32,feed:monitors.Screen) {
    root:=placed(s,name,position,rotation,{1,1,1})
    shape(s,entity(s,"Frame",{0,0,-0.05},{size.x+0.16,size.y+0.16,0.08},root),.Cube,"Cast metal")
    pane:=placed(s,"Pane",{0,0,0},FACE_BACK,{size.x,size.y,0.004},root)
    shape(s,pane,.Cube,"Satin paint")
    shown:=feed
    put(s,pane,"Screen",&shown)
    light:=render.Rect_Light{color={1,1,1},luminance=feed.brightness*math.PI,range=12}
    put(s,pane,"Rect_Light",&light)
    emission:=render.Light_Emission{slot=u8(feed.slot)}
    put(s,pane,"Light_Emission",&emission)
}

// A panel of a scene its lamps light that glows with `glow` times its color
// and lights the side `rotation` turns +Z to, as a light of area of its size:
// as strong as the demo has it next to the panel, that of a panel pi times as
// bright. It is 1 cm thick: the shadow rays, which stop 2 cm short of the
// plane of a rectangle, do not meet it.
@(private)
glowing_panel :: proc(s:^Scene_Out,name:string,position:[3]f32,rotation:mm.Quat,size:[2]f32,color:[3]f32,glow,range:f32,parent:base.Entity_Id=0) {
    id:=placed(s,name,position,rotation*FACE_BACK,{size.x,size.y,0.01},parent)
    cube(s,id,"Matte paint")
    tinted(s,id,{0.02,0.02,0.02},nits(LAMPLIT,color*glow))
    light:=render.Rect_Light{color=color,luminance=lux(LAMPLIT,glow),range=range}
    put(s,id,"Rect_Light",&light)
}

// A camera for screens, and what a screen asks of it.
@(private)
feed :: proc(s:^Scene_Out,name:string,position,target:[3]f32,camera:render.Camera,size:[2]u32,light:bool,interval:u32=0) -> monitors.Screen {
    up:=abs(linalg.normalize(target-position).y)>0.99?[3]f32{0,0,-1}:[3]f32{0,1,0}
    id:=placed(s,name,position,mm.quat_look(target-position,up),{1,1,1})
    camera:=camera
    camera.active=false
    put(s,id,"Camera",&camera)
    return {camera=core.Entity(id),width=size.x,height=size.y,interval=interval,light=light,brightness=nits(LAMPLIT,1.1)}
}

// A control room: two cameras watch a stage and the room from above, and the
// screens of a wall show them. The nearer a screen is seen, the more of its
// image is drawn.
write_monitors_scene :: proc(o:^Out,meshes:Feature_Meshes) {
    s:Scene_Out
    // A dim room at night: a stop and a half under the meter.
    feature_scene_begin(&s,o,"monitors",.Night,{0.55,0.68,1},0.5,{0.3,0.8,0.5},LAMPLIT,-1.5)
    slab(&s,o,"Floor",{0,-0.25,0},{22,0.5,18},"Tiles")
    wall:=entity(&s,"Wall",{0,2.5,-7.2},{22,5,0.4})
    solid(&s,wall,"Matte paint")
    tinted(&s,wall,{0.12,0.13,0.16})
    slab(&s,o,"Wall west",{-11.2,2.5,0},{0.4,5,18},"Bricks")
    point_light(&s,"Room light",{-3,4.2,1},{1,0.9,0.78},8*LAMP,14)
    point_light(&s,"Stage light",{8.2,4.6,4},{0.75,0.85,1},14*LAMP,12)

    // The stage: what the first camera watches moves on its own.
    up:=[3]f32{0,1,0}
    slab(&s,o,"Stage",{6,0.15,1},{5,0.3,5},"Decking")
    post:=entity(&s,"Stage post",{6,0.3,1})
    model(&s,post,meshes.post,"Marble")
    twist:=deform.Deform{kind=.Twist,axis=up,amplitude=2.6,speed=0.16}
    put(&s,post,"Deform",&twist)
    shape(&s,entity(&s,"Stage mast",{4.3,2.1,-0.4},{0.08,3.6,0.08}),.Cylinder,"Brushed steel")
    flag:=entity(&s,"Stage flag",{4.35,3.1,-0.4})
    model(&s,flag,meshes.flag,"Satin paint")
    tinted(&s,flag,{0.9,0.2,0.1})
    wave:=deform.Deform{kind=.Wave,axis={1,0,0},direction={0,0,1},amplitude=0.12,wavelength=1.1,speed=0.9,pin=0.22}
    put(&s,flag,"Deform",&wave)
    blob:=entity(&s,"Stage blob",{7.4,1.1,2})
    model(&s,blob,meshes.blob,"Lacquer")
    tinted(&s,blob,{0.15,0.6,1})
    wobble:=deform.Deform{kind=.Wave,axis=up,direction={1,0,0.4},amplitude=0.07,wavelength=0.55,speed=0.7}
    put(&s,blob,"Deform",&wobble)
    shape(&s,entity(&s,"Stage ball",{5.2,0.75,2.6},{0.9,0.9,0.9}),.Sphere,"Chrome")

    stage:=feed(&s,"Stage camera",{2.4,2.4,5.2},{6,1.5,1},{fov=42*mm.RAD_PER_DEG,near=0.1},{1280,720},false)
    above:=feed(&s,"Overview camera",{0,11,0},{0,0,0},{fov=60*mm.RAD_PER_DEG,near=0.1,projection=.Orthographic,height=19},{1024,1024},true,2)
    face:=mm.Quat(1)
    screen(&s,"Screen stage",{-3.5,2.5,-6.95},face,{5.6,3.15},stage)
    screen(&s,"Screen overview",{2.2,3.2,-6.95},face,{2.2,2.2},above)
    screen(&s,"Screen stage small",{2.2,1.25,-6.95},face,{1.6,0.9},stage)
    // A desk with a small screen, and one far at the end of the room.
    solid(&s,entity(&s,"Desk",{-6,0.45,3},{2.2,0.9,1}),"Planks")
    screen(&s,"Screen desk",{-6,1.35,3},mm.quat_axis_angle(up,0.6),{0.96,0.54},stage)
    screen(&s,"Screen far",{-10.9,2.4,-2},mm.quat_axis_angle(up,math.PI/2),{3.2,1.8},above)
    spawn_point(&s,{0,0,7})
    feature_scene_end(&s,o,"monitors")
}

// A door: two pillars, a lintel and a plate behind, facing +Z, and the portal
// of its opening, in a scene its lamps light.
@(private)
door :: proc(s:^Scene_Out,o:^Out,name:string,position:[3]f32,rotation:mm.Quat) -> base.Entity_Id {
    root:=placed(s,name,position,rotation,{1,1,1})
    slab(s,o,"Pillar left",{-2.05,2.45,0},{0.8,4.9,1.0},"Cast metal",root)
    slab(s,o,"Pillar right",{2.05,2.45,0},{0.8,4.9,1.0},"Cast metal",root)
    slab(s,o,"Lintel",{0,5.15,0},{5.3,1.1,1.2},"Cast metal",root)
    slab(s,o,"Plate",{0,2.45,-0.45},{3.3,4.9,0.1},"Rough metal",root)
    // A strip of light around the opening, on the front of the pillars and of the lintel.
    color:=[3]f32{0.35,0.75,1}
    for x,i in ([2]f32{-1.72,1.72}) {
        strip:=entity(s,i==0?"Strip left":"Strip right",{x,2.3,0.5},{0.08,4.6,0.04},root)
        cube(s,strip,"Matte paint")
        tinted(s,strip,color,nits(LAMPLIT,color*1.8))
    }
    strip:=entity(s,"Strip top",{0,4.66,0.6},{3.52,0.08,0.04},root)
    cube(s,strip,"Matte paint")
    tinted(s,strip,color,nits(LAMPLIT,color*1.8))
    return entity(s,"Portal",{0,2.3,0},{3.3,4.6,1},root)
}

// A wall of bricks with a coping of stone over it.
@(private)
wall :: proc(s:^Scene_Out,o:^Out,name:string,position,size:[3]f32,parent:base.Entity_Id=0) {
    slab(s,o,name,position,size,"Bricks",parent)
    coping:=entity(s,fmt.tprintf("%s coping",name),position+[3]f32{0,size.y*0.5+0.1,0},{size.x+(size.x>size.z?0:0.3),0.2,size.z+(size.x>size.z?0.3:0)},parent)
    cube(s,coping,"Satin paint")
    tinted(s,coping,STONE)
}

// A bench: a seat of planks on two legs.
@(private)
bench :: proc(s:^Scene_Out,o:^Out,name:string,position:[3]f32,rotation:mm.Quat,parent:base.Entity_Id=0) {
    root:=placed(s,name,position,rotation,{1,1,1},parent)
    slab(s,o,"Seat",{0,0.48,0},{2.4,0.1,0.6},"Planks",root)
    for x,i in ([2]f32{-0.95,0.95}) {
        solid(s,entity(s,i==0?"Leg left":"Leg right",{x,0.215,0},{0.12,0.43,0.5},root),"Cast metal")
    }
}

// Two places far from each other, a plaza and a patio, joined by a door in
// each: what is seen through a door is the other place, and who walks into it
// walks out of the other. A screen in the plaza shows the patio from a camera.
write_portals_scene :: proc(o:^Out,meshes:Feature_Meshes) {
    s:Scene_Out
    // A bright plaza: a stop over the meter.
    feature_scene_begin(&s,o,"portals",.Day,{1,0.93,0.82},2.2,{0.8,0.35,0.3},LAMPLIT)
    up:=[3]f32{0,1,0}

    // The plaza: cobbles, two walls of bricks with columns before the north one, lamps and benches.
    plaza:=entity(&s,"Plaza")
    slab(&s,o,"Floor",{0,-0.25,0},{32,0.5,32},"Cobblestone",plaza)
    wall(&s,o,"Wall north",{0,3,-15.6},{32,6,0.8},plaza)
    wall(&s,o,"Wall east",{15.6,3,0},{0.8,6,32},plaza)
    for x,i in ([4]f32{-10,-3.5,3.5,10}) {
        column(&s,meshes,fmt.tprintf("Column %d",i+1),{x,0,-14.3},0.9,6,plaza)
    }
    for corner,i in ([4][2]f32{{-11,-11},{11,-11},{-11,11},{11,11}}) {
        lamp(&s,fmt.tprintf("Plaza lamp %d",i+1),{corner.x,0,corner.y},{1,0.78,0.5},9,11)
    }
    bench(&s,o,"Bench north",{6.8,0,-13.2},1,plaza)
    bench(&s,o,"Bench east",{14,0,5},mm.quat_axis_angle(up,math.PI/2),plaza)
    solid(&s,entity(&s,"Crate",{-6.5,0.6,3.2},{1.2,1.2,1.2},plaza),"Planks")
    solid(&s,placed(&s,"Crate small",{-7.7,0.4,2.5},mm.quat_axis_angle(up,0.5),{0.8,0.8,0.8},plaza),"Planks")
    solid(&s,placed(&s,"Crate top",{-6.4,1.55,3.1},mm.quat_axis_angle(up,0.3),{0.7,0.7,0.7},plaza),"Planks")
    shape(&s,entity(&s,"Ball",{-8.2,0.7,-3.4},{1.4,1.4,1.4},plaza),.Sphere,"Polished metal")
    // A planter with a tree in the wind.
    for side in 0..<4 {
        along:=side<2
        sign:=side%2==0?f32(-1):f32(1)
        slab(&s,o,fmt.tprintf("Planter %d",side+1),along?[3]f32{3,0.3,-4+sign*1.35}:[3]f32{3+sign*1.35,0.3,-4},along?[3]f32{3,0.6,0.3}:[3]f32{0.3,0.6,2.4},"Bricks",plaza)
    }
    soil:=entity(&s,"Soil",{3,0.25,-4},{2.4,0.5,2.4},plaza)
    cube(&s,soil,"Matte paint")
    tinted(&s,soil,{0.16,0.11,0.07})
    tree:=entity(&s,"Tree",{3,0.5,-4},{1.1,1.1,1.1},plaza)
    model(&s,tree,meshes.tree,"Matte paint")
    sway:=deform.Deform{kind=.Sway,axis=up,direction={1,0,0.3},amplitude=0.4,speed=0.2,pin=0.12}
    put(&s,tree,"Deform",&sway)

    // The patio: a floor of marble, a ring of columns around a pool, and a sign on its back wall.
    patio:=entity(&s,"Patio",{200,0,0})
    slab(&s,o,"Floor",{0,-0.25,0},{32,0.5,32},"Marble",patio)
    wall(&s,o,"Wall back",{0,3,15.6},{32,6,0.8},patio)
    wall(&s,o,"Wall west",{-15.6,3,0},{0.8,6,32},patio)
    for i in 0..<8 {
        angle:=(f32(i)+0.5)*math.PI/4
        column(&s,meshes,fmt.tprintf("Column %d",i+1),{math.cos(angle)*10,0,math.sin(angle)*10},0.8,5,patio)
    }
    for side in 0..<4 {
        along:=side<2
        sign:=side%2==0?f32(-1):f32(1)
        rim:=entity(&s,fmt.tprintf("Pool rim %d",side+1),along?[3]f32{0,0.25,sign*3.2}:[3]f32{sign*3.2,0.25,0},along?[3]f32{6.8,0.5,0.4}:[3]f32{0.4,0.5,6},patio)
        solid(&s,rim,"Satin paint")
        tinted(&s,rim,STONE)
    }
    water:=entity(&s,"Pool water",{0,0.32,0},{6,0.1,6},patio)
    cube(&s,water,"Pool water")
    column(&s,meshes,"Pedestal",{0,0,0},1.1,1.5,patio)
    shape(&s,entity(&s,"Chrome ball",{0,2.2,0},{1.4,1.4,1.4},patio),.Sphere,"Chrome")
    cube(&s,entity(&s,"Neon sign",{0,3.6,15.1},{6,1.5,0.15},patio),"Neon sign")
    for corner,i in ([4][2]f32{{-12,-12},{12,-12},{-12,12},{12,12}}) {
        lamp(&s,fmt.tprintf("Patio lamp %d",i+1),{200+corner.x,0,corner.y},{0.45,0.75,1},9,11)
    }
    point_light(&s,"Pool light",{0,5,0},{0.7,0.85,1},30*LAMP,14,patio)

    plaza_portal:=door(&s,o,"Plaza door",{-12,0,0},mm.quat_axis_angle(up,math.PI/2))
    patio_portal:=door(&s,o,"Patio door",{200,0,-12},1)
    to_patio,to_plaza:=portals.Portal{exit=core.Entity(patio_portal)},portals.Portal{exit=core.Entity(plaza_portal)}
    put(&s,plaza_portal,"Portal",&to_patio)
    put(&s,patio_portal,"Portal",&to_plaza)

    camera:=feed(&s,"Patio camera",{211,7,11},{200,1.5,0},{fov=50*mm.RAD_PER_DEG,near=0.1},{1280,720},true)
    screen(&s,"Monitor",{0,3.3,-15.1},1,{4.8,2.7},camera)
    spawn_point(&s,{0,0,9})
    feature_scene_end(&s,o,"portals")
}

// A closed room of concrete, `size` wide, deep and high around `center` at
// floor level, with a ceiling: the light inside is only its own.
@(private)
room :: proc(s:^Scene_Out,o:^Out,center,size:[3]f32,shade:[3]f32,parent:base.Entity_Id=0) {
    slab(s,o,"Floor",center+[3]f32{0,-0.25,0},{size.x,0.5,size.z},"Tiles",parent)
    half:=size*0.5
    walls:=[4]struct{name:string,position,scale:[3]f32}{
        {"Wall north",{0,half.y,-half.z-0.2},{size.x+0.8,size.y,0.4}},
        {"Wall south",{0,half.y,half.z+0.2},{size.x+0.8,size.y,0.4}},
        {"Wall west",{-half.x-0.2,half.y,0},{0.4,size.y,size.z}},
        {"Wall east",{half.x+0.2,half.y,0},{0.4,size.y,size.z}},
    }
    for w in walls {
        wall:=entity(s,w.name,center+w.position,w.scale,parent)
        solid(s,wall,"Matte paint")
        tinted(s,wall,shade)
    }
    ceiling:=entity(s,"Ceiling",center+[3]f32{0,size.y+0.2,0},{size.x+1.6,0.4,size.z+1.6},parent)
    solid(s,ceiling,"Matte paint")
    tinted(s,ceiling,shade*0.5)
}

// A dark laboratory with a gate to a chamber far away that cyan panels light:
// the panels are lights of area, and their light comes into the laboratory
// through the gate onto a white block and a chrome ball. Two displays over a
// console light the laboratory amber and green; a dim lamp, the rest. Who
// walks into the gate walks out in the chamber, and back.
write_portal_lab_scene :: proc(o:^Out) {
    s:Scene_Out
    // A dark laboratory: two stops and a half under the meter.
    feature_scene_begin(&s,o,"portal_lab",.Night,{0.55,0.68,1},0.15,{0.3,0.8,0.5},LAMPLIT,-2.5)
    up:=[3]f32{0,1,0}
    concrete:=[3]f32{0.2,0.22,0.25}

    // The laboratory: 14 by 12 m and 6 high, the gate in its north wall.
    lab:=entity(&s,"Laboratory")
    room(&s,o,{0,0,0},{14,6,12},concrete,lab)
    solid(&s,entity(&s,"Console",{3.6,0.68,-4.9},{4.1,1.36,1.6},lab),"Rough metal")
    solid(&s,entity(&s,"Console top",{3.6,1.4,-4.8},{4.2,0.08,1.9},lab),"Brushed steel")
    for i in 0..<9 {shape(&s,entity(&s,fmt.tprintf("Switch %d",i+1),{2+0.39*f32(i),1.47,-4.2},{0.18,0.03,0.13},lab),.Cube,"Brushed steel")}
    glowing_panel(&s,"Amber display",{2.6,2.6,-5.99},1,{2.15,1.2},{1,0.3,0.03},4,14,lab)
    glowing_panel(&s,"Green display",{5.1,2.6,-5.99},1,{1.7,1.2},{0.02,1,0.3},4,14,lab)
    receiver:=entity(&s,"Receiver block",{-3.9,0.62,-2.6},{1.25,1.24,1.25},lab)
    solid(&s,receiver,"Matte paint")
    tinted(&s,receiver,{0.85,0.87,0.9})
    shape(&s,entity(&s,"Receiver ball",{-3.9,1.6,-2.6},{0.73,0.73,0.73},lab),.Sphere,"Chrome")
    shape(&s,entity(&s,"Vessel",{-5.4,1.2,-1.2},{0.8,2.4,0.8},lab),.Cylinder,"Brushed steel")
    for band in ([3]f32{0.3,1.2,2.1}) {shape(&s,entity(&s,"Vessel band",{-5.4,band,-1.2},{0.87,0.09,0.87},lab),.Cylinder,"Rough metal")}
    solid(&s,placed(&s,"Crate",{1.2,0.44,0.6},mm.quat_axis_angle(up,0.3),{1,0.88,1},lab),"Planks")
    solid(&s,entity(&s,"Equipment case",{4.8,0.75,3},{1.6,1.5,1.6},lab),"Rough metal")
    point_light(&s,"Work lamp",{-3,5.6,3},{1,0.82,0.6},3*LAMP,10,lab,0.08)

    // The chamber, 100 m away: 12 by 9 m, its gate in the south wall, cyan panels on the back wall, the ceiling and the west wall.
    chamber:=entity(&s,"Chamber",{100,0,0})
    room(&s,o,{0,0,0},{12,6,9},concrete,chamber)
    cyan:=[3]f32{0.035,0.63,1}
    glowing_panel(&s,"Back panel",{0,3.2,-4.49},1,{5.2,1.7},cyan,8,20,chamber)
    glowing_panel(&s,"Ceiling panel",{0,5.99,-0.5},mm.quat_axis_angle({1,0,0},math.PI/2),{3.1,1.6},cyan,8,20,chamber)
    glowing_panel(&s,"West panel",{-5.99,2.8,-1.5},mm.quat_axis_angle(up,math.PI/2),{1.4,2.2},cyan,8,18,chamber)
    shape(&s,entity(&s,"Pedestal",{0,0.46,-1},{1.8,0.92,1.8},chamber),.Cylinder,"Rough metal")
    shape(&s,entity(&s,"Ball",{0,1.57,-1},{1.3,1.3,1.3},chamber),.Sphere,"Chrome")
    for i in 0..<4 {
        x:=-3+2*f32(i)
        solid(&s,entity(&s,fmt.tprintf("Cabinet %d",i+1),{x,0.9,-3.9},{1.25,1.8,0.8},chamber),"Rough metal")
        for slit in 0..<5 {shape(&s,entity(&s,"Vent",{x,0.55+0.17*f32(slit),-3.49},{0.8,0.045,0.015},chamber),.Cube,"Brushed steel")}
    }

    lab_gate:=door(&s,o,"Laboratory gate",{-1.7,0,-5.45},1)
    chamber_gate:=door(&s,o,"Chamber gate",{100,0,3.95},mm.quat_axis_angle(up,math.PI))
    to_chamber,to_lab:=portals.Portal{exit=core.Entity(chamber_gate)},portals.Portal{exit=core.Entity(lab_gate)}
    put(&s,lab_gate,"Portal",&to_chamber)
    put(&s,chamber_gate,"Portal",&to_lab)
    spawn_point(&s,{-1,0,4.5})
    feature_scene_end(&s,o,"portal_lab")
}
