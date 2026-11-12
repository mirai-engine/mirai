package foliage

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import physics "plugins:physics/runtime"

// Two types, a generated cell with overrides and a manual cell.
@(private="file")
sample :: proc(s:^Source) {
    s.info.seed=7
    grass:=source_type_add(s,"grass",{1,1})
    grass.density=0.05
    tree:=source_type_add(s,"tree",{2,2})
    tree.density=0.01
    tree.collision=.Capsule
    tree.size={0.3,4,0}
    tree.casts_shadow=true
    source_cell(s,{0,0},true).generate=true
    source_instance_add(s,1,{40,1,-5},u32(mm.quat_pack(1,10)),{1,2},INSTANCE_GROUNDED,0.25)
    source_instance_add(s,0,{-0.5,0,63.9},u32(mm.quat_pack(1,10)),{1,1})
    source_override_set(s,{0,0},{type=0,point=0,kind=.Deleted})
    source_override_set(s,{0,0},{type=0,point=1,kind=.Moved,instance={position={3,0,4},rotation=u32(mm.quat_pack(1,10)),scale={2,2}}})
    source_override_set(s,{0,0},{type=1,point=0,kind=.Replaced,instance={type=0,position={10,0,10},rotation=u32(mm.quat_pack(1,10)),scale={1,1}}})
}

@(test)
cells_take_the_points_of_their_32_metres_including_negative_coordinates :: proc(t:^testing.T) {
    coord,local:=cell_of({40,1,-5})
    testing.expect_value(t,coord,[2]i32{1,-1})
    testing.expect(t,abs(local.x-8)<1e-4 && local.y==1 && abs(local.z-27)<1e-4)
    coord,local=cell_of({-0.5,0,63.9})
    testing.expect_value(t,coord,[2]i32{-1,1})
    coord,local=cell_of({32,0,0})
    testing.expect(t,coord==[2]i32{1,0} && local.x==0)
    // What rounds onto the far side is the first point of the next cell.
    coord,local=cell_of({-1e-7,0,0})
    testing.expect(t,local.x>=0 && local.x<CELL_SIZE)
    s:Source
    defer source_destroy(&s)
    sample(&s)
    testing.expect_value(t,len(s.cells),3)
    for i in 1..<len(s.cells) {testing.expect(t,coord_before(s.cells[i-1].coord,s.cells[i].coord),"cells in the order of z, then x")}
    cell:=source_cell(&s,{1,-1})
    if !testing.expect(t,cell!=nil && len(cell.manual)==1) {return}
    testing.expect(t,cell.manual[0].flags==INSTANCE_GROUNDED && cell.manual[0].ground==0.25,"the offset to the ground is kept")
    testing.expect(t,source_valid(&s))
}

@(test)
a_foliage_asset_comes_back_as_it_was_written_and_damage_is_refused :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    s:Source
    defer source_destroy(&s)
    sample(&s)
    // A cell whose neighbours are coded from each other: ids out of turn,
    // positions and grounds of both signs and -0, every rotation pattern.
    rotations:=[?]u32{0,max(u32),u32(mm.quat_pack(1,10)),0x9abcdef1}
    for k in 0..<64 {
        f:=f32(k)
        coord,id:=source_instance_add(&s,u32(k%2),{64+f*0.49,-f*1.75+3,-31.5+f*0.3},rotations[k%len(rotations)],{0.5+f,1+f*0.01},INSTANCE_GROUNDED,-f*0.125)
        testing.expect(t,coord==[2]i32{2,-1} && id!=0)
    }
    shuffled:=source_cell(&s,{2,-1})
    shuffled.manual[3].ground=-0.0
    shuffled.manual[5].position.y=-0.0
    shuffled.manual[7],shuffled.manual[40]=shuffled.manual[40],shuffled.manual[7]
    source_override_set(&s,{2,-1},{type=1,point=900,kind=.Moved,instance={type=1,position={31.99,-4,0},rotation=max(u32),scale={3,3},flags=INSTANCE_GROUNDED,ground=-0.0}})
    s.types[1].radius=2
    source_generate_area(&s,{-20,0,-10},9,true,0.5)
    data,error:=source_bytes(&s,{5,6},&types)
    defer delete(data)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,data),asset.Error.None)
    back:Source
    defer source_destroy(&back)
    id,ok:=source_read(&back,&file,&types)
    asset.asset_close(&file)
    testing.expect(t,ok && id==base.Asset_Id{5,6})
    testing.expect_value(t,back.info,s.info)
    testing.expect_value(t,len(back.types),len(s.types))
    for t2,i in s.types {testing.expect_value(t,back.types[i],t2)}
    testing.expect_value(t,len(back.cells),len(s.cells))
    for cell,i in s.cells {
        other:=back.cells[i]
        testing.expect(t,other.coord==cell.coord && other.generate==cell.generate && slice.equal(other.density[:],cell.density[:]))
        testing.expect(t,same_rows(other.manual[:],cell.manual[:]),"manual instances come back bit for bit, in their order")
        testing.expect(t,same_rows(other.overrides[:],cell.overrides[:]),"overrides come back bit for bit")
    }
    // Cut at any length, a file is refused and the source it would replace stays.
    for length in 0..<len(data) {
        cut:asset.Asset
        if asset.asset_open(&cut,data[:length])!=.None {continue}
        _,read:=source_read(&back,&cut,&types)
        asset.asset_close(&cut)
        testing.expect(t,!read,"a cut file is refused")
    }
    testing.expect_value(t,len(back.cells),len(s.cells))
    // What does not validate is not written.
    source_cell(&s,{2,-1}).manual[0].scale={0,1}
    _,invalid:=source_bytes(&s,{5,6},&types)
    testing.expect_value(t,invalid,asset.Error.Invalid)
}

