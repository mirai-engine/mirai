package foliage_editor

import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"

// foliage.query counts the instances of each layer over the cells the graph
// built, and lists those in the box of the world, in the frame of the graph,
// up to its limit.
@(test)
a_query_counts_the_layers_and_lists_the_instances_in_its_box :: proc(t:^testing.T) {
    s:pcg.Pcg_Source
    pcg.source_init(&s)
    defer pcg.source_destroy(&s)
    tree:=pcg.source_layer_add(&s,.Scatter,.Macro)
    tree.asset,tree.collides=base.Asset_Id{7,7},true
    grass:=pcg.source_layer_add(&s,.Scatter,.Meso)
    grass.filler=true
    ids:=[2]u32{tree.id,grass.id}
    g:pcg.Pcg_Generated
    defer pcg.pcg_generated_free(&g)
    append(&g.graphs,pcg.Generated_Graph{entity=1,cells=make([dynamic]pcg.Generated_Cell)})
    gen:=&g.graphs[0]
    at :: proc(layer:u32,id:u64,x:f32) -> pcg.Placed {return {position={x,0,1},rotation=1,scale={1,2,1},id=id,layer=layer}}
    for coord,k in ([3][2]i32{{0,0},{1,0},{2,0}}) {
        cell:=pcg.Generated_Cell{coord=coord,built=k<2,placed=make([dynamic]pcg.Placed)}
        x:=f32(k)*32
        append(&cell.placed,at(ids[0],1,x+1),at(ids[1],2,x+2),at(ids[1],3,x+3))
        append(&gen.cells,cell)
    }
    r:Foliage_Query_Result
    frame:=mm.Transform{position={100,0,0},rotation=1,scale={1,1,1}}
    query_fill(&r,&s,gen,frame,true,{100,-1,0},{135,1,2},2,context.temp_allocator)
    testing.expect_value(t,r.cells,2)
    testing.expect(t,len(r.layers)==2 && r.layers[0].instances==2 && r.layers[1].instances==4,"the cell not built yet counts nothing")
    testing.expect(t,r.layers[0].asset==base.Asset_Id{7,7} && r.layers[0].collides && r.layers[1].filler)
    testing.expect(t,len(r.instances)==2 && r.more,"three in the box, two listed")
    testing.expect(t,r.instances[0].position==[3]f32{101,0,1} && r.instances[0].coord==[2]i32{0,0} && r.instances[0].scale==[3]f32{1,2,1})
    r={}
    query_fill(&r,&s,gen,frame,false,{},{},2,context.temp_allocator)
    testing.expect(t,r.instances==nil && !r.more,"without a box only the counts")
}
