package mirai_physics

import "core:mem"
import "core:testing"
import "mirai:std/geom"
import math "mirai:std/math"

@(test)
pieces_name_their_group_and_origin_and_the_revision_counts_changes :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall:=test_wall(&w)
    testing.expect_value(t,breakable_revision(&w,wall),u32(0))
    pieces:[64]Piece_Info
    count:=breakable_pieces(&w,wall,pieces[:])
    for piece,at in pieces[:count] {
        testing.expect(t,piece.group==0 && piece.parent==-1 && piece.source==i32(at))
    }
    check:=breakable_check(&w,wall)
    _,broke:=breakable_damage(&w,wall,{0.3,1.5,0.2},1.5,{0,0,-9000})
    testing.expect(t,broke)
    revision:=breakable_revision(&w,wall)
    testing.expect(t,revision>0 && breakable_check(&w,wall)!=check)
    // Every piece of a body carries the id of that body, and the one of the first body is zero.
    base:=breakable_body(&w,wall)
    count=breakable_pieces(&w,wall,pieces[:])
    left:=0
    for piece in pieces[:count] {
        testing.expect_value(t,piece.group==0,piece.body==base)
        testing.expect(t,piece.group<=revision)
        left+=int(piece.group!=0)
        for other in pieces[:count] {testing.expect_value(t,piece.group==other.group,piece.body==other.body)}
    }
    testing.expect(t,left>0)

    // The halves of a cut name the piece they come from and the plane, in the frame of the body.
    _,cut:=breakable_slice(&w,wall,{0.9,1,0},{1,0,0})
    testing.expect(t,cut && breakable_revision(&w,wall)>revision)
    cut_count:=breakable_pieces(&w,wall,pieces[:])
    testing.expect(t,cut_count>count && (cut_count-count)%2==0)
    for at:=count;at<cut_count;at+=2 {
        front,back:=pieces[at],pieces[at+1]
        testing.expect(t,front.front && !back.front && front.parent==back.parent && front.source==-1)
        testing.expect_value(t,front.cut_normal,Vec3{1,0,0})
        testing.expect(t,abs(front.cut_offset-0.9)<1e-5)
        testing.expect(t,front.center.x>0.9 && back.center.x<0.9)
        parent:Piece_Info
        for piece in pieces[:count] {
            if piece.id==front.parent {parent=piece}
        }
        testing.expect(t,.Gone in parent.flags && abs(parent.volume-front.volume-back.volume)<1e-4)
    }
}

@(test)
a_destructible_made_from_a_fracture_equals_one_that_fractures_the_mesh :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_destruct_world(&a) && test_destruct_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    size:=Vec3{4,2,0.4}
    mesh:geom.Mesh_Buffer
    geom.mesh_buffer_init(&mesh)
    defer geom.mesh_buffer_destroy(&mesh)
    geom.cube_build(&mesh,size)
    sites:[24]Vec3
    geom.sites_generate(sites[:],{pattern=.Uniform,seed=7,lo=-0.5*size,hi=0.5*size})
    fracture:geom.Fracture
    geom.fracture_init(&fracture)
    defer geom.fracture_destroy(&fracture)
    testing.expect_value(t,geom.mesh_fracture(&fracture,geom.mesh_buffer_view(&mesh),sites[:],{interior_material=1}),geom.Fracture_Error.None)
    desc:=BREAKABLE_DESC_DEFAULT
    desc.position={0,1,0}
    desc.fracture=&fracture
    made,error:=breakable_create(&a,desc)
    testing.expect_value(t,error,Breakable_Error.None)
    desc.fracture=nil
    _,error=breakable_create(&b,desc)
    testing.expect_value(t,error,Breakable_Error.Invalid_Desc)
    desc.mesh,desc.sites=geom.mesh_buffer_view(&mesh),sites[:]
    other,_:=breakable_create(&b,desc)
    testing.expect_value(t,made,other)
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    testing.expect_value(t,breakable_pieces(&a,made,nil),len(fracture.pieces))
}

