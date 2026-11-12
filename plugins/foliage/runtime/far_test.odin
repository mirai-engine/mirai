package foliage

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/base"
import scene "mirai:engine/scene"
import "mirai:std/geom"
import mm "mirai:std/math"
import physics "plugins:physics/runtime"

// A crown of two quads that cross in a box, dense enough to be solid, and a
// lone triangle elsewhere that is not: the crown is the closed surface of the
// solid voxels, inside them by CROWN_INSET.
@(test)
a_crown_is_the_closed_surface_of_the_voxels_dense_with_leaves :: proc(t:^testing.T) {
    positions:=make([dynamic][3]f32)
    indices:=make([dynamic]u32)
    defer delete(positions)
    defer delete(indices)
    leaf :: proc(positions:^[dynamic][3]f32,indices:^[dynamic]u32,a,b,c,d:[3]f32) {
        first:=u32(len(positions))
        append(positions,a,b,c,d)
        append(indices,first,first+1,first+2,first,first+2,first+3)
    }
    // Leaves stacked every 0.1 m fill the box from 0 to 1 along every axis.
    for k in 0..<10 {
        y:=f32(k)*0.1+0.05
        leaf(&positions,&indices,{0,y,0},{1,y,0},{1,y,1},{0,y,1})
    }
    // Far away, one small leaf: a voxel of it is not dense, and the box grows to hold it.
    leaf(&positions,&indices,{7.9,0,7.9},{8,0,7.9},{8,0,8},{7.9,0,8})
    shape:geom.Mesh_Buffer
    geom.mesh_buffer_init(&shape)
    defer geom.mesh_buffer_destroy(&shape)
    if !testing.expect(t,crown_build(positions[:],indices[:],&shape)) {return}
    // The box is 8 m: voxels of 1 m, and the dense one is a single cube of six faces.
    testing.expect_value(t,len(shape.indices),6*6)
    testing.expect_value(t,len(shape.normals),len(shape.positions))
    inset:=CROWN_INSET
    for p,i in shape.positions {
        n:=shape.normals[i]
        // Each face is inside its voxel by the inset, along its normal.
        along:=linalg.dot(p,n)
        want:=linalg.dot(n,[3]f32{1,1,1})>0?1-inset:-inset
        testing.expectf(t,abs(along-want)<1e-4,"vertex %v of the face along %v",p,n)
    }
    // Triangles face out.
    for i:=0;i<len(shape.indices);i+=3 {
        a,b,c:=shape.positions[shape.indices[i]],shape.positions[shape.indices[i+1]],shape.positions[shape.indices[i+2]]
        testing.expect(t,linalg.dot(linalg.cross(b-a,c-a),shape.normals[shape.indices[i]])>0)
    }
    // Sparse leaves alone make no crown.
    sparse:=[8][3]f32{{0,0,0},{0.1,0,0},{0.1,0,0.1},{0,0,0.1},{7.9,0,7.9},{8,0,7.9},{8,0,8},{7.9,0,8}}
    testing.expect(t,!crown_build(sparse[:],{0,1,2,0,2,3,4,5,6,4,6,7},&shape))
    // Rays meet it as they meet its type: its shadow, and in reflections and
    // indirect light in the mean linear color of the frames it covers.
    tree:=FOLIAGE_TYPE_DEFAULT
    tree.casts_shadow,tree.ray_visible=true,false
    testing.expect_value(t,crown_flags(&tree),render.Batch_Flags{.Casts_Shadow,.Rays_Only})
    tree.casts_shadow,tree.ray_visible=false,true
    testing.expect_value(t,crown_flags(&tree),render.Batch_Flags{.Ray_Visible,.Rays_Only})
    frames:=[12]u8{255,0,188,255, 0,0,188,255, 9,9,9,0}
    albedo:=frames_albedo(frames[:])
    testing.expectf(t,abs(albedo.x-0.5)<1e-3 && albedo.y==0 && abs(albedo.z-0.5)<5e-3,"%v",albedo)
}

