package mirai_physics

import "base:runtime"
import "core:testing"

// The breakables as state of the world: what a step, a snapshot and a copy do with them.

@(test)
a_hit_breaks_two_equal_worlds_alike_and_restoring_mid_break_repeats_the_rest :: proc(t:^testing.T) {
    STEPS :: 90
    a,b:World
    testing.expect(t,test_destruct_world(&a) && test_destruct_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    for w in ([2]^World{&a,&b}) {
        test_ground(w)
        // Small groups are debris that expires, and the rest is removed, within the steps of the test.
        desc:=BREAKABLE_DESC_DEFAULT
        desc.damage_radius,desc.debris_volume,desc.debris_ticks,desc.removal_ticks=1,0.1,20,40
        test_destructible(w,{4,2,0.4},{0,1,0},24,true,desc)
        test_cannonball(w,{0,1.2,3},{0,0,-30})
    }
    hashes:[STEPS]u64
    snapshot:World
    defer world_destroy(&snapshot)
    taken,size,kinds:=-1,0,bit_set[Break_Kind]{}
    for &hash,step in hashes {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        hash=world_hash(&a)
        events,others:=world_events(&a).breaks,world_events(&b).breaks
        same:=world_hash(&b)==hash && len(events)==len(others)
        if same {
            for event,at in events {
                same&&=event==others[at]
                kinds+={event.kind}
            }
        }
        if !testing.expectf(t,same,"the worlds broke apart at step %v",step) {return}
        // The step that broke the wall left it half way: pieces in the air, debris and groups that expire.
        if taken<0 && len(events)>0 {
            testing.expect(t,test_keep(&snapshot,&a))
            taken=step
        }
    }
    if !testing.expect(t,taken>=0 && kinds>={.Impact,.Remove},"the wall broke and what came off expired") {return}
    testing.expect(t,test_restore(&a,&snapshot))
    testing.expect_value(t,world_hash(&a),hashes[taken])
    for step in taken+1..<STEPS {
        world_step(&a,1.0/60)
        if !testing.expectf(t,world_hash(&a)==hashes[step],"the restored world diverged at step %v",step) {return}
    }
}

@(test)
a_state_copy_takes_the_breakables_mid_break_and_steps_as_its_source :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_destruct_world(&a) && test_destruct_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    walls:[2]Breakable_Handle
    // The same geometry in both, as a copy of it leaves them: the wall, and a cut that makes new hulls.
    for w,i in ([2]^World{&a,&b}) {
        test_ground(w)
        walls[i]=test_wall(w)
        _,cut:=breakable_slice(w,walls[i],{1.2,1,0},{1,0.1,0})
        testing.expect(t,cut)
    }
    test_cannonball(&a,{0,1.2,3},{0,0,-30})
    for _ in 0..<20 {world_step(&a,1.0/60)}
    testing.expect(t,breakable_check(&a,walls[0])!=breakable_check(&b,walls[1]),"only the first wall was hit")
    if _,copied:=world_state_copy(&b,&a);!testing.expect(t,copied) {return}
    testing.expect_value(t,world_hash(&b),world_hash(&a))
    testing.expect_value(t,breakable_check(&b,walls[0]),breakable_check(&a,walls[0]))
    pa,pb:[128]Piece_Info
    count:=breakable_pieces(&a,walls[0],pa[:])
    testing.expect_value(t,breakable_pieces(&b,walls[0],pb[:]),count)
    for piece,at in pa[:min(count,len(pa))] {testing.expect_value(t,pb[at],piece)}
    // Both go on alike: the same steps, and a cut whose halves take the hull slots of their pieces.
    for step in 0..<60 {
        if step==10 {
            for w in ([2]^World{&a,&b}) {
                _,cut:=breakable_slice(w,walls[0],{-1,1,0},{1,0,0.2})
                testing.expect(t,cut)
            }
        }
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        if !testing.expectf(t,world_hash(&b)==world_hash(&a),"the copy diverged from its source at step %v",step) {return}
    }
}

