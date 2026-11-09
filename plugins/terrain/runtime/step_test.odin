package terrain

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import scene "mirai:engine/scene"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:rhi"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"
import mm "mirai:std/math"

when #config(TERRAIN_GPU,false) {
@(test)
shared_terrain_chunks_remain_visible_after_duplicate_copy_and_preview_retirement :: proc(t:^testing.T) {
    root:=source_test_path("shared-gpu");os.make_directory_all(root);defer os.remove_all(root)
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{65,1,65},1,32));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{93,94}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    settings:=gpu.DEFAULT_SETTINGS
    settings.gi_enabled,settings.reflections,settings.taa=false,false,false
    app,error:=host.app_create({gpu=true,gpu_validation=true,assets_root=root,window_desc={size={160,120}},threads=1,render_settings=settings})
    if !testing.expect_value(t,error,host.App_Error.None) || app==nil {return}
    defer host.app_destroy(app)
    worlds:[2]Terrain_Test_World
    for &w in worlds {terrain_test_world_init(&w)}
    defer for &w in worlds {terrain_test_world_free(&w)}
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    poses:[2]core.Table(core.World_Transform);defer for &table in poses {core.table_destroy(&table)}
    hierarchies:[2]core.Hierarchy;defer for &hierarchy in hierarchies {core.value_free(&hierarchy,type_info_of(core.Hierarchy))}
    propagations:[2]core.Propagation;defer for &propagation in propagations {core.value_free(&propagation,type_info_of(core.Propagation))}
    jumps:core.Jumps
    hidden:core.Table(render.Hidden);defer core.table_destroy(&hidden)
    elsewhere:core.Table(render.Drawn_Elsewhere);defer core.table_destroy(&elsewhere)
    suns:core.Table(render.Sun);defer core.table_destroy(&suns)
    points:core.Table(render.Point_Light);defer core.table_destroy(&points)
    spots:core.Table(render.Spot_Light);defer core.table_destroy(&spots)
    rects:core.Table(render.Rect_Light);defer core.table_destroy(&rects)
    emissions:core.Table(render.Light_Emission);defer core.table_destroy(&emissions)
    layers:core.Table(render.Layers);defer core.table_destroy(&layers)
    skies:core.Table(render.Sky);core.table_init(&skies,"Sky");defer core.table_destroy(&skies)
    posts:core.Table(render.View_Volume);defer core.table_destroy(&posts)
    highlights:core.Table(render.Highlight);defer core.table_destroy(&highlights)
    offsets:core.Table(render.Draw_Offset);defer core.table_destroy(&offsets)
    sync:render.Render_Sync;defer render.sync_free(&sync)
    view:=core.VIEW_DEFAULT
    view.position,view.rotation,view.size={12,15,18},mm.quat_look({-12,-15,-18},{0,1,0}),{160,120}
    view.fov=50*mm.RAD_PER_DEG
    owner:=core.create(&worlds[0].entities)
    core.add(&worlds[0].locals,owner,core.TRANSFORM_IDENTITY)
    core.add(&worlds[0].tints,owner,render.Tint{color={1,1,1,1},emission={3,3,3}})
    core.add(&worlds[0].terrains,owner,Terrain{source=id,revision=1})
    reference:[]u8;defer delete(reference)
    preview:base.Asset_Id
    scratch:Chunk_Mesh;chunk_mesh_init(&scratch);defer chunk_mesh_destroy(&scratch)
    for pass in 0..<6 {
        current:=0
        if pass==2 || pass==4 {terrain_test_world_copy(&worlds[1],&worlds[0]);current=1}
        w:=&worlds[current]
        if pass==1 {
            duplicate:=core.create(&w.entities)
            transform:=core.TRANSFORM_IDENTITY;transform.position.x=72
            core.add(&w.locals,duplicate,transform)
            core.add(&w.tints,duplicate,render.Tint{color={0,1,0,1},emission={3,3,3}})
            core.add(&w.terrains,duplicate,Terrain{source=id,revision=1})
        }
        terrain_test_world_settle(w)
        terrain_test_update(w,&resident,app)
        core.hierarchy_settle(&hierarchies[current],core.read(&w.parents),&w.entities)
        core.transforms_propagate(core.read(&w.locals),core.ref(&hierarchies[current]),&poses[current],&propagations[current],&jumps,{})
        core.table_settle(&poses[current],&w.entities)
        testing.expect_value(t,len(w.chunks.values),pass==0?4:8)
        // Each terrain builds its own pieces of the shared source.
        testing.expect_value(t,len(resident.sources),pass==0?1:2)
        if pass==4 {
            testing.expect(t,chunk_build(&w.data.entries[0].source,{0,0,0},&scratch))
            for &position in scratch.geometry.positions {position.y+=0.2}
            made:bool
            preview,made=chunk_publish(app.assets,.Heightfield,&scratch,false)
            testing.expect(t,made)
        } else if preview!={} {testing.expect(t,host.assets_mesh_release(app.assets,preview));preview={}}
        for _ in 0..<3 {
            host.app_frame_begin(app)
            if preview!={} {
                for marker,row in w.chunks.values {
                    if marker.coord!=([3]i32{}) {continue}
                    e:=w.chunks.entities[row]
                    world,_:=core.get(core.read(&poses[current]),e)
                    tint,_:=core.get(core.read(&w.tints),e)
                    instance,usable:=render.mesh_instance(app.assets,{mesh=preview},mm.transform_matrix(world.transform),tint)
                    testing.expect(t,usable)
                    instance.object_id,instance.copy_owner,instance.copy_variant,instance.replace_source=u64(e),99,1,true
                    testing.expect(t,host.app_instance_add(app,instance))
                }
            }
            host.app_camera_set(app,host.camera_from_view(view),view.cut,view.carried)
            outlines:core.Table(render.Outline);defer core.table_destroy(&outlines)
            outline_styles:=render.OUTLINE_STYLES_DEFAULT
            render.render_sync(&sync,app,{},core.FRAME_TIME_DEFAULT,{},core.read(&poses[current]),core.read(&w.statics),core.read(&w.tints),core.read(&hidden),core.read(&elsewhere),core.read(&w.parents),{},core.read(&suns),core.read(&points),core.read(&spots),core.read(&rects),core.read(&emissions),core.read(&skies),core.read(&posts),{},core.read(&w.overrides),core.read(&highlights),core.read(&outlines),{&outline_styles},core.read(&offsets),core.read(&layers),{},{},{},{})
            host.app_frame_end(app)
        }
        if pass==4 {continue}
        pixels,_,_,captured:=host.app_capture_pixels(app)
        if !testing.expect(t,captured) {delete(pixels);return}
        if pass==0 {
            reference=pixels
            camera:=host.camera_from_view(view)
            vp:=mm.perspective(camera.fov_y*mm.RAD_PER_DEG,160.0/120.0,camera.near,camera.far)*mm.look_at(camera.position,camera.position+camera.forward,camera.up)
            for point in ([4]mm.Vec3{{-2,0,-2},{2,0,-2},{-2,0,2},{2,0,2}}) {
                pixel,_,visible:=mm.world_to_screen(point,{160,120},vp)
                at:=(int(pixel.y)*160+int(pixel.x))*4
                if testing.expect(t,visible && at>=0 && at+3<len(reference)) {testing.expect(t,reference[at]>150,"each terrain quadrant is present")}
            }
        } else {
            testing.expectf(t,mem.compare(pixels,reference)==0,"all terrain quadrants remain after duplicate, world copy or preview retirement (pass %d)",pass)
            delete(pixels)
        }
    }
    testing.expect_value(t,rhi.device_validation_errors(app.device),0)
}
}

