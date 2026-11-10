package mirai_physics

import "core:testing"
import math "mirai:std/math"
import "mirai:std/geom"

@(private="file")
test_authored_destructible :: proc(w:^World,hierarchy:=true,settings:=Breakable_Desc{}) -> (Breakable_Handle,Breakable_Error) {
    f:geom.Fracture;geom.fracture_init(&f);defer geom.fracture_destroy(&f)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube)
    geom.cube_build(&cube)
    for part in 0..<4 {
        first_vertex,first_index:=u32(len(f.mesh.positions)),u32(len(f.mesh.indices))
        center:=Vec3{f32(part)*1.1-1.65,3,0}
        for point in cube.positions {append(&f.mesh.positions,point+center)}
        append(&f.mesh.indices,..cube.indices[:])
        for _ in 0..<len(cube.indices)/3 {append(&f.mesh.materials,0)}
        append(&f.pieces,geom.Fracture_Piece{site=u32(part),first_vertex=first_vertex,vertex_count=u32(len(cube.positions)),first_index=first_index,index_count=u32(len(cube.indices)),volume=1,center=center})
    }
    append(&f.connections,geom.Fracture_Connection{0,1,1},geom.Fracture_Connection{1,2,1},geom.Fracture_Connection{2,3,1})
    clusters:=[3]Cluster_Desc{{parent=-1,strength=100},{parent=0,strength=50},{parent=0,strength=50}}
    membership:=[4]i32{1,1,2,2}
    desc:=settings
    if desc.density==0 {desc=BREAKABLE_DESC_DEFAULT}
    desc.fracture=&f
    if hierarchy {desc.clusters,desc.piece_clusters=clusters[:],membership[:]}
    return breakable_create(w,desc)
}

@(private="file")
break_group_count :: proc(w:^World,h:Breakable_Handle) -> int {
    pieces:[16]Piece_Info
    count:=min(breakable_pieces(w,h,pieces[:]),len(pieces))
    groups:=0
    for piece,at in pieces[:count] {
        if piece.body=={} {continue}
        seen:=false
        for prior in pieces[:at] {seen=seen || prior.body==piece.body}
        if !seen {groups+=1}
    }
    return groups
}

@(test)
authored_clusters_release_root_then_children_then_leaves_and_replay :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0
    h,error:=test_authored_destructible(&w,true,settings)
    if !testing.expect_value(t,error,Breakable_Error.None) {return}
    testing.expect_value(t,break_group_count(&w,h),1)
    snapshot:World;defer world_destroy(&snapshot)
    saved:=test_keep(&snapshot,&w)
    testing.expect(t,saved)
    events:[3]Break_Event
    events[0],_=breakable_strain(&w,h,{0,3,0},100,1000)
    testing.expect_value(t,break_group_count(&w,h),2)
    clusters:[3]Cluster_Info
    testing.expect_value(t,breakable_clusters(&w,h,clusters[:]),3)
    testing.expect(t,clusters[0].broken && !clusters[1].broken && !clusters[2].broken)
    pieces:[4]Piece_Info;breakable_pieces(&w,h,pieces[:])
    events[1],_,_=breakable_strain_body(&w,h,pieces[0].id,{-1.1,3,0},100,1000)
    testing.expect_value(t,break_group_count(&w,h),3)
    events[2],_,_=breakable_strain_body(&w,h,pieces[3].id,{1.1,3,0},100,1000)
    testing.expect_value(t,break_group_count(&w,h),4)
    final:=world_hash(&w)
    testing.expect(t,test_restore(&w,&snapshot))
    for event in events {testing.expect(t,break_event_apply(&w,event))}
    testing.expect_value(t,world_hash(&w),final)
}