// A manual instance keeps its id while its source keeps it: deleting one
// before it in its cell, adding another or moving it to another cell does
// not give its id to another. No two share one, and one is never given again.
@(test)
a_manual_instance_keeps_its_id_through_the_edits_of_its_cell :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    source_type_add(&s,"bush",{3,3})
    rotation:=u32(mm.quat_pack(1,10))
    _,first:=source_instance_add(&s,0,{2,0,2},rotation,{1,1})
    _,kept:=source_instance_add(&s,0,{4,0,4},rotation,{1,1})
    position_of :: proc(s:^Source,coord:[2]i32,id:u64) -> (position:[3]f32,found:bool) {
        work:Build_Work
        defer build_work_destroy(&work)
        cell:=source_cell(s,coord)
        if cell==nil {return}
        cell_build(s,cell,{},&work)
        for p in work.placed {if p.id==id {return p.position,true}}
        return
    }
    position,found:=position_of(&s,{0,0},MANUAL|u64(kept))
    testing.expect(t,found && position==[3]f32{4,0,4})
    testing.expect(t,source_instance_remove(&s,{0,0},first))
    _,added:=source_instance_add(&s,0,{1,0,1},rotation,{1,1})
    testing.expect(t,added!=first && added!=kept,"an id is never given again")
    position,found=position_of(&s,{0,0},MANUAL|u64(kept))
    testing.expect(t,found && position==[3]f32{4,0,4},"the cell changed before it, and its id names it still")
    _,found=position_of(&s,{0,0},MANUAL|u64(first))
    testing.expect(t,!found,"the id of one deleted names nothing")
    testing.expect(t,source_valid(&s))
    // Two instances with one id, or an id the source did not give, are damage.
    cell:=source_cell(&s,{0,0})
    cell.manual[1].id=cell.manual[0].id
    testing.expect(t,!source_valid(&s))
    cell.manual[1].id=s.info.instances+1
    testing.expect(t,!source_valid(&s))
    cell.manual[1].id=0
    testing.expect(t,!source_valid(&s))
}

@(test)
the_generator_makes_the_same_points_with_the_same_ids :: proc(t:^testing.T) {
    kind:=FOLIAGE_TYPE_DEFAULT
    kind.id,kind.density,kind.tilt=3,0.2,0.3
    a,b:[dynamic]Generated
    defer delete(a)
    defer delete(b)
    scatter(11,{4,-2},kind,&a)
    scatter(11,{4,-2},kind,&b)
    testing.expect(t,len(a)>150 && len(a)<260,"about the density by the area of the cell")
    testing.expect_value(t,len(a),len(b))
    for g,i in a {
        testing.expect_value(t,g,b[i])
        testing.expect_value(t,g.point,u32(i))
        testing.expect(t,g.position.x>=0 && g.position.x<CELL_SIZE && g.position.y>=0 && g.position.y<CELL_SIZE)
        testing.expect(t,g.scale[0]>=kind.scale[0] && g.scale[0]<=kind.scale[1])
    }
    // A lower density keeps its first points where they were.
    fewer:=kind
    fewer.density=0.05
    c:[dynamic]Generated
    defer delete(c)
    scatter(11,{4,-2},fewer,&c)
    testing.expect(t,len(c)<len(a))
    for g,i in c {testing.expect_value(t,g,a[i])}
    // Another cell, seed or type is another scatter.
    clear(&b)
    scatter(11,{5,-2},kind,&b)
    testing.expect(t,b[0].position!=a[0].position)
    clear(&b)
    scatter(12,{4,-2},kind,&b)
    testing.expect(t,b[0].position!=a[0].position)
}

@(test)
overrides_change_their_generated_instance_and_orphans_are_kept :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    sample(&s)
    work:Build_Work
    defer build_work_destroy(&work)
    cell:=source_cell(&s,{0,0})
    cell_build(&s,cell,{},&work)
    testing.expect_value(t,len(work.orphans),0)
    grass,trees:=0,0
    for p in work.placed {
        if p.type==0 {grass+=1} else {trees+=1}
        testing.expect(t,p.id!=generated_id(0,0),"the deleted instance is not there")
        if p.id==generated_id(0,1) {testing.expect(t,p.position==[3]f32{3,0,4} && p.scale==[2]f32{2,2} && p.type==0,"the moved one is where its override says")}
        if p.id==generated_id(1,0) {testing.expect(t,p.type==0 && p.position==[3]f32{10,0,10},"a tree replaced by grass")}
    }
    points:[dynamic]Generated
    defer delete(points)
    scatter(s.info.seed,{0,0},s.types[0],&points)
    expected_grass:=len(points)-1+1 // the moved one stays, one deleted, one tree replaced by grass
    clear(&points)
    scatter(s.info.seed,{0,0},s.types[1],&points)
    testing.expect_value(t,grass,expected_grass)
    testing.expect_value(t,trees,len(points)-1)
    // Regenerating gives the same instances.
    first:=make([]Placed,len(work.placed))
    defer delete(first)
    copy(first,work.placed[:])
    cell_build(&s,cell,{},&work)
    for p,i in work.placed {testing.expect_value(t,p,first[i])}
    // An override the generator no longer makes is an orphan, kept in the source.
    source_override_set(&s,{0,0},{type=0,point=100000,kind=.Deleted})
    s.types[1].density=0
    cell_build(&s,cell,{},&work)
    testing.expect_value(t,len(work.orphans),2)
    testing.expect_value(t,len(cell.overrides),4)
    // A cell that no longer generates makes orphans of all its overrides.
    cell.generate=false
    cell_build(&s,cell,{},&work)
    testing.expect_value(t,len(work.orphans),4)
    testing.expect_value(t,len(work.placed),0)
}

@(test)
batch_instances_carry_the_transform_of_their_entity :: proc(t:^testing.T) {
    owner:=mm.Transform{position={100,5,0},rotation=mm.quat_axis_angle({0,1,0},math.PI*0.5),scale={2,2,2}}
    p:=Placed{position={1,0,0},rotation=1,scale={1,1.5}}
    b:=batch_instance_of(p,owner)
    testing.expect(t,linalg.length(b.position-[3]f32{100,5,-2})<1e-4,"turned and scaled by its entity")
    _,across,along:=render.batch_instance_unpack(b)
    testing.expect(t,abs(across-2)<1e-3 && abs(along-3)<1e-3)
}

