package geom

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private) Shape :: enum {Cube,Sphere,Icosphere,Cylinder,Cone,Prism,Pyramid,Capsule,Torus}

@(private) shape_build :: proc(out:^Mesh_Buffer,shape:Shape) {
    switch shape {
    case .Cube: cube_build(out)
    case .Sphere: sphere_build(out)
    case .Icosphere: icosphere_build(out)
    case .Cylinder: cylinder_build(out)
    case .Cone: cone_build(out)
    case .Prism: prism_build(out)
    case .Pyramid: pyramid_build(out)
    case .Capsule: capsule_build(out)
    case .Torus: torus_build(out)
    }
}

@(test)
primitives_are_closed_and_face_outwards :: proc(t:^testing.T) {
    b:Mesh_Buffer
    mesh_buffer_init(&b)
    defer mesh_buffer_destroy(&b)
    pi:=f32(math.PI)
    volumes:=[Shape]f32{
        .Cube=1,.Sphere=pi/6,.Icosphere=pi/6,.Cylinder=pi/4,.Cone=pi/12,.Prism=0.5,.Pyramid=1.0/3,
        .Capsule=pi*0.0625*0.5+pi/6*0.125,.Torus=2*pi*pi*0.375*0.125*0.125,
    }
    for shape in Shape {
        mesh_buffer_clear(&b)
        shape_build(&b,shape)
        mesh:=mesh_buffer_view(&b)
        testing.expectf(t,mesh_is_valid(mesh) && len(b.normals)==len(b.positions) && len(b.uvs)==len(b.positions),"%v: streams",shape)
        topology:=mesh_topology(mesh.positions,mesh.indices)
        testing.expectf(t,mesh_topology_is_closed(topology),"%v is not closed: %v",shape,topology)
        lo,hi:=mesh_bounds(mesh.positions)
        for k in 0..<3 {
            flat:=shape==.Torus && k==1
            limit:=f32(0.125) if flat else 0.25 if shape==.Capsule && k!=1 else 0.5
            slack:=f32(0.06) if shape==.Icosphere else 1e-6
            testing.expectf(t,lo[k]>=-limit-1e-6 && lo[k]<=-limit+slack && hi[k]<=limit+1e-6 && hi[k]>=limit-slack,"%v: bounds %v %v",shape,lo,hi)
        }
        volume:=mesh_volume(mesh.positions,mesh.indices)
        testing.expectf(t,volume<=volumes[shape]*1.0001 && volume>volumes[shape]*0.95,"%v: volume %v, exact %v",shape,volume,volumes[shape])
        for i:=0;i<len(mesh.indices);i+=3 {
            a,b,c:=mesh.indices[i],mesh.indices[i+1],mesh.indices[i+2]
            n:=linalg.cross(mesh.positions[b]-mesh.positions[a],mesh.positions[c]-mesh.positions[a])
            testing.expectf(t,linalg.length(n)>0,"%v: triangle %d has no area",shape,i/3)
            for v in ([3]u32{a,b,c}) {
                testing.expectf(t,abs(linalg.length(mesh.normals[v])-1)<1e-5,"%v: normal %v",shape,mesh.normals[v])
                testing.expectf(t,linalg.dot(mesh.normals[v],n)>0,"%v: triangle %d faces away from its normals",shape,i/3)
            }
            // No triangle wraps around the texture.
            u:=[3]f32{mesh.uvs[a].x,mesh.uvs[b].x,mesh.uvs[c].x}
            round:=shape==.Sphere || shape==.Icosphere || shape==.Capsule || shape==.Torus
            testing.expectf(t,!round || max(u[0],u[1],u[2])-min(u[0],u[1],u[2])<=0.5+1e-6,"%v: triangle %d spans %v in u",shape,i/3,u)
        }
        if shape!=.Icosphere && shape!=.Prism && shape!=.Pyramid {
            for uv in mesh.uvs {testing.expectf(t,uv.x>=-1e-6 && uv.x<=1+1e-6 && uv.y>=-1e-6 && uv.y<=1+1e-6,"%v: uv %v",shape,uv)}
        }
    }
}