@(test)
strain_breaks_without_launching_and_weakening_waits_for_external_damage :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0
    h,_:=test_authored_destructible(&w,false,settings)
    event,strained:=breakable_weaken(&w,h,{0,3,0},100,10000)
    testing.expect(t,strained && event.kind==.Weaken)
    testing.expect_value(t,break_group_count(&w,h),1)
    testing.expect_value(t,breakable_revision(&w,h),u32(0))
    _,broke:=breakable_strain(&w,h,{0,3,0},100,1)
    testing.expect(t,broke)
    testing.expect_value(t,break_group_count(&w,h),4)
    pieces:[4]Piece_Info;breakable_pieces(&w,h,pieces[:])
    for piece in pieces {testing.expect_value(t,body_linear_velocity(&w,piece.body),Vec3{})}
}

@(test)
authored_cluster_state_preserves_level_and_connection_strength_on_late_join :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_destruct_world(&a));defer world_destroy(&a)
    testing.expect(t,test_destruct_world(&b));defer world_destroy(&b)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0
    first,_:=test_authored_destructible(&a,true,settings)
    second,_:=test_authored_destructible(&b,true,settings)
    breakable_strain(&a,first,{0,3,0},100,1000)
    state:=make([]u8,breakable_state_size(&a,first));defer delete(state)
    testing.expect_value(t,breakable_state_write(&a,first,state),len(state))
    testing.expect_value(t,world_stats(&b).shapes,1)
    testing.expect(t,breakable_state_apply(&b,second,state))
    testing.expect_value(t,breakable_check(&b,second),breakable_check(&a,first))
    testing.expect_value(t,break_group_count(&b,second),2)
    testing.expect_value(t,world_stats(&b).shapes,world_stats(&a).shapes)
    pieces:[4]Piece_Info;breakable_pieces(&b,second,pieces[:])
    breakable_strain_body(&b,second,pieces[0].id,{-1.1,3,0},100,1000)
    testing.expect_value(t,break_group_count(&b,second),3)
}

@(test)
detached_groups_keep_gravity_surface_and_filter_take_a_new_filter_and_expire_by_timer :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT
    settings.gravity_scale,settings.friction,settings.restitution=0,0.25,0.7
    settings.filter={layers=4,block=8,overlap=16,group=2}
    settings.removal_ticks=2
    h,error:=test_authored_destructible(&w,false,settings)
    testing.expect_value(t,error,Breakable_Error.None)
    breakable_strain(&w,h,{0,3,0},100,10000)
    pieces:[4]Piece_Info;breakable_pieces(&w,h,pieces[:])
    for piece in pieces {
        _,restitution:=shape_material(&w,piece.shape)
        testing.expect_value(t,restitution,f32(0.7))
        testing.expect_value(t,shape_filter(&w,piece.shape),settings.filter)
        testing.expect_value(t,body_gravity_scale(&w,piece.body),f32(0))
    }
    moved:=Filter{layers=2,block=2}
    breakable_set_filter(&w,h,moved)
    for piece in pieces {testing.expect_value(t,shape_filter(&w,piece.shape),moved)}
    test_steps(&w,2)
    testing.expect_value(t,break_group_count(&w,h),4)
    world_step(&w,1.0/60)
    testing.expect_value(t,break_group_count(&w,h),1)
    testing.expect_value(t,len(world_events(&w).breaks),3)
    for event in world_events(&w).breaks {testing.expect_value(t,event.kind,Break_Kind.Remove)}
}

@(test)
detached_groups_can_be_removed_when_they_sleep :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0;settings.remove_on_sleep=true
    h,_:=test_authored_destructible(&w,false,settings)
    breakable_strain(&w,h,{0,3,0},100,10000)
    pieces:[4]Piece_Info;breakable_pieces(&w,h,pieces[:])
    for piece in pieces {
        if piece.group==0 {continue}
        pose:=body_transform(&w,piece.body)
        body_rest(&w,piece.body,pose.p,pose.q)
    }
    world_step(&w,1.0/60)
    testing.expect_value(t,break_group_count(&w,h),1)
}

