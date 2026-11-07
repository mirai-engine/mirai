package importer

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:std/geom"

// The vertices of a shape as an importer leaves them, all of slot `slot`.
@(private="file")
shape_vertices :: proc(buffer:^geom.Mesh_Buffer,slot:u32=0) -> []asset.Vertex {
    vertices:=make([]asset.Vertex,len(buffer.positions),context.temp_allocator)
    for position,at in buffer.positions {
        vertices[at]=test_vertex(position,buffer.normals[at],buffer.uvs[at])
        vertices[at].material=slot
    }
    return vertices
}

// Whether the levels make a mesh an asset takes, with a level of the geometry for each.
@(private="file")
levels_valid :: proc(t:^testing.T,levels:Mesh_Levels,slots:int,loc:=#caller_location) -> bool {
    geometry:asset.Mesh_Geometry
    if !testing.expect(t,levels_geometry(levels,{},&geometry,context.temp_allocator),"the levels make clusters",loc=loc) {return false}
    if len(levels.skin)==0 && !levels.pruned && len(levels.lods)>1 {
        // A static mesh keeps level 0 and the DAG of its clusters, whose levels shed triangles.
        if !testing.expect(t,len(geometry.levels)>1,"the DAG has levels",loc=loc) {return false}
        testing.expect_value(t,geometry.levels[0].triangle_count,levels.lods[0].index_count/3,loc=loc)
        for level,at in geometry.levels[1:] {testing.expect(t,level.triangle_count<=geometry.levels[at].triangle_count && level.error>=geometry.levels[at].error,"a coarser level of the DAG",loc=loc)}
    } else {
        if !testing.expect_value(t,len(geometry.levels),len(levels.lods),loc=loc) {return false}
        for lod,at in levels.lods {testing.expect_value(t,geometry.levels[at].triangle_count,lod.index_count/3,loc=loc)}
    }
    slot_rows:=make([]asset.Material_Slot,slots,context.temp_allocator)
    for &slot,at in slot_rows {slot.id=u32(at)}
    desc:=asset.Mesh_Desc{id={1,1},geometry=geometry,slots=slot_rows}
    rig_joints:[2]asset.Rig_Joint
    if len(levels.skin)>0 {
        desc.skeleton={1,1}
        desc.joints=rig_joints[:]
        for &joint in rig_joints {joint.inverse_bind=1}
    }
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document
    made:=asset.mesh_document(&doc,&types,desc)
    if made==.None {asset.document_destroy(&doc)}
    return testing.expect_value(t,made,asset.Error.None,loc=loc)
}

@(test)
a_sphere_gets_levels_that_shed_triangles_and_stay_on_its_surface :: proc(t:^testing.T) {
    sphere:geom.Mesh_Buffer
    geom.mesh_buffer_init(&sphere,context.temp_allocator)
    geom.sphere_build(&sphere,1,128,64)
    vertices:=shape_vertices(&sphere)
    whole:=[1]Submesh{{index_count=u32(len(sphere.indices))}}
    levels:=mesh_levels(vertices,sphere.indices[:],nil,whole[:],allocator=context.temp_allocator)
    if !levels_valid(t,levels,1) {return}
    testing.expectf(t,len(levels.lods)>=4 && levels.lods[len(levels.lods)-1].index_count/3<LOD_MIN_TRIANGLES,"the levels go on until one has fewer than LOD_MIN_TRIANGLES: %d levels",len(levels.lods))
    testing.expect(t,levels.lods[0].error==0 && int(levels.lods[0].vertex_count)==len(vertices) && int(levels.lods[0].index_count)==len(sphere.indices),"level 0 is the mesh as given")
    for level,at in levels.lods[1:] {
        before:=levels.lods[at]
        testing.expectf(t,f32(level.index_count)<=LOD_KEEP*f32(before.index_count) && level.index_count>0,"level %d has %d triangles after %d",at+1,level.index_count/3,before.index_count/3)
        testing.expectf(t,level.error>0 && level.error>=before.error && level.error<1,"the error of level %d is a growing bound: %f",at+1,level.error)
        testing.expect_value(t,level.first_vertex,before.first_vertex+before.vertex_count)
        testing.expect_value(t,level.first_index,before.first_index+before.index_count)
        testing.expect_value(t,level.submesh_count,1)
        range:=levels.submeshes[level.first_submesh]
        testing.expect(t,range.first_index==level.first_index && range.index_count==level.index_count,"the submesh of a level is the level")
        // No vertex is invented: every one of a level is on the sphere.
        for vertex in levels.vertices[level.first_vertex:][:level.vertex_count] {
            if abs(linalg.length(vertex.position)-1)>1e-4 {testing.expectf(t,false,"a vertex of level %d left the surface",at+1);break}
        }
    }
    fmt.printfln("sphere levels: %d/%d/%d/%d triangles, errors %.4f %.4f %.4f",levels.lods[0].index_count/3,levels.lods[1].index_count/3,levels.lods[2].index_count/3,levels.lods[3].index_count/3,levels.lods[1].error,levels.lods[2].error,levels.lods[3].error)
}

