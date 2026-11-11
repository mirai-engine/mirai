package terrain

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

@(private)
Terrain_Chunk_Damage :: enum {Local,Local_Restored,Parent,Wrong_Parent,Owner,Author}

@(test)
incomplete_terrain_chunks_are_reconstructed_without_ghosts_or_changes_to_authors :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{9,1,9},1,4));defer source_destroy(&source)
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{101,102}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    for damage in Terrain_Chunk_Damage {
        assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=32}));defer host.assets_destroy(&assets)
        app:=host.App{assets=&assets,allocator=context.allocator}
        w:Terrain_Test_World
        if !terrain_test_world_init(t,&w) {return}
        defer terrain_test_world_free(&w)
        resident:Terrain_Resident;defer terrain_resident_free(&resident)
        owner:=core.create(&w.entities)
        core.add(&w.ids,owner,{value=1})
        core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
        core.add(&w.terrains,owner,Terrain{source=id,revision=1,solid=true})
        author:=core.NONE
        if damage==.Wrong_Parent {
            author=core.create(&w.entities)
            core.add(&w.ids,author,{value=2})
            core.add(&w.transforms,author,core.TRANSFORM_IDENTITY)
            core.add(&w.statics,author,render.Mesh_Renderer{})
        }
        test_world_settle(&w.w)
        terrain_test_update(&w,&resident,&app)
        terrain_test_update(&w,&resident,&app)
        if !testing.expect(t,len(resident.owners)==1 && len(w.chunks.values)==4) {return}
        stale:=resident.owners[0].chunks[0]
        epoch,built,loads:=w.data.epoch,resident.stats.built,w.data.stats.loads
        switch damage {
        case .Local,.Local_Restored:
            core.remove(&w.transforms,stale)
            test_world_settle(&w.w)
            tables:=terrain_test_tables(&w)
            testing.expect(t,!chunk_entity_matches(&tables,stale,owner,{},0))
            // Restored where its mesh is relative to: the place of its chunk.
            if damage==.Local_Restored {place:=core.TRANSFORM_IDENTITY;place.position=chunk_origin(&w.data.entries[0].source,{});core.add(&w.transforms,stale,place)}
        case .Parent:
            core.remove(&w.parents,stale)
        case .Wrong_Parent:
            core.add(&w.parents,stale,core.Parent{entity=author})
        case .Owner:
            core.remove(&w.terrains,owner)
        case .Author:
            author=stale
            core.add(&w.ids,author,{value=2})
            transform:=core.TRANSFORM_IDENTITY;transform.position.x=72
            core.add(&w.transforms,author,transform)
            core.add(&w.statics,author,render.Mesh_Renderer{})
            core.add(&w.terrains,author,Terrain{source=id,revision=1,solid=true})
            core.remove(&w.parents,author)
            core.add(&w.colliders,author,phys.collider_box({1.25,2.5,3.75}))
        }
        test_world_settle(&w.w)
        if damage==.Wrong_Parent {
            // Only a parent written: the prune sees it all the same.
            shapes,parents:=resident.gc_shapes,resident.gc_parents
            testing.expect(t,!(core.reshaped(&w.transforms,&shapes[0]) | core.reshaped(&w.chunks,&shapes[1]) | core.reshaped(&w.ids,&shapes[2]) | core.reshaped(&w.terrains,&shapes[3])))
            testing.expect(t,core.touched(&w.parents,&parents))
        }
        terrain_test_update(&w,&resident,&app)
        testing.expect_value(t,w.data.epoch,epoch)
        testing.expect_value(t,resident.epoch,epoch)
        // A new author of the source builds its own pieces.
        testing.expect_value(t,resident.stats.built,damage==.Author?built+4:built)
        testing.expect_value(t,w.data.stats.loads,loads)
        expected:=damage==.Owner?0:damage==.Author?8:4
        testing.expect_value(t,len(w.chunks.values),expected)
        testing.expect_value(t,w.entities.alive,len(w.ids.values)+expected)
        testing.expect_value(t,len(w.colliders.values),expected+(damage==.Author?1:0))
        if damage==.Local_Restored {testing.expect(t,core.alive(&w.entities,stale) && resident.owners[0].chunks[0]==stale)} else if damage!=.Author {testing.expect(t,!core.alive(&w.entities,stale))}
        tables:=terrain_test_tables(&w)
        for chunk,row in w.chunks.values {
            e:=w.chunks.entities[row]
            testing.expect(t,chunk_entity_matches(&tables,e,chunk.owner,chunk.coord,chunk.depth))
            shown,_:=core.get(&w.statics,e)
            testing.expect(t,host.assets_mesh_generated(&assets,shown.mesh))
        }
        if author!=core.NONE {
            static,_:=core.get(&w.statics,author)
            transform,_:=core.get(&w.transforms,author)
            testing.expect(t,core.alive(&w.entities,author) && core.has(&w.ids,author) && static.mesh=={} && !core.has(&w.chunks,author))
            testing.expect_value(t,transform.position.x,damage==.Author?f32(72):f32(0))
            testing.expect(t,!core.has(&w.parents,author))
            if damage==.Author {
                marker,_:=core.get(&w.terrains,author)
                collider,_:=core.get(&w.colliders,author)
                identity,_:=core.get(&w.ids,author)
                testing.expect(t,marker==(Terrain{source=id,revision=1,solid=true}) && identity.value==2)
                testing.expect_value(t,collider,phys.collider_box({1.25,2.5,3.75}))
            } else {testing.expect(t,!core.has(&w.colliders,author))}
        }
        terrain_test_update(&w,&resident,&app)
        shapes,parents,structure,version:=resident.gc_shapes,resident.gc_parents,assets.structure,w.statics.version
        for _ in 0..<5 {terrain_test_update(&w,&resident,&app)}
        testing.expect(t,resident.gc_shapes==shapes && resident.gc_parents==parents)
        testing.expect_value(t,assets.structure,structure)
        testing.expect_value(t,w.statics.version,version)
        testing.expect_value(t,w.entities.alive,len(w.ids.values)+expected)
    }
}