@(test)
a_contact_of_the_step_that_breaks_a_piece_off_still_names_what_its_shapes_were :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    desc:=BREAKABLE_DESC_DEFAULT
    desc.damage_radius,desc.user_data=1,77
    wall,_:=test_destructible(&w,{4,2,0.4},{0,1,0},24,true,desc)
    ball:=test_cannonball(&w,{0,1.2,3},{0,0,-30})
    body_set_user_data(&w,ball,5)
    for _ in 0..<20 {
        world_step(&w,1.0/60)
        if breakable_revision(&w,wall)==0 {continue}
        // The piece the ball met left its body in this step, and its shape with it.
        ended:=0
        for event in world_events(&w).contact_begin {
            if shape_valid(&w,event.shape_a) && shape_valid(&w,event.shape_b) {continue}
            ended+=1
            users:=event.users
            testing.expect(t,users.body_a==77 && users.shape_a==77 && users.body_b==5 || users.body_b==77 && users.shape_b==77 && users.body_a==5,"the event names the wall and the ball")
        }
        testing.expect(t,ended>0,"no contact of the step lost a shape to the break")
        return
    }
    testing.expect(t,false,"the ball did not break the wall")
}

@(test)
a_strain_over_a_region_reaches_each_body_of_the_breakables_its_filter_meets :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    desc:=BREAKABLE_DESC_DEFAULT
    desc.gravity_scale,desc.debris_volume=0,0
    near,_:=test_destructible(&w,{2,1,1},{0,3,0},6,false,desc)
    desc.filter.layers=4
    other,_:=test_destructible(&w,{2,1,1},{0,6,0},6,false,desc)
    desc.filter.layers=1
    far,_:=test_destructible(&w,{2,1,1},{40,3,0},6,false,desc)
    // Two bodies of the first one: each gets an event of its own.
    _,cut:=breakable_slice(&w,near,{0,3,0},{1,0,0})
    testing.expect(t,cut)
    world_step(&w,1.0/60)
    region:=Break_Region{point={0,4,0},radius=8}
    seen:=QUERY_FILTER_DEFAULT
    seen.objects=1
    testing.expect_value(t,breakables_strain(&w,region,5,weaken=true,filter=seen),2)
    events:=world_events(&w).breaks
    if !testing.expect_value(t,len(events),2) {return}
    pieces:[32]Piece_Info
    count:=min(breakable_pieces(&w,near,pieces[:]),len(pieces))
    on:[2]Body_Handle
    for event,at in events {
        testing.expect(t,event.breakable==near && event.kind==.Weaken && event.piece>=0)
        for piece in pieces[:count] {
            if piece.id==event.piece {on[at]=piece.body}
        }
    }
    testing.expect(t,on[0]!={} && on[1]!={} && on[0]!=on[1],"one event for each body")
    testing.expect(t,breakable_revision(&w,other)==0 && breakable_revision(&w,far)==0)
    bonds:[64]Bond_Info
    for bond in bonds[:min(breakable_bonds(&w,other,bonds[:]),len(bonds))] {testing.expect_value(t,bond.strain,f32(0))}
    for bond in bonds[:min(breakable_bonds(&w,far,bonds[:]),len(bonds))] {testing.expect_value(t,bond.strain,f32(0))}
    // The body the filter names is left alone, and the next step starts its events again.
    seen.ignore_body=on[0]
    testing.expect_value(t,breakables_strain(&w,region,1e6,filter=seen),1)
    testing.expect_value(t,len(world_events(&w).breaks),3)
    world_step(&w,1.0/60)
    testing.expect_value(t,len(world_events(&w).breaks),0)
}