// The residency of the GPU test above, without its captures: a terrain, a
// duplicate of its source, copies of the world back and forth.
@(test)
terrains_of_a_shared_source_keep_one_set_of_pieces_each_across_world_copies :: proc(t:^testing.T) {
    root:=source_test_path("shared-copies");os.make_directory_all(root);defer os.remove_all(root)
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{65,1,65},1,32));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{93,95}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=32}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    worlds:[2]Terrain_Test_World
    for &w in worlds {terrain_test_world_init(&w)}
    defer for &w in worlds {terrain_test_world_free(&w)}
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&worlds[0].entities)
    core.add(&worlds[0].locals,owner,core.TRANSFORM_IDENTITY)
    core.add(&worlds[0].terrains,owner,Terrain{source=id,revision=1})
    duplicate:=core.NONE
    for pass in 0..<6 {
        current:=0
        if pass==2 || pass==4 {terrain_test_world_copy(&worlds[1],&worlds[0]);current=1}
        w:=&worlds[current]
        if pass==1 {
            duplicate=core.create(&w.entities)
            transform:=core.TRANSFORM_IDENTITY;transform.position.x=72
            core.add(&w.locals,duplicate,transform)
            core.add(&w.terrains,duplicate,Terrain{source=id,revision=1})
        }
        terrain_test_world_settle(w)
        terrain_test_update(w,&resident,&app)
        testing.expect_value(t,len(w.chunks.values),pass==0?4:8)
        testing.expect_value(t,len(resident.owners),pass==0?1:2)
        testing.expect_value(t,len(resident.sources),pass==0?1:2)
        for author in ([2]core.Entity{owner,duplicate}) {
            if author==core.NONE {continue}
            mine:=resident_source_find(&resident,id,author)
            if !testing.expectf(t,mine!=nil,"pass %d: terrain %v has its pieces",pass,author) {continue}
            for chunk in mine.chunks[:mine.quad.first[1]] {testing.expect(t,host.assets_mesh_generated(&assets,chunk.mesh))}
        }
    }
}