@(test)
a_cell_collides_with_one_static_body_and_one_instance_leaves_alone :: proc(t:^testing.T) {
    w:physics.Physics_State
    if !testing.expect(t,physics.test_state_make(&w)) {return}
    defer physics.state_destroy(&w)
    s:Source
    defer source_destroy(&s)
    sample(&s)
    fp:Foliage_Physics
    defer core.value_free(&fp,type_info_of(Foliage_Physics))
    collision:physics.Collision_Settings
    e:=core.Entity(42)
    for &cell,i in s.cells {cell.version=u32(i+1)}
    {complete,enough:=physics_owner_build(&fp,&w,&collision,e,&s,{scale={1,1,1},rotation=1});testing.expect(t,complete && enough)}
    // Trees collide, grass does not: the generated cell and the manual tree of cell (1,-1).
    testing.expect_value(t,len(fp.cells),len(s.cells))
    testing.expect_value(t,int(w.world.body_count),2)
    shapes:=int(w.world.shape_count)
    testing.expect_value(t,shapes,len(fp.shapes))
    for cell in fp.cells {if cell.body!={} {owned,_:=physics.owned_body_of(&w,cell.body);testing.expect(t,owned.owner==BODY_OWNER && owned.entity==e)}}
    // One instance leaves: its shape, and nothing else.
    testing.expect(t,collider_remove(&fp,&w,0,0))
    testing.expect_value(t,int(w.world.shape_count),shapes-1)
    testing.expect(t,!collider_remove(&fp,&w,0,0),"once")
    for handle,i in fp.shapes {if i>0 {_,valid:=physics.owned_shape_user(&w,handle);testing.expect(t,valid)}}
    // Building again replaces the bodies of the entity.
    {complete,enough:=physics_owner_build(&fp,&w,&collision,e,&s,{scale={1,1,1},rotation=1});testing.expect(t,complete && enough)}
    testing.expect_value(t,int(w.world.body_count),2)
    testing.expect_value(t,int(w.world.shape_count),shapes)
    // Building what changed keeps the bodies of the other cells.
    tree,generated:=[2]i32{1,-1},[2]i32{0,0}
    kept:physics.Body_Handle
    for cell in fp.cells {if cell.coord==tree {kept=cell.body}}
    source_cell(&s,{0,0}).version+=10
    {complete,enough:=physics_owner_build(&fp,&w,&collision,e,&s,{scale={1,1,1},rotation=1},nil,false);testing.expect(t,complete && enough)}
    testing.expect_value(t,int(w.world.body_count),2)
    testing.expect_value(t,int(w.world.shape_count),shapes)
    testing.expect_value(t,len(fp.shapes),shapes)
    for cell in fp.cells {
        if cell.coord==tree {testing.expect_value(t,cell.body,kept)}
        if cell.coord==generated {_,owned:=physics.owned_body_of(&w,cell.body);testing.expect(t,owned,"the cell that changed has a body again")}
        for handle in fp.shapes[cell.first:][:cell.count] {_,valid:=physics.owned_shape_user(&w,handle);testing.expect(t,valid)}
    }
    physics_owner_clear(&fp,&w,e)
    testing.expect(t,w.world.body_count==0 && len(fp.cells)==0 && len(fp.shapes)==0)
}

@(test)
overrides_keep_the_order_of_type_and_point_and_are_found_by_it :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    sample(&s)
    source_override_set(&s,{0,0},{type=0,point=7,kind=.Deleted})
    source_override_set(&s,{0,0},{type=0,point=3,kind=.Deleted})
    cell:=source_cell(&s,{0,0})
    for k in 1..<len(cell.overrides) {
        a,b:=cell.overrides[k-1],cell.overrides[k]
        testing.expect(t,a.type<b.type || a.type==b.type && a.point<b.point)
    }
    testing.expect_value(t,cell.overrides[override_find(cell,0,3)].point,u32(3))
    testing.expect_value(t,override_find(cell,0,4),-1)
    testing.expect(t,source_override_remove(&s,{0,0},0,3))
    testing.expect_value(t,override_find(cell,0,3),-1)
    testing.expect(t,source_valid(&s))
    // Out of order, a source is not valid: what writes it keeps the order.
    cell.overrides[0],cell.overrides[1]=cell.overrides[1],cell.overrides[0]
    testing.expect(t,!source_valid(&s))
}

@(test)
a_source_read_again_keeps_the_version_of_the_cells_that_did_not_change :: proc(t:^testing.T) {
    before,after:Source
    defer source_destroy(&before)
    defer source_destroy(&after)
    sample(&before)
    sample(&after)
    versions:=u32(0)
    for &cell in before.cells {versions+=1;cell.version=versions}
    source_instance_add(&after,0,{2,0,3},u32(mm.quat_pack(1,10)),{1,1})
    source_cell(&after,{5,5},true).generate=true
    cells_version(&after,&before,&versions)
    for cell in after.cells {
        old:=source_cell(&before,cell.coord)
        switch cell.coord {
        case {0,0},{5,5}: testing.expect(t,cell.version>3,"a changed or new cell takes the next version")
        case:             testing.expect_value(t,cell.version,old.version)
        }
    }
    // Other types change every cell.
    previous:=versions
    after.types[0].density=0.2
    keep:Source
    defer source_destroy(&keep)
    sample(&keep)
    for &cell,i in keep.cells {cell.version=u32(i+1)}
    cells_version(&after,&keep,&versions)
    for cell in after.cells {testing.expect(t,cell.version>previous)}
}