@(test)
seams_and_material_borders_do_not_stop_the_levels_and_triangles_keep_their_slot :: proc(t:^testing.T) {
    // A plane whose triangles share no vertex, as flat shading leaves it, half of each of two slots.
    plane:geom.Mesh_Buffer
    geom.mesh_buffer_init(&plane,context.temp_allocator)
    geom.plane_build(&plane,{8,8},32,32)
    triangles:=len(plane.indices)/3
    vertices:=make([]asset.Vertex,triangles*3,context.temp_allocator)
    indices:=make([]u32,triangles*3,context.temp_allocator)
    skin:=make([]asset.Skin_Vertex,triangles*3,context.temp_allocator)
    // Slot 0 first, then slot 1: the order of the submeshes.
    written:=0
    counts:[2]int
    for slot in 0..<2 {
        for triangle in 0..<triangles {
            center:=(plane.positions[plane.indices[triangle*3]]+plane.positions[plane.indices[triangle*3+1]]+plane.positions[plane.indices[triangle*3+2]])/3
            if (center.x<0)!=(slot==0) {continue}
            for k in 0..<3 {
                source:=plane.indices[triangle*3+k]
                vertices[written]=test_vertex(plane.positions[source],plane.normals[source],plane.uvs[source])
                vertices[written].material=u32(slot)
                skin[written]={joints={u16(slot),0,0,0,0,0,0,0},weights={255,0,0,0,0,0,0,0}}
                indices[written]=u32(written)
                written+=1
            }
            counts[slot]+=3
        }
    }
    submeshes:=[2]Submesh{{first_index=0,index_count=u32(counts[0]),slot=0},{first_index=u32(counts[0]),index_count=u32(counts[1]),slot=1}}
    levels:=mesh_levels(vertices,indices,skin,submeshes[:],allocator=context.temp_allocator)
    if !levels_valid(t,levels,2) {return}
    testing.expect(t,len(levels.lods)>=3,"a flat plane is simplified although no two triangles share a vertex")
    testing.expect_value(t,len(levels.skin),len(levels.vertices))
    for level,at in levels.lods[1:] {
        testing.expect_value(t,level.submesh_count,2)
        if level.submesh_count!=2 {continue}
        for range in levels.submeshes[level.first_submesh:][:2] {
            testing.expect(t,range.index_count>0)
            for index in levels.indices[range.first_index:][:range.index_count] {
                vertex:=index
                if levels.vertices[vertex].material!=range.slot || levels.skin[vertex].joints[0]!=u16(range.slot) {
                    testing.expectf(t,false,"a triangle of level %d changed slot or skin",at+1)
                    break
                }
                if (levels.vertices[vertex].position.x<=1e-5)!=(range.slot==0) && abs(levels.vertices[vertex].position.x)>1e-5 {
                    testing.expectf(t,false,"a triangle of level %d crossed the border between the slots",at+1)
                    break
                }
            }
        }
    }
    last:=levels.lods[len(levels.lods)-1]
    testing.expectf(t,last.error<1e-2,"a plane of 8 m loses triangles without leaving its plane: %f",last.error)
}