@(test)
restored_entity_handles_do_not_turn_authors_into_cached_terrain_chunks :: proc(t:^testing.T) {
    root:=source_test_path("recycled-owner");os.make_directory_all(root);defer os.remove_all(root)
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{9,1,9},1,4));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{95,96}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    for keep_original in ([2]bool{true,false}) {
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=32}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World;terrain_test_world_init(&w);defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&w.entities)
    core.add(&w.ids,owner,{value=1})
    for index in 2..<4 {core.add(&w.ids,core.create(&w.entities),{value=base.Entity_Id(index)})}
    core.add(&w.locals,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,revision=1})
    terrain_test_world_settle(&w)
    authors:core.Entities;core.entities_init(&authors);defer core.entities_destroy(&authors)
    core.entities_copy(&authors,&w.entities)
    terrain_test_update(&w,&resident,&app)
    if !testing.expect(t,len(resident.owners)==1 && len(w.chunks.values)==4) {return}
    stale:=resident.owners[0].chunks[0]
    epoch:=w.data.epoch
    core.entities_copy(&w.entities,&authors)
    core.table_clear(&w.chunks);core.table_clear(&w.parents);core.table_clear(&w.locals)
    core.table_clear(&w.statics);core.table_clear(&w.colliders);core.table_clear(&w.tints);core.table_clear(&w.overrides)
    core.add(&w.locals,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.statics,owner,render.Mesh_Renderer{})
    duplicate:=core.create(&w.entities)
    testing.expect_value(t,duplicate,stale)
    core.add(&w.ids,duplicate,{value=4})
    transform:=core.TRANSFORM_IDENTITY;transform.position.x=72
    core.add(&w.locals,duplicate,transform)
    core.add(&w.terrains,duplicate,Terrain{source=id,revision=1})
    if !keep_original {core.remove(&w.terrains,owner)}
    terrain_test_world_settle(&w)
    terrain_test_update(&w,&resident,&app)
    testing.expect_value(t,w.data.epoch,epoch)
    testing.expect_value(t,len(w.chunks.values),keep_original?8:4)
    // Each terrain builds its own pieces.
    testing.expect_value(t,len(resident.sources),keep_original?2:1)
    testing.expect_value(t,resident.stats.built,u64(8))
    for author in ([2]core.Entity{owner,duplicate}) {
        static,_:=core.get(core.read(&w.statics),author)
        testing.expect(t,core.alive(&w.entities,author),"retiring a cached owner does not destroy a new author that reused its chunk handle")
        testing.expect(t,static.mesh=={} && !core.has(&w.chunks,author),"an author keeps its recipe when a previous derived handle aliases it")
        count:=0
        for chunk,row in w.chunks.values {
            if chunk.owner!=author {continue}
            e:=w.chunks.entities[row]
            parent,_:=core.get(core.read(&w.parents),e)
            testing.expect(t,!core.has(&w.ids,e) && parent.entity==author)
            if chunk.coord==([3]i32{}) {
                shown,_:=core.get(core.read(&w.statics),e)
                testing.expect_value(t,shown.mesh,resident_source_find(&resident,id,author).chunks[0].mesh)
            }
            count+=1
        }
        testing.expect_value(t,count,author==owner && !keep_original?0:4)
    }
    }
}

@(test)
changing_the_source_retires_only_previous_chunks_before_publishing_the_new_shape :: proc(t:^testing.T) {
    root:=source_test_path("rebound-source");os.make_directory_all(root);defer os.remove_all(root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    ids:=[2]base.Asset_Id{{97,98},{99,100}}
    for samples,index in ([2][3]int{{9,1,9},{5,1,9}}) {
        source:Source
        testing.expect(t,source_make(&source,.Heightfield,samples,1,4))
        source.revision=index==0?1:7
        testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source%d.terrain",root,index),ids[index],&types),asset.Error.None)
        source_destroy(&source)
    }
    for preloaded in ([2]bool{false,true}) {
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=32}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World;terrain_test_world_init(&w);defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&w.entities)
    core.add(&w.ids,owner,{value=1})
    core.add(&w.locals,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=ids[0],revision=1,solid=true})
    shared:[2]core.Entity
    if preloaded {
        for &e,index in shared {
            e=core.create(&w.entities)
            core.add(&w.ids,e,{value=base.Entity_Id(index+2)})
            core.add(&w.locals,e,core.TRANSFORM_IDENTITY)
            core.add(&w.terrains,e,Terrain{source=ids[1],revision=1,solid=true})
        }
    }
    terrain_test_world_settle(&w)
    terrain_test_update(&w,&resident,&app)
    if !testing.expect(t,len(w.chunks.values)==(preloaded?8:4) && len(resident.owners)==(preloaded?3:1)) {return}
    if preloaded {
        for e in shared {
            marker,_:=core.get(core.read(&w.terrains),e)
            testing.expect(t,marker.revision==7,"cold load aligns all owners to the canonical file revision")
        }
    }
    previous:[4]core.Entity
    copy(previous[:],resident.owners[0].chunks)
    retired:[4]base.Asset_Id
    bound,_:=core.get(core.read(&w.terrains),owner)
    mine:=resident_source_find(&resident,bound.source,owner)
    for chunk,index in mine.chunks[:mine.quad.first[1]] {retired[index]=chunk.mesh}
    core.get(&w.terrains,owner).source=ids[1]
    terrain_test_update(&w,&resident,&app)
    for e in previous {testing.expect(t,!core.alive(&w.entities,e),"previous chunks retire before the new source publishes")}
    for id in retired {testing.expect(t,!host.assets_mesh_generated(&assets,id),"the unused source releases its immutable geometry")}
    current:[2]core.Entity
    // Each terrain has its own pieces.
    if !testing.expect(t,len(resident.owners)==(preloaded?3:1) && len(resident.sources)==(preloaded?3:1) && len(w.chunks.values)==(preloaded?6:2)) {return}
    for value in resident.owners {if value.entity==owner {copy(current[:],value.chunks)}}
    marker,_:=core.get(core.read(&w.terrains),owner)
    testing.expect(t,marker.revision==7,"binding another source does not retain the previous source revision")
    static,_:=core.get(core.read(&w.statics),owner)
    testing.expect(t,static.mesh=={} && !core.has(&w.chunks,owner))
    testing.expect_value(t,len(w.colliders.values),preloaded?6:2)
    for e in current {
        chunk,_:=core.get(core.read(&w.chunks),e)
        parent,_:=core.get(core.read(&w.parents),e)
        shown,_:=core.get(core.read(&w.statics),e)
        testing.expect(t,core.alive(&w.entities,e) && !core.has(&w.ids,e) && chunk.owner==owner && parent.entity==owner && host.assets_mesh_generated(&assets,shown.mesh))
    }
    built,structure,version,loads,markers_version:=resident.stats.built,assets.structure,w.statics.version,w.data.stats.loads,w.terrains.version
    for _ in 0..<10 {terrain_test_update(&w,&resident,&app)}
    testing.expect_value(t,resident.stats.built,built)
    testing.expect_value(t,assets.structure,structure)
    testing.expect_value(t,w.statics.version,version)
    testing.expect_value(t,w.data.stats.loads,loads)
    testing.expect_value(t,w.terrains.version,markers_version)
    testing.expect(t,len(w.chunks.values)==(preloaded?6:2) && len(w.colliders.values)==(preloaded?6:2),"stable updates keep the replacement source and its colliders")
    for value in resident.owners {if value.entity==owner {testing.expect(t,value.chunks[0]==current[0] && value.chunks[1]==current[1])}}
    }
}