@(test)
a_written_state_makes_an_intact_destructible_what_the_other_became :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_destruct_world(&a) && test_destruct_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    walls:[2]Breakable_Handle
    for w,i in ([2]^World{&a,&b}) {
        test_ground(w)
        walls[i]=test_wall(w)
    }
    buffer:[64<<10]u8
    // An intact one writes itself and applies to its equal without changing it.
    size:=breakable_state_write(&a,walls[0],buffer[:])
    testing.expect(t,size>0 && size==breakable_state_size(&a,walls[0]))
    testing.expect(t,breakable_state_apply(&b,walls[1],buffer[:size]))
    testing.expect(t,breakable_revision(&b,walls[1])==0 && breakable_check(&a,walls[0])==breakable_check(&b,walls[1]))

    _,broke:=breakable_damage(&a,walls[0],{0.3,1.5,0.2},0.8,{0,0,-200})
    _,cut:=breakable_slice(&a,walls[0],{-0.9,1,0},{1,0.2,0})
    _,strained:=breakable_damage(&a,walls[0],{-1.5,0.4,0.2},0.6,{0,0,-1})
    testing.expect(t,broke,"the first damage breaks")
    testing.expect(t,cut,"the plane cuts")
    testing.expect(t,!strained,"the weak damage only strains")
    test_steps(&a,30)
    size=breakable_state_write(&a,walls[0],buffer[:])
    testing.expect_value(t,size,breakable_state_size(&a,walls[0]))
    testing.expect_value(t,breakable_state_write(&a,walls[0],buffer[:size-1]),0)
    // A broken one takes back, in place, what it wrote of itself with its debris: it stays as it is.
    own:[64<<10]u8
    own_size:=breakable_state_write(&a,walls[0],own[:],true)
    check:=breakable_check(&a,walls[0])
    testing.expect(t,breakable_state_apply(&a,walls[0],own[:own_size]),"a broken breakable takes its own state")
    testing.expect_value(t,breakable_check(&a,walls[0]),check)
    testing.expect(t,!breakable_state_apply(&b,walls[1],buffer[:size-8]))
    testing.expect(t,breakable_state_apply(&b,walls[1],buffer[:size]))

    testing.expect_value(t,breakable_check(&b,walls[1]),breakable_check(&a,walls[0]))
    testing.expect_value(t,breakable_revision(&b,walls[1]),breakable_revision(&a,walls[0]))
    debris:f32
    testing.expect(t,test_graph_is_consistent(t,&b,walls[1]))
    pa,pb:[128]Piece_Info
    count:=breakable_pieces(&a,walls[0],pa[:])
    testing.expect_value(t,breakable_pieces(&b,walls[1],pb[:]),count)
    bodies:[2]int
    for at in 0..<count {
        x,y:=pa[at],pb[at]
        if .Debris in x.flags {
            // Debris is of each world: the copy does not get it.
            testing.expect(t,.Gone in y.flags && y.body=={})
            if .Gone not_in x.flags {debris+=x.volume}
            continue
        }
        testing.expect(t,x.group==y.group && x.flags==y.flags && x.front==y.front && (x.body=={})==(y.body=={}))
        testing.expectf(t,abs(x.volume-y.volume)<1e-6 && length(x.center-y.center)<1e-6,"piece %v: %v and %v",at,x.volume,y.volume)
        for earlier in 0..<at {
            if .Debris not_in pa[earlier].flags {testing.expect_value(t,pb[earlier].body==y.body,pa[earlier].body==x.body)}
        }
        bodies[0]+=int(x.body!={} && body_mass(&a,x.body)>0)
        bodies[1]+=int(y.body!={} && body_mass(&b,y.body)>0)
        if x.body!={} && body_type(&a,x.body)==.Dynamic {
            testing.expect(t,body_type(&b,y.body)==.Dynamic && abs(body_mass(&a,x.body)-body_mass(&b,y.body))<0.01)
        }
    }
    testing.expect_value(t,bodies[1],bodies[0])
    testing.expect(t,abs(breakable_mass(&b,walls[1])-(breakable_mass(&a,walls[0])-debris*2000))<0.01)
    ca,cb:[512]Bond_Info
    connections:=breakable_bonds(&a,walls[0],ca[:])
    testing.expect_value(t,breakable_bonds(&b,walls[1],cb[:]),connections)
    for at in 0..<connections {
        testing.expect(t,ca[at].broken==cb[at].broken && ca[at].strain==cb[at].strain && ca[at].area==cb[at].area)
    }
    // The groups of the copy are still where the breakable is: they fall like the others did.
    test_steps(&b,30)
    // From here on the same damage breaks the same on both, and names the new groups the same.
    event,again:=breakable_damage(&a,walls[0],{-1.5,0.4,0.2},0.8,{0,0,-4000})
    testing.expect(t,again && break_event_apply(&b,event))
    testing.expect_value(t,breakable_check(&b,walls[1]),breakable_check(&a,walls[0]))
}

