package geom

import "core:math/linalg"
import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"

@(private) fractures_equal :: proc(a,b:^Fracture) -> bool {
    return buffers_equal(&a.mesh,&b.mesh) && bytes_equal(a.pieces[:],b.pieces[:]) && bytes_equal(a.connections[:],b.connections[:])
}

// Every piece is closed, lies in the cell of its site, and the volumes add up.
@(private) expect_fracture :: proc(t:^testing.T,f:^Fracture,mesh:Mesh,sites:[]Vec3,what:string,loc:=#caller_location) {
    total:=mesh_volume(mesh.positions,mesh.indices)
    lo,hi:=mesh_bounds(mesh.positions)
    size:=linalg.length(hi-lo)
    tolerance:=tolerance_noise(positions_max_abs(mesh.positions))
    sum:f32
    previous:=[2]i64{-1,-1}
    vertices,indices:=u32(0),u32(0)
    for piece,i in f.pieces {
        identity:=[2]i64{i64(piece.site),i64(piece.chunk)}
        testing.expectf(t,identity[0]>previous[0] || identity[0]==previous[0] && identity[1]>previous[1],"%s: piece %d is out of order",what,i,loc=loc)
        previous=identity
        testing.expectf(t,piece.first_vertex==vertices && piece.first_index==indices,"%s: piece %d does not follow the previous one",what,i,loc=loc)
        vertices+=piece.vertex_count;indices+=piece.index_count
        part:=fracture_piece_mesh(f,i)
        testing.expectf(t,mesh_is_valid(part),"%s: piece %d has inconsistent streams",what,i,loc=loc)
        topology:=mesh_topology(part.positions,part.indices)
        testing.expectf(t,mesh_topology_is_closed(topology),"%s: piece %d is not closed: %v",what,i,topology,loc=loc)
        volume:=mesh_volume(part.positions,part.indices)
        testing.expectf(t,volume>0 && abs(volume-piece.volume)<=1e-5*abs(total),"%s: piece %d has volume %v, recorded %v",what,i,volume,piece.volume,loc=loc)
        sum+=volume
        own:=sites[piece.site]
        for p in part.positions {
            mine:=linalg.length(p-own)
            for other in sites {
                // Nearer to another site by more than the cut tolerance allows.
                if linalg.length(p-other)<mine-(tolerance*8+1e-5*size) {
                    testing.expectf(t,false,"%s: piece %d has %v nearer to site %v than to its own %v",what,i,p,other,own,loc=loc)
                    return
                }
            }
        }
    }
    testing.expectf(t,int(vertices)==len(f.mesh.positions) && int(indices)==len(f.mesh.indices),"%s: pieces do not cover the buffer",what,loc=loc)
    testing.expectf(t,abs(sum-total)<=2e-4*abs(total),"%s: pieces add up to %v of %v",what,sum,total,loc=loc)
    for c,i in f.connections {
        testing.expectf(t,c.a<c.b && int(c.b)<len(f.pieces) && c.area>0,"%s: connection %v",what,c,loc=loc)
        if i>0 {
            before:=f.connections[i-1]
            testing.expectf(t,before.a<c.a || (before.a==c.a && before.b<c.b),"%s: connections out of order",what,loc=loc)
        }
    }
}

@(test)
sites_follow_their_pattern_and_only_depend_on_the_seed :: proc(t:^testing.T) {
    a,b,c:[256]Vec3
    desc:=Site_Desc{seed=7,lo={-1,0,2},hi={3,1,4}}
    for pattern in Site_Pattern {
        desc.pattern=pattern
        desc.center={1,0.5,3}
        desc.radius=2
        desc.clusters=4
        desc.cluster_radius=0.25
        sites_generate(a[:],desc)
        sites_generate(b[:],desc)
        testing.expectf(t,bytes_equal(a[:],b[:]),"%v: the same seed gives other sites",pattern)
        other:=desc
        other.seed=8
        sites_generate(c[:],other)
        testing.expectf(t,!bytes_equal(a[:],c[:]),"%v: another seed gives the same sites",pattern)
        // A shorter request is a prefix of a longer one.
        sites_generate(c[:100],desc)
        testing.expectf(t,bytes_equal(a[:100],c[:100]),"%v: fewer sites are not a prefix",pattern)
        switch pattern {
        case .Uniform:
            mean:Vec3
            for p in a {
                testing.expect(t,p.x>=-1 && p.x<=3 && p.y>=0 && p.y<=1 && p.z>=2 && p.z<=4)
                mean+=p/256
            }
            testing.expectf(t,linalg.length(mean-Vec3{1,0.5,3})<0.25,"uniform mean %v",mean)
        case .Clustered:
            for p,i in a[4:] {testing.expectf(t,linalg.length(p-a[(i+4)%4])<=0.25+1e-6,"site %d is not near its center",i+4)}
        case .Radial:
            near:=0
            for p in a {
                distance:=linalg.length(p-desc.center)
                testing.expect(t,distance<=2+1e-5)
                if distance<0.5 {near+=1}
            }
            // Half of the sites fall within a quarter of the reach.
            testing.expectf(t,near>100 && near<156,"%d of 256 radial sites are near the center",near)
        }
    }
    sites_generate(nil,desc)
}

