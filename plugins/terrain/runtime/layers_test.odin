package terrain

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

@(private)
weights_sum :: proc(w:Weights) -> int {return int(w[0])+int(w[1])+int(w[2])+int(w[3])}

@(test)
painted_weights_stay_normalized_and_keep_the_proportions_of_the_other_layers :: proc(t:^testing.T) {
    testing.expect_value(t,weights_quantize({1,1,1,0},3),Weights{85,85,85,0})
    testing.expect_value(t,weights_sum(weights_quantize({0.3,0.3,0.4,0},3)),WEIGHT_FULL)
    testing.expect_value(t,weights_quantize({0,0,0,0},2),Weights{WEIGHT_FULL,0,0,0})
    w:=Weights{WEIGHT_FULL,0,0,0}
    for _ in 0..<40 {
        next:=weights_paint(w,2,0.25,3)
        testing.expect_value(t,weights_sum(next),WEIGHT_FULL)
        testing.expect(t,next[2]>=w[2])
        w=next
    }
    testing.expect(t,w[2]>=250)
    mixed:=Weights{100,50,105,0}
    painted:=weights_paint(mixed,2,0.5,3)
    testing.expect_value(t,weights_sum(painted),WEIGHT_FULL)
    testing.expect(t,abs(f32(painted[0])/f32(painted[1])-2)<0.1)
    erased:=weights_paint(Weights{0,WEIGHT_FULL,0,0},1,-1,3)
    testing.expect_value(t,erased,Weights{WEIGHT_FULL,0,0,0})
    testing.expect_value(t,weights_paint(Weights{WEIGHT_FULL,0,0,0},0,-1,1),Weights{WEIGHT_FULL,0,0,0})
    testing.expect_value(t,weights_paint(Weights{WEIGHT_FULL,0,0,0},0,-1,2),Weights{0,WEIGHT_FULL,0,0})
    testing.expect_value(t,weights_paint(mixed,3,1,3),mixed)
    testing.expect_value(t,weights_remove(Weights{51,102,102,0},0,3),Weights{128,127,0,0})
}

@(private)
layers_fixture :: proc(t:^testing.T,s:^Source,kind:Source_Kind) {
    switch kind {
    case .Heightfield:testing.expect(t,source_make(s,.Heightfield,{70,1,9},1,8))
    case .Volume:testing.expect(t,source_make(s,.Volume,{17,9,9},1,8))
    }
    rock:=LAYER_DEFAULT
    rock.material,rock.tiling,rock.height_blend=base.Asset_Id{7,8},2,0.5
    testing.expect(t,source_layer_set(s,0,LAYER_DEFAULT))
    testing.expect(t,source_layer_set(s,1,rock))
    testing.expect(t,source_layer_set(s,2,LAYER_DEFAULT))
    testing.expect(t,!source_layer_set(s,4,LAYER_DEFAULT))
    bad:=LAYER_DEFAULT;bad.tiling=0
    testing.expect(t,!source_layer_set(s,3,bad))
    testing.expect_value(t,s.layer_count,u32(3))
}

@(test)
terrain_layers_and_weights_round_trip_in_the_terrain_file_for_every_source :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    for kind in ([2]Source_Kind{.Heightfield,.Volume}) {
        original,loaded,cloned:Source
        defer source_destroy(&original);defer source_destroy(&loaded);defer source_destroy(&cloned)
        layers_fixture(t,&original,kind)
        x:=original.weights.size.x-3
        center:=source_origin(&original)+[3]f32{f32(x),0,4}
        change:=source_edit(&original,{kind=.Paint,center=center,radius=2.5,amount=0.8,layer=1})
        testing.expect(t,change.changed && change.error==.None)
        // Only the pages under the brush hold values: of a Volume, those of its ball.
        page_samples:=0
        g:=&original.weights
        from,to:=grid_pages(g,{x-2,0,2},{x+2,2,6})
        for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
            _,count:=grid_page_extent(g,px+g.counts.x*(py+g.counts.y*pz))
            page_samples+=count
        }}}
        testing.expect_value(t,grid_dense(&original.weights),page_samples)
        testing.expect(t,grid_value(&original.weights,{x,0,4})[1]>150)
        testing.expect_value(t,grid_value(&original.weights,{10,0,4}),Weights{WEIGHT_FULL,0,0,0})
        path:=fmt.tprintf("%s/layers.terrain",base.test_folder(t,"terrain"))
        id:=base.Asset_Id{55,u64(kind)}
        testing.expect_value(t,source_save(&original,path,id,&types),asset.Error.None)
        got,ok:=source_load(&loaded,path,&types)
        testing.expect(t,ok && got==id)
        testing.expect_value(t,loaded.info,original.info)
        testing.expect(t,grid_equal(&loaded.weights,&original.weights))
        testing.expect_value(t,grid_dense(&loaded.weights),page_samples)
        testing.expect(t,source_clone(&cloned,&loaded))
        testing.expect(t,grid_equal(&cloned.weights,&loaded.weights))
        testing.expect(t,source_layer_remove(&cloned,1))
        testing.expect_value(t,cloned.layer_count,u32(2))
        testing.expect_value(t,cloned.layers[1],LAYER_DEFAULT)
        size:=cloned.weights.size
        for z in 0..<size.z {for y in 0..<size.y {for x in 0..<size.x {
            w:=grid_value(&cloned.weights,{x,y,z})
            testing.expect(t,weights_sum(w)==WEIGHT_FULL && w[2]==0 && w[3]==0)
        }}}
        testing.expect(t,grid_value(&loaded.weights,{x,0,4})[1]>150)
        for page in loaded.weights.pages {if page.values!=nil {page.values[2]={1,2,3,4}}}
        testing.expect_value(t,source_save(&loaded,path,id,&types),asset.Error.Invalid)
    }
}

