package foliage

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"
import physics "plugins:physics/runtime"

// A point of a layer as its graph places it, standing up.
@(private="file")
point :: proc "contextless" (layer,index:u32,at:[3]f32,height:=f32(1),collides:=true) -> pcg.Placed {
    return {position=at,rotation=1,scale={1,height,1},id=u64(layer)<<32|u64(index),layer=layer,collides=collides}
}

// A graph of an entity in generated, with no cells.
@(private="file")
graph_add :: proc(g:^pcg.Pcg_Generated,e:core.Entity) -> ^pcg.Generated_Graph {
    append(&g.graphs,pcg.Generated_Graph{entity=e,cells=make([dynamic]pcg.Generated_Cell)})
    return &g.graphs[len(g.graphs)-1]
}

// A cell its graph built placing placed, in the order of the coordinates.
@(private="file")
cell_add :: proc(graph:^pcg.Generated_Graph,coord:[2]i32,placed:[]pcg.Placed,near:=f32(0)) {
    at:=0
    for at<len(graph.cells) && coord_before(graph.cells[at].coord,coord) {at+=1}
    cell:=pcg.Generated_Cell{coord=coord,built=true,revision=1,near=near,placed=make([dynamic]pcg.Placed)}
    append(&cell.placed,..placed)
    inject_at(&graph.cells,at,cell)
    graph.revision+=1
}

// What the graph places in a cell from now on: another revision of it.
@(private="file")
cell_place :: proc(graph:^pcg.Generated_Graph,coord:[2]i32,placed:[]pcg.Placed) {
    cell:=pcg.generated_cell(graph,coord)
    clear(&cell.placed)
    append(&cell.placed,..placed)
    cell.revision+=1
    graph.revision+=1
}

// The layers of a source give their looks: what they place, their
// distances and whether they collide or fill, drawn and swaying as the
// Foliage says of a mesh; the span of the ids of their points and how many a
// full cell holds are those of the points of their unit (a dither group
// shares one set) and, for a cascade, of the children of its parents.
@(test)
looks_take_their_layers_and_the_values_of_their_foliage :: proc(t:^testing.T) {
    s:pcg.Pcg_Source
    pcg.source_init(&s)
    defer pcg.source_destroy(&s)
    s.info.cell_size=10
    tree:=pcg.source_layer_add(&s,.Scatter,.Macro)
    tree.asset,tree.density,tree.impostor_distance,tree.collides=base.Asset_Id{7,7},0.1,80,true
    tree_id:=tree.id
    grass:=pcg.source_layer_add(&s,.Scatter,.Meso)
    grass.density,grass.filler,grass.dither_group=0.5,true,3
    flowers:=pcg.source_layer_add(&s,.Scatter,.Meso)
    flowers.density,flowers.dither_group=0.3,3
    sapling:=pcg.source_layer_add(&s,.Cascade,.Macro)
    sapling.parent_layer,sapling.density=tree_id,2
    looks:[dynamic]Look
    defer delete(looks)
    f:=Foliage{wind=0.5,flutter=2,shadows=true,rays=false}
    if !testing.expect(t,looks_make(&looks,&s,f,nil)) {return}
    if !testing.expect_value(t,len(looks),4) {return}
    l:=looks[0]
    testing.expect(t,l.layer==tree_id && l.asset==base.Asset_Id{7,7} && !l.prefab && l.collides && !l.filler && l.impostor_distance==80)
    testing.expect(t,l.wind==0.5 && l.flutter==2 && l.casts_shadow && !l.ray_visible,"a mesh is drawn as the Foliage says")
    testing.expect(t,abs(l.span-10)<1e-4 && abs(l.expected-10)<1e-4,"0.1 points a square metre over 100 of them")
    testing.expect(t,abs(looks[1].span-80)<1e-3 && abs(looks[1].expected-50)<1e-3 && looks[1].filler,"the grass shares the points of its group")
    testing.expect(t,abs(looks[2].span-80)<1e-3 && abs(looks[2].expected-30)<1e-3)
    testing.expect(t,abs(looks[3].span-10*pcg.CASCADE_CHILDREN_MAX)<1e-3 && abs(looks[3].expected-20)<1e-3,"two saplings a tree")
    ids:[dynamic][2]u32
    defer delete(ids)
    testing.expect(t,looks_ids(looks[:],&ids))
    for look,i in looks {testing.expect_value(t,look_index(ids[:],look.layer),i)}
    testing.expect_value(t,look_index(ids[:],99),-1)
}