@(test)
fracture_with_two_sites_halves_a_box :: proc(t:^testing.T) {
    f:Fracture
    fracture_init(&f)
    defer fracture_destroy(&f)
    box:Mesh_Buffer
    mesh_buffer_init(&box)
    defer mesh_buffer_destroy(&box)
    cube_build(&box,{4,2,2})
    for _ in 0..<12 {append(&box.materials,3)}
    mesh:=mesh_buffer_view(&box)
    sites:=[]Vec3{{1,0,0},{-2,0,0}}
    testing.expect_value(t,mesh_fracture(&f,mesh,sites,{interior_material=7}),Fracture_Error.None)
    expect_fracture(t,&f,mesh,sites,"box")
    testing.expect_value(t,len(f.pieces),2)
    // The plane between the sites is x=-0.5.
    testing.expectf(t,abs(f.pieces[0].volume-10)<1e-4 && abs(f.pieces[1].volume-6)<1e-4,"volumes %v %v",f.pieces[0].volume,f.pieces[1].volume)
    testing.expectf(t,abs(f.pieces[0].center.x-0.75)<1e-4 && abs(f.pieces[1].center.x+1.25)<1e-4,"centers %v %v",f.pieces[0].center,f.pieces[1].center)
    testing.expect_value(t,len(f.connections),1)
    testing.expectf(t,f.connections[0].a==0 && f.connections[0].b==1 && abs(f.connections[0].area-4)<1e-4,"connection %v",f.connections[0])
    for i in 0..<2 {
        part:=fracture_piece_mesh(&f,i)
        testing.expect(t,len(part.normals)==len(part.positions) && len(part.uvs)==len(part.positions))
        interior:f32
        for material,triangle in part.materials {
            testing.expect(t,material==3 || material==7)
            if material!=7 {continue}
            a,b,c:=part.positions[part.indices[triangle*3]],part.positions[part.indices[triangle*3+1]],part.positions[part.indices[triangle*3+2]]
            testing.expect(t,a.x==-0.5 && b.x==-0.5 && c.x==-0.5)
            interior+=0.5*linalg.length(linalg.cross(b-a,c-a))
        }
        testing.expectf(t,abs(interior-4)<1e-4,"interior area %v",interior)
    }
}

@(test)
fracture_of_a_grid_of_sites_connects_neighbours_by_their_faces :: proc(t:^testing.T) {
    f:Fracture
    fracture_init(&f)
    defer fracture_destroy(&f)
    box:Mesh_Buffer
    mesh_buffer_init(&box)
    defer mesh_buffer_destroy(&box)
    cube_build(&box,{2,2,2})
    mesh:=mesh_buffer_view(&box)
    sites:[8]Vec3
    for &s,i in sites {s={f32(i&1)-0.5,f32(i>>1&1)-0.5,f32(i>>2)-0.5}}
    testing.expect_value(t,mesh_fracture(&f,mesh,sites[:]),Fracture_Error.None)
    expect_fracture(t,&f,mesh,sites[:],"grid")
    testing.expect_value(t,len(f.pieces),8)
    for piece in f.pieces {
        testing.expectf(t,abs(piece.volume-1)<1e-4 && linalg.length(piece.center-sites[piece.site])<1e-4,"piece %v",piece)
    }
    // Cells that differ in one axis share a unit face; diagonal ones only touch.
    testing.expect_value(t,len(f.connections),12)
    for c in f.connections {
        different:=c.a~c.b
        testing.expectf(t,(different==1 || different==2 || different==4) && abs(c.area-1)<1e-4,"connection %v",c)
    }
}

