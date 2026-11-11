package terrain

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"

@(test)
terrain_sources_save_load_and_clone_preserve_both_representations :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    for kind in ([2]Source_Kind{.Heightfield,.Volume}) {
        original,loaded,cloned:Source
        defer source_destroy(&original);defer source_destroy(&loaded);defer source_destroy(&cloned)
        samples:=kind==.Heightfield?[3]int{9,1,13}:[3]int{9,7,13}
        testing.expect(t,source_make(&original,kind,samples,0.5,4))
        original.revision=7
        original.layers[0].material={31,u64(kind)}
        at:=kind==.Heightfield?[3]int{8,0,1}:[3]int{8,1,0}
        testing.expect(t,source_set(&original,at,-0.75))
        path:=fmt.tprintf("%s/%v.terrain",base.test_folder(t,"terrain"),kind)
        id:=base.Asset_Id{123,u64(kind)+4}
        testing.expect_value(t,source_save(&original,path,id,&types),asset.Error.None)
        got,ok:=source_load(&loaded,path,&types)
        testing.expect(t,ok && got==id)
        testing.expect_value(t,loaded.info,original.info)
        for z in 0..<samples.z {for y in 0..<samples.y {for x in 0..<samples.x {testing.expect_value(t,source_value(&loaded,{x,y,z}),source_value(&original,{x,y,z}))}}}
        testing.expect(t,source_clone(&cloned,&loaded))
        testing.expect_value(t,cloned.layers[0].material,original.layers[0].material)
        testing.expect(t,source_set(&cloned,at,source_value(&cloned,at)+2))
        testing.expect_value(t,source_value(&loaded,at),f32(-0.75))
        testing.expect_value(t,source_value(&original,at),f32(-0.75))
        if kind==.Heightfield {
            _,page_samples:=grid_page_extent(&loaded.field,0)
            testing.expect_value(t,grid_dense(&loaded.field),page_samples)
            testing.expect_value(t,raw_data(cloned.field.pages[0].values)==raw_data(loaded.field.pages[0].values),false)
        } else {testing.expect_value(t,raw_data(cloned.field.pages[0].values)==raw_data(loaded.field.pages[0].values),false)}
    }
}

@(test)
terrain_sources_reject_invalid_dimensions_values_and_unavailable_memory :: proc(t:^testing.T) {
    source:Source;defer source_destroy(&source)
    testing.expect(t,!source_make(&source,.Heightfield,{5,2,5},1,4))
    testing.expect(t,!source_make(&source,.Volume,{5,1,5},1,4))
    // A Volume reaches as far as a Heightfield; past its chunks it takes more cells in each.
    testing.expect(t,!source_make(&source,.Volume,{SAMPLES_MAX+1,5,5},1,4))
    testing.expect(t,!source_make(&source,.Volume,{4097,4097,4097},1,4) && source_valid({kind=.Volume,samples={4097,4097,4097},cell=1,chunk_cells=256,layer_count=1,layers={0=LAYER_DEFAULT}}))
    testing.expect(t,!source_make(&source,.Heightfield,{5,1,5},0,4))
    testing.expect(t,!source_make(&source,.Heightfield,{5,1,5},1,3))
    testing.expect(t,!source_make(&source,.Heightfield,{5,1,5},1,4,runtime.nil_allocator()))
    testing.expect(t,source_make(&source,.Volume,{3,3,3},1,4))
    testing.expect(t,source_value(&source,{1,1,1})<0)
    source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{5,1,5},1,4))
    source.field.pages[0].fill=f32(0h7fc00000)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    path:=fmt.tprintf("%s/invalid.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&source,path,{1,2},&types),asset.Error.Invalid)
    source.field.pages[0].fill=0
    testing.expect(t,source_set(&source,{0,0,0},HEIGHT_LIMIT+1))
    testing.expect_value(t,source_save(&source,path,{1,2},&types),asset.Error.Invalid)
}

@(test)
terrain_resident_and_snapshot_allocation_failures_return_without_indexing_missing_storage :: proc(t:^testing.T) {
    assets:=host.Assets{allocator=runtime.nil_allocator()}
    resident:=Terrain_Resident{assets=&assets}
    entry:=Data_Source{id={1,2},versions={1},quad={first={1=1}}}
    problems:core.Problems
    testing.expect(t,resident_source(&resident,&entry,core.Entity(2),&problems)==nil)
    testing.expect(t,resident_owner(&resident,core.Entity(1),&entry,&problems)==nil)
    testing.expect(t,core.problem_find(&problems,core.Entity(2),"terrain.memory")!=nil)
    testing.expect(t,core.problem_find(&problems,core.Entity(1),"terrain.memory")!=nil)
    source,destination:Terrain_Data
    source.settings=TERRAIN_SETTINGS_DEFAULT
    source.ready=true
    context.allocator=runtime.nil_allocator()
    testing.expect(t,!terrain_data_copy(&destination,&source))
    testing.expect(t,!destination.ready)
}