// A lower detail draws the first points of each cell of a filler layer, so
// it takes the last ones away and keeps the others; what is not filler, or a
// grammar, keeps all. A cell full of a layer gives way to its far form at
// DENSITY_LOD_MIN of its distances, a sparse one at all of them.
@(test)
filler_keeps_the_first_points_and_full_cells_give_way_sooner :: proc(t:^testing.T) {
    grass:=Look{filler=true,span=100}
    cases:=[?]struct{look:Look,point:u32,thin:f32,kept:bool}{
        {grass,0,0.4,true},{grass,39,0.4,true},{grass,40,0.4,false},{grass,99,0.4,false},
        {grass,99,1,true},{grass,140,1,true},{grass,10,0,false},
        {Look{span=100},99,0.4,true},{Look{filler=true},7,0.4,true},
    }
    for c in cases {
        testing.expectf(t,filler_kept(c.look,u64(5)<<32|u64(c.point),c.thin)==c.kept,"point %d at %v",c.point,c.thin)
    }
    bands:=[?]struct{count:int,expected:f32,band:u8}{{0,10,0},{1,10,0},{5,10,2},{10,10,3},{30,10,3},{4,0,0}}
    for b in bands {testing.expectf(t,density_band(b.count,b.expected)==b.band,"%d of %v",b.count,b.expected)}
    testing.expect_value(t,band_scale(0),f32(1))
    testing.expect(t,abs(band_scale(DENSITY_BANDS-1)-DENSITY_LOD_MIN)<1e-6)
    testing.expect(t,band_scale(1)>band_scale(2))
}

// The instances of a cell group by look keeping their order; the detail
// thins the filler ones, and counts all of them for the band; a layer
// without a look is left out.
@(test)
placed_instances_group_by_look_keeping_their_order :: proc(t:^testing.T) {
    looks:=[2]Look{{layer=1},{layer=2,filler=true,span=10}}
    ids:[dynamic][2]u32
    defer delete(ids)
    testing.expect(t,looks_ids(looks[:],&ids))
    placed:=[?]pcg.Placed{point(1,0,{}),point(2,8,{}),point(1,1,{}),point(9,0,{}),point(2,1,{}),point(1,2,{})}
    work:Build_Work
    defer build_work_destroy(&work)
    if !testing.expect(t,placed_group(looks[:],ids[:],placed[:],0.5,&work)) {return}
    trees:=work.order[work.firsts[0]:work.firsts[1]]
    grass:=work.order[work.firsts[1]:work.firsts[2]]
    testing.expect(t,len(trees)==3 && trees[0]==0 && trees[1]==2 && trees[2]==5)
    testing.expect(t,len(grass)==1 && grass[0]==4,"the point past half of the span of the grass goes")
    testing.expect(t,work.counts[0]==3 && work.counts[1]==2)
}

@(test)
batch_instances_carry_the_frame_of_their_graph :: proc(t:^testing.T) {
    frame:=mm.Transform{position={100,5,0},rotation=mm.quat_axis_angle({0,1,0},math.PI*0.5),scale={2,2,2}}
    p:=point(1,0,{1,0,0},1.5)
    b:=batch_instance_of(p,frame)
    testing.expect(t,linalg.length(b.position-[3]f32{100,5,-2})<1e-4,"turned and scaled by its frame")
    _,scale:=render.batch_instance_unpack(b)
    testing.expect(t,linalg.length(scale-[3]f32{2,3,2})<1e-3)
}

