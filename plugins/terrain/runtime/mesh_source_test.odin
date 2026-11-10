package terrain

import "base:runtime"
import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"

@(test)
mesh_terrain_converts_heightfields_to_open_surfaces_or_closed_solids :: proc(t:^testing.T) {
    height,source:Source
    defer source_destroy(&height);defer source_destroy(&source)
    testing.expect(t,source_make(&height,.Heightfield,{17,1,17},1,4))
    source_set(&height,{8,0,8},3)
    height.revision=9
    merged:geom.Mesh_Buffer;geom.mesh_buffer_init(&merged);defer geom.mesh_buffer_destroy(&merged)
    for depth in ([2]f32{0,6}) {
        testing.expect(t,source_convert_heightfield(&source,&height,depth))
        testing.expect_value(t,source.kind,Source_Kind.Mesh)
        testing.expect_value(t,source.revision,u32(9))
        testing.expect_value(t,len(source.distances.pages),0)
        testing.expect_value(t,len(source.mesh_chunks),16)
        testing.expect(t,source_mesh_collect(&source,&merged))
        testing.expect_value(t,geom.mesh_is_closed(merged.positions[:],merged.indices[:]),depth>0)
        if depth>0 {testing.expect(t,geom.mesh_volume(merged.positions[:],merged.indices[:])>1536)}
        point,normal,hit:=source_ray(&source,{0,10,0},{0,-1,0})
        testing.expect(t,hit && abs(point.y-3)<1e-5 && normal.y>0)
    }
    testing.expect(t,!source_convert_heightfield(&source,&height,-1))
}

@(test)
mesh_terrain_solid_base_fans_stay_local_and_close_partial_chunks :: proc(t:^testing.T) {
    for samples in ([3][3]int{{65,1,65},{66,1,70},{2,1,6}}) {
        height,source:Source
        defer source_destroy(&height);defer source_destroy(&source)
        if !testing.expect(t,source_make(&height,.Heightfield,samples,0.25,32)) {return}
        if !testing.expect(t,source_convert_heightfield(&source,&height,3)) {return}
        merged:geom.Mesh_Buffer;geom.mesh_buffer_init(&merged);defer geom.mesh_buffer_destroy(&merged)
        if !testing.expect(t,source_mesh_collect(&source,&merged)) {return}
        testing.expect(t,geom.mesh_is_closed(merged.positions[:],merged.indices[:]))
        volume:=f32(samples.x-1)*f32(samples.z-1)*0.25*0.25*3
        testing.expect(t,abs(geom.mesh_volume(merged.positions[:],merged.indices[:])-volume)<1e-6*volume)
        if samples.x==65 {testing.expect_value(t,len(merged.indices)/3,9216)}
        for &chunk,i in source.mesh_chunks {
            low,high,_:=chunk_region(&height,chunk_coord(&source,i))
            from,to:=source_point(&height,low),source_point(&height,high)
            mesh:=&chunk.geometry
            top,bottom:=0,0
            for face:=0;face<len(mesh.indices);face+=3 {
                a,b,c:=mesh.positions[mesh.indices[face]],mesh.positions[mesh.indices[face+1]],mesh.positions[mesh.indices[face+2]]
                if a.y==0 && b.y==0 && c.y==0 {top+=1}
                if a.y!= -3 || b.y!= -3 || c.y!= -3 {continue}
                bottom+=1
                testing.expect(t,(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z)<0)
                for p in ([3][3]f32{a,b,c}) {testing.expect(t,p.x>=from.x && p.x<=to.x && p.z>=from.z && p.z<=to.z)}
            }
            testing.expect_value(t,top,2*(high.x-low.x)*(high.z-low.z))
            testing.expect_value(t,bottom,2*(high.x-low.x+high.z-low.z))
            for material in mesh.materials {testing.expect_value(t,material,u32(0))}
        }
    }
}

@(private)
Mesh_Conversion_Failure :: struct {owner:runtime.Allocator,remaining:int}