@(test)
a_mesh_over_its_most_triangles_is_simplified_into_level_0_with_its_slots :: proc(t:^testing.T) {
    sphere:geom.Mesh_Buffer
    geom.mesh_buffer_init(&sphere,context.temp_allocator)
    geom.sphere_build(&sphere,1,128,64)
    // The triangles of the upper half in slot 0, those of the lower one in slot 1.
    triangles:=len(sphere.indices)/3
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    submeshes:[2]Submesh
    for slot in 0..<2 {
        submeshes[slot]={first_index=u32(len(indices)),slot=u32(slot)}
        for triangle in 0..<triangles {
            corners:=sphere.indices[triangle*3:][:3]
            if (sphere.positions[corners[0]].y+sphere.positions[corners[1]].y+sphere.positions[corners[2]].y<0)!=(slot==1) {continue}
            for corner in corners {
                vertex:=test_vertex(sphere.positions[corner],sphere.normals[corner],sphere.uvs[corner])
                vertex.material=u32(slot)
                append(&indices,u32(len(vertices)))
                append(&vertices,vertex)
            }
        }
        submeshes[slot].index_count=u32(len(indices))-submeshes[slot].first_index
    }
    most:=triangles/8
    levels:=mesh_levels(vertices[:],indices[:],nil,submeshes[:],allocator=context.temp_allocator,max_triangles=most)
    if !levels_valid(t,levels,2) {return}
    first:=levels.lods[0]
    testing.expectf(t,int(first.index_count)/3<=most && int(first.index_count)/3>most/2,"level 0 has %d triangles for at most %d",first.index_count/3,most)
    testing.expect(t,first.error==0 && first.submesh_count==2,"level 0 is what the others are measured against, with both slots")
    testing.expect(t,len(levels.lods)>1 && levels.lods[1].index_count<first.index_count,"the levels go on from it")
    for range in levels.submeshes[:2] {
        for index in levels.indices[range.first_index:][:range.index_count] {
            vertex:=levels.vertices[index]
            if vertex.material!=range.slot || (range.slot==0?vertex.position.y< -1e-4:vertex.position.y>1e-4) {
                testing.expect(t,false,"a triangle of level 0 changed slot or crossed the border between them")
                break
            }
        }
    }
    within:=mesh_levels(vertices[:],indices[:],nil,submeshes[:],allocator=context.temp_allocator,max_triangles=triangles)
    testing.expect(t,int(within.lods[0].index_count)==len(indices),"a mesh within its most triangles is kept as given")
}

@(test)
a_small_mesh_or_one_told_not_to_keeps_one_level :: proc(t:^testing.T) {
    cube:geom.Mesh_Buffer
    geom.mesh_buffer_init(&cube,context.temp_allocator)
    geom.cube_build(&cube)
    small:=mesh_levels(shape_vertices(&cube),cube.indices[:],nil,nil,allocator=context.temp_allocator)
    testing.expect(t,len(small.lods)==1 && len(small.vertices)==len(cube.positions) && len(small.indices)==len(cube.indices))
    testing.expect(t,levels_valid(t,small,1))
    sphere:geom.Mesh_Buffer
    geom.mesh_buffer_init(&sphere,context.temp_allocator)
    geom.sphere_build(&sphere,1,48,24)
    kept:=mesh_levels(shape_vertices(&sphere),sphere.indices[:],nil,nil,false,context.temp_allocator)
    testing.expect(t,len(kept.lods)==1 && len(kept.indices)==len(sphere.indices))
    // Without submeshes the levels have none either.
    plain:=mesh_levels(shape_vertices(&sphere),sphere.indices[:],nil,nil,allocator=context.temp_allocator)
    testing.expect(t,len(plain.lods)>1 && len(plain.submeshes)==0 && levels_valid(t,plain,1))
}

@(private="file")
collision_valid :: proc(t:^testing.T,collision:Mesh_Collision,loc:=#caller_location) {
    for collider in collision.colliders {
        testing.expect(t,int(collider.first_point)+int(collider.point_count)<=len(collision.points) && int(collider.first_index)+int(collider.index_count)<=len(collision.indices),loc=loc)
        testing.expect(t,collider.rotation==1 && collider.point_count>=3,loc=loc)
        for index in collision.indices[collider.first_index:][:collider.index_count] {
            if index>=collider.point_count {testing.expect(t,false,"an index of a collider names a point of its own",loc=loc);break}
        }
    }
}