// Every cell the graph keeps collides with one static body at its corner;
// a cell that only lost instances keeps its body and loses their shapes, one
// whose instances moved is built again, and one the graph no longer keeps
// goes. Within a budget the cells nearest the sources go first and the
// others wait.
@(test)
every_cell_of_a_graph_collides_and_what_is_taken_out_leaves_alone :: proc(t:^testing.T) {
    w:physics.Physics_State
    if !testing.expect(t,physics.test_state_make(&w)) {return}
    defer physics.state_destroy(&w)
    g:pcg.Pcg_Generated
    defer pcg.pcg_generated_free(&g)
    e:=core.Entity(42)
    graph:=graph_add(&g,e)
    // Two trees and grass that does not collide; a tree twice as tall in (1,-1); one in (10,0).
    cell_add(graph,{0,0},{point(1,0,{5,0,5}),point(1,1,{10,0,5}),point(2,0,{7,0,7},1,false)})
    cell_add(graph,{1,-1},{point(1,0,{40,1,-5},2)})
    cell_add(graph,{10,0},{point(1,0,{325,0,5})})
    capsule:=physics.collider_capsule(0.3,max(4*0.5-0.3,0))
    capsule.center.y=2
    shapes:=[1]Type_Shape{{layer=1,collider=capsule,placement=1}}
    fp:Foliage_Physics
    defer core.value_free(&fp,type_info_of(Foliage_Physics))
    collision:physics.Collision_Settings
    // The graph far from the origin: each body stands at the corner of its cell.
    frame:=mm.Transform{position={20000,0,-30000},rotation=1,scale={1,1,1}}
    {complete,enough:=physics_owner_build(&fp,&w,&collision,e,graph,32,frame,shapes[:]);testing.expect(t,complete && enough)}
    testing.expect_value(t,len(fp.cells),3)
    testing.expect_value(t,int(w.world.body_count),3)
    testing.expect_value(t,int(w.world.shape_count),4)
    bodies:[3]physics.Body_Handle
    for cell,i in fp.cells {
        bodies[i]=cell.body
        owned,_:=physics.owned_body_of(&w,cell.body)
        testing.expect(t,owned.owner==BODY_OWNER && owned.entity==e)
        info,_:=physics.body_info({ptr=&w},cell.body)
        testing.expect(t,linalg.length(info.pose.position-(frame.position+pcg.cell_corner(32,cell.coord)))<1e-3,"at the corner of its cell")
    }
    // The tree twice as tall, 8 m and 27 m from the corner of its cell: its capsule from its foot up.
    shape,made:=instance_shape(shapes[0],point(1,0,{40,1,-5},2),pcg.cell_corner(32,{1,-1}),frame)
    testing.expect(t,made && linalg.length(shape.position-[3]f32{8,1+4,27})<1e-3)
    testing.expect(t,abs(shape.collider.size.x-0.3)<1e-5 && abs(shape.collider.size.y-(4-0.3))<1e-4,"8 m from end to end")
    // A ray down on the first tree meets its instance.
    hit,met:=physics.raycast(core.ref(&w),frame.position+{5,10,5},{0,-1,0},20)
    plant,found:=hit_of(core.ref(&w),hit)
    testing.expect(t,met && found && plant==pcg.Pcg_Instance{e,{0,0},u64(1)<<32},"the tree that stands there")
    // A tree taken out: its shapes go, and the body of its cell and the others stay.
    cell_place(graph,{0,0},{point(1,1,{10,0,5}),point(2,0,{7,0,7},1,false)})
    {complete,enough:=physics_owner_build(&fp,&w,&collision,e,graph,32,frame,shapes[:],false);testing.expect(t,complete && enough)}
    testing.expect_value(t,int(w.world.shape_count),3)
    testing.expect_value(t,int(w.world.body_count),3)
    for cell,i in fp.cells {testing.expect_value(t,cell.body,bodies[i])}
    testing.expect_value(t,fp.stats.removed,u64(1))
    // The last tree of the cell moved: it is built again, and still collides.
    cell_place(graph,{0,0},{point(1,1,{12,0,5})})
    {complete,enough:=physics_owner_build(&fp,&w,&collision,e,graph,32,frame,shapes[:],false);testing.expect(t,complete && enough)}
    testing.expect_value(t,int(w.world.shape_count),3)
    testing.expect_value(t,int(w.world.body_count),3)
    for cell in fp.cells {
        for s in fp.shapes[cell.first:][:cell.count] {_,valid:=physics.owned_shape_user(&w,s.handle);testing.expect(t,valid)}
    }
    // The graph no longer keeps (10,0): its body goes.
    pcg.generated_cell(graph,{10,0}).built=false
    delete(graph.cells[2].placed)
    ordered_remove(&graph.cells,2)
    {complete,enough:=physics_owner_build(&fp,&w,&collision,e,graph,32,frame,shapes[:],false);testing.expect(t,complete && enough)}
    testing.expect(t,len(fp.cells)==2 && w.world.body_count==2)
    // Built again within one instance a tick, the nearest a source first.
    physics_owner_clear(&fp,&w,e)
    testing.expect(t,w.world.body_count==0 && len(fp.cells)==0 && len(fp.shapes)==0)
    sources:=[1]scene.Source{{position=frame.position+{40,0,-5},ahead=frame.position+{40,0,-5}}}
    near:=scene.sources_near_of(sources[:],mm.transform_matrix(frame),32)
    budget:=Physics_Budget{instances=1}
    physics_owner_build(&fp,&w,&collision,e,graph,32,frame,shapes[:],true,&near,&budget)
    testing.expect(t,budget.waiting && w.world.body_count==1,"one cell, and the other waits")
    for cell in fp.cells {testing.expect(t,(cell.body!={})==(cell.coord==[2]i32{1,-1}),"the nearest")}
    budget=Physics_Budget{instances=PHYSICS_INSTANCES_A_TICK}
    physics_owner_build(&fp,&w,&collision,e,graph,32,frame,shapes[:],false,&near,&budget)
    testing.expect(t,!budget.waiting && w.world.body_count==2)
    physics_owner_clear(&fp,&w,e)
}