@(private)
mesh_conversion_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Mesh_Conversion_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
mesh_terrain_solid_conversion_allocation_failures_preserve_source_and_destination :: proc(t:^testing.T) {
    height,source,before:Source
    defer source_destroy(&height);defer source_destroy(&source);defer source_destroy(&before)
    if !testing.expect(t,source_make(&height,.Heightfield,{9,1,9},1,4)) {return}
    height.revision=7;source_set(&height,{4,0,0},0.5)
    if !testing.expect(t,source_convert_heightfield(&source,&height,3)) {return}
    if !testing.expect(t,source_clone(&before,&source,editable=false)) {return}
    for allocations in ([7]int{0,1,2,3,4,8,16}) {
        failure:=Mesh_Conversion_Failure{context.allocator,allocations}
        testing.expect(t,!source_convert_heightfield(&source,&height,5,{mesh_conversion_failure_allocator,&failure}))
        testing.expect_value(t,source.info,before.info)
        for &chunk,i in source.mesh_chunks {testing.expect(t,mesh_equal(&chunk.geometry,&before.mesh_chunks[i].geometry))}
    }
    testing.expect(t,!source_convert_heightfield(&height,&height,3,runtime.nil_allocator()))
    testing.expect_value(t,height.kind,Source_Kind.Heightfield)
    testing.expect_value(t,height.revision,u32(7));testing.expect_value(t,source_value(&height,{4,0,0}),f32(0.5))
    testing.expect(t,source_convert_heightfield(&height,&height,3))
    testing.expect_value(t,height.kind,Source_Kind.Mesh);testing.expect_value(t,height.revision,u32(7))
}