@(test)
painting_marks_only_the_chunks_whose_vertices_read_the_weights :: proc(t:^testing.T) {
    height:Source
    defer source_destroy(&height)
    layers_fixture(t,&height,.Heightfield)
    change:=source_edit(&height,{kind=.Paint,center=source_origin(&height)+{20,0,4},radius=1.5,amount=1,layer=2})
    low,high:=chunk_range(&height,change)
    testing.expect(t,low.x>=1 && high.x<=3)
    testing.expect_value(t,source_edit(&height,{kind=.Paint,center={},radius=1,amount=1,layer=3}).error,Edit_Error.Layer)
    // A new source has one layer, which covers it all: painting it changes nothing, and there is no other.
    fresh:Source;defer source_destroy(&fresh)
    testing.expect(t,source_make(&fresh,.Heightfield,{9,1,9},1,4))
    painted:=source_edit(&fresh,{kind=.Paint,center={},radius=1,amount=1})
    testing.expect(t,painted.error==.None && !painted.changed)
    testing.expect_value(t,source_edit(&fresh,{kind=.Paint,center={},radius=1,amount=1,layer=1}).error,Edit_Error.Layer)
}

@(test)
chunks_carry_the_layer_weights_in_their_uvs :: proc(t:^testing.T) {
    height:Source;defer source_destroy(&height)
    layers_fixture(t,&height,.Heightfield)
    _=source_edit(&height,{kind=.Paint,center=source_origin(&height)+{4,0,4},radius=2,amount=1,layer=1})
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&height,{0,0,0},&mesh,false))
    for p,i in mesh.geometry.positions {
        w:=[4]f32{mesh.geometry.uvs[i].x,mesh.geometry.uvs[i].y,mesh.uv1s[i].x,mesh.uv1s[i].y}
        testing.expect(t,abs(w[0]+w[1]+w[2]+w[3]-1)<1e-4)
        if p.x==source_origin(&height).x+4 && p.z==source_origin(&height).z+4 {testing.expect(t,w[1]>0.9)}
    }
    // A steep rule covers what is painted.
    steep:=height.layers[2]
    steep.auto={enabled=true,slope={0.6,math.PI/2},height={-100,100},softness={0,0}}
    testing.expect(t,source_layer_set(&height,2,steep))
    for x in 0..<9 {for z in 0..<9 {source_set(&height,{x,0,z},f32(x)*3)}}
    testing.expect(t,chunk_build(&height,{0,0,0},&mesh,false))
    testing.expect(t,mesh.uv1s[3*9+3].x>0.99)
}

@(test)
layer_materials_fill_the_textures_and_values_of_the_layered_program :: proc(t:^testing.T) {
    source:Source;defer source_destroy(&source)
    layers_fixture(t,&source,.Heightfield)
    o:=layers_override(nil,&source)
    testing.expect(t,o.slots=={} && o.texture_slots=={},"every value and texture is of the one slot of a terrain")
    testing.expect_value(t,o.count,u32(6))
    testing.expect_value(t,o.texture_count,u32(6))
    testing.expect_value(t,o.texture_names[2],base.name_hash("color1"))
    testing.expect_value(t,o.texture_names[3],base.name_hash("normal1"))
    testing.expect_value(t,o.names[3],base.name_hash("detail1"))
    testing.expect_value(t,o.values[3],[4]f32{2,0.5,0,0})
    testing.expect_value(t,o.values[2],[4]f32{1,1,1,1})
}