// Rocks of one mesh share one hull, which each instance scales and turns: a
// ray meets each at its own size, and the hull goes back to physics once no
// rock uses it.
@(test)
rocks_collide_as_one_hull_each_instance_scales :: proc(t:^testing.T) {
    w:physics.Physics_State
    if !testing.expect(t,physics.test_state_make(&w)) {return}
    defer physics.state_destroy(&w)
    g:pcg.Pcg_Generated
    defer pcg.pcg_generated_free(&g)
    e:=core.Entity(5)
    graph:=graph_add(&g,e)
    wide:=point(1,0,{5,0,5})
    wide.rotation,wide.scale=mm.quat_axis_angle({0,1,0},math.PI*0.5),{2,1,2}
    cell_add(graph,{0,0},{wide,point(1,1,{10,0,5},3)})
    fp:Foliage_Physics
    defer core.value_free(&fp,type_info_of(Foliage_Physics))
    hulls:=make([dynamic]physics.Hull_Handle,context.temp_allocator)
    if made,_:=physics.owned_hulls(&w,nil,nil,{shape=.Cube},&hulls);!testing.expect(t,made && len(hulls)==1) {return}
    append(&fp.hulls,hulls[0])
    types:=[1]Type_Shape{{1,physics.collider_hull(),1,hulls[0]}}
    collision:physics.Collision_Settings
    {complete,enough:=physics_owner_build(&fp,&w,&collision,e,graph,32,{rotation=1,scale={1,1,1}},types[:]);testing.expect(t,complete && enough)}
    testing.expect_value(t,len(fp.shapes),2)
    top,on_top:=physics.raycast(core.ref(&w),{5,10,5},{0,-1,0},20)
    tall,on_tall:=physics.raycast(core.ref(&w),{10,10,5},{0,-1,0},20)
    testing.expect(t,on_top && abs(top.distance-9.5)<1e-3,"a metre tall")
    testing.expect(t,on_tall && abs(tall.distance-8.5)<1e-3,"three metres tall")
    side,on_side:=physics.raycast(core.ref(&w),{0,0.2,5},{1,0,0},20)
    testing.expect(t,on_side && abs(side.distance-4)<1e-3,"two metres wide across x")
    plant,found:=shape_instance(&w,side.body,side.shape)
    testing.expect(t,found && plant.id==wide.id)
    hulls_sweep(&fp,&w)
    testing.expect_value(t,len(fp.hulls),1)
    physics_owner_clear(&fp,&w,e)
    hulls_sweep(&fp,&w)
    testing.expect_value(t,len(fp.hulls),0)
}