@(test)
a_cell_that_crosses_a_ring_twice_gives_a_piece_for_each_part :: proc(t:^testing.T) {
    f:Fracture
    fracture_init(&f)
    defer fracture_destroy(&f)
    ring:Mesh_Buffer
    mesh_buffer_init(&ring)
    defer mesh_buffer_destroy(&ring)
    torus_build(&ring)
    mesh:=mesh_buffer_view(&ring)
    // The middle cell is the slab |z|<0.2, nearer the axis than the tube
    // reaches: it holds the ring where it crosses x at both sides.
    sites:=[]Vec3{{0,0,0},{0,0,0.4},{0,0,-0.4}}
    testing.expect_value(t,mesh_fracture(&f,mesh,sites),Fracture_Error.None)
    expect_fracture(t,&f,mesh,sites,"ring")
    testing.expect_value(t,len(f.pieces),4)
    testing.expect(t,f.pieces[0].site==0 && f.pieces[0].chunk==0 && f.pieces[1].site==0 && f.pieces[1].chunk==1)
    testing.expectf(t,f.pieces[0].center.x*f.pieces[1].center.x<0,"one part at each side: %v %v",f.pieces[0].center,f.pieces[1].center)
    testing.expect(t,f.pieces[2].site==1 && f.pieces[3].site==2 && f.pieces[2].chunk==0 && f.pieces[3].chunk==0)
    // Each part of the slab touches both ends; the ends do not touch each other.
    testing.expect_value(t,len(f.connections),4)
    for c in f.connections {testing.expectf(t,c.a<2 && c.b>=2 && c.area>0,"connection %v",c)}
    // The same sites give the same parts.
    again:Fracture
    fracture_init(&again)
    defer fracture_destroy(&again)
    mesh_fracture(&again,mesh,sites)
    testing.expect(t,fractures_equal(&f,&again))
}

@(test)
fracture_handles_degenerate_sites_and_bad_input :: proc(t:^testing.T) {
    f:Fracture
    fracture_init(&f)
    defer fracture_destroy(&f)
    box:Mesh_Buffer
    mesh_buffer_init(&box)
    defer mesh_buffer_destroy(&box)
    cube_build(&box)
    mesh:=mesh_buffer_view(&box)
    testing.expect_value(t,mesh_fracture(&f,mesh,nil),Fracture_Error.No_Sites)
    broken:=mesh
    broken.indices=[]u32{0,1,500}
    testing.expect_value(t,mesh_fracture(&f,broken,{{0,0,0}}),Fracture_Error.Invalid_Mesh)
    testing.expect_value(t,len(f.pieces),0)

    // One site: the mesh itself.
    testing.expect_value(t,mesh_fracture(&f,mesh,{{9,9,9}}),Fracture_Error.None)
    testing.expect_value(t,len(f.pieces),1)
    testing.expect(t,bytes_equal(f.mesh.positions[:],mesh.positions) && bytes_equal(f.mesh.indices[:],mesh.indices))
    testing.expect_value(t,len(f.connections),0)

    // Repeated sites give one piece, at the first of them; sites whose cell
    // misses the mesh give none.
    sites:=[]Vec3{{0.25,0,0},{-0.25,0,0},{0.25,0,0},{50,0,0},{-0.25,0,0},{0.25,0,0}}
    testing.expect_value(t,mesh_fracture(&f,mesh,sites),Fracture_Error.None)
    expect_fracture(t,&f,mesh,sites,"repeated")
    testing.expect_value(t,len(f.pieces),2)
    testing.expect_value(t,f.pieces[0].site,u32(0))
    testing.expect_value(t,f.pieces[1].site,u32(1))
    testing.expect_value(t,len(f.connections),1)

    // Sites on a line, on a plane, on the corners of the mesh and on its faces.
    line:[9]Vec3
    for &s,i in line {s={f32(i)*0.1-0.4,0,0}}
    testing.expect_value(t,mesh_fracture(&f,mesh,line[:]),Fracture_Error.None)
    expect_fracture(t,&f,mesh,line[:],"line")
    testing.expect_value(t,len(f.pieces),9)
    testing.expect_value(t,len(f.connections),8)
    plane:[16]Vec3
    for &s,i in plane {s={f32(i%4)*0.25-0.375,0.1,f32(i/4)*0.25-0.375}}
    testing.expect_value(t,mesh_fracture(&f,mesh,plane[:]),Fracture_Error.None)
    expect_fracture(t,&f,mesh,plane[:],"plane")
    testing.expect_value(t,len(f.pieces),16)
    testing.expect_value(t,len(f.connections),24)
    corners:=box_corners({-0.5,-0.5,-0.5},{0.5,0.5,0.5})
    on_surface:[14]Vec3
    copy(on_surface[:],corners[:])
    for i in 0..<6 {on_surface[8+i][i/2]=0.5 if i%2==0 else -0.5}
    testing.expect_value(t,mesh_fracture(&f,mesh,on_surface[:]),Fracture_Error.None)
    expect_fracture(t,&f,mesh,on_surface[:],"surface")
    testing.expect_value(t,len(f.pieces),14)

    // Pieces up to min_volume are dropped, and so are their connections.
    uneven:=[]Vec3{{0,0,0},{0.49,0.49,0.49},{-0.2,0,0}}
    testing.expect_value(t,mesh_fracture(&f,mesh,uneven),Fracture_Error.None)
    testing.expect_value(t,len(f.pieces),3)
    testing.expect_value(t,mesh_fracture(&f,mesh,uneven,{min_volume=0.1}),Fracture_Error.None)
    testing.expect_value(t,len(f.pieces),2)
    testing.expect_value(t,len(f.connections),1)
}