@(private)
Terrain_Test_Allocator :: struct {owner:runtime.Allocator,requests:u64}
@(private)
terrain_test_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    counter:=(^Terrain_Test_Allocator)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {intrinsics.atomic_add(&counter.requests,1)}
    return counter.owner.procedure(counter.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(private)
Terrain_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    terrains:core.Table(Terrain),
    chunks:core.Table(Terrain_Chunk),
    statics:core.Table(render.Mesh_Renderer),
    locals:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    colliders:core.Table(phys.Collider),
    tints:core.Table(render.Tint),
    overrides:core.Table(render.Material_Override),
    poses:core.Table(core.World_Transform), // stays empty: the owners stand at the origin
    sources:scene.Streaming_Sources,
    physics_settings:phys.Physics_Settings,
    data:Terrain_Data,
    requests:Terrain_Requests,
    digs:Terrain_Digs,
    physics:phys.Physics_State,
    collision_meshes:phys.Collider_Meshes,
    rigids:core.Table(phys.Rigid_Body),
    characters:core.Table(phys.Character),
    moves:core.Table(phys.Character_Move),
    joints:core.Table(phys.Joint),
    names:core.Table(core.Name),
    body_states:core.Table(core.Motion),replicas:core.Table(core.Pose_Target),
    character_states:core.Table(phys.Character_State),
    joint_states:core.Table(phys.Joint_State),
    problems:core.Problems,
    body_requests:phys.Body_Requests,
    events:phys.Physics_Events,
    info:core.World_Info,
    tables:[9]core.Table_Info,
}

@(private)
terrain_test_world_init :: proc(w:^Terrain_Test_World) {
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id")
    core.table_init(&w.terrains,"Terrain");core.table_init(&w.chunks,"Terrain_Chunk")
    core.table_init(&w.statics,"Mesh_Renderer");core.table_init(&w.locals,"Transform")
    core.table_init(&w.parents,"Parent");core.table_init(&w.colliders,"Collider")
    core.table_init(&w.tints,"Tint");core.table_init(&w.overrides,"Material_Override")
    w.tables={
        {type=core.Id,info=type_info_of(core.Id),offset=offset_of(Terrain_Test_World,ids)},
        {type=Terrain,info=type_info_of(Terrain),offset=offset_of(Terrain_Test_World,terrains)},
        {type=Terrain_Chunk,info=type_info_of(Terrain_Chunk),offset=offset_of(Terrain_Test_World,chunks)},
        {type=render.Mesh_Renderer,info=type_info_of(render.Mesh_Renderer),offset=offset_of(Terrain_Test_World,statics)},
        {type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Terrain_Test_World,locals)},
        {type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Terrain_Test_World,parents)},
        {type=phys.Collider,info=type_info_of(phys.Collider),offset=offset_of(Terrain_Test_World,colliders)},
        {type=render.Tint,info=type_info_of(render.Tint),offset=offset_of(Terrain_Test_World,tints)},
        {type=render.Material_Override,info=type_info_of(render.Material_Override),offset=offset_of(Terrain_Test_World,overrides)},
    }
    w.info={entities=offset_of(Terrain_Test_World,entities),tables=w.tables[:]}
}

@(private)
terrain_test_world_settle :: proc(w:^Terrain_Test_World) {
    core.table_settle(&w.ids,&w.entities)
    core.table_settle(&w.terrains,&w.entities);core.table_settle(&w.chunks,&w.entities)
    core.table_settle(&w.statics,&w.entities);core.table_settle(&w.locals,&w.entities)
    core.table_settle(&w.parents,&w.entities);core.table_settle(&w.colliders,&w.entities)
    core.table_settle(&w.tints,&w.entities);core.table_settle(&w.overrides,&w.entities)
    core.table_settle(&w.rigids,&w.entities);core.table_settle(&w.characters,&w.entities)
    core.table_settle(&w.moves,&w.entities);core.table_settle(&w.joints,&w.entities)
    core.table_settle(&w.names,&w.entities);core.table_settle(&w.body_states,&w.entities)
    core.table_settle(&w.character_states,&w.entities);core.table_settle(&w.joint_states,&w.entities)
    core.entities_settle(&w.entities)
}