@(test)
a_part_of_a_prefab_composes_with_its_instance_and_says_what_it_leaves_out :: proc(t:^testing.T) {
    owner:=mm.transform_matrix({position={10,0,0},rotation=1,scale={2,2,2}})
    p:=point(1,0,{1,0,0},1.5)
    p.rotation=mm.quat_axis_angle({0,1,0},math.PI*0.5)
    part:=mm.transform_matrix({position={0,1,0},rotation=1,scale={1,1,1}})
    b,error:=part_instance(p,owner,part)
    testing.expect(t,error<1e-4)
    testing.expect(t,linalg.length(b.position-[3]f32{12,3,0})<1e-3,"the part one metre up, under the instance and the entity")
    _,scale:=render.batch_instance_unpack(b)
    testing.expect(t,linalg.length(scale-[3]f32{2,3,2})<1e-2)
    // A part stretched along its x alone is drawn as it is.
    stretched:=mm.transform_matrix({rotation=1,scale={3,1,1}})
    b,error=part_instance(p,owner,stretched)
    _,scale=render.batch_instance_unpack(b)
    testing.expect(t,error<1e-4 && linalg.length(scale-[3]f32{6,3,2})<2e-2)
    // A sheared one is approximated, and says by how much.
    sheared:=mm.Mat4(1)
    sheared[1].x=1
    _,error=part_instance(p,owner,sheared)
    testing.expect(t,error>PREFAB_ERROR)
}