@(test)
passive_fragment_deadlines_survive_expiry_restore_and_explicit_removal_replay :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0;settings.removal_ticks=3;settings.remove_on_sleep=true;settings.passive_removal=true
    h,_:=test_authored_destructible(&w,false,settings)
    breakable_strain(&w,h,{0,3,0},100,10000)
    pieces:[4]Piece_Info;breakable_pieces(&w,h,pieces[:])
    representative:i32=-1
    body:Body_Handle
    for piece in pieces {
        ticks,expires:=breakable_body_remaining_ticks(&w,h,piece.body)
        if piece.group==0 {
            testing.expect(t,!expires)
            _,removed:=breakable_remove_body(&w,h,piece.id)
            testing.expect(t,!removed)
            testing.expect(t,!break_event_apply(&w,{breakable=h,piece=piece.id,kind=.Remove}))
            continue
        }
        testing.expect(t,expires)
        testing.expect_value(t,ticks,u32(3))
        representative,body=piece.id,piece.body
        pose:=body_transform(&w,piece.body);body_rest(&w,piece.body,pose.p,pose.q)
    }
    snapshot:World;defer world_destroy(&snapshot)
    saved:=test_keep(&snapshot,&w);testing.expect(t,saved)
    test_steps(&w,5)
    ticks,expires:=breakable_body_remaining_ticks(&w,h,body)
    testing.expect(t,expires)
    testing.expect_value(t,ticks,u32(0))
    testing.expect_value(t,break_group_count(&w,h),4)
    event,removed:=breakable_remove_body(&w,h,representative)
    testing.expect(t,removed && event.kind==.Remove)
    testing.expect_value(t,break_group_count(&w,h),3)
    final:=world_hash(&w)
    testing.expect(t,test_restore(&w,&snapshot))
    test_steps(&w,5)
    testing.expect(t,break_event_apply(&w,event))
    testing.expect_value(t,world_hash(&w),final)
}

@(test)
fragment_state_preserves_finite_and_unlimited_lifetimes_for_passive_worlds :: proc(t:^testing.T) {
    for lifetime in ([2]u32{0,4}) {
        a,b:World;testing.expect(t,test_destruct_world(&a));testing.expect(t,test_destruct_world(&b))
        settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0;settings.removal_ticks=lifetime;settings.passive_removal=true
        first,_:=test_authored_destructible(&a,false,settings)
        second,_:=test_authored_destructible(&b,false,settings)
        breakable_strain(&a,first,{0,3,0},100,10000)
        test_steps(&a,2)
        state:=make([]u8,breakable_state_size(&a,first))
        testing.expect_value(t,breakable_state_write(&a,first,state),len(state))
        testing.expect(t,breakable_state_apply(&b,second,state))
        pieces:[4]Piece_Info;breakable_pieces(&b,second,pieces[:])
        for piece in pieces {
            ticks,expires:=breakable_body_remaining_ticks(&b,second,piece.body)
            testing.expect_value(t,expires,piece.group!=0 && lifetime!=0)
            if expires {testing.expect_value(t,ticks,u32(2))}
        }
        testing.expect_value(t,breakable_check(&b,second),breakable_check(&a,first))
        delete(state);world_destroy(&a);world_destroy(&b)
    }
}