@(test)
primitives_keep_the_layout_of_the_legacy_shapes :: proc(t:^testing.T) {
    b:Mesh_Buffer
    mesh_buffer_init(&b)
    defer mesh_buffer_destroy(&b)
    counts:=[?]struct {shape:Shape,vertices,indices:int}{
        {.Cube,24,36},{.Sphere,17*33,(16*32*2-2*32)*3},{.Cylinder,33*4,32*12},{.Cone,32*4+1,32*6},{.Prism,18,24},{.Pyramid,16,18},
    }
    for c in counts {
        mesh_buffer_clear(&b)
        shape_build(&b,c.shape)
        testing.expectf(t,len(b.positions)==c.vertices && len(b.indices)==c.indices,"%v: %d vertices, %d indices",c.shape,len(b.positions),len(b.indices))
    }
    // Cube: the first face is +X with the world's up at the top of the image;
    // +Y shows the image with -Z at the top.
    mesh_buffer_clear(&b)
    cube_build(&b)
    for i in 0..<24 {
        p,n,uv:=b.positions[i],b.normals[i],b.uvs[i]
        switch i/4 {
        case 0:
            testing.expect_value(t,n,Vec3{1,0,0})
            testing.expect_value(t,uv,Vec2{0.5-p.z,0.5-p.y})
        case 2:
            testing.expect_value(t,n,Vec3{0,1,0})
            testing.expect_value(t,uv,Vec2{p.x+0.5,0.5+p.z})
        case 3:
            testing.expect_value(t,n,Vec3{0,-1,0})
            testing.expect_value(t,uv,Vec2{p.x+0.5,0.5-p.z})
        case 4:
            testing.expect_value(t,n,Vec3{0,0,1})
            testing.expect_value(t,uv,Vec2{p.x+0.5,0.5-p.y})
        }
    }
    // Sphere: rows from the north pole, columns from +X towards +Z, u backwards.
    mesh_buffer_clear(&b)
    sphere_build(&b)
    testing.expect_value(t,b.positions[0],Vec3{0,0.5,0})
    testing.expect_value(t,b.uvs[0],Vec2{1,0})
    testing.expect_value(t,b.positions[8*33],Vec3{0.5,0,0})
    testing.expect_value(t,b.uvs[8*33],Vec2{1,0.5})
    testing.expect_value(t,b.positions[8*33+8],Vec3{0,0,0.5})
    testing.expect_value(t,b.uvs[8*33+8],Vec2{0.75,0.5})
    testing.expect_value(t,b.positions[8*33+32],Vec3{0.5,0,0})
    testing.expect_value(t,b.uvs[8*33+32],Vec2{0,0.5})
    testing.expect_value(t,b.positions[16*33+5],Vec3{0,-0.5,0})
    // Cylinder: bottom and top vertex per column, then the discs.
    mesh_buffer_clear(&b)
    cylinder_build(&b)
    testing.expect_value(t,b.positions[0],Vec3{0.5,-0.5,0})
    testing.expect_value(t,b.uvs[0],Vec2{1,1})
    testing.expect_value(t,b.positions[1],Vec3{0.5,0.5,0})
    testing.expect_value(t,b.uvs[1],Vec2{1,0})
    testing.expect_value(t,b.normals[16],Vec3{0,0,1})
    testing.expect_value(t,b.positions[66],Vec3{0,0.5,0})
    testing.expect_value(t,b.uvs[66],Vec2{0.5,0.5})
    testing.expect_value(t,b.uvs[67],Vec2{1,0.5})
    testing.expect_value(t,b.normals[99],Vec3{0,-1,0})
    // Cone: the apex of every side triangle, and normals that lean up by the slope.
    mesh_buffer_clear(&b)
    cone_build(&b)
    testing.expect_value(t,b.positions[2],Vec3{0,0.5,0})
    testing.expect_value(t,b.uvs[2],Vec2{1-1.0/64,0})
    testing.expectf(t,abs(b.normals[0].y-0.4472136)<1e-6 && abs(b.normals[0].x-0.8944272)<1e-6,"cone normal %v",b.normals[0])
    // Prism: the triangle faces +Z with its edge on top. Pyramid: floor first.
    mesh_buffer_clear(&b)
    prism_build(&b)
    testing.expect_value(t,b.positions[2],Vec3{0,0.5,0.5})
    testing.expect_value(t,b.normals[0],Vec3{0,0,1})
    testing.expect_value(t,b.uvs[2],Vec2{0.5,0})
    mesh_buffer_clear(&b)
    pyramid_build(&b)
    testing.expect_value(t,b.normals[0],Vec3{0,-1,0})
    testing.expect_value(t,b.positions[6],Vec3{0,0.5,0})
}

