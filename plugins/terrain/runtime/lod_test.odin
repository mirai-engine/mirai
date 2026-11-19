package terrain

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import camera "mirai:engine/camera"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"

// The coarsest level of a chunk leaves a sample inside it along each axis;
// a Volume has no levels of its own.
@(test)
the_coarsest_level_of_a_chunk_leaves_a_sample_inside_it :: proc(t:^testing.T) {
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{70,1,70},1,64))
    testing.expect_value(t,chunk_lod_max(&source,{0,0,0}),u8(5))
    testing.expect_value(t,chunk_lod_max(&source,{1,0,0}),u8(1))
    volume:Source;defer source_destroy(&volume)
    testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,8))
    testing.expect_value(t,chunk_lod_max(&volume,{0,0,0}),u8(0))
}

// Every chunk of a Heightfield shows every sample in the levels of its
// clusters, which each view chooses, solid or not: a view that moves over it,
// near its far end or on a split screen, builds no piece again and changes no
// mesh it shows, so the maps of the shadows draw nothing again; the colliders
// keep every sample.
@(test)
a_view_that_moves_over_a_heightfield_changes_no_mesh_of_it :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{129,1,129},1,16))
    for z in 0..<129 {for x in 0..<129 {testing.expect(t,source_set(&source,{x,0,z},0.3*math.sin(f32(x)*0.7)*math.cos(f32(z)*0.5)))}}
    // A bump of one sample, far from the view, which its collider keeps.
    testing.expect(t,source_set(&source,{121,0,121},3))
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{77,78}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    for solid in ([2]bool{true,false}) {
        assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
        app:=host.App{assets=&assets,allocator=context.allocator}
        w:Terrain_Test_World
        if !terrain_test_world_init(t,&w) {return}
        defer terrain_test_world_free(&w)
        resident:Terrain_Resident;defer terrain_resident_free(&resident)
        owner:=core.create(&w.entities)
        core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
        core.add(&w.terrains,owner,Terrain{source=id,solid=solid})
        test_world_settle(&w.w)
        view:=core.VIEW_DEFAULT
        view.position={-60,5,-60}
        view.size={1440,900}
        for _ in 0..<3 {terrain_test_update(&w,&resident,&app,view=view,settings={})}
        chunks:=resident.sources[0].chunks[:64]
        meshes:[64]base.Asset_Id
        for &chunk,i in chunks {
            testing.expectf(t,chunk.shown && chunk.mesh!={} && !chunk.bare && chunk.built.lod==Chunk_Lod{},"solid %v: chunk %d shows %v",solid,i,chunk.built.lod)
            meshes[i]=chunk.mesh
        }
        built,released:=resident.stats.built,resident.stats.released
        locals:camera.Camera_Views
        for &slot in locals.slots[:2] {slot.camera,slot.pose.fov=owner,view.fov}
        for position in ([?][3]f32{{-59.9,5,-60},{0,40,0},{60,2,60},{120,1,120}}) {
            view.position=position
            terrain_test_update(&w,&resident,&app,view=view,settings={})
            locals.slots[0].pose.position,locals.slots[1].pose.position=position,{-60,5,-60}
            terrain_test_update(&w,&resident,&app,view=view,settings={},locals=core.ref(&locals))
        }
        // Far above it, alone, for as long as anything would take to build.
        view.position={0,1500,0}
        for _ in 0..<4 {terrain_test_update(&w,&resident,&app,view=view,settings={})}
        for &chunk,i in chunks {testing.expectf(t,chunk.mesh==meshes[i],"solid %v: chunk %d took another mesh",solid,i)}
        testing.expect_value(t,resident.stats.built,built)
        testing.expect_value(t,resident.stats.released,released)
        if solid {
            hit,ok:=phys.raycast({&w.state},{57,20,57},{0,-1,0})
            testing.expect(t,ok && abs(hit.point.y-3)<1e-4,"the collider keeps the sample")
        }
        testing.expect_value(t,w.problems.count,0)
    }
}

@(private)
lod_seam_source :: proc(t:^testing.T,s:^Source) {
    testing.expect(t,source_make(s,.Heightfield,{69,1,69},0.5,16))
    for z in 0..<69 {for x in 0..<69 {source_set(s,{x,0,z},math.sin(f32(x)*0.37)*2+math.cos(f32(z)*0.23)*3+f32((x*7+z*13)%5)*0.1)}}
}
