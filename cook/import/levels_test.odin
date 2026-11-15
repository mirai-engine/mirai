package importer

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:cook/textures"
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
    if levels.dag {
        // A static mesh keeps level 0 and the DAG of its clusters, whose levels shed triangles.
        testing.expect_value(t,len(levels.lods),1,loc=loc)
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
    // Skinned, so it keeps whole levels.
    skin:=make([]asset.Skin_Vertex,len(vertices),context.temp_allocator)
    for &s in skin {s.weights[0]=255}
    levels:=mesh_levels(vertices,sphere.indices[:],skin,whole[:],allocator=context.temp_allocator)
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
    testing.expect(t,len(small.lods)==1 && small.dag && len(small.vertices)==len(cube.positions) && len(small.indices)==len(cube.indices))
    testing.expect(t,levels_valid(t,small,1))
    sphere:geom.Mesh_Buffer
    geom.mesh_buffer_init(&sphere,context.temp_allocator)
    geom.sphere_build(&sphere,1,48,24)
    kept:=mesh_levels(shape_vertices(&sphere),sphere.indices[:],nil,nil,false,context.temp_allocator)
    testing.expect(t,len(kept.lods)==1 && !kept.dag && len(kept.indices)==len(sphere.indices))
    // Without submeshes the levels have none either.
    skin:=make([]asset.Skin_Vertex,len(sphere.positions),context.temp_allocator)
    for &s in skin {s.weights[0]=255}
    plain:=mesh_levels(shape_vertices(&sphere),sphere.indices[:],skin,nil,allocator=context.temp_allocator)
    testing.expect(t,len(plain.lods)>1 && len(plain.submeshes)==0 && levels_valid(t,plain,1))
}