@(test)
primitives_take_sizes_and_append :: proc(t:^testing.T) {
    b:Mesh_Buffer
    mesh_buffer_init(&b)
    defer mesh_buffer_destroy(&b)
    cube_build(&b,{2,4,6})
    lo,hi:=mesh_bounds(b.positions[:])
    testing.expect_value(t,lo,Vec3{-1,-2,-3})
    testing.expect_value(t,hi,Vec3{1,2,3})
    testing.expect_value(t,buffer_volume(&b),48)
    first:=len(b.positions)
    cylinder_build(&b,2,10,12)
    testing.expect(t,mesh_is_valid(mesh_buffer_view(&b)))
    for i in b.indices[36:] {testing.expect(t,int(i)>=first)}
    lo,hi=mesh_bounds(b.positions[first:])
    testing.expectf(t,abs(lo.y+5)<1e-6 && abs(hi.y-5)<1e-6 && abs(hi.x-2)<1e-6,"cylinder bounds %v %v",lo,hi)

    mesh_buffer_clear(&b)
    pyramid_build(&b,{2,1,4})
    testing.expectf(t,abs(buffer_volume(&b)-8.0/3)<1e-5,"pyramid volume %v",buffer_volume(&b))
    for i:=0;i<len(b.indices);i+=3 {
        a,p,c:=b.positions[b.indices[i]],b.positions[b.indices[i+1]],b.positions[b.indices[i+2]]
        n:=linalg.normalize(linalg.cross(p-a,c-a))
        testing.expectf(t,linalg.length(n-b.normals[b.indices[i]])<1e-5,"scaled face normal %v, expected %v",b.normals[b.indices[i]],n)
    }

    mesh_buffer_clear(&b)
    capsule_build(&b,0.5,1)
    testing.expect(t,mesh_is_closed(b.positions[:],b.indices[:]))
    testing.expectf(t,abs(buffer_volume(&b)-math.PI/6)<0.02,"capsule without a straight part: volume %v",buffer_volume(&b))
    mesh_buffer_clear(&b)
    capsule_build(&b,1,6,16,4)
    lo,hi=mesh_bounds(b.positions[:])
    testing.expectf(t,abs(lo.y+3)<1e-6 && abs(hi.y-3)<1e-6 && abs(hi.x-1)<1e-6,"capsule bounds %v %v",lo,hi)

    mesh_buffer_clear(&b)
    plane_build(&b,{4,2},4,2)
    testing.expect_value(t,len(b.positions),15)
    testing.expect_value(t,len(b.indices),48)
    testing.expect_value(t,mesh_topology(b.positions[:],b.indices[:]).boundary_edges,12)
    testing.expect_value(t,mesh_area(b.positions[:],b.indices[:]),8)
    testing.expect_value(t,b.positions[0],Vec3{-2,0,-1})
    testing.expect_value(t,b.uvs[14],Vec2{1,1})
    for i:=0;i<len(b.indices);i+=3 {
        a,p,c:=b.positions[b.indices[i]],b.positions[b.indices[i+1]],b.positions[b.indices[i+2]]
        testing.expect(t,linalg.cross(p-a,c-a).y>0)
    }

    for level in 0..<4 {
        mesh_buffer_clear(&b)
        icosphere_build(&b,3,level)
        triangles:=20
        for _ in 0..<level {triangles*=4}
        testing.expect_value(t,len(b.indices)/3,triangles)
        testing.expect(t,mesh_is_closed(b.positions[:],b.indices[:]))
        for p in b.positions {testing.expectf(t,abs(linalg.length(p)-3)<1e-5,"icosphere radius %v",linalg.length(p))}
    }

    mesh_buffer_clear(&b)
    torus_build(&b,2,0.5,24,12)
    welded:Mesh_Buffer
    mesh_buffer_init(&welded)
    defer mesh_buffer_destroy(&welded)
    mesh_weld(mesh_buffer_view(&b),0,&welded)
    // A torus has genus one: V - E + F = 0.
    testing.expect_value(t,len(welded.positions)-len(welded.indices)/2+len(welded.indices)/3,0)
}