@(test)
chunk_collision_masks_remove_flat_seams_and_preserve_convex_crests_and_source_borders :: proc(t:^testing.T) {
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    height:Source;testing.expect(t,source_make(&height,.Heightfield,{9,1,9},1,4));defer source_destroy(&height)
    testing.expect(t,chunk_build(&height,{0,0,0},&mesh))
    for i in 0..<4 {testing.expect_value(t,mesh.disabled_borders[i],u8(0));testing.expect_value(t,mesh.disabled_borders[4+i],u8(1))}
    source_set(&height,{4,0,0},2)
    source_set(&height,{4,0,1},2)
    testing.expect(t,chunk_build(&height,{0,0,0},&mesh))
    testing.expect_value(t,mesh.disabled_borders[4],u8(0))
    testing.expect_value(t,mesh.disabled_borders[7],u8(1))
    volume:Source;testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,4));defer source_destroy(&volume)
    for crease in ([2]bool{false,true}) {
        for z in 0..<9 {for y in 0..<9 {for x in 0..<9 {
            p:=source_point(&volume,{x,y,z})
            source_set(&volume,{x,y,z},p.y+(crease?abs(p.x):0))
        }}}
        testing.expect(t,chunk_build(&volume,{0,0,0},&mesh))
        chunk_in_terrain(&mesh)
        seams:=0
        for triangle:=0;triangle<len(mesh.geometry.indices);triangle+=3 {
            for edge in 0..<3 {
                a:=mesh.geometry.positions[mesh.geometry.indices[triangle+edge]]
                b:=mesh.geometry.positions[mesh.geometry.indices[triangle+(edge+1)%3]]
                disabled:=mesh.disabled_edges[triangle/3] & u8(1<<uint(edge))!=0
                if a.x==0 && b.x==0 {testing.expect_value(t,disabled,!crease);seams+=1}
                if a.x== -4 && b.x== -4 {testing.expect(t,!disabled)}
            }
        }
        testing.expect(t,seams>0)
    }
}

@(test)
chunk_visual_build_preserves_geometry_and_reuses_collision_buffers_for_all_sources :: proc(t:^testing.T) {
    height,volume:Source
    defer source_destroy(&height);defer source_destroy(&volume)
    if !testing.expect(t,source_make(&height,.Heightfield,{9,1,9},1,4)) {return}
    source_set(&height,{3,0,3},0.75)
    if !testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,4)) {return}
    reused:Chunk_Mesh;chunk_mesh_init(&reused);defer chunk_mesh_destroy(&reused)
    for source in ([2]^Source{&height,&volume}) {
        expected:Chunk_Mesh;chunk_mesh_init(&expected);defer chunk_mesh_destroy(&expected)
        if !testing.expect(t,chunk_build(source,{0,0,0},&expected)) {return}
        testing.expect(t,len(expected.geometry.indices)>0)
        testing.expect(t,len(expected.disabled_edges)>0 || len(expected.disabled_borders)>0)
        for collision in ([5]bool{false,true,false,true,false}) {
            if !testing.expect(t,chunk_build(source,{0,0,0},&reused,collision)) {return}
            a,b:=&reused.geometry,&expected.geometry
            testing.expect(t,slice.equal(a.positions[:],b.positions[:]))
            testing.expect(t,slice.equal(a.normals[:],b.normals[:]))
            testing.expect(t,slice.equal(a.uvs[:],b.uvs[:]))
            testing.expect(t,slice.equal(a.colors[:],b.colors[:]))
            testing.expect(t,slice.equal(a.indices[:],b.indices[:]))
            testing.expect(t,slice.equal(a.materials[:],b.materials[:]))
            if testing.expect_value(t,len(reused.uv1s),len(expected.uv1s)) {
                for uv,i in expected.uv1s {testing.expect_value(t,reused.uv1s[i],uv)}
            }
            if collision {
                if testing.expect_value(t,len(reused.disabled_edges),len(expected.disabled_edges)) {
                    for mask,i in expected.disabled_edges {testing.expect_value(t,reused.disabled_edges[i],mask)}
                }
                if testing.expect_value(t,len(reused.disabled_borders),len(expected.disabled_borders)) {
                    for mask,i in expected.disabled_borders {testing.expect_value(t,reused.disabled_borders[i],mask)}
                }
                if testing.expect_value(t,len(reused.heights),len(expected.heights)) {
                    for height,i in expected.heights {testing.expect_value(t,reused.heights[i],height)}
                }
                testing.expect_value(t,reused.columns,expected.columns);testing.expect_value(t,reused.rows,expected.rows)
                testing.expect_value(t,reused.origin,expected.origin);testing.expect_value(t,reused.cell,expected.cell)
            } else {
                testing.expect_value(t,len(reused.disabled_edges),0);testing.expect_value(t,len(reused.disabled_borders),0)
                testing.expect_value(t,len(reused.heights),0)
                testing.expect_value(t,reused.columns,0);testing.expect_value(t,reused.rows,0)
                testing.expect_value(t,reused.origin,expected.origin);testing.expect_value(t,reused.cell,[3]f32{})
            }
        }
    }
}