@(private)
terrain_test_world_free :: proc(w:^Terrain_Test_World) {
    core.table_destroy(&w.ids)
    terrain_data_free(&w.data);core.value_free(&w.requests,type_info_of(Terrain_Requests));core.value_free(&w.digs,type_info_of(Terrain_Digs))
    phys.state_destroy(&w.physics);phys.collider_meshes_destroy(&w.collision_meshes)
    core.value_free(&w.body_requests,type_info_of(phys.Body_Requests));core.value_free(&w.events,type_info_of(phys.Physics_Events))
    core.table_destroy(&w.terrains);core.table_destroy(&w.chunks);core.table_destroy(&w.statics);core.table_destroy(&w.locals)
    core.table_destroy(&w.parents);core.table_destroy(&w.colliders);core.table_destroy(&w.tints);core.table_destroy(&w.overrides)
    core.table_destroy(&w.poses)
    core.table_destroy(&w.rigids);core.table_destroy(&w.characters);core.table_destroy(&w.moves);core.table_destroy(&w.joints)
    core.table_destroy(&w.names);core.table_destroy(&w.body_states);core.table_destroy(&w.character_states);core.table_destroy(&w.joint_states)
    core.entities_destroy(&w.entities)
}

@(private)
terrain_test_world_copy :: proc(dst,src:^Terrain_Test_World) {
    core.entities_copy(&dst.entities,&src.entities)
    core.table_copy(&dst.ids,&src.ids)
    core.table_copy(&dst.terrains,&src.terrains);core.table_copy(&dst.chunks,&src.chunks)
    core.table_copy(&dst.statics,&src.statics);core.table_copy(&dst.locals,&src.locals)
    core.table_copy(&dst.parents,&src.parents);core.table_copy(&dst.colliders,&src.colliders)
    core.table_copy(&dst.tints,&src.tints);core.table_copy(&dst.overrides,&src.overrides)
    core.table_copy(&dst.rigids,&src.rigids);core.table_copy(&dst.characters,&src.characters)
    core.table_copy(&dst.moves,&src.moves);core.table_copy(&dst.joints,&src.joints)
    core.table_copy(&dst.names,&src.names);core.table_copy(&dst.body_states,&src.body_states)
    core.table_copy(&dst.character_states,&src.character_states);core.table_copy(&dst.joint_states,&src.joint_states)
    terrain_data_copy(&dst.data,&src.data)
    phys.state_copy(&dst.physics,&src.physics)
}

@(private)
// Puts a source in the memory of the registry of the assets, unsaved, as the
// editor writes it.
terrain_test_write :: proc(t:^testing.T,assets:^host.Assets,path:string,source:^Source,id:base.Asset_Id) {
    bytes,error:=source_bytes(source,id,&assets.types)
    defer delete(bytes)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,asset.registry_memory_set(&assets.registry,path,bytes),asset.Error.None)
}

terrain_test_tables :: proc(w:^Terrain_Test_World) -> Chunk_Tables {
    return {core.commands(w,&w.info),&w.chunks,core.read(&w.locals),core.read(&w.parents),core.read(&w.ids),&w.colliders,&w.statics,&w.tints,&w.overrides}
}

// What the tests run with unless they say: every chunk at level 0, so that a
// count of builds does not follow the levels an edit changes.
// A dig in the world edits the terrain it touches, in the space of its source;
// one that touches none asks nothing.
@(test)
a_dig_finds_the_terrain_it_touches_and_reads_in_its_space :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    terrains:core.Table(Terrain);core.table_init(&terrains,"Terrain");defer core.table_destroy(&terrains)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    data:Terrain_Data;defer delete(data.entries)
    append(&data.entries,Data_Source{id={1,0}})
    testing.expect(t,source_make(&data.entries[0].source,.Heightfield,{33,1,33},1,32));defer source_destroy(&data.entries[0].source)
    near,far:=core.create(&es),core.create(&es)
    for e,i in ([2]core.Entity{near,far}) {
        core.add(&terrains,e,Terrain{source={1,0},solid=true})
        core.add(&worlds,e,core.World_Transform{transform={position={f32(i)*500,0,0},rotation=1,scale=2}})
    }
    core.table_settle(&terrains,&es);core.table_settle(&worlds,&es)
    brush:=Brush{kind=.Raise,center={510,1,6},radius=4,amount=1,normal={0,1,0},rotation=1}
    resolved,ok:=edit_resolve(Edit_Request{brush=brush},&data,core.read(&terrains),core.read(&worlds))
    testing.expect(t,ok && resolved.owner==far)
    testing.expect_value(t,resolved.brush.center,[3]f32{5,0.5,3})
    testing.expect_value(t,resolved.brush.radius,f32(2))
    testing.expect_value(t,resolved.brush.amount,f32(0.5))
    brush.center={1000,0,6}
    _,ok=edit_resolve(Edit_Request{brush=brush},&data,core.read(&terrains),core.read(&worlds))
    testing.expect(t,!ok,"a dig that touches no terrain asks nothing")
    resolved,ok=edit_resolve(Edit_Request{brush=brush,owner=near},&data,core.read(&terrains),core.read(&worlds))
    testing.expect(t,ok && resolved.owner==near,"a dig that names its terrain is not searched for")
}

TERRAIN_TEST_SETTINGS :: Terrain_Settings{lod_distance=-1}

terrain_test_update :: proc(w:^Terrain_Test_World,resident:^Terrain_Resident,app:^host.App,time:core.Time={},view:=core.View{},settings:=TERRAIN_TEST_SETTINGS) {
    // A tick, and those that take what its jobs built: a rebuilt chunk shows in the tick after it changed.
    terrain_test_tick(w,resident,app,time,view,settings)
    for _ in 0..<8 {
        if !work_busy(&w.data,nil) {break}
        terrain_test_tick(w,resident,app,{},view,settings)
    }
}