@(test)
instances_stand_on_their_ground_and_generated_ones_leave_where_it_has_none :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    sample(&s)
    s.types[0].align=1
    // A slope that rises 1 m a metre along x, and a hole where x is past 16 m.
    samples:=5
    heights:=make([]f32,samples*samples)
    defer delete(heights)
    for z in 0..<samples {for x in 0..<samples {
        heights[z*samples+x]=f32(x)*CELL_SIZE/f32(samples-1)
        if x>2 {heights[z*samples+x]=NO_GROUND}
    }}
    ground:=Ground_Cell{samples=samples,heights=heights}
    h,n,ok:=ground_at(ground,4,10)
    testing.expect(t,ok && abs(h-4)<1e-4 && abs(n.x+0.7071)<1e-3 && abs(n.y-0.7071)<1e-3)
    _,_,ok=ground_at(ground,20,10)
    testing.expect(t,!ok,"no ground in the hole")
    cell:=source_cell(&s,{0,0})
    append(&cell.manual,Foliage_Instance{id=10,type=0,flags=INSTANCE_GROUNDED,position={6,0,6},rotation=u32(mm.quat_pack(1,10)),scale={1,1},ground=0.5})
    append(&cell.manual,Foliage_Instance{id=11,type=0,position={7,3,7},rotation=u32(mm.quat_pack(1,10)),scale={1,1}})
    s.info.instances=11
    work:Build_Work
    defer build_work_destroy(&work)
    cell_build(&s,cell,ground,&work)
    flat:Build_Work
    defer build_work_destroy(&flat)
    cell_build(&s,cell,{},&flat)
    testing.expect(t,len(work.placed)<len(flat.placed),"generated instances over the hole are not there")
    // Under a Foliage that has ground, a cell whose ground is not known is not the plane y = 0.
    owner:Ground_Owner
    unknown,_:=ground_cell(&owner,{0,0})
    unread:Build_Work
    defer build_work_destroy(&unread)
    cell_build(&s,cell,unknown,&unread)
    testing.expect_value(t,len(unread.placed),2)
    for p in unread.placed {testing.expect(t,p.id&MANUAL!=0,"no generated instance where the ground is not known")}
    for p in work.placed {
        switch p.id {
        case MANUAL|10: testing.expect(t,abs(p.position.y-6.5)<1e-4,"a grounded instance stands its offset over the ground")
        case MANUAL|11: testing.expect_value(t,p.position.y,f32(3))
        case:
            if p.id&MANUAL!=0 || p.id==generated_id(0,1) || p.id==generated_id(1,0) {continue}
            testing.expect(t,p.position.x<=16+1e-3,"no generated instance past the hole")
            testing.expect(t,abs(p.position.y-p.position.x)<1e-3,"on the slope")
            if p.type==0 {
                up:=mm.quat_rotate(p.rotation,{0,1,0})
                testing.expect(t,up.x< -0.5,"leans with the slope")
            }
        }
    }
}

@(test)
a_manual_instance_aligned_with_its_ground_leans_with_the_ground_that_changes :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    sample(&s)
    s.types[0].align=1
    cell:=source_cell(&s,{0,0})
    cell.generate=false
    yaw:=mm.Quat(quaternion(w=0.9238795,x=0,y=0.38268343,z=0))
    append(&cell.manual,Foliage_Instance{id=10,type=0,flags=INSTANCE_GROUNDED|INSTANCE_ALIGNED,position={6,0,6},rotation=u32(mm.quat_pack(yaw,10)),scale={1,1},ground=0.5})
    append(&cell.manual,Foliage_Instance{id=11,type=0,flags=INSTANCE_GROUNDED,position={8,0,8},rotation=u32(mm.quat_pack(yaw,10)),scale={1,1}})
    s.info.instances=11
    testing.expect(t,source_valid(&s))
    samples:=5
    heights:=make([]f32,samples*samples)
    defer delete(heights)
    work:Build_Work
    defer build_work_destroy(&work)
    // Flat at 2 m, then a slope that rises 1 m a metre along x.
    for slope in ([2]bool{false,true}) {
        for z in 0..<samples {for x in 0..<samples {heights[z*samples+x]=slope?f32(x)*CELL_SIZE/f32(samples-1):2}}
        cell_build(&s,cell,{samples=samples,heights=heights},&work)
        if !testing.expect_value(t,len(work.placed),2) {return}
        aligned,kept:=work.placed[0],work.placed[1]
        testing.expect(t,abs(aligned.position.y-(slope?6.5:2.5))<1e-4,"it stands its offset over the ground")
        up:=mm.quat_rotate(aligned.rotation,{0,1,0})
        if slope {
            testing.expect(t,abs(up.x+0.7071)<1e-2 && abs(up.y-0.7071)<1e-2,"the aligned one leans with the new slope")
        } else {
            testing.expect(t,abs(up.y-1)<1e-3,"on flat ground it stands up")
        }
        normal:=slope?[3]f32{-0.70710677,0.70710677,0}:[3]f32{0,1,0}
        forward:=mm.quat_rotate(conj(ground_slope(1,normal))*aligned.rotation,{1,0,0})
        testing.expect(t,abs(forward.z-mm.quat_rotate(yaw,{1,0,0}).z)<1e-2,"it keeps its own turn")
        testing.expect(t,abs(mm.quat_rotate(kept.rotation,{0,1,0}).y-1)<1e-3,"one only grounded keeps its rotation")
    }
    // An aligned one that is not grounded is damage.
    cell.manual[1].flags=INSTANCE_ALIGNED
    testing.expect(t,!source_valid(&s))
}

@(test)
placed_instances_group_by_type_keeping_their_order :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    sample(&s)
    work:Build_Work
    defer build_work_destroy(&work)
    for type in ([]u32{1,0,1,9,0,1}) {append(&work.placed,Placed{type=type})}
    placed_group(&s,&work)
    testing.expect_value(t,len(work.firsts),3)
    grass:=work.order[work.firsts[0]:work.firsts[1]]
    trees:=work.order[work.firsts[1]:work.firsts[2]]
    testing.expect(t,len(grass)==2 && grass[0]==1 && grass[1]==4)
    testing.expect(t,len(trees)==3 && trees[0]==0 && trees[1]==2 && trees[2]==5)
    testing.expect_value(t,len(work.order),5)
}

