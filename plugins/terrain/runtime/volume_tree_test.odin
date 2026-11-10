package terrain

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

// The bytes a grid takes in memory besides the values of its pages: its
// tables of pages and blocks and its directory.
grid_tables_bytes :: proc "contextless" (g:^Grid($T)) -> int {
    return cap(g.pages)*size_of(Page(T))+cap(g.blocks)*size_of(Page_Block)+cap(g.encoded)*size_of(Page_Encoded)+len(g.top)*size_of(Tile)+len(g.tables)*(size_of([TABLE_SLABS]Tile)+size_of(rawptr))+cap(g.slabs)*size_of([3]i32)
}

// A Volume has an octree over its chunks: every chunk is under one root, and
// a node is the welded surface of its chunks, with the vertices on the sides
// it shares locked through every level the renderer makes of it.
@(test)
a_volume_node_is_the_surface_of_its_chunks_and_keeps_the_sides_it_shares_through_its_levels :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    if !testing.expect(t,source_make(&s,.Volume,{129,33,129},1,16)) {return}
    // A hill and a pit, so the surface is not flat across the sides of the nodes.
    testing.expect(t,source_edit(&s,{kind=.Add,center={0,0,0},radius=9,amount=1}).changed)
    testing.expect(t,source_edit(&s,{kind=.Carve,center={20,0,-12},radius=7,amount=1}).changed)
    q:=quad_of(&s)
    chunks:=q.first[1]
    testing.expect_value(t,q.depth,2)
    testing.expect_value(t,chunks,8*2*8)
    testing.expect_value(t,quad_total(&q)-q.first[q.depth],4)
    // Every chunk is one of the chunks of each node over it, up to a root.
    for i in 0..<chunks {
        coord:=chunk_coord(&s,i)
        at,depth:=i,0
        for parent:=quad_parent(&q,at);parent>=0;parent=quad_parent(&q,at) {
            at=parent
            depth+=1
            low,high:=quad_chunks3(&q,at)
            inside:=true
            for axis in 0..<3 {inside&&=int(coord[axis])>=low[axis] && int(coord[axis])<high[axis]}
            if !inside {testing.expectf(t,false,"chunk %v is not under node %d",coord,at);return}
        }
        testing.expect_value(t,depth,q.depth)
    }
    // A node holds the triangles of its chunks.
    piece,node,other:Chunk_Mesh
    chunk_mesh_init(&piece);chunk_mesh_init(&node);chunk_mesh_init(&other)
    defer chunk_mesh_destroy(&piece);defer chunk_mesh_destroy(&node);defer chunk_mesh_destroy(&other)
    first:=q.first[q.depth]
    if !testing.expect(t,node_build(&s,&q,first,{},nil,&node)) {return}
    low,high:=quad_chunks3(&q,first)
    triangles:=0
    for z in low.z..<high.z {for y in low.y..<high.y {for x in low.x..<high.x {
        testing.expect(t,chunk_build(&s,{i32(x),i32(y),i32(z)},&piece,false))
        triangles+=len(piece.geometry.indices)/3
    }}}
    testing.expect(t,triangles>0)
    testing.expect_value(t,len(node.geometry.indices)/3,triangles)
    // The vertices on the sides another root shares are locked, and that root builds the same ones there.
    _,region_high:=quad_region3(&s,&q,first)
    origin:=source_origin(&s)
    face:=origin.x+f32(region_high.x)*s.cell-node.origin.x // its +X side, in its own space
    locked,on_face:=0,0
    for position,i in node.geometry.positions {
        if node.locked[i] {locked+=1}
        if position.x==face {
            on_face+=1
            testing.expect(t,node.locked[i],"a vertex on a shared side is locked")
        }
    }
    testing.expect(t,on_face>0 && locked>=on_face && locked<len(node.geometry.positions))
    if !testing.expect(t,node_build(&s,&q,first+1,{},nil,&other)) {return}
    shared:=0
    for position in other.geometry.positions {
        if position.x+other.origin.x!=face+node.origin.x {continue}
        found:=false
        for mine in node.geometry.positions {if mine+node.origin==position+other.origin {found=true;break}}
        testing.expect(t,found,"the node beside it has a vertex this one lacks on their side")
        shared+=1
    }
    testing.expect_value(t,shared,on_face)
    // Its levels keep every locked vertex where it is: the coarsest still meets its neighbor.
    if !testing.expect(t,chunk_render_prepare(.Volume,&node,{},true)) {return}
    g:=node.render.geometry
    if !testing.expect(t,len(g.levels)>1,"a node has levels for the renderer to choose from") {return}
    vertices:=make([dynamic]asset.Vertex);defer delete(vertices)
    indices:=make([dynamic]u32);defer delete(indices)
    testing.expect(t,asset.mesh_level_decode(g,len(g.levels)-1,&vertices,&indices))
    testing.expect(t,len(indices)/3<triangles,"the coarsest level has fewer triangles")
    missing:=0
    for position,i in node.geometry.positions {
        if !node.locked[i] {continue}
        kept:=false
        for v in vertices {
            d:=v.position-position
            if abs(d.x)<=g.position_step && abs(d.y)<=g.position_step && abs(d.z)<=g.position_step {kept=true;break}
        }
        if !kept {missing+=1}
    }
    testing.expectf(t,missing==0,"%d locked vertices of %d are gone from the coarsest level",missing,locked)
}

