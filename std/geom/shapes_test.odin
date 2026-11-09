package geom

import "core:math/linalg"
import "core:testing"

@(private="file")
volume_of :: proc(b:^Mesh_Buffer) -> f32 {
    sum:=f64(0)
    for t:=0;t+2<len(b.indices);t+=3 {
        p0,p1,p2:=b.positions[b.indices[t]],b.positions[b.indices[t+1]],b.positions[b.indices[t+2]]
        sum+=f64(linalg.dot(p0,linalg.cross(p1,p2)))/6
    }
    return f32(sum)
}

// Every triangle faces the same way as the normals of its vertices.
@(private="file")
faces_as_its_normals :: proc(t:^testing.T,b:^Mesh_Buffer,what:string,loc:=#caller_location) {
    for at:=0;at+2<len(b.indices);at+=3 {
        i0,i1,i2:=b.indices[at],b.indices[at+1],b.indices[at+2]
        n:=linalg.cross(b.positions[i1]-b.positions[i0],b.positions[i2]-b.positions[i0])
        if !testing.expectf(t,linalg.dot(n,b.normals[i0]+b.normals[i1]+b.normals[i2])>=0,"%s: triangle %d looks away from its normals",what,at/3,loc=loc) {return}
    }
}

@(test)
the_shapes_of_props_are_closed_and_face_outwards :: proc(t:^testing.T) {
    b:Mesh_Buffer
    mesh_buffer_init(&b,context.temp_allocator)
    bent:=[3]Vec3{{0,0,0},{0.5,3,0.1},{1.5,6,0.4}}
    tube_build(&b,bent[:],{0.4,0.2},7,6)
    testing.expect(t,mesh_is_closed(b.positions[:],b.indices[:]),"tube")
    testing.expect(t,volume_of(&b)>0,"tube")
    faces_as_its_normals(t,&b,"tube")
    testing.expect(t,mesh_is_valid(mesh_buffer_view(&b)),"tube")

    mesh_buffer_clear(&b)
    jar:=[4]Vec2{{0,0},{0.5,0.2},{0.4,1},{0,1.2}}
    lathe_build(&b,jar[:],9)
    testing.expect(t,mesh_is_closed(b.positions[:],b.indices[:]),"lathe to the axis")
    testing.expect(t,volume_of(&b)>0,"lathe to the axis")
    faces_as_its_normals(t,&b,"lathe")

    mesh_buffer_clear(&b)
    post:=[3]Vec2{{0.5,0},{0.4,1},{0.2,1.5}}
    lathe_build(&b,post[:],8)
    testing.expect(t,mesh_is_closed(b.positions[:],b.indices[:]),"lathe with its ends closed by discs")
    testing.expect(t,volume_of(&b)>0,"lathe")

    for flip in ([]bool{false,true}) {
        mesh_buffer_clear(&b)
        arrow:=[?]Vec2{{0,0},{2,0},{2.5,0.5},{2,1},{0,1}}
        if flip {
            for i in 0..<len(arrow)/2 {arrow[i],arrow[len(arrow)-1-i]=arrow[len(arrow)-1-i],arrow[i]}
        }
        extrude_build(&b,arrow[:],0.1)
        testing.expect(t,mesh_is_closed(b.positions[:],b.indices[:]),"extrude")
        testing.expect(t,volume_of(&b)>0,"extrude, whichever way the outline runs")
        faces_as_its_normals(t,&b,"extrude")
    }

    mesh_buffer_clear(&b)
    blob_build(&b,{1,0.6,1},2,0.3,7)
    testing.expect(t,mesh_is_closed(b.positions[:],b.indices[:]),"blob")
    testing.expect(t,volume_of(&b)>0,"blob")
    faces_as_its_normals(t,&b,"blob")
    moved:=false
    for p in b.positions {moved|=abs(linalg.length(p)-1)>0.1 && abs(p.y)<0.1}
    testing.expect(t,moved,"its surface is not a plain sphere")
}