@(test)
a_part_of_a_prefab_composes_with_its_instance_and_says_what_it_leaves_out :: proc(t:^testing.T) {
    owner:=mm.transform_matrix({position={10,0,0},rotation=1,scale={2,2,2}})
    p:=Placed{position={1,0,0},rotation=mm.quat_axis_angle({0,1,0},math.PI*0.5),scale={1,1.5}}
    part:=mm.transform_matrix({position={0,1,0},rotation=1,scale={1,1,1}})
    b,error:=part_instance(p,owner,part)
    testing.expect(t,error<1e-4)
    testing.expect(t,linalg.length(b.position-[3]f32{12,3,0})<1e-3,"the part one metre up, under the instance and the entity")
    _,across,along:=render.batch_instance_unpack(b)
    testing.expect(t,abs(across-2)<1e-2 && abs(along-3)<1e-2)
    // A part scaled along x alone is approximated, and says by how much.
    stretched:=mm.transform_matrix({rotation=1,scale={3,1,1}})
    _,error=part_instance(p,owner,stretched)
    testing.expect(t,error>PREFAB_ERROR)
}

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
    data,error:=asset.scene_bytes(&prefab)
    defer delete(data)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,data),asset.Error.None) {return}
    defer asset.asset_close(&file)
    parts:[dynamic]Prefab_Part
    defer delete(parts)
    testing.expect(t,prefab_parts(&file,&types,&parts))
    if !testing.expect_value(t,len(parts),1) {return}
    testing.expect_value(t,parts[0].renderer.mesh,base.Asset_Id{7,7})
    // The trunk one metre up scaled twice, the crown one metre along it; the root's own place is the instance's.
    testing.expect(t,linalg.length(parts[0].placement[3].xyz-[3]f32{2,1,0})<1e-5)
    testing.expect(t,abs(linalg.length(parts[0].placement[0].xyz)-2)<1e-5)
}

@(test)
a_removed_type_takes_its_instances_and_overrides_with_it :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    sample(&s)
    // Grass: a manual one in (-1,1), a Deleted, a Moved and the instance that replaces a tree.
    testing.expect(t,source_type_remove(&s,0))
    testing.expect(t,!source_type_remove(&s,0),"there is no such type any more")
    testing.expect_value(t,len(s.types),1)
    testing.expect_value(t,len(source_cell(&s,{-1,1}).manual),0)
    testing.expect_value(t,len(source_cell(&s,{1,-1}).manual),1)
    overrides:=source_cell(&s,{0,0}).overrides[:]
    if testing.expect_value(t,len(overrides),1) {
        testing.expect(t,overrides[0].type==1 && overrides[0].kind==.Deleted,"the tree it replaced is not there")
    }
    testing.expect(t,source_valid(&s))
}

// One type of grass over a generated cell, and the points it gets there
// without a rule, on the ground given.
@(private="file")
rule_sample :: proc(s:^Source,ground:Ground_Cell,work:^Build_Work) -> ^Cell {
    s.info.seed=5
    source_type_add(s,"grass",{1,1}).density=0.08
    cell:=source_cell(s,{0,0},true)
    cell.generate=true
    cell_build(s,cell,ground,work)
    return cell
}

@(private="file")
placed_by_id :: proc(placed:[]Placed,id:u64) -> (Placed,bool) {
    for p in placed {if p.id==id {return p,true}}
    return {},false
}

@(test)
a_rule_of_slope_and_height_takes_out_the_generated_points_off_it_and_keeps_the_ids_of_the_rest :: proc(t:^testing.T) {
    // Flat at 2 m up to x = 16 m, then a rise of 2 m a metre.
    samples:=5
    heights:=make([]f32,samples*samples)
    defer delete(heights)
    for z in 0..<samples {for x in 0..<samples {heights[z*samples+x]=2+f32(max(x-2,0))*16}}
    ground:=Ground_Cell{samples=samples,heights=heights}
    s:Source
    defer source_destroy(&s)
    all:Build_Work
    defer build_work_destroy(&all)
    cell:=rule_sample(&s,ground,&all)
    testing.expect(t,len(all.placed)>40)
    work:Build_Work
    defer build_work_destroy(&work)
    s.types[0].rule={enabled=true,slope={0,0.3},height={-POSITION_MAX,POSITION_MAX}}
    testing.expect(t,source_valid(&s))
    cell_build(&s,cell,ground,&work)
    flat,steep:=0,0
    for p in all.placed {
        kept,found:=placed_by_id(work.placed[:],p.id)
        if p.position.x<16-1e-3 {
            flat+=1
            testing.expect(t,found && kept==p,"a point on the flat stays as it was, with its id")
        } else if p.position.x>16+1e-3 {
            steep+=1
            testing.expect(t,!found,"a point on the slope is not there")
        }
    }
    testing.expect(t,flat>0 && steep>0)
    testing.expect_value(t,len(work.placed),flat)
    // Height: only the ground from 1 m to 3 m takes it.
    s.types[0].rule={enabled=true,slope={0,math.PI/2},height={1,3}}
    cell_build(&s,cell,ground,&work)
    for p in work.placed {testing.expect(t,p.position.y>=1 && p.position.y<=3)}
    testing.expect(t,len(work.placed)>=flat && len(work.placed)<len(all.placed))
    // Off, the rule takes nothing out.
    s.types[0].rule.enabled=false
    cell_build(&s,cell,ground,&work)
    testing.expect_value(t,len(work.placed),len(all.placed))
}

