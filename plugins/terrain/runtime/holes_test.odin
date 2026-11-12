package terrain

import "core:fmt"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

@(test)
holes_are_cut_and_filled_by_cells_and_round_trip_in_the_terrain_file :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    source,loaded,cloned:Source
    defer source_destroy(&source);defer source_destroy(&loaded);defer source_destroy(&cloned)
    testing.expect(t,source_make(&source,.Heightfield,{17,1,17},1,8))
    testing.expect_value(t,source_edit(&source,{kind=.Fill,center={},radius=2}).changed,false)
    testing.expect_value(t,len(source.holes.pages),0)
    // The cell [8,8] spans 0..1 in X and Z: its center is 0.5,0.5.
    change:=source_edit(&source,{kind=.Hole,center={0.5,0,0.5},radius=0.6})
    testing.expect(t,change.changed && change.error==.None)
    testing.expect(t,source_hole(&source,8,8))
    testing.expect(t,!source_hole(&source,7,8) && !source_hole(&source,9,8))
    testing.expect_value(t,change.low,[3]int{8,0,8});testing.expect_value(t,change.high,[3]int{9,0,9})
    testing.expect(t,source_edit(&source,{kind=.Hole,center={-4.5,0,-4.5},radius=1.2}).changed)
    testing.expect(t,source_hole(&source,3,3) && source_hole(&source,4,3) && !source_hole(&source,5,5))
    path:=fmt.tprintf("%s/holes.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&source,path,{9,9},&types),asset.Error.None)
    _,ok:=source_load(&loaded,path,&types)
    testing.expect(t,ok && grid_equal(&loaded.holes,&source.holes))
    testing.expect(t,source_clone(&cloned,&loaded))
    testing.expect(t,source_edit(&cloned,{kind=.Fill,center={0.5,0,0.5},radius=0.6}).changed)
    testing.expect(t,!source_hole(&cloned,8,8) && source_hole(&loaded,8,8))
    volume:Source;defer source_destroy(&volume)
    testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,4))
    testing.expect_value(t,source_edit(&volume,{kind=.Hole,center={},radius=1}).error,Edit_Error.Kind)
    plain:Source;defer source_destroy(&plain)
    testing.expect(t,source_make(&plain,.Heightfield,{9,1,9},1,4))
    testing.expect_value(t,source_save(&plain,path,{9,9},&types),asset.Error.None)
    file:asset.Asset
    testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None)
    defer asset.asset_close(&file)
    _,has_holes:=asset.asset_table(&file,"hole_pages")
    testing.expect(t,!has_holes,"a source without holes stores none")
}

@(test)
holes_leave_no_triangles_picking_or_flat_edges_and_keep_the_collider_samples :: proc(t:^testing.T) {
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{17,1,17},1,8))
    testing.expect(t,source_edit(&source,{kind=.Hole,center={0.5,0,0.5},radius=0.6}).changed)
    _,_,through:=source_ray(&source,{0.5,10,0.5},{0,-1,0})
    testing.expect(t,!through)
    _,_,beside:=source_ray(&source,{1.5,10,0.5},{0,-1,0})
    testing.expect(t,beside)
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    // The hole is the corner cell of chunk [1,0,1].
    testing.expect(t,chunk_build(&source,{1,0,1},&mesh))
    testing.expect_value(t,len(mesh.geometry.indices),(64-1)*6)
    testing.expect_value(t,len(mesh.heights),81)
    testing.expect_value(t,len(mesh.holes),64)
    testing.expect_value(t,mesh.holes[0],u8(1))
    // The edges of chunk [0,0,1] and [1,0,0] across from the hole stay borders.
    testing.expect(t,chunk_build(&source,{0,0,1},&mesh))
    testing.expect_value(t,mesh.disabled_borders[8],u8(0))
    testing.expect_value(t,mesh.disabled_borders[9],u8(1))
    testing.expect_value(t,len(mesh.holes),64)
    testing.expect(t,chunk_holed(&source,chunk_index(&source,{1,0,1})))
    testing.expect(t,!chunk_holed(&source,chunk_index(&source,{0,0,1})))
}