@(test)
cutting_a_detached_group_preserves_its_deadline_mass_and_replay :: proc(t:^testing.T) {
    for lifetime in ([2]u32{0,20}) {
        w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
        settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0;settings.removal_ticks=lifetime
        h,_:=test_authored_destructible(&w,false,settings)
        breakable_strain(&w,h,{0,3,0},100,10000)
        test_steps(&w,2)
        pieces:[16]Piece_Info
        count:=min(breakable_pieces(&w,h,pieces[:]),len(pieces))
        target:Piece_Info
        for piece in pieces[:count] {if piece.group!=0 {target=piece;break}}
        if !testing.expect(t,target.body!=0) {return}
        remaining,expires:=breakable_body_remaining_ticks(&w,h,target.body)
        mass:=breakable_mass(&w,h)
        snapshot:World;defer world_destroy(&snapshot)
        saved:=test_keep(&snapshot,&w);testing.expect(t,saved)
        pose:=body_transform(&w,target.body)
        event,cut:=breakable_slice_body(&w,h,target.id,xf_point(pose,target.center),{0,1,0})
        if !testing.expect(t,cut) {return}
        ticks,scheduled:=breakable_body_remaining_ticks(&w,h,target.body)
        testing.expect_value(t,scheduled,expires)
        testing.expect_value(t,ticks,remaining)
        test_steps(&w,2)
        testing.expect(t,body_valid(&w,target.body),"the retained half of a detached group stays alive")
        testing.expect_value(t,break_group_count(&w,h),5)
        testing.expect(t,abs(breakable_mass(&w,h)-mass)<0.01)
        final:=world_hash(&w)
        testing.expect(t,test_restore(&w,&snapshot))
        testing.expect(t,break_event_apply(&w,event))
        test_steps(&w,2)
        testing.expect_value(t,world_hash(&w),final)
        state:=make([]u8,breakable_state_size(&w,h));defer delete(state)
        testing.expect_value(t,breakable_state_write(&w,h,state),len(state))
        b:World;testing.expect(t,test_destruct_world(&b));defer world_destroy(&b)
        other,_:=test_authored_destructible(&b,false,settings)
        testing.expect(t,breakable_state_apply(&b,other,state))
        testing.expect_value(t,breakable_check(&b,other),breakable_check(&w,h))
        count=min(breakable_pieces(&b,other,pieces[:]),len(pieces))
        for piece in pieces[:count] {
            if piece.body==0 || piece.group!=target.group {continue}
            ticks,scheduled=breakable_body_remaining_ticks(&b,other,piece.body)
            testing.expect_value(t,scheduled,expires)
            testing.expect_value(t,ticks,expires?remaining-2:u32(0))
        }
        if expires {
            test_steps(&w,int(remaining)-2)
            testing.expect(t,body_valid(&w,target.body))
            world_step(&w,1.0/60)
            testing.expect(t,!body_valid(&w,target.body),"the cut keeps the original removal deadline")
        }
    }
}

@(test)
invalid_authored_cluster_membership_is_rejected_before_allocating_bodies :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    f:geom.Fracture;geom.fracture_init(&f);defer geom.fracture_destroy(&f)
    geom.mesh_fracture(&f,geom.mesh_buffer_view(&cube),([]Vec3{{}}))
    cluster:=[1]Cluster_Desc{{parent=0,strength=10}}
    membership:=[1]i32{0}
    settings:=BREAKABLE_DESC_DEFAULT;settings.fracture=&f;settings.clusters=cluster[:];settings.piece_clusters=membership[:]
    _,error:=breakable_create(&w,settings)
    testing.expect_value(t,error,Breakable_Error.Invalid_Desc)
    testing.expect_value(t,world_stats(&w).bodies,0)
}

@(test)
authored_piece_cluster_bond_and_hull_capacity_failures_leave_no_live_destructible :: proc(t:^testing.T) {
    for failure in 0..<4 {
        desc:=world_desc_default();desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=8,8,16,0
        desc.hull_capacity=8
        desc.breakable_capacity,desc.piece_capacity,desc.bond_capacity=1,8,8
        if failure==0 {desc.piece_capacity=3}
        if failure==1 {desc.bond_capacity=5}
        if failure==2 {desc.hull_capacity=3}
        if failure==3 {desc.shape_capacity=3}
        w:World;testing.expect(t,world_init(&w,desc))
        h,error:=test_authored_destructible(&w)
        testing.expect_value(t,error,Breakable_Error.Capacity)
        testing.expect_value(t,h,Breakable_Handle(0))
        testing.expect_value(t,w.body_count,i32(0));testing.expect_value(t,w.shape_count,i32(0))
        testing.expect_value(t,w.breakable_count,i32(0));testing.expect_value(t,w.piece_count,i32(0));testing.expect_value(t,w.bond_count,i32(0))
        world_destroy(&w)
    }
}

