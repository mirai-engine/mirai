package terrain

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

// Weights of whole layers and values, in the order they are kept.
@(private)
weights_of :: proc(layers,values:[WEIGHT_SLOTS]int) -> Weights {return weights_pack(layers,values)}

@(private)
mix_of :: proc(shares:..f32) -> (f:Layer_Mix) {
    for share,i in shares {f[i]=share}
    return
}

@(test)
painted_weights_stay_normalized_and_keep_the_proportions_of_the_other_layers :: proc(t:^testing.T) {
    testing.expect_value(t,weights_quantize(mix_of(1,1,1),3),weights_of({0,1,2},{85,85,85}))
    testing.expect(t,weights_full(weights_quantize(mix_of(0.3,0.3,0.4),3)))
    testing.expect_value(t,weights_quantize({},2),WEIGHTS_FIRST)
    w:=WEIGHTS_FIRST
    for _ in 0..<40 {
        next:=weights_paint(w,2,0.25,3)
        testing.expect(t,weights_full(next))
        testing.expect(t,weights_float(next)[2]>=weights_float(w)[2])
        w=next
    }
    testing.expect(t,weights_float(w)[2]>=250.0/255)
    mixed:=weights_of({2,0,1},{105,100,50})
    painted:=weights_paint(mixed,2,0.5,3)
    testing.expect(t,weights_full(painted))
    f:=weights_float(painted)
    testing.expect(t,abs(f[0]/f[1]-2)<0.1)
    testing.expect_value(t,weights_paint(weights_of({1,0,0},{WEIGHT_FULL,0,0}),1,-1,3),WEIGHTS_FIRST)
    testing.expect_value(t,weights_paint(WEIGHTS_FIRST,0,-1,1),WEIGHTS_FIRST)
    testing.expect_value(t,weights_paint(WEIGHTS_FIRST,0,-1,2),weights_of({1,0,0},{WEIGHT_FULL,0,0}))
    testing.expect_value(t,weights_paint(mixed,3,1,3),mixed)
    testing.expect_value(t,weights_remove(weights_of({1,2,0},{102,102,51}),0,3),weights_of({0,1,0},{128,127,0}))
    // A sample holds its three heaviest layers: a fourth painted over three
    // takes the place of the lightest, and those above a removed one go down.
    three:=weights_of({4,9,20},{85,85,85})
    fourth:=weights_paint(three,30,0.1,32)
    testing.expect(t,weights_full(fourth))
    layer,value:=weights_slot(fourth,2)
    testing.expect(t,layer==30 && value>0,"the layer painted keeps a slot")
    testing.expect_value(t,weights_remove(three,9,32),weights_of({4,19,0},{128,127,0}))
    // What is not kept as weights is refused: out of order, a layer twice, bit 15.
    testing.expect(t,!weights_full(weights_of({0,1,0},{50,100,105})))
    testing.expect(t,!weights_full(Weights(u32(weights_of({3,0,0},{WEIGHT_FULL,0,0}))|WEIGHT_HOLE)))
    testing.expect(t,!weights_full(Weights(u32(3|3<<WEIGHT_LAYER_BITS)|128<<WEIGHT_VALUES_SHIFT|127<<(WEIGHT_VALUES_SHIFT+8))))
}

// The ground gives the four layers that weigh most at a point, by material:
// layers of one material add up, and what the rest weigh goes to them.
@(test)
the_ground_takes_the_four_heaviest_materials_of_any_number_of_layers :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{9,1,9},1,4))
    for i in 0..<6 {
        layer:=LAYER_DEFAULT
        layer.material=base.Asset_Id{100,u64(i==5?1:i)}
        testing.expect(t,source_layer_set(&s,i,layer))
    }
    weights,materials:=layers_dominant(&s,mix_of(0.05,0.2,0.25,0.15,0.1,0.25))
    testing.expect_value(t,materials,[4]base.Asset_Id{{100,1},{100,2},{100,3},{100,4}})
    testing.expect_value(t,int(weights[0])+int(weights[1])+int(weights[2])+int(weights[3]),WEIGHT_FULL)
    testing.expect(t,weights[0]>weights[1] && weights[1]>weights[2],"layer 5 adds to layer 1, of its material")
    one,only:=layers_dominant(&s,{})
    testing.expect(t,one=={WEIGHT_FULL,0,0,0} && only[0]==base.Asset_Id{100,0})
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
    bad=LAYER_DEFAULT;bad.detile=2
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
        testing.expect(t,weights_float(grid_value(&original.weights,{x,0,4}))[1]>150.0/255)
        testing.expect_value(t,grid_value(&original.weights,{10,0,4}),WEIGHTS_FIRST)
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
            testing.expect(t,weights_used(grid_value(&cloned.weights,{x,y,z}),2))
        }}}
        testing.expect(t,weights_float(grid_value(&loaded.weights,{x,0,4}))[1]>150.0/255)
        for page in loaded.weights.pages {if page.values!=nil {page.values[2]=Weights(WEIGHT_HOLE)}}
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