// A chunk with holes keeps its level far away: its collider has every hole,
// and its material cuts those its coarse triangles span.
@(test)
bodies_fall_through_holes_cut_at_run_time_and_far_holed_chunks_cut_them_by_their_material :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{65,1,65},1,16))
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{87,88}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&w.entities)
    core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,solid=true})
    test_world_settle(&w.w)
    view:=core.VIEW_DEFAULT
    view.position={-30,2,-30}
    settings:=Terrain_Settings{lod_distance=8}
    for _ in 0..<2 {terrain_test_update(&w,&resident,&app,view=view,settings=settings)}
    far:=chunk_index(&w.data.entries[0].source,{3,0,3})
    testing.expect(t,resident.sources[0].chunks[far].built.lod.level>0)
    _,hit:=phys.raycast({&w.state},{28.5,10,28.5},{0,-1,0})
    testing.expect(t,hit)
    dig(&w.terrain_requests,{kind=.Hole,center={28.5,0,28.5},radius=0.6},owner)
    terrain_test_update(&w,&resident,&app,view=view,settings=settings)
    chunk:=resident.sources[0].chunks[far]
    testing.expect(t,chunk.built.lod.level>0 && chunk.shape.holed)
    shown:=resident.owners[0].chunks[far]
    if static,has:=core.get(&w.statics,shown);testing.expect(t,has) {testing.expect_value(t,static.materials[0],LAYERS_HOLED_MATERIAL)}
    testing.expect(t,w.data.entries[0].source.revision==2)
    _,hit=phys.raycast({&w.state},{28.5,10,28.5},{0,-1,0})
    testing.expect(t,!hit,"the collider has the hole")
    _,hit=phys.raycast({&w.state},{27.5,10,28.5},{0,-1,0})
    testing.expect(t,hit)
    dig(&w.terrain_requests,{kind=.Fill,center={28.5,0,28.5},radius=0.6},owner)
    terrain_test_update(&w,&resident,&app,view=view,settings=settings)
    _,hit=phys.raycast({&w.state},{28.5,10,28.5},{0,-1,0})
    testing.expect(t,hit)
    testing.expect(t,resident.sources[0].chunks[far].built.lod.level>0 && !resident.sources[0].chunks[far].shape.holed)
    testing.expect_value(t,w.problems.count,0)
}

// The coarse grid holds what share of each of its cells is holes: a node far
// away leaves out the triangles over holes alone and cuts by its maps those
// over a hole of half its texel or more, and the ground answers no surface
// there, whatever pages are in memory.
@(test)
far_nodes_and_the_coarse_ground_keep_the_holes_the_coarse_grid_holds :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{129,1,129},1,16))
    // A pit of 24 cells a side from cell 40, and one cell alone at 100.
    for z in 40..<64 {for x in 40..<64 {testing.expect(t,source_edit(&s,{kind=.Hole,center=source_point(&s,{x,0,z})+{0.5,0,0.5},radius=0.4}).changed)}}
    testing.expect(t,source_edit(&s,{kind=.Hole,center=source_point(&s,{100,0,100})+{0.5,0,0.5},radius=0.4}).changed)
    counts:=chunk_counts(&s)
    ranges:=make([][2]f32,counts.x*counts.z);defer delete(ranges)
    testing.expect(t,source_coarse_build(&s,ranges))
    testing.expect_value(t,grid_get(&s.coarse.holes,5,5),u8(255))
    testing.expect_value(t,grid_get(&s.coarse.holes,4,4),u8(0))
    testing.expect_value(t,grid_get(&s.coarse.holes,12,12),u8(4))
    q:=quad_of(&s)
    node:=quad_index(&q,2,{0,0})
    border:Piece_Border;defer piece_border_destroy(&border)
    for i in 0..<4 {append(&border.sides[i],..[]u8{3,3,3,3});append(&border.corners[i],..[]u8{3,3,3,3,3})}
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,node_build(&s,&q,node,{level=3},&border,&mesh))
    m:=&mesh.maps
    testing.expect_value(t,m.spacing,4)
    testing.expect(t,m.control[12+m.size.x*12]&WEIGHT_HOLE!=0,"the texel inside the pit is a hole")
    testing.expect(t,m.control[2+m.size.x*2]&WEIGHT_HOLE==0)
    // No triangle lies inside the pit.
    origin:=chunk_origin(&s,quad_place(&s,&q,node))
    for corner:=0;corner+2<len(mesh.geometry.indices);corner+=3 {
        c:=(mesh.geometry.positions[mesh.geometry.indices[corner]]+mesh.geometry.positions[mesh.geometry.indices[corner+1]]+mesh.geometry.positions[mesh.geometry.indices[corner+2]])/3+origin-source_origin(&s)
        testing.expect(t,!(c.x>41 && c.x<63 && c.z>41 && c.z<63),"a triangle over the pit")
    }
    inside:=source_point(&s,{52,0,52})
    _,_,_,ok:=source_coarse_at(&s,inside.x,inside.z)
    testing.expect(t,!ok,"the ground over the pit is no surface")
    testing.expect(t,!source_hole(&s,30,30))
}