@(test)
a_rule_of_layers_takes_the_ground_with_enough_of_them_and_none_where_they_are_not_known :: proc(t:^testing.T) {
    testing.expect(t,rule_allows({rule={enabled=true,slope={0,1},height={-1,1},layers=0b0110,weight=0.6}},0,{0,1,0},{0.2,0.3,0.4,0},true),"layers 1 and 2 together")
    testing.expect(t,!rule_allows({rule={enabled=true,slope={0,1},height={-1,1},layers=0b0010,weight=0.6}},0,{0,1,0},{0.2,0.3,0.4,0},true))
    testing.expect(t,!rule_allows({rule={enabled=true,slope={0,1},height={-1,1},layers=0b0010}},0,{0,1,0},{},false),"no weights known")
    testing.expect(t,rule_allows({rule={enabled=true,slope={0,1},height={-1,1}}},0,{0,1,0},{},false),"no layers asked")
    // Layer 1 all over x up to 16 m, then layer 0 from 24 m; between them, half of each at 20 m.
    samples:=5
    heights:=make([]f32,samples*samples)
    defer delete(heights)
    weights:=make([][4]u8,samples*samples)
    defer delete(weights)
    for z in 0..<samples {for x in 0..<samples {weights[z*samples+x]=x<=2?{0,255,0,0}:{255,0,0,0}}}
    ground:=Ground_Cell{samples=samples,heights=heights,weights=weights}
    w,ok:=ground_weights_at(ground,20,5)
    testing.expect(t,ok && abs(w[0]-0.5)<1e-4 && abs(w[1]-0.5)<1e-4)
    s:Source
    defer source_destroy(&s)
    all:Build_Work
    defer build_work_destroy(&all)
    cell:=rule_sample(&s,ground,&all)
    s.types[0].rule={enabled=true,slope={0,math.PI/2},height={-POSITION_MAX,POSITION_MAX},layers=0b10,weight=1}
    work:Build_Work
    defer build_work_destroy(&work)
    cell_build(&s,cell,ground,&work)
    kept:=0
    for p in all.placed {
        _,found:=placed_by_id(work.placed[:],p.id)
        if p.position.x<=16-1e-3 {testing.expect(t,found,"all of layer 1");kept+=1}
        if p.position.x>16+1e-3 {testing.expect(t,!found,"less than all of layer 1")}
    }
    testing.expect(t,kept>0)
    // Half of it takes the ground to x = 20 m.
    s.types[0].rule.weight=0.5
    cell_build(&s,cell,ground,&work)
    for p in work.placed {testing.expect(t,p.position.x<=20+1e-3)}
    testing.expect(t,len(work.placed)>kept)
    // A sample without layers, or no weights at all: a rule of layers takes nothing.
    weights[1]={}
    _,ok=ground_weights_at(ground,1,1)
    testing.expect(t,!ok)
    cell_build(&s,cell,{samples=samples,heights=heights},&work)
    testing.expect_value(t,len(work.placed),0)
    s.types[0].rule.layers=0
    cell_build(&s,cell,{samples=samples,heights=heights},&work)
    testing.expect_value(t,len(work.placed),len(all.placed))
}

@(test)
a_generated_point_takes_an_offset_of_its_type_and_keeps_its_other_values :: proc(t:^testing.T) {
    kind:=FOLIAGE_TYPE_DEFAULT
    kind.id,kind.density,kind.tilt=2,0.05,0.2
    before,after:[dynamic]Generated
    defer delete(before)
    defer delete(after)
    scatter(9,{1,3},kind,&before)
    kind.offset={-0.5,1.5}
    scatter(9,{1,3},kind,&after)
    testing.expect_value(t,len(after),len(before))
    low,high:=f32(1e9),f32(-1e9)
    for g,i in after {
        testing.expect(t,g.offset>=-0.5 && g.offset<=1.5)
        low,high=min(low,g.offset),max(high,g.offset)
        moved:=g
        moved.offset=0
        testing.expect_value(t,moved,before[i])
    }
    testing.expect(t,low<0 && high>1,"over the range")
    // Each stands its offset along its own y over the ground.
    s:Source
    defer source_destroy(&s)
    s.info.seed=9
    grass:=source_type_add(&s,"grass",{1,1})
    grass.density,grass.tilt,grass.offset=0.05,0.2,{-0.5,1.5}
    cell:=source_cell(&s,{1,3},true)
    cell.generate=true
    work:Build_Work
    defer build_work_destroy(&work)
    cell_build(&s,cell,{},&work)
    clear(&after)
    scatter(9,{1,3},s.types[0],&after)
    testing.expect_value(t,len(work.placed),len(after))
    for p,i in work.placed {
        g:=after[i]
        foot:=p.position-mm.quat_rotate(p.rotation,{0,g.offset,0})
        testing.expect(t,abs(foot.y)<1e-4 && abs(foot.x-(g.position.x+CELL_SIZE))<1e-3,"the offset along its y, from the plane")
    }
}