// An instance takes the variant whose turn is nearest its own, and the wind
// turned into the space of that variant is the wind of the world once the
// instance turns it back: downwind within half a step of turn.
@(test)
an_instance_sways_with_the_variant_of_its_turn_and_downwind :: proc(t:^testing.T) {
    count:=u32(4)
    for degrees in ([]f32{0,40,50,89,91,180,-100,359}) {
        q:=mm.quat_axis_angle({0,1,0},degrees*math.PI/180)
        k:=wind_variant(q,count)
        turn:=wind_variant_turn(k,count)*180/math.PI
        off:=math.mod(abs(turn-math.mod(degrees+360,360))+180,360)-180
        testing.expectf(t,abs(off)<=45+1e-3,"%v degrees takes variant %d of %v degrees",degrees,k,turn)
        wind:=[3]f32{3,0,-4}
        swayed:=mm.quat_rotate(q,wind_variant_local(wind,k,count))
        testing.expect(t,linalg.dot(linalg.normalize(swayed),linalg.normalize(wind))>=math.cos(f32(math.PI/4))-1e-4,"within half a step of turn of the wind")
        if degrees==0 {testing.expect(t,linalg.length(swayed-wind)<1e-4)}
    }
    testing.expect_value(t,wind_variant(mm.quat_axis_angle({0,1,0},2),1),u32(0))
    // The box of the variants holds the farthest point swayed by the strongest wind.
    t_type:=FOLIAGE_TYPE_DEFAULT
    t_type.casts_shadow=true
    amount:=sway_amount(t_type)
    low,high:=wind_bounds({-1,0,-1},{1,10,1},amount)
    farthest:=linalg.length([3]f32{1,10,1})*amount*WIND_SPEED_MAX
    testing.expect(t,high.x>=1+farthest-1e-4 && low.y<=-farthest+1e-4)
    testing.expect_value(t,wind_variants(t_type),u32(WIND_VARIANTS))
    t_type.casts_shadow=false
    testing.expect_value(t,wind_variants(t_type),u32(0))
}

// The picker finds the instance of a variant among those of its type.
@(test)
the_instance_of_a_variant_is_found_among_those_of_its_type :: proc(t:^testing.T) {
    placed:=[4]Placed{
        {rotation=mm.quat_axis_angle({0,1,0},0)},
        {rotation=mm.quat_axis_angle({0,1,0},math.PI)},
        {rotation=mm.quat_axis_angle({0,1,0},0.1)},
        {rotation=mm.quat_axis_angle({0,1,0},math.PI*0.5)},
    }
    order:=[4]u32{0,1,2,3}
    testing.expect_value(t,role_instance(ROLE_MESH,4,1,placed[:],order[:],2),2)
    testing.expect_value(t,role_instance(ROLE_VARIANT,4,1,placed[:],order[:],1),2)
    testing.expect_value(t,role_instance(ROLE_VARIANT+2,4,1,placed[:],order[:],0),1)
    testing.expect_value(t,role_instance(ROLE_VARIANT+2,4,1,placed[:],order[:],1),-1)
}

// The mesh of a type with an impostor gives way to it at its distance, and
// is gone a blend past it; one whose impostor would come after it is gone has none.
@(test)
a_type_with_an_impostor_draws_its_mesh_up_to_its_distance :: proc(t:^testing.T) {
    tree:=FOLIAGE_TYPE_DEFAULT
    tree.fade_distance,tree.cull_distance,tree.impostor_distance=1500,2000,100
    testing.expect(t,type_far(tree))
    fade,cull:=mesh_distances(tree,true)
    testing.expect(t,fade==100 && abs(cull-100*(1+IMPOSTOR_BLEND))<1e-3)
    fade,cull=mesh_distances(tree,false)
    testing.expect(t,fade==1500 && cull==2000)
    tree.impostor_distance=2500
    testing.expect(t,!type_far(tree))
    tree.impostor_distance,tree.cull_distance=100,0
    testing.expect(t,type_far(tree),"a type never culled keeps its impostor to any distance")
    // Its frames are as sharp as the mesh it replaces: a tree of 10 m at 100 m spans 125
    // pixels, and so does one of 20 m at 200 m; a bush of 1 m, few.
    tree.scale,tree.height={1,1},{1,1}
    testing.expect_value(t,impostor_frame(tree,10),u32(128))
    tree.impostor_distance=200
    testing.expect_value(t,impostor_frame(tree,20),u32(128))
    testing.expect_value(t,impostor_frame(tree,1),u32(IMPOSTOR_FRAME_MIN))
    testing.expect_value(t,impostor_frame(tree,1000),u32(IMPOSTOR_FRAME_MAX))
    tree.impostor_distance=100
    // A type collides as far as its mesh is drawn.
    s:Source
    defer source_destroy(&s)
    tree.collision=.Capsule
    append(&s.types,tree)
    testing.expect(t,abs(collision_reach(&s)-100*(1+IMPOSTOR_BLEND))<1e-3)
    // Never culled, it collides as far as COLLISION_REACH.
    s.types[0].impostor_distance=0
    testing.expect_value(t,collision_reach(&s),COLLISION_REACH)
    // The new fields keep the source valid within their range.
    s.info.next_type=1
    testing.expect(t,source_valid(&s))
    s.types[0].wind_variants=WIND_VARIANTS_MAX+1
    testing.expect(t,!source_valid(&s))
}