@(test)
an_event_limited_to_a_body_breaks_the_same_wherever_the_other_bodies_are :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_destruct_world(&a) && test_destruct_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    crates:[2]Breakable_Handle
    for w,i in ([2]^World{&a,&b}) {
        world_set_gravity(w,{})
        crates[i],_=test_destructible(w,{2,1,1},{0,3,0},12,false)
        // Two halves that drift apart; in the second world the other way, and turning.
        _,cut:=breakable_slice(w,crates[i],{0,3,0},{1,0,0})
        testing.expect(t,cut)
    }
    pa,pb:[64]Piece_Info
    count:=breakable_pieces(&a,crates[0],pa[:])
    testing.expect_value(t,breakable_pieces(&b,crates[1],pb[:]),count)
    front:i32=-1
    for piece in pa[:count] {
        if piece.body!={} && piece.center.x>0.2 && front<0 {front=piece.id}
    }
    if !testing.expect(t,front>=0) {return}
    // The half the event is about is in the same place in both worlds; the other one is not.
    for piece,at in pa[:count] {
        if piece.body=={} {continue}
        other:=pb[at].body
        hit:=false
        for same in pa[:count] {hit||=same.id==front && same.body==piece.body}
        if !hit {body_set_transform(&b,other,{-0.4,3.3,0.2},Quat(quaternion(w=0.9238795,x=0,y=0.3826834,z=0)))}
    }
    check:=breakable_check(&a,crates[0])
    testing.expect_value(t,breakable_check(&b,crates[1]),check)
    // What is not a piece in the world is refused, and a point out of reach strains nothing.
    _,_,strained:=breakable_damage_body(&a,crates[0],-1,{0.5,3,0},0.6,{0,300,0})
    testing.expect(t,!strained)
    _,_,strained=breakable_damage_body(&a,crates[0],front,{9,9,9},0.6,{0,300,0})
    testing.expect(t,!strained)
    event,broke,reached:=breakable_damage_body(&a,crates[0],front,{0.55,3,0},0.7,{0,4000,0})
    testing.expect(t,broke && reached && event.piece==front)
    testing.expect(t,breakable_check(&a,crates[0])!=check)
    testing.expect(t,break_event_apply(&b,event))
    testing.expect_value(t,breakable_check(&b,crates[1]),breakable_check(&a,crates[0]))
    // The other half took nothing: all its bonds are as they were.
    ca,cb:[512]Bond_Info
    connections:=breakable_bonds(&a,crates[0],ca[:])
    breakable_bonds(&b,crates[1],cb[:])
    for at in 0..<connections {testing.expect(t,ca[at].broken==cb[at].broken && ca[at].strain==cb[at].strain)}
    // A cut limited to a body leaves the others whole.
    count=breakable_pieces(&a,crates[0],pa[:])
    back:i32=-1
    for piece in pa[:count] {
        if piece.body!={} && piece.center.x< -0.2 && back<0 {back=piece.id}
    }
    _,sliced:=breakable_slice_body(&a,crates[0],back,{0,3,0},{0,1,0})
    testing.expect(t,sliced)
    after:=breakable_pieces(&a,crates[0],pb[:])
    for piece in pb[count:after] {testing.expect(t,piece.center.x<1e-3,"only the half the cut names was cut")}
}

// What a recording of a breakable keeps at a change: its state with its debris, and its poses.
@(private="file")
Recorded :: struct {
    state:[dynamic]u8,
    poses:[64]Breakable_Pose,
    count:int,
}