terrain_test_tick :: proc(w:^Terrain_Test_World,resident:^Terrain_Resident,app:^host.App,time:core.Time={},view:=core.View{},settings:=TERRAIN_TEST_SETTINGS) {
    c:=terrain_test_tables(w)
    physics:=w.physics_settings
    if physics=={} {physics=phys.Physics_Settings{bodies=64,shapes=64,contacts=64,joints=1,characters=1,hulls=1,meshes=64,heightfields=64}}
    terrain_update(c.commands,&w.terrains,c.chunks,c.locals,c.parents,c.ids,c.colliders,c.meshes,c.tints,c.overrides,&w.data,resident,&w.requests,&w.digs,settings,app,{playing=true},{phase=.Fixed},view,core.read(&w.poses),core.ref(&w.sources),{},physics,{},nil,&w.problems,{})
    terrain_test_world_settle(w)
    phys.physics_step(&w.physics,{&physics},&w.body_requests,&w.events,&w.collision_meshes,app,time,
        core.read(&w.rigids),core.read(&w.colliders),core.read(&w.characters),core.read(&w.moves),&w.joints,
        core.read(&w.statics),core.read(&w.parents),core.read(&w.names),&w.locals,&w.body_states,core.read(&w.replicas),&w.character_states,&w.joint_states,{},nil,{},{},nil,nil,&w.problems,{},{},{},{},{},{})
    terrain_test_world_settle(w)
}

@(test)
terrain_copy_republishes_identical_chunks_without_losing_contacts_or_changing_resimulation :: proc(t:^testing.T) {
    for kind in ([2]Source_Kind{.Heightfield,.Volume}) {
    root:=source_test_path(fmt.tprintf("warmstart-%v",kind));os.make_directory_all(root);defer os.remove_all(root)
    samples:=kind==.Heightfield?[3]int{9,1,9}:[3]int{9,9,9}
    source:Source;testing.expect(t,source_make(&source,kind,samples,1,4));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{73,74}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=32}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    worlds:[2]Terrain_Test_World
    for &w in worlds {terrain_test_world_init(&w)}
    defer for &w in worlds {terrain_test_world_free(&w)}
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    w:=&worlds[0]
    owner,ball:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.locals,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,solid=true})
    core.add(&w.locals,ball,core.Transform{position={-0.25,0.49,-0.25},rotation=1,scale={1,1,1}})
    core.add(&w.rigids,ball,phys.RIGID_BODY_DYNAMIC)
    core.add(&w.colliders,ball,phys.collider_sphere(0.5))
    terrain_test_world_settle(w)
    tick:=core.Time{playing=true,dt=1.0/60}
    for _ in 0..<12 {terrain_test_update(w,&resident,&app,tick)}
    body:=phys.body_of({&w.physics},ball)
    contacts:[16]sim.Contact_Info
    testing.expect(t,sim.body_contacts(&w.physics.world,body,contacts[:])>0)
    cloned:=&worlds[1]
    terrain_test_world_copy(cloned,w)
    hash:=sim.world_hash(&cloned.physics.world)
    velocity:=sim.body_linear_velocity(&cloned.physics.world,body)
    terrain_test_update(cloned,&resident,&app)
    testing.expect_value(t,sim.world_hash(&cloned.physics.world),hash)
    testing.expect_value(t,sim.body_linear_velocity(&cloned.physics.world,body),velocity)
    testing.expect(t,sim.body_contacts(&cloned.physics.world,body,contacts[:])>0)
    for _ in 0..<6 {
        terrain_test_update(w,&resident,&app,tick)
        terrain_test_update(cloned,&resident,&app,tick)
        testing.expect_value(t,sim.world_hash(&cloned.physics.world),sim.world_hash(&w.physics.world))
        testing.expect_value(t,sim.body_linear_velocity(&cloned.physics.world,body),sim.body_linear_velocity(&w.physics.world,body))
    }
    }
}