// What a piece shows of its layers and its slope is in its maps, a texel each
// sample, the same at every level of its triangles; a vertex says where it is
// over them.
@(test)
a_piece_shows_the_weights_and_normals_of_every_sample_at_any_level :: proc(t:^testing.T) {
    height:Source;defer source_destroy(&height)
    layers_fixture(t,&height,.Heightfield)
    for x in 0..<70 {for z in 0..<9 {source_set(&height,{x,0,z},0.4*math.sin(f32(x)*1.7)+0.3*f32(z))}}
    // A path one sample wide.
    for z in 0..<9 {testing.expect(t,grid_put(&height.weights,{5,0,z},weights_of({1,0,0},{WEIGHT_FULL,0,0}),height.allocator))}
    fine,coarse:Chunk_Mesh
    chunk_mesh_init(&fine);defer chunk_mesh_destroy(&fine)
    chunk_mesh_init(&coarse);defer chunk_mesh_destroy(&coarse)
    testing.expect(t,chunk_build(&height,{0,0,0},&fine,false))
    testing.expect(t,chunk_build(&height,{0,0,0},&coarse,false,{level=2,sides={2,2,2,2},corners={2,2,2,2}}))
    testing.expect(t,len(coarse.geometry.positions)<len(fine.geometry.positions))
    testing.expect_value(t,coarse.maps.size,[2]int{9,9})
    testing.expect(t,fine.maps.size==coarse.maps.size && slice_equal(fine.maps.control[:],coarse.maps.control[:]) && slice_equal(fine.maps.normal[:],coarse.maps.normal[:]),"the maps do not follow the level")
    testing.expect(t,weights_float(Weights(coarse.maps.control[5+9*4]))[1]>0.99,"the path shows at level 2")
    n:=heightfield_normal(&height,3,4,1)
    testing.expect_value(t,coarse.maps.normal[3+9*4],normal_bytes(n))
    for p,i in coarse.geometry.positions {
        testing.expect(t,abs(coarse.geometry.uvs[i].x-p.x)<1e-4 && abs(coarse.geometry.uvs[i].y-p.z)<1e-4,"uv0 is the place over the maps")
    }
    // A steep rule covers what is painted, in the maps.
    steep:=height.layers[2]
    steep.auto={enabled=true,slope={0.6,math.PI/2},height={-100,100},softness={0,0}}
    testing.expect(t,source_layer_set(&height,2,steep))
    for x in 0..<9 {for z in 0..<9 {source_set(&height,{x,0,z},f32(x)*3)}}
    testing.expect(t,chunk_build(&height,{0,0,0},&fine,false))
    testing.expect(t,weights_float(Weights(fine.maps.control[3*9+3]))[2]>0.99)
}

// Tint and Roughness paint a Heightfield toward their color and roughness,
// the maps of its pieces show it, and its file keeps it; a Volume has none.
@(test)
color_and_roughness_painted_over_the_layers_reach_the_maps_and_the_file :: proc(t:^testing.T) {
    s,loaded:Source;defer source_destroy(&s);defer source_destroy(&loaded)
    testing.expect(t,source_make(&s,.Heightfield,{17,1,17},1,8))
    testing.expect(t,grid_none(&s.paint),"nothing painted holds no pages")
    for _ in 0..<12 {testing.expect(t,source_edit(&s,{kind=.Tint,center={},radius=2,amount=0.5,color={1,0,0},falloff=.Constant}).error==.None)}
    testing.expect_value(t,grid_get(&s.paint,8,8),Paint{255,0,0,PAINT_ROUGHNESS_NEUTRAL})
    testing.expect_value(t,grid_get(&s.paint,2,2),PAINT_NEUTRAL)
    for _ in 0..<12 {source_edit(&s,{kind=.Roughness,center={},radius=2,amount=0.5,target=0,falloff=.Constant})}
    testing.expect_value(t,grid_get(&s.paint,8,8),Paint{255,0,0,0})
    testing.expect_value(t,source_edit(&s,{kind=.Tint,center={},radius=2,amount=1,color={2,0,0}}).error,Edit_Error.Color)
    testing.expect_value(t,source_edit(&s,{kind=.Roughness,center={},radius=2,amount=1,target=-1}).error,Edit_Error.Target)
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&s,{1,0,1},&mesh,false))
    testing.expect_value(t,mesh.maps.paint[0],Paint{255,0,0,0})
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    path:=fmt.tprintf("%s/paint.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&s,path,{61,62},&types),asset.Error.None)
    _,ok:=source_load(&loaded,path,&types)
    testing.expect(t,ok && grid_equal(&loaded.paint,&s.paint))
    volume:Source;defer source_destroy(&volume)
    testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,4))
    testing.expect_value(t,source_edit(&volume,{kind=.Tint,center={},radius=1,amount=1,color={1,1,1}}).error,Edit_Error.Kind)
}