// A prefab a layer places: its shown meshes placed from its root, the
// colliders an instance can have, and the wind of the Foliage_Sway of its root.
@(test)
the_parts_of_a_prefab_are_its_shown_meshes_placed_from_its_root :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    prefab:asset.Scene
    testing.expect_value(t,asset.scene_init(&prefab,&types,{0xf0,0xf1}),asset.Error.None)
    defer asset.scene_destroy(&prefab)
    prefab.doc.flags+={.Prefab}
    asset.scene_entity_add(&prefab,1,0,"Tree")
    asset.scene_entity_add(&prefab,2,1,"Trunk")
    asset.scene_entity_add(&prefab,3,2,"Crown")
    asset.scene_entity_add(&prefab,4,1,"Hidden")
    places:=[4]core.Transform{{position={5,0,0},rotation=1,scale=1},{position={0,1,0},rotation=1,scale=2},{position={1,0,0},rotation=1,scale=1},{rotation=1,scale=1}}
    for &place,i in places {asset.scene_set(&prefab,base.Entity_Id(i+1),"Transform",&place)}
    crown:=render.Mesh_Renderer{mesh={7,7}}
    asset.scene_set(&prefab,3,"Mesh_Renderer",&crown)
    asset.scene_set(&prefab,4,"Mesh_Renderer",&crown)
    hidden:render.Hidden
    asset.scene_set(&prefab,4,"Hidden",&hidden)
    // A capsule on the trunk collides, and so does the hull of what the hidden one shows; a triangle
    // mesh, on the root, cannot be an instance's.
    trunk:=physics.collider_capsule(0.25,1)
    asset.scene_set(&prefab,2,"Collider",&trunk)
    hull:=physics.collider_hull()
    asset.scene_set(&prefab,4,"Collider",&hull)
    triangles:=physics.COLLIDER_DEFAULT
    triangles.kind=.Mesh
    asset.scene_set(&prefab,1,"Collider",&triangles)
    // The root sways; the sway of another entity says nothing of the prefab.
    root_sway:=Foliage_Sway{wind=2.5,flutter=0.5}
    asset.scene_set(&prefab,1,"Foliage_Sway",&root_sway)
    other_sway:=Foliage_Sway{wind=9}
    asset.scene_set(&prefab,3,"Foliage_Sway",&other_sway)
    data,error:=asset.scene_bytes(&prefab)
    defer delete(data)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,data),asset.Error.None) {return}
    defer asset.asset_close(&file)
    parts:[dynamic]Prefab_Part
    defer delete(parts)
    colliders:[dynamic]Prefab_Collider
    defer delete(colliders)
    read,left_out:=prefab_parts(&file,&types,&parts,&colliders)
    testing.expect(t,read && left_out==1)
    if !testing.expect_value(t,len(parts),1) {return}
    testing.expect_value(t,parts[0].renderer.mesh,base.Asset_Id{7,7})
    // The trunk one metre up scaled twice, the crown one metre along it; the root's own place is the instance's.
    testing.expect(t,linalg.length(parts[0].placement[3].xyz-[3]f32{2,1,0})<1e-5)
    testing.expect(t,abs(linalg.length(parts[0].placement[0].xyz)-2)<1e-5)
    if !testing.expect_value(t,len(colliders),2) {return}
    if colliders[0].collider.kind!=.Capsule {colliders[0],colliders[1]=colliders[1],colliders[0]}
    testing.expect(t,colliders[0].collider.kind==.Capsule && linalg.length(colliders[0].placement[3].xyz-[3]f32{0,1,0})<1e-5)
    testing.expect(t,colliders[1].collider.kind==.Hull && colliders[1].renderer.mesh==base.Asset_Id{7,7})
    // An instance 1.5 times as tall turned a quarter: the trunk's capsule twice as thick, three times as long, one and a half metres up from its foot.
    p:=point(1,0,{33,0,1},1.5)
    p.rotation=mm.quat_axis_angle({0,1,0},math.PI*0.5)
    made,ok:=instance_shape({1,colliders[0].collider,colliders[0].placement,{}},p,pcg.cell_corner(32,{1,0}),{rotation=1,scale={1,1,1}})
    testing.expect(t,ok && linalg.length(made.position-[3]f32{1,1.5,1})<1e-4)
    testing.expect(t,abs(made.collider.size.x-0.5)<1e-4 && abs(made.collider.size.y-((1+0.25)*3-0.5))<1e-4)
    sway,sways:=prefab_sway(&file,&types)
    testing.expect(t,sways && sway==root_sway,"the sway of its root")
}

// The instance a pick of a batch names: the index-th of the layer in its
// cell, past those the detail thins.
@(test)
a_pick_names_the_instance_its_batch_draws :: proc(t:^testing.T) {
    looks:=[2]Look{{layer=1},{layer=2,filler=true,span=4}}
    ids:[dynamic][2]u32
    defer delete(ids)
    testing.expect(t,looks_ids(looks[:],&ids))
    placed:=[?]pcg.Placed{point(2,3,{}),point(1,0,{}),point(2,0,{}),point(1,1,{}),point(2,1,{})}
    cases:=[?]struct{layer:u32,index:int,thin:f32,id:u64,ok:bool}{
        {1,0,1,u64(1)<<32,true},{1,1,1,u64(1)<<32|1,true},{1,2,1,0,false},
        {2,0,1,u64(2)<<32|3,true},{2,0,0.5,u64(2)<<32,true},{2,1,0.5,u64(2)<<32|1,true},{2,2,0.5,0,false},
        {3,0,1,0,false},{1,-1,1,0,false},
    }
    for c in cases {
        id,ok:=layer_instance(looks[:],ids[:],placed[:],c.layer,c.index,c.thin)
        testing.expectf(t,ok==c.ok && id==c.id,"layer %d, instance %d at %v: %x",c.layer,c.index,c.thin,id)
    }
}