@(test)
a_strain_in_an_oriented_box_breaks_without_impulse :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0
    h,_:=test_authored_destructible(&w,false,settings)
    region:=Break_Region{point={0,3,0},half_extents={.2,3,.3},rotation=math.quat_axis_angle({0,0,1},PI*.5)}
    event,broke,strained:=breakable_strain_region(&w,h,-1,region,10000)
    testing.expect(t,broke && strained)
    testing.expect_value(t,event.vector,Vec3{})
    testing.expect_value(t,break_group_count(&w,h),4)
    pieces:[4]Piece_Info;breakable_pieces(&w,h,pieces[:])
    for piece in pieces {testing.expect_value(t,body_linear_velocity(&w,piece.body),Vec3{})}
}

@(test)
a_whole_cluster_collides_as_one_hull_with_the_mass_of_its_pieces_until_it_breaks :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0
    h,error:=test_authored_destructible(&w,true,settings)
    if !testing.expect_value(t,error,Breakable_Error.None) {return}
    pieces:[4]Piece_Info;breakable_pieces(&w,h,pieces[:])
    for piece in pieces {testing.expect(t,piece.shape==pieces[0].shape && piece.body==pieces[0].body && piece.shape!={})}
    testing.expect_value(t,world_stats(&w).shapes,1)
    body:=pieces[0].body
    testing.expectf(t,abs(body_mass(&w,body)-4*2000)<0.05,"the hull weighs %v, its pieces 8000",body_mass(&w,body))
    testing.expect(t,length(body_center(&w,body)-Vec3{0,3,0})<1e-4)
    // The hull fills the gaps between its pieces while the cluster stands.
    hit,_:=ray_cast_closest(&w,{0,5,0},{0,-4,0})
    testing.expect_value(t,hit.body,body)
    breakable_strain(&w,h,{0,3,0},100,1000)
    testing.expect_value(t,world_stats(&w).shapes,2)
    breakable_pieces(&w,h,pieces[:])
    testing.expect(t,pieces[0].shape==pieces[1].shape && pieces[2].shape==pieces[3].shape && pieces[0].shape!=pieces[2].shape)
    hit,_=ray_cast_closest(&w,{0,5,0},{0,-4,0})
    testing.expect_value(t,hit.body,Body_Handle{})
    moved:=Filter{layers=2,block=2}
    breakable_set_filter(&w,h,moved)
    testing.expect(t,shape_filter(&w,pieces[0].shape)==moved && shape_filter(&w,pieces[2].shape)==moved)
    breakable_strain_body(&w,h,pieces[0].id,{-1.1,3,0},100,1000)
    testing.expect_value(t,world_stats(&w).shapes,3)
    breakable_pieces(&w,h,pieces[:])
    testing.expect(t,pieces[0].shape!=pieces[1].shape && pieces[2].shape==pieces[3].shape)
    total:f32
    for piece,at in pieces {
        seen:=false
        for prior in pieces[:at] {seen||=prior.body==piece.body}
        if !seen {total+=body_mass(&w,piece.body)}
        testing.expect_value(t,shape_filter(&w,piece.shape),moved)
    }
    testing.expectf(t,abs(total-4*2000)<0.05,"the bodies weigh %v",total)
}

@(test)
an_impact_on_a_whole_cluster_names_one_of_its_pieces_and_breaks_it :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0;settings.damage_threshold=10;settings.damage_radius=3
    h,_:=test_authored_destructible(&w,true,settings)
    test_cannonball(&w,{0.55,6,0},{0,-30,0})
    found:=false
    for _ in 0..<30 {
        world_step(&w,1.0/60)
        for event in world_events(&w).breaks {
            pieces:[4]Piece_Info
            count:=breakable_pieces(&w,h,pieces[:])
            named:=false
            for piece in pieces[:count] {named||=piece.id==event.piece}
            testing.expect(t,event.kind==.Impact && named)
            found=true
        }
        if found {break}
    }
    testing.expect(t,found)
    testing.expect(t,breakable_revision(&w,h)>0 && break_group_count(&w,h)>1)
}