@(private)
slice_equal :: proc(a,b:[]$T) -> bool {
    if len(a)!=len(b) {return false}
    for v,i in a {if v!=b[i] {return false}}
    return true
}

@(test)
each_collider_cell_shows_the_material_that_covers_most_of_it :: proc(t:^testing.T) {
    height:Source;defer source_destroy(&height)
    layers_fixture(t,&height,.Heightfield)
    rock:=height.layers[1].material
    _=source_edit(&height,{kind=.Paint,center=source_origin(&height)+{4,0,4},radius=3,amount=1,layer=1})
    // Rock is the layer that covers most of cell (0,0), but layers 0 and 2 share a material that covers more.
    testing.expect(t,grid_prepare(&height.weights,{0,0,0},{1,0,1},height.allocator))
    for x in 0..=1 {for z in 0..=1 {grid_set(&height.weights,x,z,weights_pack({1,0,2},{105,75,75}))}}
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&height,{0,0,0},&mesh,true))
    if !testing.expect(t,len(mesh.materials)==2 && mesh.materials[0]=={} && mesh.materials[1]==rock && len(mesh.surfaces)==8*8) {return}
    testing.expect(t,mesh.surfaces[4*8+4]==1 && mesh.surfaces[3*8+3]==1)
    testing.expect_value(t,mesh.surfaces[0],u8(0))
    testing.expect_value(t,mesh.surfaces[7*8+7],u8(0))
    // One material: the cells name none.
    fresh:Source;defer source_destroy(&fresh)
    testing.expect(t,source_make(&fresh,.Heightfield,{9,1,9},1,8))
    testing.expect(t,chunk_build(&fresh,{0,0,0},&mesh,true))
    testing.expect(t,len(mesh.materials)==1 && len(mesh.surfaces)==0)
}

// The table of the layers the program reads holds every layer, past four,
// each value where terrain_surface.slang reads it.
@(test)
the_table_of_the_layers_holds_each_layer_where_the_program_reads_it :: proc(t:^testing.T) {
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{9,1,9},1,4))
    for i in 0..<6 {
        layer:=LAYER_DEFAULT
        layer.tiling,layer.far_tiling,layer.detile=f32(i+1),f32(10*i),0.5
        testing.expect(t,source_layer_set(&source,i,layer))
    }
    testing.expect_value(t,source.layer_count,u32(6))
    pixels:=make([]u8,4*LAYERS_TEXELS*6,context.temp_allocator)
    layers_table(nil,&source,pixels)
    word :: proc(pixels:[]u8,layer,texel:int) -> u32 {
        at:=4*(texel+LAYERS_TEXELS*layer)
        return u32(pixels[at])|u32(pixels[at+1])<<8|u32(pixels[at+2])<<16|u32(pixels[at+3])<<24
    }
    for i in 0..<6 {
        testing.expect_value(t,word(pixels,i,0),max(u32))
        testing.expect_value(t,transmute(f32)word(pixels,i,4),f32(i+1))
        testing.expect_value(t,transmute(f32)word(pixels,i,5),f32(10*i))
        testing.expect_value(t,pixels[4*(3+LAYERS_TEXELS*i)+2],u8(128))
    }
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
    // An index no layer has is refused, not taken as the first.
    request_layer(&w.terrain_requests,owner,-1,rock)
    request_layer_remove(&w.terrain_requests,owner,min(int))
    testing.expect_value(t,w.terrain_requests.layers.refused,2)
    terrain_test_update(&w,&resident,&app)
    testing.expect(t,core.problem_find(&w.problems,owner,"terrain.layer_invalid")!=nil)
    testing.expect_value(t,w.data.entries[0].source.layer_count,u32(2))
    testing.expect_value(t,w.data.entries[0].source.layers[0],grass)
    testing.expect_value(t,layered_chunks(&w),16)
    for row in 0..<core.count(&w.statics) {
        e:=w.statics.entities[row]
        if e==owner {continue}
        shown:=w.statics.values[row]
        testing.expect_value(t,shown.materials[0],LAYERS_MATERIAL)
        look,_:=core.get(&w.looks,e)
        control,has:=render.material_texture_of(&look,0,base.name_hash("control"))
        testing.expect(t,has && control!={},"each chunk shows its maps")
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
// and its chunks show it in slot 0 without the table of Terrain_Layers.
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
    terrain_test_update(&w,&resident,&app)
    testing.expect(t,core.count(&w.statics)>0)
    for row in 0..<core.count(&w.statics) {testing.expect_value(t,w.statics.values[row].materials[0],blend)}
    testing.expect_value(t,layered_chunks(&w),0)
    // Without it, the layers blend their materials again.
    read.layers_material={}
    testing.expect_value(t,chunk_materials(&read)[0],LAYERS_MATERIAL)
}