// The cells to build go nearest the sources first, within the instances of
// the frame; one goes while some are left.
@(test)
cells_are_built_nearest_first_within_the_instances_of_a_frame :: proc(t:^testing.T) {
    g:pcg.Pcg_Generated
    defer pcg.pcg_generated_free(&g)
    graph:=graph_add(&g,1)
    many:=make([]pcg.Placed,3000,context.temp_allocator)
    cell_add(graph,{0,0},nil,2)
    cell_add(graph,{1,0},many,0.5)
    cell_add(graph,{2,0},nil,0)
    cells:=[3]Resident_Cell{{coord={0,0}},{coord={1,0}},{coord={2,0}}}
    builds:=[3]scene.Resident_Order{{near=2,index=0},{near=0.5,index=1},{near=0,index=2}}
    left:=CELL_COST_MIN+10
    testing.expect_value(t,builds_take(builds[:],graph,cells[:],&left),2)
    testing.expect(t,builds[0].index==2 && builds[1].index==1,"the nearest, then the next one past the budget")
    testing.expect_value(t,left,10-3000)
}

@(private)
@(test_world)
Foliage_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    foliages:core.Table(Foliage),
    graphs:core.Table(pcg.Pcg_Graph),
    worlds:core.Table(core.World_Transform),
    marked:core.Table(Foliage_Marked),
    data:pcg.Pcg_Data,
    marks:Foliage_Marks,
    requests:Foliage_Requests,
    network:core.Network,
}

// A Foliage of a graph of source {9,9} at a place of the world, with an Id when id is not 0.
@(private="file")
foliage_add :: proc(w:^Foliage_World,id:base.Entity_Id,at:[3]f32,anchored:=false) -> core.Entity {
    e:=core.create(&w.entities)
    if id!=0 {core.add(&w.ids,e,core.Id{value=id})}
    core.add(&w.foliages,e,FOLIAGE_DEFAULT)
    core.add(&w.graphs,e,pcg.Pcg_Graph{source={9,9},world_anchored=anchored})
    core.add(&w.worlds,e,core.World_Transform{transform={position=at,rotation=1,scale={1,1,1}}})
    return e
}

// What a game finds is what the graphs of the Foliage of the world place,
// in the world: in a sphere, in a box, or by its instance; an entity
// without a Foliage, or a cell its graph does not keep, gives nothing.
@(test)
the_instances_a_game_finds_are_those_their_graphs_place :: proc(t:^testing.T) {
    w:Foliage_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    append(&w.data.entries,pcg.Pcg_Data_Entry{id={9,9},epoch=1,loads=1})
    pcg.source_init(&w.data.entries[0].source)
    w.data.entries[0].source.info.cell_size=32
    g:pcg.Pcg_Generated
    defer pcg.pcg_generated_free(&g)
    wood:=foliage_add(&w,0,{100,0,0})
    anchored:=foliage_add(&w,0,{100,0,0},true)
    test_world_settle(&w)
    a,b:=point(1,0,{5,0,5}),point(1,1,{40,0,5})
    for e in ([2]core.Entity{wood,anchored}) {
        graph:=graph_add(&g,e)
        cell_add(graph,{0,0},{a})
        cell_add(graph,{1,0},{b})
    }
    found:=make([dynamic]Foliage_Found,context.temp_allocator)
    testing.expect(t,foliage_in_sphere(&found,{105,0,5},2,core.ref(&w.data),core.ref(&g),core.read(&w.foliages),core.read(&w.graphs),core.read(&w.worlds)))
    if testing.expect_value(t,len(found),1) {
        testing.expect(t,found[0].plant==pcg.Pcg_Instance{wood,{0,0},a.id} && found[0].layer==1 && linalg.length(found[0].transform.position-[3]f32{105,0,5})<1e-4)
    }
    clear(&found)
    testing.expect(t,foliage_in_box(&found,{0,-1,0},{150,1,10},core.ref(&w.data),core.ref(&g),core.read(&w.foliages),core.read(&w.graphs),core.read(&w.worlds)))
    testing.expect_value(t,len(found),4)
    clear(&found)
    // The graph anchored to the world places where its points are, wherever its entity is.
    testing.expect(t,foliage_in_sphere(&found,{5,0,5},1,core.ref(&w.data),core.ref(&g),core.read(&w.foliages),core.read(&w.graphs),core.read(&w.worlds)))
    testing.expect(t,len(found)==1 && found[0].plant.graph==anchored)
    at,shown:=foliage_plant({wood,{1,0},b.id},core.ref(&g),core.read(&w.foliages),core.read(&w.graphs),core.read(&w.worlds))
    testing.expect(t,shown && linalg.length(at.transform.position-[3]f32{140,0,5})<1e-4)
    _,shown=foliage_plant({wood,{1,0},a.id},core.ref(&g),core.read(&w.foliages),core.read(&w.graphs),core.read(&w.worlds))
    testing.expect(t,!shown,"not in that cell")
    _,shown=foliage_plant({wood,{5,0},a.id},core.ref(&g),core.read(&w.foliages),core.read(&w.graphs),core.read(&w.worlds))
    testing.expect(t,!shown,"a cell the graph does not keep")
    core.remove(&w.foliages,wood)
    test_world_settle(&w)
    _,shown=foliage_plant({wood,{1,0},b.id},core.ref(&g),core.read(&w.foliages),core.read(&w.graphs),core.read(&w.worlds))
    testing.expect(t,!shown,"without its Foliage")
}