@(private="file")
record :: proc(w:^World,h:Breakable_Handle,r:^Recorded) {
    resize(&r.state,breakable_state_size(w,h))
    breakable_state_write(w,h,r.state[:],true)
    r.count=breakable_poses(w,h,r.poses[:])
}

// A wall of 64 pieces anchored by its base whose single pieces come off as debris that lasts 20 steps.
@(private="file")
test_debris_wall :: proc(w:^World) -> (Breakable_Handle,Breakable_Error) {
    desc:=BREAKABLE_DESC_DEFAULT
    desc.debris_volume,desc.debris_ticks=0.08,20
    return test_destructible(w,{4,2,0.4},{0,1,0},64,true,desc)
}

@(test)
a_broken_breakable_takes_back_each_recorded_state_in_place_and_without_allocating :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall,error:=test_debris_wall(&w)
    if !testing.expect_value(t,error,Breakable_Error.None) {return}
    stages:[4]Recorded
    defer for &stage in stages {delete(stage.state)}
    versions:[4]u32
    record(&w,wall,&stages[0])
    versions[0]=breakable_state_version(&w,wall)
    _,broke:=breakable_damage(&w,wall,{0.3,1.5,0.2},1.2,{0,0,-6000})
    testing.expect(t,broke)
    test_steps(&w,10)
    record(&w,wall,&stages[1])
    versions[1]=breakable_state_version(&w,wall)
    pieces:[256]Piece_Info
    count:=breakable_pieces(&w,wall,pieces[:])
    debris,chunks:=0,0
    for piece in pieces[:count] {
        if piece.body=={} || piece.group==0 {continue}
        if .Debris in piece.flags {debris+=1} else {chunks+=1}
    }
    testing.expect(t,debris>0 && chunks>0,"the damage throws debris and chunks")
    _,cut:=breakable_slice(&w,wall,{-0.9,1,0},{1,0.2,0})
    testing.expect(t,cut)
    test_steps(&w,5)
    record(&w,wall,&stages[2])
    versions[2]=breakable_state_version(&w,wall)
    test_steps(&w,30)
    record(&w,wall,&stages[3])
    versions[3]=breakable_state_version(&w,wall)
    testing.expect(t,versions[0]<versions[1] && versions[1]<versions[2] && versions[2]<versions[3],"every change counts, the expiring debris too")
    count=breakable_pieces(&w,wall,pieces[:])
    for piece in pieces[:count] {
        if .Debris in piece.flags {testing.expect(t,.Gone in piece.flags,"the debris expired")}
    }
    // Back through every change, then forward again through the cut. What it writes then is what was
    // recorded; the bodies of the groups both had stay; and going back allocates nothing.
    written:=make([]u8,64<<10)
    defer delete(written)
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,w.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    backing:=w.allocator
    for stage,step in ([5]int{3,2,1,0,2}) {
        r:=&stages[stage]
        before:[256]Piece_Info
        had:=breakable_pieces(&w,wall,before[:])
        version:=breakable_state_version(&w,wall)
        backward:=step<4
        if backward {
            w.allocator=mem.tracking_allocator(&tracker)
            context.allocator=w.allocator
        }
        applied:=breakable_state_apply(&w,wall,r.state[:])
        placed:=breakable_poses_apply(&w,wall,r.poses[:r.count],true)
        if backward {
            w.allocator=backing
            context.allocator=backing
        }
        if !testing.expectf(t,applied && placed,"stage %v applies",stage) {return}
        testing.expectf(t,tracker.total_allocation_count==0,"going back to stage %v allocates nothing",stage)
        testing.expect(t,breakable_state_version(&w,wall)!=version)
        size:=breakable_state_write(&w,wall,written,true)
        testing.expectf(t,size==len(r.state) && mem.compare(written[:size],r.state[:])==0,"stage %v writes what was recorded",stage)
        testing.expect(t,test_graph_is_consistent(t,&w,wall))
        count=breakable_pieces(&w,wall,pieces[:])
        for piece in pieces[:count] {
            if piece.body=={} {continue}
            testing.expect_value(t,body_is_debris(&w,piece.body),.Debris in piece.flags)
            for prior in before[:had] {
                if prior.body!={} && prior.group==piece.group {testing.expectf(t,prior.body==piece.body,"group %v keeps its body",piece.group)}
            }
        }
        poses:[64]Breakable_Pose
        testing.expect_value(t,breakable_poses(&w,wall,poses[:]),r.count)
        for pose,at in poses[:r.count] {
            want:=r.poses[at]
            testing.expect(t,pose.group==want.group && pose.remaining==want.remaining && pose.linear=={} && pose.angular=={})
            testing.expectf(t,length(pose.position-want.position)<1e-5 && math.quat_angle(pose.rotation,want.rotation)<1e-3,"group %v is where it was",want.group)
        }
    }
    // As created, again: one body, the revision of an intact one.
    testing.expect(t,breakable_state_apply(&w,wall,stages[0].state[:]))
    count=breakable_pieces(&w,wall,pieces[:])
    for piece in pieces[:count] {testing.expect(t,piece.body==breakable_body(&w,wall) && piece.group==0)}
    testing.expect_value(t,breakable_revision(&w,wall),u32(0))
}