@(test)
a_cut_without_hulls_for_its_halves_is_refused_and_says_so :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w,512,5));defer world_destroy(&w)
    settings:=BREAKABLE_DESC_DEFAULT;settings.gravity_scale=0
    h,error:=test_authored_destructible(&w,false,settings)
    if !testing.expect_value(t,error,Breakable_Error.None) {return}
    _,cut:=breakable_slice(&w,h,{0.6,3,0},{1,0,0})
    testing.expect(t,!cut,"a cut without hulls for its halves does not happen")
    testing.expect_value(t,breakable_pieces(&w,h,nil),4)
    testing.expect_value(t,break_group_count(&w,h),1)
    _,refused:=breakable_shortfall(&w,h)
    testing.expect_value(t,refused,Break_Capacities{.Hulls})
    world_step(&w,1.0/60)
    _,refused=breakable_shortfall(&w,h)
    testing.expect_value(t,refused,Break_Capacities{})
}

@(test)
a_strain_weighs_as_a_volume_does_whole_inside_and_rising_over_its_blend :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    h:=test_wall(&w)
    bonds:=make([]Bond_Info,breakable_bonds(&w,h,nil));defer delete(bonds)
    // A sphere around the middle of the wall, and a box turned a quarter that crosses it.
    Case :: struct {region:Break_Region,name:string}
    turn:=math.quat_axis_angle({0,0,1},PI*.5)
    for c in ([]Case{
        {{point={0,1,0},radius=1.5},"a sphere without blend"},{{point={0,1,0},radius=1.5,blend=1},"a sphere with blend"},
        {{point={0,1,0},radius=1.5,blend=1.5},"a sphere that blends to its center"},
        {{point={0,1,0},half_extents={1.5,1.2,1},rotation=turn},"a box without blend"},{{point={0,1,0},half_extents={1.5,1.2,1},rotation=turn,blend=.5},"a box with blend"},
    }) {
        region:=c.region
        breakable_bonds(&w,h,bonds)
        before:=make([]f32,len(bonds));defer delete(before)
        for bond,at in bonds {before[at]=bond.strain}
        event,_,strained:=breakable_strain_region(&w,h,-1,region,1,weaken=true)
        testing.expectf(t,strained && event.region==region,"%s strains nothing",c.name)
        breakable_bonds(&w,h,bonds)
        pieces:[64]Piece_Info
        count:=min(breakable_pieces(&w,h,pieces[:]),len(pieces))
        whole,partial:=0,0
        for bond,at in bonds {
            center:Vec3
            for piece in pieces[:count] {
                if piece.id==bond.a || piece.id==bond.b {center+=0.5*(piece.center+Vec3{0,1,0})}
            }
            expected:=break_region_weight(&region,center)
            testing.expectf(t,abs(bond.strain-before[at]-expected)<1e-4,"%s: a bond at %v took %v, not %v",c.name,center,bond.strain-before[at],expected)
            whole+=int(expected==1)
            partial+=int(expected>0 && expected<1)
        }
        testing.expectf(t,whole>0 || region.blend>=region.radius && region.radius>0,"%s holds no bond whole",c.name)
        testing.expectf(t,(partial>0)==(region.blend>0),"%s: %d bonds in its blend",c.name,partial)
    }
    nan:=transmute(f32)u32(0x7fc00000)
    for blend in ([]f32{-1,nan}) {
        _,_,strained:=breakable_strain_region(&w,h,-1,{point={0,1,0},radius=3,blend=blend},1,weaken=true)
        testing.expect(t,!strained)
    }
}