@(test)
fracture_pieces_are_closed_and_add_up_to_the_mesh :: proc(t:^testing.T) {
    f,again:Fracture
    fracture_init(&f);fracture_init(&again)
    defer fracture_destroy(&f)
    defer fracture_destroy(&again)
    b:Mesh_Buffer
    mesh_buffer_init(&b)
    defer mesh_buffer_destroy(&b)
    sites:[dynamic]Vec3
    defer delete(sites)
    rng:=base.rng_make(0xf4ac)
    for round in 0..<54 {
        shape:=Shape(round%len(Shape))
        mesh_buffer_clear(&b)
        shape_build(&b,shape)
        scales:=[3]f32{1,1e-2,150}
        scale:=scales[round/len(Shape)%3]
        offset:=Vec3{mm.random_f32(&rng)-0.5,mm.random_f32(&rng)-0.5,mm.random_f32(&rng)-0.5}*scale*(round%4==0?400:1)
        for &p in b.positions {p=p*scale+offset}
        mesh:=mesh_buffer_view(&b)
        lo,hi:=mesh_bounds(mesh.positions)
        resize(&sites,2+int(base.rng_u32(&rng)%30))
        pattern:=Site_Pattern(round/2%len(Site_Pattern))
        impact:=mesh.positions[int(base.rng_u32(&rng))%len(mesh.positions)]
        sites_generate(sites[:],{pattern=pattern,seed=u64(round),lo=lo,hi=hi,center=impact,radius=0.4*scale})
        what:=[3]string{"uniform","clustered","radial"}
        testing.expect_value(t,mesh_fracture(&f,mesh,sites[:],{interior_material=1}),Fracture_Error.None)
        expect_fracture(t,&f,mesh,sites[:],what[int(pattern)])
        testing.expectf(t,len(f.pieces)>=2,"round %d (%v, %d sites): %d pieces",round,shape,len(sites),len(f.pieces))
        // The same fracture with fresh memory, and again with used memory.
        mesh_fracture(&again,mesh,sites[:],{interior_material=1})
        testing.expectf(t,fractures_equal(&f,&again),"round %d (%v): two fractures differ",round,shape)
        if round%9==0 {
            mesh_fracture(&again,mesh,sites[:len(sites)/2],{})
            mesh_fracture(&again,mesh,sites[:],{interior_material=1})
            testing.expectf(t,fractures_equal(&f,&again),"round %d (%v): a reused fracture differs",round,shape)
        }
        // The pieces of a connected mesh are connected through their faces.
        reached:=make([]bool,len(f.pieces))
        defer delete(reached)
        reached[0]=true
        for _ in 0..<len(f.pieces) {
            for c in f.connections {
                if reached[c.a] || reached[c.b] {reached[c.a]=true;reached[c.b]=true}
            }
        }
        for r,i in reached {testing.expectf(t,r,"round %d (%v): piece %d is not connected",round,shape,i)}
    }
}