@(test)
heightfield_queries_and_meshes_use_the_physics_diagonal_and_high_surfaces_sculpt :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{2,1,2},1,4));defer source_destroy(&source)
    testing.expect(t,source_set(&source,{1,0,1},2))
    testing.expect_value(t,source_height(&source,-0.25,-0.25),f32(0))
    testing.expect_value(t,source_height(&source,0.25,0.25),f32(1))
    for xz in ([2][2]f32{{-0.25,-0.25},{0.25,0.25}}) {
        hit,normal,ok:=source_ray(&source,{xz.x,10,xz.y},{0,-1,0})
        testing.expect(t,ok && normal.y>0)
        testing.expectf(t,abs(hit.y-source_height(&source,xz.x,xz.y))<1e-6,"height query and ray differ")
    }
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&source,{0,0,0},&mesh))
    expected:=[6]u32{0,2,1,1,2,3}
    for index,i in mesh.geometry.indices {testing.expect_value(t,index,expected[i])}
    for z in 0..<2 {for x in 0..<2 {testing.expect(t,source_set(&source,{x,0,z},100))}}
    change:=source_edit(&source,{kind=.Raise,center={-0.5,100,-0.5},radius=0.4,amount=2})
    testing.expect(t,change.changed)
    testing.expect_value(t,source_value(&source,{0,0,0}),f32(102))
    testing.expect_value(t,source.revision,u32(0))
}

@(test)
terrain_brushes_mark_only_touched_chunks_including_border_normals :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{65,1,65},1,16));defer source_destroy(&source)
    change:=source_edit(&source,{kind=.Raise,center={0,0,0},radius=0.4,amount=1})
    low,high:=chunk_range(&source,change)
    testing.expect_value(t,low,[3]int{1,0,1});testing.expect_value(t,high,[3]int{2,0,2})
    count:=0
    for z in 0..<4 {for x in 0..<4 {if chunk_touched(&source,{i32(x),0,i32(z)},change) {count+=1}}}
    testing.expect_value(t,count,4)
    testing.expect(t,source_edit(&source,{kind=.Smooth,center={0,50,0},radius=0.4,amount=1}).changed)
    held:=raw_data(source.field.pages[0].values)
    scratch:=raw_data(source.scratch)
    source.allocator=runtime.nil_allocator()
    testing.expect(t,source_edit(&source,{kind=.Lower,center={0,50,0},radius=0.4,amount=0.5}).changed)
    testing.expect(t,source_edit(&source,{kind=.Smooth,center={0,50,0},radius=0.4,amount=1}).changed)
    source.allocator=context.allocator
    testing.expect_value(t,source_value(&source,{32,0,32}),f32(0))
    testing.expect_value(t,raw_data(source.field.pages[0].values),held);testing.expect_value(t,raw_data(source.scratch),scratch)
    _,page_samples:=grid_page_extent(&source.field,0)
    testing.expect_value(t,grid_dense(&source.field),page_samples)
    source.allocator=runtime.nil_allocator()
    testing.expect_value(t,source_edit(&source,{kind=.Raise,center={32,0,32},radius=0.4,amount=1}).error,Edit_Error.Out_Of_Memory)
    source.allocator=context.allocator
    testing.expect_value(t,source_value(&source,{64,0,64}),f32(0))
}