@(test)
a_foliage_file_written_before_the_rules_reads_them_off_and_bad_rules_are_refused :: proc(t:^testing.T) {
    // The type as it was before offset and rule.
    Older_Type :: struct {
        id:u32,
        name:[32]u8 `mirai:"text"`,
        mesh:base.Asset_Id,
        density:f32,
        scale:[2]f32,
        height:[2]f32,
        yaw:f32,
        tilt:f32,
        align:f32,
    }
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    document:asset.Document
    asset.document_init(&document,FOLIAGE_KIND,{7,8})
    defer asset.document_destroy(&document)
    document.kind_version=VERSION
    info:=Foliage_Info{seed=3,next_type=1}
    older:=[]Older_Type{{id=0,mesh={1,1},density=0.2,scale={1,1},height={1,2},yaw=1,align=1}}
    _,put:=asset.document_put_row(&document,&types,"foliage",&info)
    testing.expect_value(t,put,asset.Error.None)
    _,put=asset.document_put(&document,&types,"types",older)
    testing.expect_value(t,put,asset.Error.None)
    data,error:=asset.document_bytes(&document)
    defer delete(data)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    file:asset.Asset
    testing.expect_value(t,asset.asset_open(&file,data),asset.Error.None)
    s:Source
    defer source_destroy(&s)
    _,ok:=source_read(&s,&file,&types)
    asset.asset_close(&file)
    if !testing.expect(t,ok && len(s.types)==1) {return}
    testing.expect(t,s.types[0].density==0.2 && s.types[0].height==[2]f32{1,2})
    testing.expect_value(t,s.types[0].rule,Foliage_Rule{})
    testing.expect_value(t,s.types[0].offset,[2]f32{})
    testing.expect(t,rule_allows(s.types[0],100,{1,0,0},{},false),"a rule that is off takes any ground")
    // The default, turned on, is valid; what is out of range is not.
    s.types[0].rule=FOLIAGE_TYPE_DEFAULT.rule
    s.types[0].rule.enabled=true
    testing.expect(t,source_valid(&s))
    bad:=[?]Foliage_Rule{
        {slope={0.5,0.2}},
        {slope={-0.1,1}},
        {slope={0,2}},
        {height={1,0}},
        {height={0,math.F32_MAX}},
        {weight=1.5},
        {layers=1<<4},
        {slope={0,math.nan_f32()}},
    }
    for rule in bad {
        s.types[0].rule=rule
        testing.expect(t,!source_valid(&s))
    }
    s.types[0].rule={}
    s.types[0].offset={1,0}
    testing.expect(t,!source_valid(&s),"an inverted offset")
    s.types[0].offset={0,math.inf_f32(1)}
    testing.expect(t,!source_valid(&s))
}

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What a cell asks memory for (its instances placed, grouped by type, its
// tile of ground and its collision), a new type of a source and a source read
// from its file, with the memory ending at each request in turn: the call is
// refused and what it works on stays usable, and with memory enough it goes
// through.
@(test)
foliage_calls_without_memory_are_refused :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    sample(&s)
    for &cell,i in s.cells {cell.version=u32(i+1)}
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    whole:Build_Work
    defer build_work_destroy(&whole)
    if !testing.expect(t,cell_build(&s,source_cell(&s,{0,0}),{},&whole) && len(whole.placed)>0) {return}
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    data,written:=source_bytes(&s,{5,6},&types)
    defer delete(data)
    file:asset.Asset
    if !testing.expect(t,written==.None && asset.asset_open(&file,data)==.None) {return}
    defer asset.asset_close(&file)
    Call :: enum {Cell_Build,Placed_Group,Ground_Tile,Collision,Type_Add,Source_Read}
    for call in Call {
        fresh:Source
        work:Build_Work
        ground:Ground_Owner
        fp:Foliage_Physics
        collision:physics.Collision_Settings
        w:physics.Physics_State
        if !testing.expect(t,physics.test_state_make(&w)) {return}
        if call==.Placed_Group {append(&work.placed,..whole.placed[:])}
        done,refused:=false,false
        for served in 0..<64 {
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            switch call {
            case .Cell_Build:
                done=cell_build(&s,source_cell(&s,{0,0}),{},&work)
            case .Placed_Group:
                done=placed_group(&s,&work)
            case .Ground_Tile:
                _,_,tile:=ground_tile(&ground,{0,0},4)
                done=tile!=nil
            case .Collision:
                _,done=physics_owner_build(&fp,&w,&collision,core.Entity(42),&s,{scale={1,1,1},rotation=1})
            case .Type_Add:
                done=source_type_add(&fresh,"moss",{2,2})!=nil
            case .Source_Read:
                _,done=source_read(&fresh,&file,&types)
            }
            context.allocator=owner
            limit.remaining=max(int)
            if done {
                if call==.Cell_Build {testing.expectf(t,len(work.placed)==len(whole.placed),"a cell built with %d requests served has %d of its %d instances",served,len(work.placed),len(whole.placed))}
                break
            }
            refused=true
            #partial switch call {
            case .Cell_Build:  testing.expectf(t,len(work.placed)==0,"%v with %d requests served leaves %d instances",call,served,len(work.placed))
            case .Ground_Tile: testing.expectf(t,len(ground.tiles)==0,"%v with %d requests served leaves a tile",call,served)
            case .Type_Add,.Source_Read: testing.expectf(t,len(fresh.types)+len(fresh.cells)==0 && fresh.info=={},"%v with %d requests served leaves a part of the source",call,served)
            }
        }
        testing.expectf(t,done && refused,"%v: refused without memory, and with it it goes through",call)
        // With memory again what was refused is whole.
        #partial switch call {
        case .Cell_Build:
            testing.expect(t,cell_build(&s,source_cell(&s,{0,0}),{},&work) && len(work.placed)==len(whole.placed))
        case .Placed_Group:
            testing.expect(t,len(work.firsts)==len(s.types)+1 && len(work.order)==len(work.placed))
        case .Ground_Tile:
            heights,_,tile:=ground_tile(&ground,{0,0})
            testing.expect(t,tile!=nil && len(heights)==16)
        case .Type_Add:
            testing.expect(t,len(fresh.types)==1 && fresh.info.next_type==1,"the type that was refused took no id")
        case .Source_Read:
            testing.expect(t,len(fresh.types)==len(s.types) && len(fresh.cells)==len(s.cells))
        }
        source_destroy(&fresh)
        build_work_destroy(&work)
        ground_owner_destroy(&ground)
        physics_owner_clear(&fp,&w,core.Entity(42))
        core.value_free(&fp,type_info_of(Foliage_Physics))
        physics.state_destroy(&w)
    }
}

// The points of a type cover their cell evenly: 256 of them put one in each
// square of 2 m, as no points at random do.
@(test)
generated_points_cover_their_cell_with_one_in_each_square :: proc(t:^testing.T) {
    kind:=FOLIAGE_TYPE_DEFAULT
    kind.id,kind.density=5,0.25
    for coord in ([?][2]i32{{0,0},{-3,7}}) {
        points:[dynamic]Generated
        defer delete(points)
        scatter(21,coord,kind,&points)
        if !testing.expect_value(t,len(points),256) {return}
        squares:[256]int
        for g in points {squares[int(g.position.y/2)*16+int(g.position.x/2)]+=1}
        for n,k in squares {testing.expectf(t,n==1,"square %d holds %d points",k,n)}
    }
}