@(test)
a_blade_has_both_faces_and_a_fan_fills_its_turn :: proc(t:^testing.T) {
    b:Mesh_Buffer
    mesh_buffer_init(&b,context.temp_allocator)
    leaf:=Blade{length=4,width=1,rise=1,droop=2,belly=0.3,fold=0.05,segments=5}
    blade_build(&b,{0,5,0},{1,0,0},leaf)
    testing.expect(t,mesh_is_valid(mesh_buffer_view(&b)))
    faces_as_its_normals(t,&b,"blade")
    area:=mesh_area(b.positions[:],b.indices[:])
    testing.expectf(t,area>2.5 && area<8,"both faces of a leaf about 4 by 1: area %v",area)
    tip:=b.positions[len(b.positions)-1]
    testing.expectf(t,abs(tip.x-4)<1e-4 && abs(tip.y-(5+1-2-0.05))<1e-4,"the tip goes along and falls by droop: %v",tip)
    points:=len(b.positions)

    mesh_buffer_clear(&b)
    fan_build(&b,{},8,leaf,1,3)
    testing.expect_value(t,len(b.positions),8*points)
    low,high:=mesh_bounds(b.positions[:])
    testing.expect(t,low.x<-1 && high.x>1 && low.z<-1 && high.z>1,"the blades go around")
    same:Mesh_Buffer
    mesh_buffer_init(&same,context.temp_allocator)
    fan_build(&same,{},8,leaf,1,3)
    testing.expect(t,slices_equal(b.positions[:],same.positions[:]),"a seed makes the same fan")
}

@(private="file")
slices_equal :: proc(a,b:[]Vec3) -> bool {
    if len(a)!=len(b) {return false}
    for v,i in a {if v!=b[i] {return false}}
    return true
}

@(test)
parts_are_painted_placed_and_flattened_in_one_buffer :: proc(t:^testing.T) {
    b:Mesh_Buffer
    mesh_buffer_init(&b,context.temp_allocator)
    bark:=Vec4{0.4,0.2,0.1,1}
    leaf:=Vec4{0.2,0.6,0.1,1}
    cone_build(&b,0.5,1,5)
    trunk:=len(b.positions)
    mesh_buffer_paint(&b,bark)
    testing.expect_value(t,len(b.colors),trunk)
    cube_build(&b,{1,1,1})
    mesh_buffer_place(&b,trunk,{10,0,0},0.25,{2,2,2})
    mesh_buffer_paint(&b,leaf)
    testing.expect(t,mesh_is_valid(mesh_buffer_view(&b)))
    testing.expect_value(t,b.colors[0],bark)
    testing.expect_value(t,b.colors[len(b.colors)-1],leaf)
    low,high:=mesh_bounds(b.positions[trunk:])
    testing.expectf(t,abs(low.x-9)<1e-5 && abs(high.x-11)<1e-5 && abs(low.z+1)<1e-5,"a part moves to its place, scaled and turned: %v %v",low,high)

    triangles:=len(b.indices)/3
    mesh_buffer_flatten(&b)
    testing.expect_value(t,len(b.indices)/3,triangles)
    testing.expect_value(t,len(b.positions),3*triangles)
    testing.expect(t,mesh_is_valid(mesh_buffer_view(&b)))
    testing.expect_value(t,b.colors[0],bark)
    for at:=0;at+2<len(b.indices);at+=3 {
        i0,i1,i2:=b.indices[at],b.indices[at+1],b.indices[at+2]
        n:=linalg.normalize(linalg.cross(b.positions[i1]-b.positions[i0],b.positions[i2]-b.positions[i0]))
        testing.expectf(t,linalg.length(n-b.normals[i0])<1e-4 && b.normals[i0]==b.normals[i2],"triangle %d takes the normal of its face",at/3)
    }
}