@(test)
terrain_runtime_publishes_only_dirty_chunks_and_copies_play_and_rollback_with_collision :: proc(t:^testing.T) {
    heap:base.Heap;testing.expect(t,base.heap_init(&heap,32*1024*1024));defer base.heap_destroy(&heap)
    allocator:=Terrain_Test_Allocator{owner=base.heap_allocator(&heap)}
    temporary:base.Arena;testing.expect(t,base.arena_init(&temporary,16*1024*1024));defer base.arena_destroy(&temporary)
    context.allocator={terrain_test_allocator,&allocator}
    context.temp_allocator=base.arena_allocator(&temporary)
    root:=source_test_path("runtime");os.make_directory_all(root);defer os.remove_all(root)
    path:=fmt.tprintf("%s/source.terrain",root)
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{17,1,17},1,4));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{47,48}
    testing.expect_value(t,source_save(&source,path,id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=64}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    worlds:[2]Terrain_Test_World
    for &w in worlds {terrain_test_world_init(&w)}
    defer for &w in worlds {terrain_test_world_free(&w)}
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    w:=&worlds[0]
    owner:=core.create(&w.entities)
    core.add(&w.locals,owner,core.Transform{position={10,4,20},rotation=1,scale={1,1,1}})
    core.add(&w.terrains,owner,Terrain{source=id,solid=true})
    terrain_test_world_settle(w)
    terrain_test_update(w,&resident,&app)
    if !testing.expectf(t,len(w.data.entries)>0,"source load failed: files %v, problems %v, root %s",assets.registry.files[:],core.problems_list(&w.problems),root) {return}
    marker,_:=core.get(core.read(&w.terrains),owner)
    testing.expect_value(t,marker.revision,u32(1))
    testing.expect_value(t,len(w.chunks.values),16)
    testing.expect_value(t,len(w.colliders.values),16)
    testing.expect_value(t,resident.stats.built,u64(16))
    testing.expect_value(t,w.data.stats.loads,u64(1))
    before:[16]base.Asset_Id
    for chunk,i in resident.sources[0].chunks[:resident.sources[0].quad.first[1]] {before[i]=chunk.mesh}
    dig(&w.requests,{kind=.Raise,center={-6,0,-6},radius=0.4,amount=1},owner)
    terrain_test_update(w,&resident,&app)
    changed:=0
    for chunk,i in resident.sources[0].chunks[:resident.sources[0].quad.first[1]] {if chunk.mesh!=before[i] {changed+=1}}
    testing.expect_value(t,changed,1)
    testing.expect_value(t,resident.stats.built,u64(17))
    hit,hit_ok:=phys.raycast({&w.physics},{4,20,14},{0,-1,0})
    testing.expect(t,hit_ok && abs(hit.point.y-5)<1e-4)
    disk:Source;defer source_destroy(&disk)
    _,loaded:=source_load(&disk,path,&types);testing.expect(t,loaded)
    testing.expect_value(t,source_value(&disk,{2,0,2}),f32(0))
    calls,temps:=allocator.requests,temporary.requests
    version,structure,built:=w.statics.version,assets.structure,resident.stats.built
    for _ in 0..<10 {terrain_test_update(w,&resident,&app)}
    stable_calls,stable_temps:=allocator.requests,temporary.requests
    testing.expect_value(t,stable_calls,calls);testing.expect_value(t,stable_temps,temps)
    testing.expect_value(t,w.statics.version,version);testing.expect_value(t,assets.structure,structure)
    testing.expect_value(t,resident.stats.built,built);testing.expect_value(t,w.data.stats.loads,u64(1))
    copy_world:=&worlds[1]
    terrain_test_world_copy(copy_world,w)
    dig(&copy_world.requests,{kind=.Raise,center={-6,0,-6},radius=0.4,amount=1},owner)
    terrain_test_update(copy_world,&resident,&app)
    testing.expect_value(t,source_value(&w.data.entries[0].source,{2,0,2}),f32(1))
    hit,hit_ok=phys.raycast({&copy_world.physics},{4,20,14},{0,-1,0})
    testing.expect(t,hit_ok && abs(hit.point.y-6)<1e-4)
    terrain_test_world_copy(copy_world,w)
    terrain_test_update(copy_world,&resident,&app)
    hit,hit_ok=phys.raycast({&copy_world.physics},{4,20,14},{0,-1,0})
    testing.expect(t,hit_ok && abs(hit.point.y-5)<1e-4)
    request_save(&copy_world.requests,owner)
    terrain_test_update(copy_world,&resident,&app)
    _,loaded=source_load(&disk,path,&types);testing.expect(t,loaded)
    testing.expect_value(t,source_value(&disk,{2,0,2}),f32(1))
    testing.expect_value(t,copy_world.data.stats.saves,u64(1))
    testing.expect_value(t,w.problems.count+copy_world.problems.count,0)
    testing.expect_value(t,copy_world.problems.count,0)
    core.remove(&copy_world.terrains,owner);terrain_test_world_settle(copy_world)
    terrain_test_update(copy_world,&resident,&app)
    testing.expect_value(t,len(copy_world.chunks.values),0)
    testing.expect_value(t,len(copy_world.data.entries),0)
    testing.expect_value(t,resident.stats.meshes,u32(0))
    testing.expect_value(t,heap.failed,u64(0))
}

@(test)
volume_runtime_keeps_empty_chunk_identity_and_updates_collision_when_material_appears_or_disappears :: proc(t:^testing.T) {
    root:=source_test_path("volume-runtime");os.make_directory_all(root);defer os.remove_all(root)
    source:Source;testing.expect(t,source_make(&source,.Volume,{17,17,17},1,8));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{81,82}
    path:=fmt.tprintf("%s/volume.terrain",root)
    testing.expect_value(t,source_save(&source,path,id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=32}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World;terrain_test_world_init(&w);defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&w.entities)
    core.add(&w.locals,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,solid=true})
    terrain_test_world_settle(&w);terrain_test_update(&w,&resident,&app)
    testing.expect_value(t,len(w.chunks.values),8)
    testing.expect_value(t,len(w.colliders.values),4)
    identities:[8]core.Entity
    copy(identities[:],resident.owners[0].chunks)
    dig(&w.requests,{kind=.Add,center={0,3,0},radius=1.5,amount=1},owner)
    terrain_test_update(&w,&resident,&app)
    hit,ok:=phys.raycast({&w.physics},{0,8,0},{0,-1,0})
    testing.expect(t,ok && abs(hit.point.y-4.5)<1e-3)
    testing.expect(t,len(w.colliders.values)>4)
    for e,i in resident.owners[0].chunks {testing.expect_value(t,e,identities[i])}
    testing.expect_value(t,len(w.digs.digs.items),0)
    dig(&w.requests,{kind=.Remove,center={0,0,0},radius=30,amount=1},owner)
    terrain_test_update(&w,&resident,&app)
    // What it took is published once: the box of the source and what Add gave it.
    testing.expect_value(t,len(w.digs.digs.items),1)
    if len(w.digs.digs.items)==1 {
        dig:=w.digs.digs.items[0]
        testing.expect(t,dig.owner==owner && dig.source==id && dig.layers[0]==dig.volume)
        testing.expectf(t,abs(dig.volume-14*7*14)<14*7*14*0.1,"the box holds about %v cubic metres, it took %v",14*7*14,dig.volume)
        testing.expectf(t,abs(dig.center.x)<0.2 && abs(dig.center.z)<0.2 && dig.center.y<-2 && dig.center.y>-4,"%v",dig.center)
    }
    _,ok=phys.raycast({&w.physics},{0,8,0},{0,-1,0});testing.expect(t,!ok)
    testing.expect_value(t,len(w.chunks.values),8)
    testing.expect_value(t,len(w.colliders.values),0)
    testing.expect_value(t,len(w.statics.values),0)
    testing.expect_value(t,resident.stats.meshes,u32(0))
    testing.expect_value(t,w.problems.count,0)
}