@(test)
mesh_terrain_serializes_materials_attributes_chunks_and_independent_history :: proc(t:^testing.T) {
    box:geom.Mesh_Buffer;geom.mesh_buffer_init(&box);defer geom.mesh_buffer_destroy(&box)
    geom.cube_build(&box,{8,4,8})
    for p in box.positions {append(&box.colors,[4]f32{p.x,p.y,p.z,1})}
    for _ in 0..<len(box.indices)/3 {append(&box.materials,1)}
    slots:=[2]base.Asset_Id{{3,4},{5,6}}
    source,loaded,snapshot:Source
    defer source_destroy(&source);defer source_destroy(&loaded);defer source_destroy(&snapshot)
    testing.expect(t,source_from_mesh(&source,geom.mesh_buffer_view(&box),1,4,slots[:]))
    source.revision=12
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    path:=fmt.tprintf("%s/mesh-roundtrip.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&source,path,{17,18},&types),asset.Error.None)
    id,ok:=source_load(&loaded,path,&types)
    testing.expect(t,ok && id==base.Asset_Id{17,18})
    testing.expect_value(t,loaded.info,source.info)
    testing.expect_value(t,loaded.slots[0],slots[1])
    testing.expect_value(t,loaded.layers[0].material,slots[0])
    for &chunk,i in source.mesh_chunks {testing.expect(t,mesh_equal(&chunk.geometry,&loaded.mesh_chunks[i].geometry))}
    testing.expect(t,source_clone(&snapshot,&loaded,editable=false))
    change:=source_edit(&loaded,{kind=.Raise,center={4,0,0},normal={1,0,0},radius=8,amount=1})
    testing.expect(t,change.changed && change.error==.None)
    for &chunk,i in source.mesh_chunks {testing.expect(t,mesh_equal(&chunk.geometry,&snapshot.mesh_chunks[i].geometry))}
    testing.expect(t,!source_clone(&snapshot,&source,runtime.nil_allocator()))
    testing.expect_value(t,snapshot.revision,u32(12))
}

@(test)
mesh_terrain_surface_brushes_are_local_and_refinement_keeps_seams_closed :: proc(t:^testing.T) {
    height,source:Source
    defer source_destroy(&height);defer source_destroy(&source)
    testing.expect(t,source_make(&height,.Heightfield,{33,1,33},1,4))
    testing.expect(t,source_convert_heightfield(&source,&height,4))
    change:=source_edit(&source,{kind=.Raise,center={-10,0,-10},normal={0.5,1,0},radius=2,amount=0.25})
    testing.expect(t,change.changed && change.error==.None)
    count:=0
    for dirty in source.mesh_changed {if dirty {count+=1}}
    testing.expect(t,count>0 && count<len(source.mesh_chunks)/2)
    merged:geom.Mesh_Buffer;geom.mesh_buffer_init(&merged);defer geom.mesh_buffer_destroy(&merged)
    testing.expect(t,source_mesh_collect(&source,&merged))
    testing.expect(t,geom.mesh_is_closed(merged.positions[:],merged.indices[:]))
    old_triangles:=len(merged.indices)/3
    change=source_edit(&source,{kind=.Refine,center={-12,0,-12},radius=1.5,amount=1,max_edge=0.6})
    testing.expect(t,change.changed && change.error==.None)
    testing.expect(t,source_mesh_collect(&source,&merged))
    testing.expect(t,len(merged.indices)/3>old_triangles)
    testing.expect(t,geom.mesh_is_closed(merged.positions[:],merged.indices[:]))
    change=source_edit(&source,{kind=.Smooth,center={-12,0,-12},radius=3,amount=0.2})
    testing.expect_value(t,change.error,Edit_Error.None)
    testing.expect(t,source_mesh_collect(&source,&merged))
    testing.expect(t,geom.mesh_is_closed(merged.positions[:],merged.indices[:]))
}

@(test)
mesh_terrain_boolean_caves_keep_roofs_and_reject_open_surfaces_atomically :: proc(t:^testing.T) {
    height,source:Source
    defer source_destroy(&height);defer source_destroy(&source)
    testing.expect(t,source_make(&height,.Heightfield,{9,1,9},1,4))
    testing.expect(t,source_convert_heightfield(&source,&height))
    before:=source_cost(&source)
    change:=source_edit(&source,{kind=.Subtract,center={0,-3,3},radius=1.5,amount=1})
    testing.expect_value(t,change.error,Edit_Error.Not_Closed)
    testing.expect(t,!change.changed && source_cost(&source)==before)
    testing.expect(t,source_convert_heightfield(&source,&height,6))
    change=source_edit(&source,{kind=.Subtract,center={0,-3,3},radius=1.5,amount=1})
    testing.expect_value(t,change.error,Edit_Error.None)
    testing.expect(t,change.changed)
    merged:geom.Mesh_Buffer;geom.mesh_buffer_init(&merged);defer geom.mesh_buffer_destroy(&merged)
    testing.expect(t,source_mesh_collect(&source,&merged))
    testing.expect(t,geom.mesh_is_closed(merged.positions[:],merged.indices[:]))
    testing.expect(t,geom.mesh_volume(merged.positions[:],merged.indices[:])<384)
    roof,_,hit:=source_ray(&source,{0,4,3},{0,-1,0})
    testing.expect(t,hit && abs(roof.y)<1e-5)
    wall,_,inside:=source_ray(&source,{0,-3,6},{0,0,-1})
    testing.expect(t,inside && wall.z<3)
}

@(test)
mesh_terrain_runtime_converts_reloads_copies_and_rebuilds_only_changed_sections :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    allocator:=Terrain_Test_Allocator{owner=context.allocator}
    temporary:=Terrain_Test_Allocator{owner=context.temp_allocator}
    context.allocator={terrain_test_allocator,&allocator}
    context.temp_allocator={terrain_test_allocator,&temporary}
    path:=fmt.tprintf("%s/source.terrain",root)
    height,source:Source;defer source_destroy(&height);defer source_destroy(&source)
    testing.expect(t,source_make(&height,.Heightfield,{17,1,17},1,4));height.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{177,188}
    testing.expect_value(t,source_save(&height,path,id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=64}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    worlds:[2]Terrain_Test_World
    defer for &w in worlds {terrain_test_world_free(&w)}
    for &w in worlds {if !terrain_test_world_init(t,&w) {return}}
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    w:=&worlds[0]
    owner:=core.create(&w.entities)
    core.add(&w.ids,owner,{value=1});core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,revision=1,solid=true})
    core.test_world_settle(&w.w);terrain_test_update(w,&resident,&app)
    testing.expect(t,source_convert_heightfield(&source,&height,6));source.revision=2
    terrain_test_write(t,&assets,"source.terrain",&source,id)
    core.edit(&w.terrains,owner).revision=2
    terrain_test_update(w,&resident,&app)
    testing.expect_value(t,w.data.entries[0].source.kind,Source_Kind.Mesh)
    testing.expect_value(t,len(w.chunks.values),16)
    for collider in w.colliders.values {testing.expect_value(t,collider.kind,phys.Collider_Kind.Mesh)}
    for e in w.colliders.entities {testing.expect(t,phys.collider_ready({&w.state},e))}
    before:[16]base.Asset_Id
    for chunk,i in resident.sources[0].chunks[:resident.sources[0].quad.first[1]] {before[i]=chunk.mesh}
    dig(&w.terrain_requests,{kind=.Raise,center={-6,0,-6},normal={0,1,0},radius=0.6,amount=1},owner)
    terrain_test_update(w,&resident,&app)
    changed:=0
    for chunk,i in resident.sources[0].chunks[:resident.sources[0].quad.first[1]] {if chunk.mesh!=before[i] {changed+=1}}
    testing.expect(t,changed>0 && changed<8)
    hit,hit_ok:=phys.raycast({&w.state},{-6,10,-6},{0,-1,0})
    testing.expect(t,hit_ok && abs(hit.point.y-1)<1e-4)
    version,structure,built:=w.statics.version,assets.structure,resident.stats.built
    calls,temps:=allocator.requests,temporary.requests
    for _ in 0..<10 {terrain_test_update(w,&resident,&app)}
    stable_calls,stable_temps:=allocator.requests,temporary.requests
    testing.expect_value(t,stable_calls,calls);testing.expect_value(t,stable_temps,temps)
    testing.expect_value(t,w.statics.version,version);testing.expect_value(t,assets.structure,structure);testing.expect_value(t,resident.stats.built,built)
    cloned:=&worlds[1];core.test_world_copy(&cloned.w,&w.w)
    dig(&cloned.terrain_requests,{kind=.Raise,center={-6,1,-6},normal={0,1,0},radius=0.6,amount=1},owner)
    terrain_test_update(cloned,&resident,&app)
    point,_,found:=source_ray(&w.data.entries[0].source,{-6,10,-6},{0,-1,0})
    testing.expect(t,found && abs(point.y-1)<1e-4)
    hit,hit_ok=phys.raycast({&cloned.state},{-6,10,-6},{0,-1,0})
    testing.expect(t,hit_ok && abs(hit.point.y-2)<1e-4)
    terrain_test_update(w,&resident,&app)
    height.revision=1;terrain_test_write(t,&assets,"source.terrain",&height,id)
    core.edit(&w.terrains,owner).revision=1
    terrain_test_update(w,&resident,&app)
    testing.expect_value(t,w.data.entries[0].source.kind,Source_Kind.Heightfield)
    for collider in w.colliders.values {testing.expect_value(t,collider.kind,phys.Collider_Kind.Heightfield)}
    testing.expect(t,source_make(&height,.Heightfield,{9,1,9},1,4));height.revision=4
    terrain_test_write(t,&assets,"source.terrain",&height,id)
    core.edit(&w.terrains,owner).revision=4
    terrain_test_update(w,&resident,&app)
    testing.expect_value(t,len(w.chunks.values),4)
    testing.expect_value(t,w.entities.alive,5)
    testing.expect_value(t,w.problems.count,0)
}

