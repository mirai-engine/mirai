package terrain

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// The pieces of terrains far from the origin of the render, on both sides of
// a multiple of its step, as the renderer places them: the entity of each
// piece composed from its terrain, relative to the origin the eye has (the
// multiple of ORIGIN_STEP nearest it), with the bounds of its mesh. Two
// terrains as the edge tiles of the synthetic world of alien-planet (335.28 m
// a side, their corners past +1024 m and -1024 m), seen from (0, 900,
// -1800): each covers its region once, where its terrain is, to the
// millimetre.
@(test)
terrain_pieces_far_from_the_render_origin_cover_their_region_on_both_sides :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    id:=base.Asset_Id{701,702}
    SAMPLES :: 129
    SIDE :: f32(335.28)
    {
        source:Source;testing.expect(t,source_make(&source,.Heightfield,{SAMPLES,1,SAMPLES},SIDE/(SAMPLES-1),16));defer source_destroy(&source)
        for z in 0..<SAMPLES {for x in 0..<SAMPLES {testing.expect(t,source_set(&source,{x,0,z},f32((x*7+z*3)%5)*0.5))}}
        source.revision=1
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    }
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=1024}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=runtime.heap_allocator()}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    // The Landscape under the tiles of index 7 and 0, as the scene composes it.
    landscape:=[3]f32{-167.65868,-1.28911,-167.63974}
    places:=[2][3]f32{{1173.48,0,1173.48}+landscape,{-1173.48,0,-1173.48}+landscape}
    owners:[2]core.Entity
    for place,i in places {
        e:=core.create(&w.entities)
        local:=core.TRANSFORM_IDENTITY
        local.position=place
        core.add(&w.transforms,e,local)
        core.add(&w.worlds,e,core.World_Transform{transform={position=place,rotation=local.rotation,scale=local.scale}})
        core.add(&w.terrains,e,Terrain{source=id,solid=true})
        owners[i]=e
    }
    core.test_world_settle(&w.w)
    eye:=[3]f32{0,900,-1800}
    view:=core.VIEW_DEFAULT
    view.position,view.size=eye,{1440,900}
    w.streaming.items[0]={eye,eye,0};w.streaming.count=1;w.streaming.revision+=1
    w.settings={}
    for _ in 0..<64 {
        test_step(&w.terrain,core.commands_of(core.test_world_ref(&w.w)),&resident,&app,&w.problems,Terrain_Settings{},view=view)
        core.test_world_settle(&w.w)
        idle:=!work_busy(&w.data,nil)
        for &source in resident.sources {if len(source.pending)>0 {idle=false}}
        if idle {break}
    }
    // The origin of the render for that eye: what origin_follow jumps to.
    origin:[3]f32
    for axis in 0..<3 {origin[axis]=f32(math.round(eye[axis]/render.ORIGIN_STEP))*render.ORIGIN_STEP}
    testing.expect_value(t,origin,[3]f32{0,1024,-2048})
    for owner,i in owners {
        o:Resident_Owner
        for &candidate in resident.owners {if candidate.entity==owner {o=candidate}}
        source:=resident_source_find(&resident,o.source,owner)
        if !testing.expect(t,source!=nil && len(o.nodes)>0) {return}
        s:=&data_find(&w.data,id).source
        start:=places[i]+source_origin(s)
        low_expected,high_expected:=[2]f64{f64(start.x),f64(start.z)}-{f64(origin.x),f64(origin.z)},[2]f64{f64(start.x+SIDE),f64(start.z+SIDE)}-{f64(origin.x),f64(origin.z)}
        area,drawn:=0.0,0
        world,_:=core.get(core.read(&w.worlds),owner)
        for node,index in o.nodes {
            if !node.visible {continue}
            e:=o.chunks[index]
            mesh:=source.chunks[index].mesh
            if !testing.expectf(t,e!=core.NONE && mesh!={},"terrain %d: piece %d is shown with its entity and mesh",i,index) {continue}
            local,placed:=core.get(core.read(&w.transforms),e)
            parent,parented:=core.get(core.read(&w.parents),e)
            testing.expect(t,placed && parented && parent.entity==owner)
            m:=render.origin_matrix(mm.transform_matrix(mm.transform_compose(world.transform,core.to_math(local))),origin)
            ref,known:=assets.index[mesh]
            if !testing.expect(t,known && ref.kind==.Mesh) {continue}
            low,high:=assets.meshes[ref.index].bounds_min,assets.meshes[ref.index].bounds_max
            a:=[2]f64{f64(m[0,3]+low.x),f64(m[2,3]+low.z)}
            b:=[2]f64{f64(m[0,3]+high.x),f64(m[2,3]+high.z)}
            // Where the piece is in the terrain: its samples.
            r0,r1:=quad_region(s,&o.quad,index)
            want0:=low_expected+[2]f64{f64(r0.x),f64(r0.y)}*f64(s.cell)
            want1:=low_expected+[2]f64{f64(r1.x),f64(r1.y)}*f64(s.cell)
            for axis in 0..<2 {
                testing.expectf(t,abs(a[axis]-want0[axis])<1e-3 && abs(b[axis]-want1[axis])<1e-3,"terrain %d: piece %d is drawn over %v..%v relative to the origin, not %v..%v",i,index,a,b,want0,want1)
            }
            for axis in 0..<2 {testing.expect(t,a[axis]>=low_expected[axis]-1e-3 && b[axis]<=high_expected[axis]+1e-3)}
            area+=(b.x-a.x)*(b.y-a.y)
            drawn+=1
        }
        whole:=(high_expected.x-low_expected.x)*(high_expected.y-low_expected.y)
        testing.expectf(t,drawn>0 && abs(area-whole)<whole*1e-5,"terrain %d: its pieces cover %.1f m2 of %.1f",i,area,whole)
    }
    testing.expect_value(t,w.problems.count,0)
}