@(test)
terrain_runtime_reads_unsaved_sources_and_follows_a_discard_without_reloading_each_frame :: proc(t:^testing.T) {
    root:=source_test_path("unsaved");os.make_directory_all(root);defer os.remove_all(root)
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{9,1,9},1,4));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id,fresh:=base.Asset_Id{91,92},base.Asset_Id{93,94}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=32}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World;terrain_test_world_init(&w);defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner,added:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.locals,owner,core.TRANSFORM_IDENTITY);
    core.add(&w.terrains,owner,Terrain{source=id,revision=1,solid=true})
    terrain_test_world_settle(&w);terrain_test_update(&w,&resident,&app)
    testing.expect_value(t,w.data.stats.loads,u64(1))
    middle:=[3]int{4,0,4}
    source_set(&source,middle,3);source.revision=2
    terrain_test_write(t,&assets,"source.terrain",&source,id)
    core.get(&w.terrains,owner).revision=2
    for _ in 0..<4 {terrain_test_update(&w,&resident,&app)}
    testing.expect_value(t,w.data.stats.loads,u64(2))
    testing.expect_value(t,source_value(&w.data.entries[0].source,middle),f32(3))
    // A source that only the memory of the registry holds, as a new terrain.
    terrain_test_write(t,&assets,"terrain/new.terrain",&source,fresh)
    testing.expect(t,!os.exists(fmt.tprintf("%s/terrain/new.terrain",root)))
    core.add(&w.locals,added,core.TRANSFORM_IDENTITY);
    core.add(&w.terrains,added,Terrain{source=fresh,solid=true})
    terrain_test_world_settle(&w)
    for _ in 0..<4 {terrain_test_update(&w,&resident,&app)}
    testing.expect_value(t,w.data.stats.loads,u64(3))
    testing.expect_value(t,len(w.data.entries),2)
    // Discard: the file on disk answers again, and the owners keep the
    // revision of their history.
    {dropped,_:=asset.registry_memory_drop(&assets.registry,"source.terrain");testing.expect(t,dropped)}
    for _ in 0..<4 {terrain_test_update(&w,&resident,&app)}
    testing.expect_value(t,w.data.stats.loads,u64(4))
    entry:=data_find(&w.data,id)
    if !testing.expect(t,entry!=nil) {return}
    testing.expect_value(t,source_value(&entry.source,middle),f32(0))
    testing.expect_value(t,entry.source.revision,u32(1))
    testing.expect_value(t,core.get(&w.terrains,owner).revision,u32(2))
    testing.expect_value(t,w.problems.count,0)
}

@(test)
terrains_that_cannot_load_or_be_edited_report_their_entity_and_the_fix :: proc(t:^testing.T) {
    root:=source_test_path("problems");os.make_directory_all(root);defer os.remove_all(root)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=8}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World;terrain_test_world_init(&w);defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    missing:=base.Asset_Id{0xabc,0xdef}
    owner,stranger:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.locals,owner,core.TRANSFORM_IDENTITY);
    core.add(&w.terrains,owner,Terrain{source=missing,solid=true})
    terrain_test_world_settle(&w)
    dig(&w.requests,{kind=.Raise,center={0,0,0},radius=1,amount=1},stranger)
    dig(&w.requests,{kind=.Raise,center={0,0,0},radius=1,amount=1},owner)
    for _ in 0..<3 {terrain_test_update(&w,&resident,&app)}
    unread:=core.problem_find(&w.problems,owner,"terrain.source_unread")
    if testing.expect(t,unread!=nil) {
        testing.expect_value(t,unread.count,u64(3))
        text:=core.problem_text(unread)
        testing.expect(t,strings.contains(text,"0000000000000abc0000000000000def"),text)
        testing.expect(t,strings.contains(text,"set Terrain.source to a .terrain of the assets"),text)
    }
    stranger_problem:=core.problem_find(&w.problems,stranger,"terrain.request_owner")
    testing.expect(t,stranger_problem!=nil && strings.contains(core.problem_text(stranger_problem),"has no Terrain"))
    testing.expect(t,core.problem_find(&w.problems,owner,"terrain.not_loaded")!=nil)
    testing.expect_value(t,w.problems.count,3)
}