// A cave far deeper than a Volume once reached: dug across the borders of its
// blocks, kept by its file, read by pages and dug again.
@(test)
a_cave_deeper_than_the_old_limit_is_dug_saved_read_by_pages_and_dug_again :: proc(t:^testing.T) {
    s,paged:Source;defer source_destroy(&s);defer source_destroy(&paged)
    // 512 cells deep: its ground from the middle of the box down.
    if !testing.expect(t,source_make(&s,.Volume,{65,513,65},1,32)) {return}
    g:=&s.distances
    blocks:=g.counts.x*g.counts.y*g.counts.z
    held_before:=0
    for page in g.pages {if page.values!=nil {held_before+=1}}
    // A shaft 200 m down from the top of the ground, at a corner of four columns of blocks.
    shaft:=Brush{kind=.Carve,shape=.Capsule,center={0,0,0},delta={0,-200,0},radius=3,amount=1}
    change:=source_edit(&s,shaft)
    if !testing.expect(t,change.error==.None && change.changed) {return}
    from,to:=grid_pages(g,change.low,change.high)
    testing.expect(t,to.y-from.y>=12 && to.x>from.x && to.z>from.z,"the dig crosses blocks along every axis")
    middle:=[3]int{32,256,32}
    testing.expect(t,source_value(&s,middle-{0,180,0})>0,"air 180 m down the shaft")
    testing.expect(t,source_value(&s,middle-{8,180,0})<0 && source_value(&s,middle-{0,230,0})<0,"rock beside it and under it")
    // What it holds: the blocks its surface crosses.
    with_values:=0
    for page in g.pages {if page.values!=nil {with_values+=1}}
    testing.expect(t,with_values>held_before && with_values<blocks,"only the blocks a surface crosses hold values")
    dense:=65*513*65*size_of(f32)
    // The file keeps it, and a source read by pages reads only where it is asked.
    root:=base.test_folder(t,"terrain")
    path:=fmt.tprintf("%s/cave.terrain",root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{451,452}
    data,error:=source_bytes(&s,id,&types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    defer delete(data)
    testing.expectf(t,len(data)<dense/8,"its file takes %d bytes of the %d of every sample",len(data),dense)
    testing.expect_value(t,source_save(&s,path,id,&types),asset.Error.None)
    front:asset.Asset
    if !testing.expect_value(t,asset.asset_load_front(&front,path),asset.Error.None) {return}
    got,ok:=source_read(&paged,&front,&types,pages=path)
    asset.asset_close(&front)
    if !testing.expect(t,ok && got==id) {return}
    testing.expect_value(t,grid_dense(&paged.distances),0)
    testing.expect(t,len(paged.distances.pages)<=len(g.pages),"it holds no more pages than the one saved")
    low,high:=middle-{12,196,12},middle-{-12,164,-12}
    testing.expect(t,!source_region_held(&paged,low,high) && source_region_read(&paged,low,high))
    same:=true
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {same&&=source_value(&paged,{x,y,z})==source_value(&s,{x,y,z})}}}
    testing.expect(t,same,"the cave reads as it was saved")
    testing.expect(t,grid_dense(&paged.distances)<with_values*PAGE_VALUES/2,"the rest of the shaft stays in the file")
    // Dug again down there, and shown: the chunk that deep builds its walls.
    room:=source_edit(&paged,{kind=.Carve,center={0,-180,0},radius=8,amount=1})
    testing.expect(t,room.error==.None && room.changed)
    testing.expect(t,source_value(&paged,middle-{6,180,0})>0,"the room is wider than the shaft")
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    deep:=[3]i32{0,i32((256-180)/32),0}
    region_low,region_high,_:=chunk_pages_region(&paged,chunk_index(&paged,deep))
    testing.expect(t,source_region_read(&paged,region_low,region_high))
    testing.expect(t,chunk_build(&paged,deep,&mesh,true) && len(mesh.geometry.indices)>0,"the walls of the room")
}

