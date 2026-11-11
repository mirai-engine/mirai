package mirai_physics

import "core:testing"
import "mirai:std/geom"

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
    testing.expect(t,!breakable_state_apply(&a,walls[0],buffer[:size]),"only a breakable that is as created takes a state")
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