@(private="file")
marks_step :: proc(w:^Foliage_World,problems:^core.Problems) {
    foliage_marks(&w.marks,&w.requests,&w.marked,core.read(&w.foliages),core.read(&w.ids),core.ref(&w.network),core.commands(w,test_world_info(w)),context.allocator,problems)
    test_world_settle(w)
}

// The game marks instances in play (burnt, wet): the end that decides keeps
// each mark of a cell in one entity, a later mark of an instance changes its
// entry, the cell shows them over its own look, and taking the entity away
// gives it back.
@(test)
marks_of_play_are_one_entry_for_each_instance_of_their_cell :: proc(t:^testing.T) {
    w:Foliage_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    problems:core.Problems
    wood:=foliage_add(&w,800,{})
    test_world_settle(&w)
    plant:=pcg.Pcg_Instance{wood,{1,0},u64(1)<<32|7}
    w.network.role=.Client
    foliage_mark(&w.requests,plant,{0.1,0.1,0.1},0)
    marks_step(&w,&problems)
    testing.expect_value(t,core.count(&w.marked),0)
    w.network.role=.Server
    foliage_mark(&w.requests,plant,{0.1,0.1,0.1},0)
    marks_step(&w,&problems)
    foliage_mark(&w.requests,plant,{0.2,0.2,0.2},1)
    marks_step(&w,&problems)
    marks_step(&w,&problems)
    testing.expect_value(t,core.count(&w.marked),1)
    page:=core.at(&w.marked,0)
    testing.expect(t,page.foliage==800 && page.coord==plant.coord && page.count==1,"one entry, changed in place")
    wet:=render.batch_color({0.2,0.2,0.2},1)
    testing.expect_value(t,page.instances[0].color,wet)
    marks,hash:=marked_cell(marked_owner(&w.marks,wood),plant.coord)
    testing.expect(t,len(marks)==1 && hash!=0)
    testing.expect(t,marked_color(marks,plant.id)==wet && marked_color(marks,plant.id+1)==render.BATCH_COLOR_PLAIN,"only the marked one")
    // Without the entity, the cell has no marks.
    core.destroy(&w.entities,core.entity_at(&w.marked,0))
    test_world_settle(&w)
    marks_step(&w,&problems)
    marks,hash=marked_cell(marked_owner(&w.marks,wood),plant.coord)
    testing.expect(t,len(marks)==0 && hash==0)
}