@(test)
volume_removal_creates_a_cavity_with_a_roof_and_addition_refills_it :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Volume,{17,17,17},1,8));defer source_destroy(&source)
    center:=[3]f32{0,-3,0}
    testing.expect(t,source_density(&source,center)<0)
    testing.expect(t,source_edit(&source,{kind=.Carve,center=center,radius=1.5,amount=1}).changed)
    testing.expect(t,source_density(&source,center)>0)
    for direction in ([2][3]f32{{0,1,0},{0,-1,0}}) {
        point,normal,ok:=source_ray(&source,center,direction)
        testing.expect(t,ok)
        testing.expectf(t,abs(point.y-(center.y+direction.y*1.5))<1e-3,"cavity surface %v",point)
        testing.expect(t,normal.y*direction.y<0)
    }
    part:Chunk_Mesh;chunk_mesh_init(&part);defer chunk_mesh_destroy(&part)
    combined,welded:geom.Mesh_Buffer;geom.mesh_buffer_init(&combined);geom.mesh_buffer_init(&welded)
    defer geom.mesh_buffer_destroy(&combined);defer geom.mesh_buffer_destroy(&welded)
    n:=chunk_counts(&source)
    for i in 0..<n.x*n.y*n.z {
        testing.expect(t,chunk_build(&source,chunk_coord(&source,i),&part))
        chunk_in_terrain(&part)
        offset:=u32(len(combined.positions))
        append(&combined.positions,..part.geometry.positions[:])
        for index in part.geometry.indices {append(&combined.indices,index+offset)}
    }
    geom.mesh_weld(geom.mesh_buffer_view(&combined),0,&welded)
    testing.expect(t,geom.mesh_topology_is_closed(geom.mesh_topology(welded.positions[:],welded.indices[:],by_position=false)))
    testing.expect(t,source_edit(&source,{kind=.Add,center=center,radius=1.5,amount=1}).changed)
    testing.expect(t,source_density(&source,center)<0)
}

@(test)
volume_picking_hits_the_tetra_surface :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Volume,{3,3,3},1,4));defer source_destroy(&source)
    testing.expect(t,grid_init(&source.field,source.field.size,1,source.allocator))
    testing.expect(t,source_set(&source,{0,0,0},-1))
    context.allocator=runtime.nil_allocator()
    for _ in 0..<4 {
        hit,normal,ok:=source_ray(&source,{-1,-1,-1},{1,1,1})
        testing.expect(t,ok)
        for coordinate in hit {testing.expectf(t,abs(coordinate+0.5)<1e-6,"tetra body diagonal hit %v",hit)}
        testing.expect(t,normal.x+normal.y+normal.z>0)
        testing.expectf(t,source_density(&source,hit)>0.7,"the trilinear field intentionally differs from the tetra surface")
    }
}

@(test)
published_chunks_keep_heightfield_geometry_uv_channels_and_immutable_lifetimes :: proc(t:^testing.T) {
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root="assets",capacity=8}));defer host.assets_destroy(&assets)
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{9,1,9},2,4));defer source_destroy(&source)
    source_set(&source,{5,0,4},3)
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&source,{1,0,1},&mesh))
    id,ok:=chunk_publish(&assets,&mesh);testing.expect(t,ok)
    field,found:=host.assets_heightfield(&assets,id);testing.expect(t,found)
    testing.expect_value(t,field.origin,[3]f32{0,0,0})
    testing.expect_value(t,field.cell,[3]f32{2,1,2})
    testing.expect_value(t,field.columns,5);testing.expect_value(t,field.rows,5)
    testing.expect_value(t,field.heights[1],f32(3))
    source_set(&source,{5,0,4},10)
    testing.expect(t,chunk_build(&source,{1,0,1},&mesh))
    next,added:=chunk_publish(&assets,&mesh);testing.expect(t,added && next!=id)
    testing.expect_value(t,field.heights[1],f32(3))
    testing.expect(t,host.assets_mesh_release(&assets,id))
    _,found=host.assets_heightfield(&assets,id);testing.expect(t,!found)
    new_field,new_found:=host.assets_heightfield(&assets,next);testing.expect(t,new_found)
    testing.expect_value(t,new_field.heights[1],f32(10))
    testing.expect(t,host.assets_mesh_release(&assets,next))
}

// A chunk back in the space of its terrain, where tests compare chunks with
// each other and with the source.
chunk_in_terrain :: proc(mesh:^Chunk_Mesh) {
    for &p in mesh.geometry.positions {p+=mesh.origin}
}

// A chunk far from the centre of a terrain of kilometres is in its own space:
// its vertices stay within it.
@(test)
chunks_far_from_the_centre_of_a_large_terrain_keep_their_own_space :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{1025,1,1025},15.3,64));defer source_destroy(&source)
    for z in 960..<1025 {for x in 960..<1025 {source_set(&source,{x,0,z},f32(x%7)*0.25)}}
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    coord:=[3]i32{15,0,15}
    testing.expect(t,chunk_build(&source,coord,&mesh,false))
    testing.expect_value(t,mesh.origin,chunk_origin(&source,coord))
    testing.expect(t,mesh.origin.x>6800 && mesh.origin.z>6800)
    size:=f32(64)*15.3
    for p in mesh.geometry.positions {testing.expect(t,p.x>=0 && p.x<=size+1e-3 && p.z>=0 && p.z<=size+1e-3)}
}