// Types with a radius keep their instances apart, of one type and of two,
// within a cell and across the borders of cells, the same each time; one
// without a radius stands anywhere.
@(test)
instances_with_a_radius_keep_apart_within_and_across_cells :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    s.info.seed=3
    tree:=source_type_add(&s,"tree",{1,1})
    tree.density,tree.radius=0.3,1.5
    bush:=source_type_add(&s,"bush",{2,2})
    bush.density,bush.radius=1,0.5
    grass:=source_type_add(&s,"grass",{3,3})
    grass.density=0.2
    for z in i32(0)..<2 {for x in i32(0)..<2 {source_cell(&s,{x,z},true).generate=true}}
    testing.expect(t,source_valid(&s))
    work:Build_Work
    defer build_work_destroy(&work)
    placed:[dynamic]Placed
    defer delete(placed)
    for &cell in s.cells {
        if !testing.expect(t,cell_build(&s,&cell,{},&work)) {return}
        append(&placed,..work.placed[:])
        again:=make([]Placed,len(work.placed))
        defer delete(again)
        copy(again,work.placed[:])
        cell_build(&s,&cell,{},&work)
        testing.expect(t,slice.equal(again,work.placed[:]),"the same each time")
    }
    radius:=[3]f32{1.5,0.5,0}
    counts:[3]int
    for a,i in placed {
        counts[a.type]+=1
        for b in placed[i+1:] {
            if radius[a.type]==0 || radius[b.type]==0 {continue}
            d:=a.position.xz-b.position.xz
            reach:=radius[a.type]*a.scale[0]+radius[b.type]*b.scale[0]
            testing.expectf(t,d.x*d.x+d.y*d.y>=reach*reach*(1-1e-5),"types %d and %d %v apart, nearer than %v",a.type,b.type,linalg.length(d),reach)
        }
    }
    points:[dynamic]Generated
    defer delete(points)
    for &cell in s.cells {scatter(s.info.seed,cell.coord,s.types[2],&points)}
    testing.expect_value(t,counts[2],len(points))
    testing.expect(t,counts[0]>100 && counts[1]>100,"spaced types still fill the cells")
}

// The density of a cell and what keeps foliage out of it take its generated
// instances away and leave the others with their ids.
@(test)
the_density_of_a_cell_and_what_keeps_foliage_out_thin_its_instances :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    s.info.seed=5
    grass:=source_type_add(&s,"grass",{1,1})
    grass.density=0.5
    cell:=source_cell(&s,{0,0},true)
    cell.generate=true
    all:Build_Work
    defer build_work_destroy(&all)
    cell_build(&s,cell,{},&all)
    n:=DENSITY_SAMPLES
    resize(&cell.density,n*n)
    for z in 0..<n {for x in 0..<n {cell.density[z*n+x]=x<n/2?255:0}}
    testing.expect(t,source_valid(&s))
    work:Build_Work
    defer build_work_destroy(&work)
    cell_build(&s,cell,{},&work)
    left:=0
    for p in work.placed {
        testing.expect(t,p.position.x<16,"none where it generates none")
        original,found:=placed_by_id(all.placed[:],p.id)
        testing.expect(t,found && original==p,"the others keep their id and place")
        if p.position.x<14 {left+=1}
    }
    full:=0
    for p in all.placed {if p.position.x<14 {full+=1}}
    testing.expect_value(t,left,full)
    // Squares kept out over x and z from 8 to 12 m take what stands there.
    clear(&cell.density)
    heights:=make([]f32,9*9)
    defer delete(heights)
    kept:[KEEP_OUT_WORDS]u64
    step:=CELL_SIZE/KEEP_OUT_SIDE
    for k in 0..<KEEP_OUT_SIDE*KEEP_OUT_SIDE {
        x,z:=(f32(k%KEEP_OUT_SIDE)+0.5)*step,(f32(k/KEEP_OUT_SIDE)+0.5)*step
        if x>8 && x<12 && z>8 && z<12 {kept[k>>6]|=1<<(uint(k)&63)}
    }
    cell_build(&s,cell,{samples=9,heights=heights,kept=kept[:]},&work)
    testing.expect(t,len(work.placed)>0 && len(work.placed)<len(all.placed))
    for p in work.placed {testing.expect(t,!(p.position.x>8 && p.position.x<12 && p.position.z>8 && p.position.z<12),"none where foliage is kept out")}
}

// The Generate brush raises the density of the cells under it, fading toward
// its border, lowers it again with off, and keeps no grid where all of it is.
@(test)
the_generate_brush_paints_the_density_of_the_cells_under_it :: proc(t:^testing.T) {
    s:Source
    defer source_destroy(&s)
    testing.expect(t,source_generate_area(&s,{16,0,16},6,true,0.5))
    cell:=source_cell(&s,{0,0})
    if !testing.expect(t,cell!=nil && cell.generate && len(cell.density)==DENSITY_SAMPLES*DENSITY_SAMPLES) {return}
    testing.expect(t,source_valid(&s))
    testing.expect(t,cell_density_at(cell,16,16)==1 && cell_density_at(cell,0,0)==0,"all of it at the centre, none away from it")
    soft:=cell_density_at(cell,21,16)
    testing.expect(t,soft>0 && soft<1,"less of it toward its border")
    testing.expect(t,!source_generate_area(&s,{16,0,16},6,true,0.5),"again it changes nothing")
    testing.expect(t,source_generate_area(&s,{16,0,16},60,true,0.5) && len(source_cell(&s,{0,0}).density)==0,"all of it everywhere keeps no grid")
    testing.expect(t,source_generate_area(&s,{16,0,16},6,false,0.5))
    cell=source_cell(&s,{0,0})
    testing.expect(t,cell.generate && cell_density_at(cell,16,16)==0 && cell_density_at(cell,0,0)==1)
    testing.expect(t,source_generate_area(&s,{16,0,16},60,false,0.5) && source_cell(&s,{0,0})==nil,"none of it takes out the cell that holds nothing else")
}