@(test)
breakables_and_bodies_asked_for_with_hostile_values_are_refused :: proc(t:^testing.T) {
    w,empty:World
    testing.expect(t,test_destruct_world(&w) && test_destruct_world(&empty))
    defer world_destroy(&w)
    defer world_destroy(&empty)
    wall:=test_wall(&w)
    root:=breakable_body(&w,wall)
    before:=world_hash(&w)
    nan:=transmute(f32)u32(0x7fc00000)
    inf:=transmute(f32)u32(0x7f800000)
    regions:=[]Break_Region{
        {point={nan,1,0},radius=3},{point={0,1,0},radius=nan},{point={0,1,0},radius=-1},{point={0,inf,0},radius=3},
        {point={0,1,0},half_extents={1,nan,1}},{point={0,1,0},half_extents={1,-1,1}},
        {point={0,1,0},half_extents={1,1,1},rotation=Quat(quaternion(w=nan,x=0,y=0,z=0))},
        {point={0,1,0},radius=3,blend=-1},{point={0,1,0},radius=3,blend=nan},
    }
    for region,at in regions {
        testing.expectf(t,breakables_strain(&w,region,1000)==0,"region %v strained",at)
    }
    for amount in ([]f32{0,-5,nan,inf}) {
        testing.expectf(t,breakables_strain(&w,{point={0,1,0},radius=3},amount)==0,"an amount of %v strained",amount)
    }
    testing.expect_value(t,breakables_strain(&w,{point={0,1,0},radius=3},1000,{nan,0,0}),0)
    testing.expect_value(t,world_hash(&w),before)
    testing.expect_value(t,len(world_events(&w).breaks),0)
    // A world that never had a breakable holds no pools for them, and has nothing to strain or name.
    ground:=test_ground(&empty)
    testing.expect_value(t,breakables_strain(&empty,{point={0,1,0},radius=3},1000),0)
    world_step(&empty,1.0/60)
    testing.expect(t,empty.pieces==nil && empty.bonds==nil && empty.breaking.hits==nil)
    for body in ([]Body_Handle{{},root,Body_Handle(max(u64)),ground}) {
        h,piece:=breakable_of(&empty,body)
        testing.expect(t,h=={} && piece==-1)
    }
    for body in ([]Body_Handle{{},test_ground(&w),Body_Handle(max(u64))}) {
        h,piece:=breakable_of(&w,body)
        testing.expect(t,h=={} && piece==-1)
    }
    owner,held:=breakable_of(&w,root)
    testing.expect(t,owner==wall && held>=0)
    // A shape of another owner whose tag is no piece: its hits damage nothing, and its body is of no breakable.
    for tag in ([]u32{max(u32),1<<31,u32(len(w.pieces))+1,u32(held)+1}) {
        desc:=BODY_DESC_DEFAULT
        desc.position,desc.linear_velocity={0,6,0},{0,-20,0}
        tagged:=body_create(&w,desc)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry,shape.hits,shape.tag=Sphere{0.25},true,tag
        shape_create(&w,tagged,shape)
        strange,none:=breakable_of(&w,tagged)
        testing.expect(t,strange=={} && none==-1)
        hits:=0
        for _ in 0..<30 {
            world_step(&w,1.0/60)
            hits+=len(world_events(&w).hit)
            for event in world_events(&w).breaks {testing.expect(t,event.breakable==wall)}
        }
        testing.expectf(t,hits>0,"the shape tagged %v hit nothing",tag)
        body_destroy(&w,tagged)
    }
    for h in ([]Breakable_Handle{{},Breakable_Handle(max(u64)),Breakable_Handle(u64(wall)+2)}) {
        testing.expect(t,!breakable_valid(&w,h) && breakable_pieces(&w,h,nil)==0 && breakable_state_size(&w,h)==0 && breakable_check(&w,h)==0)
        _,broke:=breakable_damage(&w,h,{0,1,0},3,{0,0,-9000})
        _,cut:=breakable_slice(&w,h,{0,1,0},{0,1,0})
        testing.expect(t,!broke && !cut)
    }
}

// The pools of the breakables, with the memory ending at each request in turn: the breakable is refused
// and the world holds none of them, and with memory enough it is made.
@(test)
the_first_breakable_without_memory_for_its_pools_is_refused_and_leaves_none :: proc(t:^testing.T) {
    Limit :: struct {owner:runtime.Allocator,remaining:int}
    limited :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        limit:=(^Limit)(data)
        if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
            if limit.remaining<=0 {return nil,.Out_Of_Memory}
            limit.remaining-=1
        }
        return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
    }
    limit:=Limit{owner=context.allocator,remaining=max(int)}
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=32,64,256,4
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity,desc.character_capacity=32,2,2,16,2
    desc.breakable_capacity,desc.piece_capacity,desc.bond_capacity=2,32,128
    desc.allocator={limited,&limit}
    w:World
    if !testing.expect(t,world_init(&w,desc)) {return}
    defer world_destroy(&w)
    before:=world_hash(&w)
    made,refused:=false,false
    for served in 0..<64 {
        limit.remaining=served
        h,error:=test_destructible(&w,{1,1,1},{0,2,0},4,false)
        limit.remaining=max(int)
        if w.breaking.made {
            // The pools found their memory: what the breakable itself lacks is not theirs to answer for.
            testing.expect(t,error!=.None || breakable_valid(&w,h))
            testing.expect(t,error==.None || w.breakable_count==0 && w.piece_count==0 && w.bond_count==0 && w.body_count==0 && w.shape_count==0)
            made=true
            break
        }
        refused=true
        if !testing.expectf(t,error==.Out_Of_Memory && h=={} && w.pieces==nil && w.bonds==nil && w.piece_hulls==nil && w.breaking.hits==nil && world_hash(&w)==before,"with %d requests served: %v left something",served,error) {return}
    }
    testing.expect(t,made && refused,"refused without memory, and made with it")
    h,error:=test_destructible(&w,{1,1,1},{0,4,0},4,false)
    testing.expect(t,error==.None && breakable_valid(&w,h))
}