// A cell that changes writes only its block of the impostors: in its room
// while they fit, else in a free block or at the end, and the room of the
// blocks freed at the end goes.
@(test)
a_cell_writes_only_its_block_of_impostors :: proc(t:^testing.T) {
    d:Impostor_Draw
    defer impostor_draw_destroy(&d)
    some :: proc(n:int,x:f32) -> []Impostor_Instance {
        out:=make([]Impostor_Instance,n,context.temp_allocator)
        for &i,k in out {i={position={3000+x,10,f32(k)},row=1<<16 | u32(k)}}
        return out
    }
    a,b,c:u32
    testing.expect(t,impostors_set(&d,&a,some(3,0)) && impostors_set(&d,&b,some(5,1)))
    testing.expect(t,d.count==8 && len(d.instances)==8)
    testing.expect_value(t,d.instances[3].position+d.anchor,[3]f32{3001,10,0})
    clear(&d.writes)
    // Fewer: in its room, the rest of which draws nothing.
    testing.expect(t,impostors_set(&d,&b,some(2,1)))
    testing.expect_value(t,len(d.writes),1)
    testing.expect_value(t,d.writes[0],[2]u32{3,5})
    testing.expect(t,d.instances[5].row==IMPOSTOR_NONE && d.instances[7].row==IMPOSTOR_NONE && d.count==5)
    clear(&d.writes)
    // More than its room: at the end, and the room it leaves draws nothing until another cell takes it.
    testing.expect(t,impostors_set(&d,&a,some(4,2)))
    testing.expect(t,d.blocks[a-1].first==8 && d.instances[0].row==IMPOSTOR_NONE && d.count==6)
    testing.expect(t,impostors_set(&d,&c,some(2,3)))
    testing.expect(t,d.blocks[c-1].first==0 && len(d.instances)==12 && d.count==8)
    // The blocks freed at the end give their room back.
    impostors_free(&d,&a)
    testing.expect(t,a==0 && len(d.instances)==8 && d.count==4)
}

@(private)
@(test_world)
Collision_World :: struct {
    using world:Test_World,
    foliages:core.Table(Foliage),
    worlds:core.Table(core.World_Transform),
    kept:core.Table(scene.Far_Kept),
    data:Foliage_Data,
    sources:scene.Simulation_Sources,
}