// An L of two boxes that share a face: not convex, with volume.
@(private="file")
angle_build :: proc(out:^geom.Mesh_Buffer) {
    box:geom.Mesh_Buffer
    geom.mesh_buffer_init(&box,context.temp_allocator)
    for part in 0..<2 {
        geom.cube_build(&box,part==0?geom.Vec3{3,1,1}:geom.Vec3{1,3,1})
        offset:=part==0?geom.Vec3{1,0,0}:geom.Vec3{0,2,0}
        first:=u32(len(out.positions))
        for position,at in box.positions {
            append(&out.positions,position+offset)
            append(&out.normals,box.normals[at])
            append(&out.uvs,box.uvs[at])
        }
        for index in box.indices {append(&out.indices,first+index)}
    }
}

@(test)
collision_is_a_hull_convex_pieces_or_a_simplified_or_exact_surface :: proc(t:^testing.T) {
    sphere:geom.Mesh_Buffer
    geom.mesh_buffer_init(&sphere,context.temp_allocator)
    geom.sphere_build(&sphere,1,48,24)
    vertices:=shape_vertices(&sphere)
    none,none_ok:=mesh_collision(vertices,sphere.indices[:],.None,allocator=context.temp_allocator)
    testing.expect(t,none_ok && len(none.colliders)==0)

    hull,hull_ok:=mesh_collision(vertices,sphere.indices[:],.Hull,allocator=context.temp_allocator)
    testing.expect(t,hull_ok && len(hull.colliders)==1 && len(hull.indices)==0)
    if hull_ok {
        collision_valid(t,hull)
        testing.expect(t,hull.colliders[0].kind==.Hull && int(hull.colliders[0].point_count)<=COLLISION_HULL_VERTICES && hull.colliders[0].point_count>=8)
        for point in hull.points {testing.expect(t,abs(linalg.length(point)-1)<1e-4,"the points of a hull are points of the mesh")}
    }

    surface,surface_ok:=mesh_collision(vertices,sphere.indices[:],.Mesh,allocator=context.temp_allocator)
    testing.expect(t,surface_ok && len(surface.colliders)==1)
    if surface_ok {
        collision_valid(t,surface)
        triangles:=int(surface.colliders[0].index_count)/3
        testing.expectf(t,surface.colliders[0].kind==.Mesh && triangles<=len(sphere.indices)/3*3/10 && triangles>=COLLISION_MESH_MIN_TRIANGLES,"the surface keeps about a quarter of its triangles: %d of %d",triangles,len(sphere.indices)/3)
        testing.expect(t,int(surface.colliders[0].point_count)<len(vertices),"the points are those of the surface, welded")
    }
    exact,exact_ok:=mesh_collision(vertices,sphere.indices[:],.Exact,allocator=context.temp_allocator)
    testing.expect(t,exact_ok && len(exact.colliders)==1)
    if exact_ok {
        collision_valid(t,exact)
        testing.expect(t,exact.colliders[0].kind==.Mesh && int(exact.colliders[0].index_count)==len(sphere.indices),"exact keeps every triangle")
        testing.expect(t,int(exact.colliders[0].point_count)<len(vertices),"the points are those of the surface, welded")
    }

    angle:geom.Mesh_Buffer
    geom.mesh_buffer_init(&angle,context.temp_allocator)
    angle_build(&angle)
    angle_vertices:=shape_vertices(&angle)
    pieces,pieces_ok:=mesh_collision(angle_vertices,angle.indices[:],.Pieces,allocator=context.temp_allocator)
    testing.expect(t,pieces_ok && len(pieces.colliders)>=2,"a shape that is not convex is several hulls")
    if pieces_ok {
        collision_valid(t,pieces)
        for collider in pieces.colliders {testing.expect(t,collider.kind==.Hull && int(collider.point_count)<=COLLISION_HULL_VERTICES)}
    }
    two,two_ok:=mesh_collision(angle_vertices,angle.indices[:],.Pieces,2,context.temp_allocator)
    testing.expect(t,two_ok && len(two.colliders)==2,"the most pieces are those asked for")
    one,one_ok:=mesh_collision(angle_vertices,angle.indices[:],.Hull,allocator=context.temp_allocator)
    testing.expect(t,one_ok && len(one.colliders)==1 && one.colliders[0].point_count<=16,"one hull has the corners of the two boxes at most")

    // A flat surface has a flat hull, its outline, but no convex pieces; its triangles are still a collision mesh.
    plane:geom.Mesh_Buffer
    geom.mesh_buffer_init(&plane,context.temp_allocator)
    geom.plane_build(&plane,{2,2},4,4)
    flat:=shape_vertices(&plane)
    outline,outline_ok:=mesh_collision(flat,plane.indices[:],.Hull,allocator=context.temp_allocator)
    testing.expect(t,outline_ok && len(outline.colliders)==1 && outline.colliders[0].point_count==4,"the four corners of the plane")
    _,flat_pieces:=mesh_collision(flat,plane.indices[:],.Pieces,allocator=context.temp_allocator)
    flat_mesh,flat_mesh_ok:=mesh_collision(flat,plane.indices[:],.Mesh,allocator=context.temp_allocator)
    testing.expect(t,!flat_pieces && flat_mesh_ok && int(flat_mesh.colliders[0].index_count)==len(plane.indices),"a small surface is stored as it is")
    _,empty:=mesh_collision(flat,nil,.Mesh,allocator=context.temp_allocator)
    testing.expect(t,!empty)
}