@(test)
a_held_breakable_does_not_fall_break_or_expire_and_goes_on_from_its_poses_when_let_go :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall,error:=test_debris_wall(&w)
    if !testing.expect_value(t,error,Breakable_Error.None) {return}
    crate,_:=test_destructible(&w,{1,1,1},{6,3,0},8,false)
    mass:=body_mass(&w,breakable_body(&w,crate))
    _,broke:=breakable_damage(&w,wall,{0.3,1.5,0.2},1.2,{0,0,-6000})
    testing.expect(t,broke)
    test_steps(&w,3)
    poses:[64]Breakable_Pose
    count:=breakable_pieces(&w,wall,nil)
    n:=breakable_poses(&w,wall,poses[:])
    revision,version:=breakable_revision(&w,wall),breakable_state_version(&w,wall)
    root:=breakable_body(&w,wall)
    testing.expect(t,breakable_poses_apply(&w,wall,poses[:n],true) && breakable_poses_apply(&w,crate,nil,true))
    pieces:[256]Piece_Info
    for piece in pieces[:breakable_pieces(&w,wall,pieces[:])] {
        if piece.body!={} {testing.expect_value(t,body_type(&w,piece.body),piece.body==root?Body_Type.Static:.Kinematic)}
    }
    testing.expect_value(t,body_type(&w,breakable_body(&w,crate)),Body_Type.Kinematic)
    // A copy keeps it held.
    kept:World
    defer world_destroy(&kept)
    testing.expect(t,test_keep(&kept,&w))
    // A ball through what is held breaks nothing, and longer than the debris lasts nothing expires.
    test_cannonball(&w,{0,1,3},{0,0,-30})
    test_steps(&w,40)
    testing.expect(t,breakable_revision(&w,wall)==revision && breakable_state_version(&w,wall)==version)
    held:[64]Breakable_Pose
    testing.expect_value(t,breakable_poses(&w,wall,held[:]),n)
    for pose,at in held[:n] {testing.expect(t,length(pose.position-poses[at].position)<1e-5,"what is held stays")}
    _,restored:=world_state_copy(&w,&kept)
    testing.expect(t,restored && body_type(&w,breakable_body(&w,crate))==.Kinematic)
    // Let go: dynamic again with the velocities of the poses, and debris told to expire in 2 steps does.
    for &pose in poses[1:n] {pose.linear,pose.remaining={0,5,0},2}
    testing.expect(t,breakable_poses_apply(&w,wall,poses[:n],false) && breakable_poses_apply(&w,crate,nil,false))
    testing.expect(t,body_type(&w,breakable_body(&w,crate))==.Dynamic && abs(body_mass(&w,breakable_body(&w,crate))-mass)<1e-3)
    for piece in pieces[:breakable_pieces(&w,wall,pieces[:])] {
        if piece.body=={} || piece.body==root {continue}
        testing.expect(t,body_type(&w,piece.body)==.Dynamic && body_mass(&w,piece.body)>0)
        testing.expectf(t,length(body_linear_velocity(&w,piece.body)-Vec3{0,5,0})<1e-4,"group %v leaves with the velocity of its pose",piece.group)
    }
    test_steps(&w,3)
    gone,stays:=0,0
    for piece in pieces[:breakable_pieces(&w,wall,pieces[:])] {
        if piece.group==0 {continue}
        if .Debris in piece.flags {gone+=int(.Gone in piece.flags)} else {stays+=int(piece.body!={})}
    }
    testing.expect(t,gone>0 && stays>0,"the debris expired and the chunks, that never expire, stay")
    testing.expect(t,count>0)
}