@(test)
layered_terrains_show_the_layered_material_and_repaint_only_touched_chunks :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    heap:base.Heap;testing.expect(t,base.heap_init(&heap,32*1024*1024));defer base.heap_destroy(&heap)
    allocator:=Terrain_Test_Allocator{owner=base.heap_allocator(&heap)}
    temporary:base.Arena;testing.expect(t,base.arena_init(&temporary,16*1024*1024));defer base.arena_destroy(&temporary)
    context.allocator={terrain_test_allocator,&allocator}
    context.temp_allocator=base.arena_allocator(&temporary)
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{17,1,17},1,4));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{57,58}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=64}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&w.entities)
    core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,solid=true})
    test_world_settle(&w.w)
    terrain_test_update(&w,&resident,&app)
    // A new source shows its one layer in every chunk.
    testing.expect(t,core.count(&w.statics)>0)
    testing.expect_value(t,layered_chunks(&w),16)
    for row in 0..<core.count(&w.statics) {
        if w.statics.entities[row]!=owner {testing.expect_value(t,w.statics.values[row].materials[0],LAYERS_MATERIAL)}
    }
    grass,rock:=LAYER_DEFAULT,LAYER_DEFAULT
    rock.tiling=8
    request_layer(&w.terrain_requests,owner,0,grass)
    request_layer(&w.terrain_requests,owner,1,rock)
    request_layer(&w.terrain_requests,owner,3,rock)
    terrain_test_update(&w,&resident,&app)
    testing.expect(t,core.problem_find(&w.problems,owner,"terrain.layer_invalid")!=nil)
    testing.expect_value(t,w.data.entries[0].source.layer_count,u32(2))
    testing.expect_value(t,layered_chunks(&w),16)
    for row in 0..<core.count(&w.statics) {
        e:=w.statics.entities[row]
        if e==owner {continue}
        shown:=w.statics.values[row]
        testing.expect_value(t,shown.materials[0],LAYERS_MATERIAL)
        override,_:=core.get(&w.looks,e)
        testing.expect_value(t,override.values[3].x,f32(8))
    }
    before:[16]base.Asset_Id
    for chunk,i in resident.sources[0].chunks[:resident.sources[0].quad.first[1]] {before[i]=chunk.mesh}
    dig(&w.terrain_requests,{kind=.Paint,center={-6,0,-6},radius=0.6,amount=1,layer=1},owner)
    terrain_test_update(&w,&resident,&app)
    changed:=0
    for chunk,i in resident.sources[0].chunks[:resident.sources[0].quad.first[1]] {if chunk.mesh!=before[i] {changed+=1}}
    testing.expect_value(t,changed,1)
    calls,temps,version:=allocator.requests,temporary.requests,w.statics.version
    for _ in 0..<10 {terrain_test_update(&w,&resident,&app)}
    testing.expect_value(t,allocator.requests,calls);testing.expect_value(t,temporary.requests,temps)
    testing.expect_value(t,w.statics.version,version)
    // The last layer stays.
    core.problems_clear(&w.problems)
    request_layer_remove(&w.terrain_requests,owner,0)
    request_layer_remove(&w.terrain_requests,owner,0)
    terrain_test_update(&w,&resident,&app)
    testing.expect_value(t,w.data.entries[0].source.layer_count,u32(1))
    testing.expect(t,core.problem_find(&w.problems,owner,"terrain.layer_invalid")!=nil)
    testing.expect_value(t,layered_chunks(&w),16)
}

// A source whose layers a program of its own blends keeps it in its file,
// and its chunks show it in slot 0 without the parameters of Terrain_Layers.
@(test)
a_program_of_the_source_blends_its_layers_in_place_of_terrain_layers :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{17,1,17},1,4));defer source_destroy(&source)
    source.revision=1
    testing.expect(t,source_layer_set(&source,0,LAYER_DEFAULT))
    testing.expect(t,source_layer_set(&source,1,LAYER_DEFAULT))
    blend:=base.Asset_Id{71,72}
    source.layers_material=blend
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{57,59}
    path:=fmt.tprintf("%s/source.terrain",root)
    testing.expect_value(t,source_save(&source,path,id,&types),asset.Error.None)
    read:Source;defer source_destroy(&read)
    _,loaded:=source_load(&read,path,&types)
    if !testing.expect(t,loaded) {return}
    testing.expect_value(t,read.layers_material,blend)
    testing.expect_value(t,chunk_materials(&read)[0],blend)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=64}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&w.entities)
    core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,solid=true})
    test_world_settle(&w.w)
    terrain_test_update(&w,&resident,&app)
    testing.expect(t,core.count(&w.statics)>0)
    for row in 0..<core.count(&w.statics) {testing.expect_value(t,w.statics.values[row].materials[0],blend)}
    testing.expect_value(t,layered_chunks(&w),0)
    // Without it, the layers blend their materials again.
    read.layers_material={}
    testing.expect_value(t,chunk_materials(&read)[0],LAYERS_MATERIAL)
}