// A Volume far past the old limit costs the blocks its surfaces cross: the
// air over them and the ground under them hold nothing, in memory or in its
// file, and its file gives it back.
@(test)
a_large_volume_holds_and_stores_only_the_blocks_of_its_surfaces :: proc(t:^testing.T) {
    s,loaded:Source;defer source_destroy(&s);defer source_destroy(&loaded)
    if !testing.expect(t,source_make(&s,.Volume,{513,513,513},1,64)) {return}
    testing.expect(t,source_edit(&s,{kind=.Carve,center={100,0,-60},radius=10,amount=1}).changed)
    g:=&s.distances
    blocks:=g.counts.x*g.counts.y*g.counts.z
    dense:=513*513*513*size_of(f32)
    // What a table of every block took before, without one value.
    tables_before:=blocks*size_of(Page(f32))
    held:=grid_dense(g)*size_of(f32)
    tables:=grid_tables_bytes(g)
    testing.expectf(t,len(g.pages)<blocks*2/3,"it holds %d pages of its %d blocks",len(g.pages),blocks)
    testing.expectf(t,tables<tables_before && held+tables<dense/4,"values %d, tables %d (%d for every block), every sample %d",held,tables,tables_before,dense)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{461,462}
    path:=fmt.tprintf("%s/wide.terrain",base.test_folder(t,"terrain"))
    testing.expect_value(t,source_save(&s,path,id,&types),asset.Error.None)
    got,ok:=source_load(&loaded,path,&types)
    if !testing.expect(t,ok && got==id) {return}
    testing.expect(t,grid_equal(&loaded.distances,g) && grid_equal(&loaded.weights,&s.weights),"the file gives back every sample")
    testing.expect(t,len(loaded.distances.pages)<=len(g.pages) && len(loaded.distances.tables)<=len(g.tables),"and holds no more than it had")
    // Saved again it is the same file: what a grid holds of pages of one value does not change it.
    testing.expect(t,grid_prepare(&loaded.distances,{4,4,4},{5,5,5},loaded.allocator))
    a,a_error:=source_bytes(&s,id,&types)
    b,b_error:=source_bytes(&loaded,id,&types)
    defer delete(a);defer delete(b)
    testing.expect(t,a_error==.None && b_error==.None && string(a)==string(b))
}