@(test)
the_poses_between_two_recorded_lists_move_the_groups_both_have :: proc(t:^testing.T) {
    turn:=Quat(quaternion(w=0.7071068,x=0,y=0.7071068,z=0))
    from:=[3]Breakable_Pose{{group=0,rotation=QUAT_IDENTITY},{group=4,position={0,2,0},linear={2,0,0},rotation=QUAT_IDENTITY,remaining=10},{group=7,position={9,9,9},remaining=max(u32)}}
    to:=[2]Breakable_Pose{{group=0,rotation=QUAT_IDENTITY},{group=4,position={2,2,0},rotation=turn,remaining=6}}
    out:[4]Breakable_Pose
    testing.expect_value(t,breakable_poses_blend(from[:],to[:],0.5,out[:]),3)
    testing.expect(t,out[1].group==4 && length(out[1].position-Vec3{1,2,0})<1e-6 && out[1].linear=={1,0,0} && out[1].remaining==8)
    testing.expect(t,math.quat_angle(out[1].rotation,math.quat_slerp(QUAT_IDENTITY,turn,0.5))<1e-3)
    testing.expect(t,out[2].group==7 && out[2].position=={9,9,9},"a group of only one list is where that one says")
    // t past an end, or not a number, is that end; a short out still counts every pose.
    nan:=transmute(f32)u32(0x7fc00000)
    for value,at in ([3]f32{-3,nan,7}) {
        testing.expect_value(t,breakable_poses_blend(from[:],to[:],value,out[:1]),3)
        if !testing.expect_value(t,breakable_poses_blend(from[:],to[:],value,out[:]),3) {continue}
        testing.expect_value(t,out[1].position,at<2?Vec3{0,2,0}:Vec3{2,2,0})
    }
}

@(test)
poses_and_states_that_are_not_of_the_breakable_change_nothing :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall,_:=test_debris_wall(&w)
    other:=test_wall(&w,16)
    _,broke:=breakable_damage(&w,wall,{0.3,1.5,0.2},1.2,{0,0,-6000})
    testing.expect(t,broke)
    test_steps(&w,3)
    poses:[64]Breakable_Pose
    n:=breakable_poses(&w,wall,poses[:])
    hash:=world_hash(&w)
    nan:=transmute(f32)u32(0x7fc00000)
    for field in 0..<4 {
        hostile:=poses
        switch field {
        case 0: hostile[n-1].position.y=nan
        case 1: hostile[n-1].rotation.x=nan
        case 2: hostile[n-1].linear.z=nan
        case 3: hostile[n-1].angular.x=transmute(f32)u32(0x7f800000)
        }
        testing.expect(t,!breakable_poses_apply(&w,wall,hostile[:n],true))
    }
    testing.expect_value(t,world_hash(&w),hash)
    // A state cut short, of another breakable, or with flags no piece has, is refused before anything changes.
    state:[64<<10]u8
    size:=breakable_state_write(&w,wall,state[:],true)
    alien:[64<<10]u8
    alien_size:=breakable_state_write(&w,other,alien[:],true)
    bad:=state
    (^Break_State_Piece)(&bad[size_of(Break_State_Header)])^.flags+=transmute(Piece_Flags)u32(1<<12)
    for refused in ([][]u8{state[:size-1],state[:3],alien[:alien_size],bad[:size]}) {testing.expect(t,!breakable_state_apply(&w,wall,refused))}
    testing.expect_value(t,world_hash(&w),hash)
}