// A sphere in slot 0 and, in slot 1, cards of two triangles at the corners
// given, each `size` across.
@(private="file")
Cards :: struct {vertices:[dynamic]asset.Vertex,indices:[dynamic]u32,sphere:int}

@(private="file")
cards_build :: proc(sphere_detail:int) -> (c:Cards) {
    sphere:geom.Mesh_Buffer
    geom.mesh_buffer_init(&sphere,context.temp_allocator)
    geom.sphere_build(&sphere,1,sphere_detail,sphere_detail/2)
    c.vertices=make([dynamic]asset.Vertex,context.temp_allocator)
    c.indices=make([dynamic]u32,context.temp_allocator)
    for p,at in sphere.positions {append(&c.vertices,test_vertex(p,sphere.normals[at],sphere.uvs[at]))}
    append(&c.indices,..sphere.indices[:])
    c.sphere=len(sphere.indices)
    return
}

@(private="file")
cards_add :: proc(c:^Cards,center:geom.Vec3,size:f32) {
    first:=u32(len(c.vertices))
    for corner in ([4][2]f32{{0,0},{1,0},{0,1},{1,1}}) {
        v:=test_vertex(center+{(corner.x-0.5)*size,0,(corner.y-0.5)*size},{0,1,0},corner)
        v.material=1
        append(&c.vertices,v)
    }
    append(&c.indices,first,first+2,first+1,first+1,first+2,first+3)
}

// The area of the triangles of a range of a level.
@(private="file")
cards_area :: proc(levels:Mesh_Levels,range:Submesh) -> (sum:f32) {
    for i:=u32(0);i<range.index_count;i+=3 {
        p:=[3]geom.Vec3{}
        for k in 0..<u32(3) {p[k]=levels.vertices[levels.indices[range.first_index+i+k]].position}
        sum+=0.5*linalg.length(linalg.cross(p[1]-p[0],p[2]-p[0]))
    }
    return
}

// The centers of the cards of a level, which they grow around, in millimetres.
@(private="file")
cards_centers :: proc(levels:Mesh_Levels,lod:Lod) -> map[[2]i32]bool {
    cards:=levels.submeshes[lod.first_submesh+1]
    out:=make(map[[2]i32]bool,context.temp_allocator)
    for i:=u32(0);i<cards.index_count;i+=6 {
        p:=levels.vertices[levels.indices[cards.first_index+i]].position
        q:=levels.vertices[levels.indices[cards.first_index+i+5]].position
        out[{i32(math.round((p.x+q.x)*500)),i32(math.round((p.z+q.z)*500))}]=true
    }
    return out
}