@(test)
a_faceted_mesh_with_a_seam_on_every_edge_reaches_a_small_root :: proc(t:^testing.T) {
    // A crystal: each triangle has vertices of its own, its flat normal and a uv chart of its own.
    sphere:geom.Mesh_Buffer
    geom.mesh_buffer_init(&sphere,context.temp_allocator)
    geom.sphere_build(&sphere,1,64,32)
    triangles:=len(sphere.indices)/3
    vertices:=make([]asset.Vertex,triangles*3,context.temp_allocator)
    indices:=make([]u32,triangles*3,context.temp_allocator)
    for triangle in 0..<triangles {
        p:=[3]geom.Vec3{}
        for k in 0..<3 {p[k]=sphere.positions[sphere.indices[triangle*3+k]]}
        normal:=linalg.normalize(linalg.cross(p[1]-p[0],p[2]-p[0]))
        chart:=f32(triangle%61)
        for k in 0..<3 {
            vertices[triangle*3+k]=test_vertex(p[k],normal,{p[k].x*0.25+chart,p[k].z*0.25})
            indices[triangle*3+k]=u32(triangle*3+k)
        }
    }
    skin:=make([]asset.Skin_Vertex,len(vertices),context.temp_allocator)
    for &s in skin {s.weights[0]=255}
    // Static as a DAG, skinned as whole levels.
    cases:=[]struct{name:string,skin:[]asset.Skin_Vertex}{{"static",nil},{"skinned",skin}}
    for c in cases {
        levels:=mesh_levels(vertices,indices,c.skin,nil,allocator=context.temp_allocator)
        if !levels_valid(t,levels,1) {continue}
        geometry:asset.Mesh_Geometry
        levels_geometry(levels,{},&geometry,context.temp_allocator)
        root:=0
        for cluster in geometry.clusters {
            if cluster.parent_error==asset.CLUSTER_ROOT {root+=int(asset.cluster_triangle_count(cluster))}
        }
        testing.expectf(t,root<LOD_MIN_TRIANGLES,"%s: the roots keep %d of %d triangles",c.name,root,triangles)
    }
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

// A mask of size² texels: a serrated leaf with a stem, or a cluster of
// round leaves with gaps between them, as an image whose color is that of
// the leaves where the mask keeps them and black where it does not.
@(private="file")
Test_Mask :: enum {Leaf,Cluster}

@(private="file")
mask_kept :: proc(kind:Test_Mask,size:int,x,y:int) -> bool {
    p:=[2]f32{(f32(x)+0.5)/f32(size),(f32(y)+0.5)/f32(size)}
    switch kind {
    case .Leaf:
        if abs(p.x-0.5)<0.012 && p.y>0.85 {return true}
        d:=p-{0.5,0.48}
        angle:=math.atan2(d.y,d.x)
        teeth:=1-0.1*abs(math.mod(angle*7/math.PI+8,1)*2-1)
        return (d.x/0.2)*(d.x/0.2)+(d.y/0.4)*(d.y/0.4)<=teeth*teeth
    case .Cluster:
        centers:=[?][2]f32{{0.2,0.2},{0.33,0.25},{0.25,0.36},{0.7,0.2},{0.82,0.3},{0.7,0.33},{0.2,0.72},{0.34,0.8},{0.22,0.86},{0.72,0.7},{0.84,0.78},{0.66,0.84},{0.5,0.5},{0.6,0.55}}
        for c in centers {
            d:=p-c
            if d.x*d.x+d.y*d.y<=0.065*0.065 {return true}
        }
    }
    return false
}

@(private="file")
mask_source :: proc(kind:Test_Mask,size:int) -> textures.Source {
    texels:=make([]u8,size*size*4,context.temp_allocator)
    for y in 0..<size {
        for x in 0..<size {
            if !mask_kept(kind,size,x,y) {continue}
            at:=(y*size+x)*4
            texels[at],texels[at+1],texels[at+2],texels[at+3]=40,120,30,255
        }
    }
    return textures.rgba8(texels,size,size)
}

@(private="file")
mask_of :: proc(source:textures.Source,cutoff:u8) -> Outline_Mask {
    covered:=make([]bool,source.width*source.height,context.temp_allocator)
    for &c,i in covered {c=source.texels[i*4+3]>=cutoff}
    return {covered,source.width,source.height}
}

// Every outline of a ladder holds every texel its mask keeps, draws no
// farther from them than its tolerance allows, and each draws fewer
// triangles with more error than the one before. The forest's leaf
// reproduces what the design measured on it: its quad covers 0.417, and
// with the outline each size on screen takes at 1 pixel of error about six
// triangles a leaf, about 0.78 of what it draws covered, over 1.3 to 40 m. A
// single leaf is drawn as its outlines; a cluster of leaves keeps its mask on
// a convex outline that halves the empty area of its quad.
@(test)
a_masked_card_becomes_the_outlines_its_mask_needs :: proc(t:^testing.T) {
    forest,_:=textures.image_decode(#load("../../demo/assets/forest/leaves_color.png"),context.temp_allocator)
    Case :: struct {name:string,source:textures.Source,leaf:bool,quad:f64,triangles:[2]f64,coverage:f64}
    cases:=[]Case{
        {"forest leaf",textures.rgba8(forest.pixels,forest.width,forest.height),true,0.417,{4,9},0.7},
        {"serrated leaf",mask_source(.Leaf,128),true,0,{},0},
        {"cluster",mask_source(.Cluster,128),false,0,{},0},
    }
    for c in cases {
        mask:=mask_of(c.source,128)
        ladder,ok:=outline_ladder(mask,context.temp_allocator)
        if !testing.expectf(t,ok,"%s: a ladder",c.name) {continue}
        testing.expectf(t,ladder.leaf==c.leaf,"%s: drawn as outlines %v",c.name,ladder.leaf)
        distance2:=make([]u32,len(mask.covered),context.temp_allocator)
        nearest:=make([]u32,len(mask.covered),context.temp_allocator)
        geom.grid_nearest(mask.covered,mask.width,mask.height,0,nearest,distance2)
        for rung,k in ladder.rungs {
            drawn:=make([]bool,len(mask.covered),context.temp_allocator)
            first,loop:=0,0
            for loops in rung.set.polygon_loops {
                count:=0
                for size in rung.set.loop_sizes[loop:][:loops] {count+=size}
                points:=rung.set.points[first:][:count]
                indices:[dynamic]u32
                indices.allocator=context.temp_allocator
                geom.polygon_triangulate(points,rung.set.loop_sizes[loop:][:loops],&indices)
                for i:=0;i+2<len(indices);i+=3 {triangle_raster({points[indices[i]],points[indices[i+1]],points[indices[i+2]]},mask.width,mask.height,drawn)}
                first+=count
                loop+=loops
            }
            worst:u32
            for d,at in drawn {
                if d {worst=max(worst,distance2[at])}
                if mask.covered[at] && !d {testing.expectf(t,false,"%s: outline %d leaves out texel %d the mask keeps",c.name,k,at);break}
            }
            error:=f32(math.sqrt(f64(worst)))
            testing.expectf(t,abs(error-rung.error)<1e-3,"%s: outline %d draws %f texels out, not %f",c.name,k,error,rung.error)
            if rung.tolerance>0 {testing.expectf(t,rung.error<=2*rung.tolerance+2,"%s: outline %d cut at %f draws %f out",c.name,k,rung.tolerance,rung.error)}
            if k>0 {
                finer:=ladder.rungs[k-1]
                testing.expectf(t,rung.error>=finer.error && rung.triangles<=finer.triangles,"%s: outline %d is not coarser than %d",c.name,k,k-1)
            }
        }
        quad:=f64(ladder.opaque)/f64(mask.width*mask.height)
        if c.quad>0 {testing.expectf(t,abs(quad-c.quad)<0.002,"%s: the quad covers %f",c.name,quad)}
        if !c.leaf {
            hull:=f64(ladder.opaque)/ladder.hull.area
            testing.expectf(t,ladder.hull.triangles<=6 && hull>=1.5*quad,"%s: masked on %d triangles covering %f, the quad %f",c.name,ladder.hull.triangles,hull,quad)
        }
        if c.triangles=={} {continue}
        // Cards of 5.8 to 180 pixels, uniform over the ground from 1.3 to 40 m, each with the outline its pixel allows.
        triangles,coverage,weight:f64
        for i in 0..<2000 {
            distance:=1.3+(40-1.3)*f64(i)/1999
            allowed:=f32(f64(mask.width)*distance/234)
            pick:=ladder.rungs[0]
            for rung in ladder.rungs {if rung.error<=allowed {pick=rung}}
            triangles+=f64(pick.triangles)*distance
            coverage+=f64(ladder.opaque)/pick.area*distance
            weight+=distance
        }
        triangles/=weight
        coverage/=weight
        testing.expectf(t,triangles>=c.triangles[0] && triangles<=c.triangles[1] && coverage>=c.coverage,"%s: %f triangles a card covering %f at 1 pixel",c.name,triangles,coverage)
        fmt.printfln("%s: quad %.3f, %.1f triangles a card covering %.3f at 1 pixel over 1.3-40 m",c.name,quad,triangles,coverage)
    }
}

// A tree read with masked cards: a trunk, leaves of one masked material and
// clusters of another, each card a strip bent along its middle.
@(private="file")
tree_read :: proc(r:^Reader) {
    r.out=context.temp_allocator
    r.meshes.allocator=context.temp_allocator
    r.materials.allocator=context.temp_allocator
    r.images.allocator=context.temp_allocator
    r.material_names.allocator=context.temp_allocator
    no_images:[asset.Material_Map_Kind]int
    for &i in no_images {i=-1}
    material_add(r,"Bark",0,asset.MATERIAL_DEFAULTS,no_images)
    for kind,k in Test_Mask {
        append(&r.images,Imported_Image{name="mask",made=mask_source(kind,128),srgb=true})
        info:=asset.MATERIAL_DEFAULTS
        info.alpha_mode=.Mask
        images:=no_images
        images[.Base_Color]=int(k)
        material_add(r,"Leaves" if kind==.Leaf else "Clusters",int(k)+1,info,images)
    }
    c:=cards_build(128)
    for &v in c.vertices {v.material=0}
    Strips :: struct {count:int,slot:u32,size:f32}
    for s in ([2]Strips{{48,1,0.3},{24,2,0.6}}) {
        for card in 0..<s.count {
            first:=u32(len(c.vertices))
            base:=geom.Vec3{f32(card%8)*0.7-2.5,1.5+f32(s.slot),f32(card/8)*0.7-2.5}
            for row in 0..<3 {
                for column in 0..<2 {
                    uv:=[2]f32{f32(column),f32(row)*0.5}
                    // The upper half leans up: the strip is bent along its middle.
                    position:=base+{(uv.x-0.5)*s.size,0,f32(row)*0.5*s.size}
                    if row==2 {position=base+{(uv.x-0.5)*s.size,0.3*s.size,0.85*s.size}}
                    v:=test_vertex(position,{0,1,0},uv)
                    v.material=s.slot
                    append(&c.vertices,v)
                }
            }
            append(&c.indices,first,first+2,first+1,first+1,first+2,first+3,first+2,first+4,first+3,first+3,first+4,first+5)
        }
    }
    leaves:=u32(48*12)
    submeshes:=make([]Submesh,3,context.temp_allocator)
    submeshes[0]={index_count=u32(c.sphere),slot=0}
    submeshes[1]={first_index=u32(c.sphere),index_count=leaves,slot=1}
    submeshes[2]={first_index=u32(c.sphere)+leaves,index_count=24*12,slot=2}
    slots:=make([]Imported_Slot,3,context.temp_allocator)
    for &slot,at in slots {slot={id=u32(at)+1,material=at}}
    append(&r.meshes,Imported_Mesh{name="tree",vertices=c.vertices[:],indices=c.indices[:],submeshes=submeshes,slots=slots})
}

// The area of the triangles of a slot in a level.
@(private="file")
slot_area :: proc(levels:Mesh_Levels,lod:Lod,slot:u32) -> (sum:f32) {
    for range in levels.submeshes[lod.first_submesh:][:lod.submesh_count] {
        if range.slot!=slot {continue}
        for i:=u32(0);i<range.index_count;i+=3 {
            p:=[3]geom.Vec3{}
            for k in 0..<u32(3) {p[k]=levels.vertices[levels.indices[range.first_index+i+k]].position}
            sum+=0.5*linalg.length(linalg.cross(p[1]-p[0],p[2]-p[0]))
        }
    }
    return
}

// Leaf cards become opaque outlines seen from both sides whose image fills
// what the mask left empty; cluster cards keep their mask on a convex
// outline. The levels step through the coarser outlines of the leaves before
// they prune them, so level 1 comes long before a leaf is a pixel wide, and
// every level draws at least the area of what the masks keep and not much
// more.
@(test)
masked_cards_are_cut_to_outlines_whose_levels_coarsen_in_steps :: proc(t:^testing.T) {
    r:Reader
    tree_read(&r)
    model_cutouts(&r)
    leaves,clusters:=r.materials[1].info,r.materials[2].info
    testing.expect(t,leaves.alpha_mode==.Opaque && leaves.two_sided,"the leaves are opaque sheets")
    testing.expect(t,clusters.alpha_mode==.Mask && clusters.two_sided,"the clusters keep their mask")
    testing.expect(t,r.images[0].alpha_fill==leaves.alpha_cutoff && r.images[1].alpha_fill==0,"the image of the leaves fills what the mask left empty")
    mesh:=&r.meshes[0]
    testing.expect_value(t,len(mesh.outlines.cards),48)
    testing.expect_value(t,len(mesh.outlines.rungs),48*(OUTLINE_RUNGS-1))
    for sub in mesh.submeshes {
        for index in mesh.indices[sub.first_index:][:sub.index_count] {
            if mesh.vertices[index].material!=sub.slot {testing.expect(t,false,"a vertex of another slot");break}
        }
    }
    // A cluster card is drawn on a few triangles.
    clusters_range:=mesh.submeshes[2]
    testing.expectf(t,clusters_range.slot==2 && clusters_range.index_count/3<=24*6,"the clusters draw %d triangles",clusters_range.index_count/3)
    levels:=mesh_levels(mesh.vertices,mesh.indices,nil,mesh.submeshes,allocator=context.temp_allocator,outlines=mesh.outlines)
    if !levels_valid(t,levels,3) {return}
    testing.expect(t,len(levels.lods)>=4,"several levels")
    // Some level draws every leaf on an outline coarser than level 0 and finer than its quadrilateral.
    stepped:=false
    for lod in levels.lods[1:] {
        for range in levels.submeshes[lod.first_submesh:][:lod.submesh_count] {
            if range.slot==1 && range.index_count/3<levels.submeshes[1].index_count/3 && range.index_count/3>48*2 {stepped=true}
        }
    }
    testing.expect(t,stepped,"the leaves step through an outline between the finest and the coarsest")
    area:=slot_area(levels,levels.lods[0],1)
    quad:=f32(48)*0.3*0.3*0.5*(1+math.sqrt(f32(0.3*0.3+0.35*0.35))/0.15)
    testing.expectf(t,area<0.6*quad,"level 0 draws %f of the %f of the leaf cards",area,quad)
    // Pruning the leaves starts at the radius of a leaf over ISLAND_PIXELS: level 1 is far below it.
    testing.expectf(t,levels.lods[1].error<0.3*0.5/ISLAND_PIXELS,"level 1 takes an error of %f",levels.lods[1].error)
    for lod,k in levels.lods[1:] {
        level_area:=slot_area(levels,lod,1)
        testing.expectf(t,level_area>=0.999*area && level_area<=1.6*area,"level %d draws %f of the leaves, level 0 %f",k+1,level_area,area)
        testing.expect(t,lod.index_count<levels.lods[k].index_count,"a level draws fewer triangles")
    }
    for lod in levels.lods {fmt.printfln("cut tree level: %d triangles, error %.4f, leaves %.4f",lod.index_count/3,lod.error,slot_area(levels,lod,1))}
}
