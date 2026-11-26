package terrain

import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import gpu "mirai:render"
import "mirai:std/base"

// The renderer keeps the color of the ground of the Heightfield chunks shown,
// as many as it has slots for, the nearest to the view: a node of the
// quadtree, a chunk of a Volume and one of a terrain turned keep none; a view
// that moves on gives the slots of the farthest to the nearest, one that
// moves less than GROUND_VIEW_STEP changes nothing, and a chunk that goes
// leaves its slot to the next.
@(test)
the_nearest_heightfield_chunks_keep_the_color_of_their_ground :: proc(t:^testing.T) {
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    r:=new(gpu.Renderer);defer free(r)
    r.allocator=context.allocator
    r.settings.ground_chunks=4
    sync:render.Render_Sync;defer render.sync_free(&sync)
    field,volume:=base.Asset_Id{93,7},base.Asset_Id{93,8}
    append(&w.data.entries,Data_Source{id=field},Data_Source{id=volume})
    defer clear(&w.data.entries)
    w.data.entries[0].source.info={kind=.Heightfield,cell=1,chunk_cells=10}
    w.data.entries[1].source.info={kind=.Volume,cell=1,chunk_cells=10}
    Owner :: struct {source:base.Asset_Id,turned:bool}
    owners:[3]core.Entity
    for owner,i in ([3]Owner{{field,false},{volume,false},{field,true}}) {
        owners[i]=core.create(&w.entities)
        place:=core.World_Transform{transform={rotation=owner.turned?quaternion(w=0.92387953,x=0,y=0.38268343,z=0):1,scale=1}}
        core.add(&w.terrains,owners[i],Terrain{source=owner.source})
        core.add(&w.worlds,owners[i],place)
    }
    // Nine chunks of 10 m of the first terrain, a node over them, and a chunk of each of the others.
    Piece :: struct {owner:int,low:[2]f32,depth:u8}
    pieces:[12]Piece
    for &piece,i in pieces[:9] {piece={0,{f32(i%3)*10,f32(i/3)*10},0}}
    pieces[9],pieces[10],pieces[11]={0,{0,0},1},{1,{0,0},0},{2,{0,0},0}
    entities:[12]core.Entity
    for piece,i in pieces {
        e:=core.create(&w.entities)
        entities[i]=e
        place:=core.World_Transform{transform={position={piece.low.x,0,piece.low.y},rotation=piece.owner==2?quaternion(w=0.92387953,x=0,y=0.38268343,z=0):1,scale=1}}
        core.add(&w.chunks,e,Terrain_Chunk{owner=owners[piece.owner],depth=piece.depth,revision=1})
        core.add(&w.worlds,e,place)
        core.add(&w.statics,e,render.Mesh_Renderer{})
        _,drawn:=core.entity_map_put(&sync.drawn,e,render.Drawn{})
        testing.expect(t,drawn)
    }
    test_world_settle(&w.w)
    ground:Terrain_Ground_Color
    Step :: struct {
        view:[2]f32,    // x and z of the view
        gone:int,       // the piece whose chunk goes before it; -1: none
        kept:[4][2]f32, // where the chunks that keep their color start
    }
    steps:=[]Step{
        {{5,5},-1,{{0,0},{10,0},{0,10},{10,10}}},
        {{6,6},-1,{{0,0},{10,0},{0,10},{10,10}}},
        {{25,25},-1,{{20,20},{10,20},{20,10},{10,10}}},
        // Halfway back, the chunks kept are not far enough to give up their slots.
        {{17,17},-1,{{20,20},{10,20},{20,10},{10,10}}},
        {{25,27},8,{{10,20},{20,10},{10,10},{0,20}}},
    }
    for step,i in steps {
        if step.gone>=0 {
            core.remove(&w.chunks,entities[step.gone])
            test_world_settle(&w.w)
        }
        view:=core.VIEW_DEFAULT
        view.position={step.view.x,3,step.view.y}
        r.error=""
        terrain_ground_color(&ground,core.ref(&w.data),core.read(&w.terrains),core.read(&w.chunks),core.read(&w.worlds),core.read(&w.looks),core.read(&w.statics),core.ref(&sync),r,view)
        testing.expectf(t,r.error=="","step %d: %s",i,r.error)
        if !testing.expectf(t,ground.count==4,"step %d: %d chunks keep their color",i,ground.count) {continue}
        for low in step.kept {
            kept:=false
            for held in ground.shown[:ground.count] {kept||=held==low}
            testing.expectf(t,kept,"step %d: the chunk at %v keeps its color: %v",i,low,ground.shown[:ground.count])
        }
    }
}