@(test)
a_submesh_of_cards_drops_half_of_them_where_its_error_allows_and_keeps_its_area :: proc(t:^testing.T) {
    CARDS :: 256
    SIZE :: f32(0.1)
    c:=cards_build(64)
    for card in 0..<CARDS {cards_add(&c,{f32(card%16)*0.3-2.4,1.5,f32(card/16)*0.3-2.4},SIZE)}
    submeshes:=[2]Submesh{{index_count=u32(c.sphere),slot=0},{first_index=u32(c.sphere),index_count=CARDS*6,slot=1}}
    levels:=mesh_levels(c.vertices[:],c.indices[:],nil,submeshes[:],allocator=context.temp_allocator)
    if !levels_valid(t,levels,2) {return}
    testing.expect(t,len(levels.lods)>=3)
    radius:=SIZE*math.SQRT_TWO/2
    previous_error:f32
    previous_cards:=CARDS
    for lod,k in levels.lods {
        cards:=levels.submeshes[lod.first_submesh+1]
        testing.expect_value(t,cards.slot,1)
        kept:=int(cards.index_count)/6
        // A power of two of them, never more than the level before.
        testing.expectf(t,kept<=previous_cards && CARDS%kept==0 && (CARDS/kept)&(CARDS/kept-1)==0,"level %d keeps %d cards after %d",k,kept,previous_cards)
        testing.expectf(t,abs(cards_area(levels,cards)-CARDS*SIZE*SIZE)<CARDS*SIZE*SIZE*1e-3,"level %d keeps the area of the cards: %f",k,cards_area(levels,cards))
        // Where cards are dropped, the error covers the radius they grew to.
        grown:=radius*math.sqrt(f32(CARDS)/f32(kept))/ISLAND_PIXELS
        testing.expectf(t,kept==CARDS || lod.error>=grown*0.999,"level %d keeps %d cards with an error of %f under their grown radius %f",k,kept,lod.error,grown)
        testing.expect(t,k==0 || lod.error>=previous_error,"the error does not drop")
        previous_error,previous_cards=lod.error,kept
        // The sphere is simplified, and its vertices stay those of level 0.
        if k>0 {
            body:=levels.submeshes[lod.first_submesh]
            testing.expect(t,body.index_count<levels.submeshes[0].index_count)
            for index in levels.indices[body.first_index:][:body.index_count] {
                if abs(linalg.length(levels.vertices[index].position)-1)>1e-4 {testing.expect(t,false,"a vertex of the sphere moved");break}
            }
        }
    }
    // The first level simplifies the sphere with less error than dropping a card would take: it keeps them all.
    testing.expectf(t,levels.submeshes[levels.lods[1].first_submesh+1].index_count/6==CARDS && levels.lods[1].error<radius*math.SQRT_TWO/ISLAND_PIXELS,"level 1 keeps every card: error %f",levels.lods[1].error)
    testing.expect(t,previous_cards<CARDS,"the coarsest level drops cards")
    // The cards a level keeps are among those of the level before.
    for k in 2..<len(levels.lods) {
        before,after:=cards_centers(levels,levels.lods[k-1]),cards_centers(levels,levels.lods[k])
        for center in after {testing.expect(t,center in before,"a level keeps a card the level before dropped")}
    }
}

@(test)
a_few_large_islands_do_not_hold_back_the_small_ones :: proc(t:^testing.T) {
    // 256 cards of 0.1 m and 16 of 2 m in one submesh, as leaves and a few lianas.
    SMALL,LARGE :: 256,16
    c:=cards_build(32)
    for card in 0..<SMALL {cards_add(&c,{f32(card%16)*0.3-2.4,1.5,f32(card/16)*0.3-2.4},0.1)}
    for card in 0..<LARGE {cards_add(&c,{f32(card%4)*3-4.5,3,f32(card/4)*3-4.5},2)}
    submeshes:=[2]Submesh{{index_count=u32(c.sphere),slot=0},{first_index=u32(c.sphere),index_count=(SMALL+LARGE)*6,slot=1}}
    levels:=mesh_levels(c.vertices[:],c.indices[:],nil,submeshes[:],allocator=context.temp_allocator)
    if !levels_valid(t,levels,2) {return}
    large_radius:=f32(2)*math.SQRT_TWO/2
    pruned_small:=false
    for lod,k in levels.lods[1:] {
        cards:=levels.submeshes[lod.first_submesh+1]
        large,small:=0,0
        for i:=u32(0);i<cards.index_count;i+=6 {
            p:=levels.vertices[levels.indices[cards.first_index+i]].position
            q:=levels.vertices[levels.indices[cards.first_index+i+5]].position
            if abs(p.y-3)<1e-3 {large+=1} else {small+=1}
        }
        if large==LARGE && small<SMALL {
            pruned_small=true
            testing.expectf(t,lod.error<large_radius*math.SQRT_TWO/ISLAND_PIXELS,"level %d drops small cards with an error %f below what dropping a large one takes",k+1,lod.error)
        }
    }
    testing.expect(t,pruned_small,"a level drops small cards and keeps every large one")
}
