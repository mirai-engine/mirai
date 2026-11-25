package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import "mirai:std/geom"
import mm "mirai:std/math"

// The meshes of the scenes of the deformable meshes, the monitors and the
// portals, fine enough for a deformer to bend them.

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
mesh_write :: proc(o:^Out,name:string,m:^Feature_Mesh) {
    id:=asset.content_id(PROJECT,"mesh",name)
    folder:="blockout"
    switch name {case "blob","flag","hose","membrane","post","reed": folder="deform"}
    file:=fmt.tprintf("assets/%s/%s.mesh",folder,name)
    if !asset.mesh_tangents(&m.vertices,m.indices[:]) {asset.content_check(&o.content,file,.Out_Of_Memory);return}
    mesh_write_built(o,file,file,{id=id},{vertices=m.vertices[:],flags={.Has_Colors}},m.indices[:])
}

write_feature_meshes :: proc(o:^Out) {
    os.make_directory_all(path(o,"assets/blockout"))
    os.make_directory_all(path(o,"assets/deform"))
    scratch:=context.temp_allocator
    white:=rgb(1,1,1)
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_sheet(&m,{2.4,1.4},40,22,white)
        mesh_write(o,"flag",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_stalk(&m,{0,0,0},0.035,0.01,1.5,6,14,rgb(0.32,0.62,0.2))
        mesh_write(o,"reed",&m)
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
        mesh_write(o,"tree",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_post(&m,0.28,3.2,40,white)
        mesh_write(o,"post",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        sheet:geom.Mesh_Buffer
        geom.mesh_buffer_init(&sheet,scratch)
        geom.plane_build(&sheet,{5,5},80,80)
        mesh_built(&m,&sheet,{0,0,0},white)
        mesh_write(o,"membrane",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        ball:geom.Mesh_Buffer
        geom.mesh_buffer_init(&ball,scratch)
        geom.sphere_build(&ball,0.6,56,28)
        mesh_built(&m,&ball,{0,0,0},white)
        mesh_write(o,"blob",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_column(&m,16,192,0.13,white)
        mesh_write(o,"column",&m)
    }
    {
        m:=Feature_Mesh{make([dynamic]asset.Vertex,scratch),make([dynamic]u32,scratch)}
        mesh_stalk(&m,{0,0,0},0.13,0.13,3.4,24,96,white)
        mesh_write(o,"hose",&m)
    }
}

