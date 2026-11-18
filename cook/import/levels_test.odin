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