@(test)
mesh_terrain_budget_failure_keeps_geometry_and_dirty_state_unchanged :: proc(t:^testing.T) {
    source,snapshot:Source;defer source_destroy(&source);defer source_destroy(&snapshot)
    testing.expect(t,source_make(&source,.Mesh,{9,1,9},1,4))
    testing.expect(t,source_clone(&snapshot,&source))
    change:=source_edit(&source,{kind=.Refine,center={0,0,0},radius=3,amount=1,max_edge=0.5},source_cost(&source))
    testing.expect(t,!change.changed && change.error==.Budget)
    for &chunk,i in source.mesh_chunks {testing.expect(t,mesh_equal(&chunk.geometry,&snapshot.mesh_chunks[i].geometry));testing.expect(t,!source.mesh_changed[i])}
}

@(test)
mesh_terrain_reload_updates_collision_halo_across_a_hard_normal_seam :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/source.terrain",root)
    geometry:geom.Mesh_Buffer;geom.mesh_buffer_init(&geometry);defer geom.mesh_buffer_destroy(&geometry)
    append(&geometry.positions,[3]f32{-4,0,-2},{0,0,-2},{-4,0,2},{0,0,2},{0,0,-2},{4,0,-2},{0,0,2},{4,0,2})
    append(&geometry.indices,0,2,1,1,2,3,4,6,5,5,6,7)
    for i in 0..<8 {append(&geometry.normals,i<4?[3]f32{0,1,0}:[3]f32{0,0.8,0.6})}
    source,old:Source;defer source_destroy(&source);defer source_destroy(&old)
    testing.expect(t,source_from_mesh(&source,geom.mesh_buffer_view(&geometry),1,4))
    source.revision=1
    testing.expect(t,source_clone(&old,&source))
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{211,212}
    testing.expect_value(t,source_save(&source,path,id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=16}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&w.entities)
    core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY);
    core.add(&w.terrains,owner,Terrain{source=id,revision=1,solid=true})
    core.test_world_settle(&w.w);terrain_test_update(&w,&resident,&app)
    original:=resident.sources[0].chunks[1].mesh
    mask:=host.assets_mesh_disabled_edges(&assets,original)
    previous_mask:=make([]u8,len(mask));defer delete(previous_mask)
    copy(previous_mask,mask)
    testing.expect(t,len(mask)>0 && mask[0]!=0)
    change:=source_edit(&source,{kind=.Lower,center={-4,0,0},normal={0,1,0},radius=3,amount=1})
    testing.expect(t,change.changed && change.error==.None)
    testing.expect(t,mesh_equal(&source.mesh_chunks[1].geometry,&old.mesh_chunks[1].geometry))
    testing.expect(t,source.mesh_changed[1])
    source.revision=2
    terrain_test_write(t,&assets,"source.terrain",&source,id)
    core.edit(&w.terrains,owner).revision=2
    terrain_test_update(&w,&resident,&app)
    replacement:=resident.sources[0].chunks[1].mesh
    testing.expect(t,replacement!=original)
    changed_mask:=host.assets_mesh_disabled_edges(&assets,replacement)
    testing.expect(t,len(changed_mask)==len(previous_mask) && changed_mask[0]!=previous_mask[0])
    testing.expect_value(t,resident.stats.built,u64(4))
    testing.expect_value(t,w.problems.count,0)
}