// The tangents a Heightfield chunk gives its vertices are those MikkTSpace
// finds for its grid of uvs, along its slopes too.
@(test)
heightfield_tangents_are_those_mikktspace_gives_the_grid :: proc(t:^testing.T) {
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{17,1,17},1,8))
    testing.expect(t,source_edit(&source,{kind=.Raise,center={4,0,4},radius=5,amount=3}).changed)
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&source,{0,0,0},&mesh))
    m:=&mesh.geometry
    given:=make([][4]f32,len(m.normals),context.temp_allocator)
    heightfield_tangents(m.normals[:],given)
    corners:=make([][4]f32,len(m.indices),context.temp_allocator)
    testing.expect(t,geom.corner_tangents(m.positions[:],m.normals[:],m.uvs[:],m.indices[:],corners))
    worst:=f32(1)
    for index,at in m.indices {
        a,b:=given[index],corners[at]
        testing.expect(t,a.w==b.w,"the sign of the bitangent")
        worst=min(worst,a.x*b.x+a.y*b.y+a.z*b.z)
    }
    testing.expectf(t,worst>0.99,"the tangents part by %v",worst)
}

// What the job of a Heightfield chunk makes for the renderer is the chunk as
// it is: its triangles, in its one slot, with the tangents of
// its grid.
@(test)
a_heightfield_chunk_prepares_its_render_geometry_where_it_is_built :: proc(t:^testing.T) {
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{17,1,17},1,8))
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&source,{1,0,0},&mesh))
    testing.expect(t,chunk_render_prepare(&mesh,{}))
    m:=&mesh.geometry
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    testing.expect(t,asset.mesh_level_decode(mesh.render.geometry,0,&vertices,&indices))
    testing.expect_value(t,len(indices),len(m.indices))
    tangents:=make([][4]f32,len(m.normals),context.temp_allocator)
    heightfield_tangents(m.normals[:],tangents)
    // The constructor orders the triangles by place: each corner is the vertex of the chunk where it is.
    for index,k in indices {
        v:=vertices[index]
        i:=0
        for position,at in m.positions {if linalg.length(position-v.position)<linalg.length(m.positions[i]-v.position) {i=at}}
        tangent,sign:=mm.tangent_unpack(v.tangent)
        if linalg.length(v.position-m.positions[i])>1e-3 || linalg.dot(tangent,tangents[i].xyz)<0.99 || sign!=tangents[i].w || v.material!=0 {
            testing.expectf(t,false,"corner %d is not that of the chunk",k)
            break
        }
    }
    testing.expect(t,chunk_build(&source,{0,0,0},&mesh) && !mesh.render_ready,"building again forgets it")
}