// A cell collides while a source of the simulation (a body a seat drives, a
// mark) is within the reach of the types that collide, whatever the view,
// and lets go of its body once every source has gone past it; without
// sources every cell collides.
@(test)
the_cells_of_foliage_collide_while_they_are_resident :: proc(t:^testing.T) {
    w:Collision_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    state:physics.Physics_State
    if !testing.expect(t,physics.test_state_make(&state)) {return}
    defer physics.state_destroy(&state)
    append(&w.data.entries,Data_Entry{id={9,9},epoch=1,loads=1})
    s:=&w.data.entries[0].source
    tree:=source_type_add(s,"tree",{2,2})
    tree.collision,tree.size,tree.cull_distance,tree.fade_distance=.Capsule,{0.3,4,0},40,30
    for x in 0..<4 {source_instance_add(s,tree.id,{f32(x)*CELL_SIZE*4+5,0,5},u32(mm.quat_pack(1,10)),{1,1})}
    for &cell,i in s.cells {cell.version=u32(i+1)}
    testing.expect_value(t,collision_reach(s),f32(40))
    e:=core.create(&w.entities)
    core.add(&w.foliages,e,Foliage{source={9,9}})
    core.add(&w.worlds,e,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    test_world_settle(&w)
    fp:Foliage_Physics
    defer core.value_free(&fp,type_info_of(Foliage_Physics))
    problems:core.Problems
    step :: proc(w:^Collision_World,fp:^Foliage_Physics,state:^physics.Physics_State,problems:^core.Problems) {
        foliage_physics(fp,state,{},core.ref(&w.data),{},{},core.read(&w.foliages),core.read(&w.worlds),core.read(&w.kept),core.ref(&w.sources),{},problems)
    }
    w.sources.items[0]={position={5,0,5},ahead={5,0,5}}
    w.sources.count=1
    step(&w,&fp,&state,&problems)
    testing.expect_value(t,len(fp.cells),4)
    testing.expect_value(t,int(state.world.body_count),1)
    testing.expect(t,fp.cells[0].resident && fp.cells[0].body!={} && !fp.cells[1].resident && fp.cells[1].body=={})
    // The source moves to the second tree: its cell collides, the first lets go.
    w.sources.items[0]={position={CELL_SIZE*4+5,0,5},ahead={CELL_SIZE*4+5,0,5}}
    step(&w,&fp,&state,&problems)
    testing.expect_value(t,int(state.world.body_count),1)
    testing.expect(t,!fp.cells[0].resident && fp.cells[1].resident && fp.cells[1].body!={})
    // Without sources every cell collides.
    w.sources.count=0
    step(&w,&fp,&state,&problems)
    testing.expect_value(t,int(state.world.body_count),4)
    testing.expect_value(t,problems.count,0)
}

// The crown of a cell of a wood: the crowns of its trees, each a box of 4 m,
// placed and scaled as each instance is, give one crown of the cell that
// covers every tree and has fewer triangles than their crowns together.
@(test)
the_crown_of_a_cell_covers_its_trees_with_fewer_triangles_than_theirs :: proc(t:^testing.T) {
    tree:geom.Mesh_Buffer
    geom.mesh_buffer_init(&tree)
    defer geom.mesh_buffer_destroy(&tree)
    geom.cube_build(&tree,{4,4,4})
    crowns:=[2]Crown_Triangles{{},{tree.positions[:],tree.indices[:]}}
    placed:=make([dynamic]Placed,context.temp_allocator)
    for z in 0..<10 {
        for x in 0..<10 {
            append(&placed,Placed{type=1,position={f32(x)*3+2,4,f32(z)*3+2},rotation=1,scale={1,1}})
        }
    }
    // A type without crown triangles adds nothing.
    append(&placed,Placed{type=0,position={100,0,100},rotation=1,scale={1,1}})
    cell:geom.Mesh_Buffer
    geom.mesh_buffer_init(&cell)
    defer geom.mesh_buffer_destroy(&cell)
    if !testing.expect(t,cell_crown_build(placed[:],crowns[:],&cell)) {return}
    testing.expect(t,len(cell.indices)<100*len(tree.indices),"one crown, coarser than every tree's")
    low,high:=geom.mesh_bounds(cell.positions[:])
    testing.expectf(t,low.x<2 && low.z<2 && high.x>27 && high.z>27 && high.x<40,"it covers the wood and not the type without a crown: %v %v",low,high)
    // A scaled tree is a taller crown.
    tall:=[1]Placed{{type=1,position={0,0,0},rotation=1,scale={1,3}}}
    if !testing.expect(t,cell_crown_build(tall[:],crowns[:],&cell)) {return}
    low,high=geom.mesh_bounds(cell.positions[:])
    testing.expectf(t,high.y-low.y>2*(high.x-low.x),"%v %v",low,high)
    // Cells share a crown when they are made of the same: the same trees on
    // another ground, or with a type near enough to draw its mesh, are not.
    wood:=placed[:100]
    key:=crown_key(wood,crowns[:])
    same:=slice.clone(wood,context.temp_allocator)
    testing.expect_value(t,crown_key(same,crowns[:]),key)
    same[7].position.y+=0.5
    testing.expect(t,crown_key(same,crowns[:])!=key,"a ground sculpted under one tree")
    none:=[2]Crown_Triangles{}
    testing.expect(t,crown_key(nil,none[:])!=key,"the type near: its trees give no crown")
}

// Past RESIDENT_CELLS a Foliage keeps the nearest resident cells; those
// within reach that it leaves out are a problem.
@(test)
past_their_budget_the_nearest_cells_stay_resident :: proc(t:^testing.T) {
    cells:=[]Resident_Cell{{resident=true},{resident=true},{resident=false},{resident=true},{resident=true}}
    order:=[]scene.Resident_Order{{near=1.2,index=0},{near=0.5,index=1},{near=0,index=3},{near=0.9,index=4}}
    testing.expect_value(t,resident_cap(cells,order,8,1),0)
    testing.expect(t,cells[0].resident && cells[1].resident && cells[3].resident && cells[4].resident,"under the budget all stay")
    left_out:=resident_cap(cells,order,2,1)
    testing.expect(t,cells[3].resident && cells[1].resident,"the nearest stay")
    testing.expect(t,!cells[4].resident && !cells[0].resident && !cells[2].resident,"the farthest go")
    testing.expect_value(t,left_out,1)
}

// When the renderer forgets its batches and meshes, the cells let go of the
// crowns they share, and those and the far forms are made again: none is
// kept for a cell that no longer traces it.
@(test)
what_the_renderer_forgets_takes_the_crowns_and_far_forms_with_it :: proc(t:^testing.T) {
    resident:Foliage_Resident
    defer foliage_resident_free(&resident)
    crown:=base.Asset_Id{5,5}
    owner:Resident_Owner
    for coord in ([2][2]i32{{0,0},{1,0}}) {append(&owner.cells,Resident_Cell{coord=coord,crown=crown,built=true})}
    append(&owner.kinds,Kind_Key{{6,6},64})
    append(&resident.owners,owner)
    append(&resident.crowns,Shared_Crown{coord={0,0},mesh=crown,users=2})
    append(&resident.kinds,Resident_Kind{key={{6,6},64},made=true})
    resident_forget(&resident)
    testing.expect_value(t,len(resident.crowns),0)
    testing.expect_value(t,len(resident.kinds),0)
    testing.expect(t,len(resident.owners[0].cells)==0 && !resident.owners[0].built && len(resident.owners[0].kinds)==0)
}
