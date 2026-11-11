package mirai_physics

import "core:testing"
import math "mirai:std/math"
import "mirai:std/geom"

@(private)
test_destruct_world :: proc(w:^World,pieces:=512,hulls:=256) -> bool {
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=256,512,4096,16
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=hulls,4,2,256
    desc.character_capacity=4
    desc.breakable_capacity,desc.piece_capacity,desc.bond_capacity=8,pieces,4096
    return world_init(w,desc)
}

// A box of `size` centered at `position`, fractured at `count` sites; the pieces that reach its bottom
// 5 cm are anchors when `anchored`.
@(private)
test_destructible :: proc(w:^World,size,position:Vec3,count:int,anchored:bool,desc:=Breakable_Desc{}) -> (Breakable_Handle,Breakable_Error) {
    d:=desc
    if d.density==0 {d=BREAKABLE_DESC_DEFAULT}
    mesh:geom.Mesh_Buffer
    geom.mesh_buffer_init(&mesh)
    defer geom.mesh_buffer_destroy(&mesh)
    geom.cube_build(&mesh,size)
    sites:=make([]Vec3,count)
    defer delete(sites)
    if count==1 {
        sites[0]={}
    } else {
        geom.sites_generate(sites,{pattern=.Uniform,seed=7,lo=-0.5*size,hi=0.5*size})
    }
    half:=0.5*size
    anchors:=[1]Aabb{{{-half.x-0.1,-half.y-0.1,-half.z-0.1},{half.x+0.1,-half.y+0.05,half.z+0.1}}}
    d.mesh,d.sites,d.position=geom.mesh_buffer_view(&mesh),sites,position
    if anchored {d.anchors=anchors[:]}
    return breakable_create(w,d)
}

@(private)
test_wall :: proc(w:^World,count:=24) -> Breakable_Handle {
    desc:=BREAKABLE_DESC_DEFAULT
    h,_:=test_destructible(w,{4,2,0.4},{0,1,0},count,true,desc)
    return h
}

@(private)
test_cannonball :: proc(w:^World,position,velocity:Vec3,radius:f32=0.25) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.position,desc.linear_velocity,desc.bullet=position,velocity,true
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Sphere{radius}
    shape_create(w,body,shape)
    return body
}

// Every unbroken bond joins two pieces of one body; every dynamic body of the breakable is one
// connected group; every group left in a static body has an anchor.
@(private)
test_graph_is_consistent :: proc(t:^testing.T,w:^World,h:Breakable_Handle) -> bool {
    pieces:=make([]Piece_Info,breakable_pieces(w,h,nil))
    connections:=make([]Bond_Info,breakable_bonds(w,h,nil))
    parent:=make([]i32,len(w.pieces))
    anchored:=make([]bool,len(w.pieces))
    defer {
        delete(pieces)
        delete(connections)
        delete(parent)
        delete(anchored)
    }
    breakable_pieces(w,h,pieces)
    breakable_bonds(w,h,connections)
    for &p,i in parent {p=i32(i)}
    body_of :: proc(pieces:[]Piece_Info,id:i32) -> Body_Handle {
        for piece in pieces {
            if piece.id==id {return piece.body}
        }
        return {}
    }
    for c in connections {
        if c.broken {continue}
        if body_of(pieces,c.a)=={} || body_of(pieces,c.a)!=body_of(pieces,c.b) {return false}
        union_join(parent,c.a,c.b)
    }
    for piece in pieces {
        if .Anchor in piece.flags {anchored[union_find(parent,piece.id)]=true}
    }
    for a in pieces {
        if a.body=={} {continue}
        root:=union_find(parent,a.id)
        if body_type(w,a.body)==.Static {
            if !anchored[root] {return false}
            continue
        }
        for b in pieces {
            if b.body==a.body && union_find(parent,b.id)!=root {return false}
        }
    }
    return true
}

@(test)
an_anchored_wall_hit_by_a_fast_sphere_loses_pieces_and_keeps_its_mass :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall:=test_wall(&w)
    testing.expect(t,breakable_valid(&w,wall))
    root:=breakable_body(&w,wall)
    testing.expect_value(t,body_type(&w,root),Body_Type.Static)
    pieces:[64]Piece_Info
    count:=breakable_pieces(&w,wall,pieces[:])
    testing.expect(t,count>=20 && count<=24)
    testing.expect_value(t,world_stats(&w).pieces,count)
    volume:f32
    anchors:=0
    for piece in pieces[:count] {
        volume+=piece.volume
        if .Anchor in piece.flags {anchors+=1}
        testing.expect_value(t,piece.body,root)
    }
    testing.expectf(t,abs(volume-3.2)<0.01,"volume of the pieces %v",volume)
    testing.expect(t,anchors>0 && anchors<count)
    mass:=breakable_mass(&w,wall)
    testing.expect(t,abs(mass-2000*volume)<1)
    testing.expect(t,breakable_bonds(&w,wall,nil)>count)
    test_steps(&w,10)
    testing.expect_value(t,len(world_events(&w).breaks),0)

    ball:=test_cannonball(&w,{0,1.2,3},{0,0,-30})
    events:=0
    thrown:f32
    for _ in 0..<20 {
        world_step(&w,1.0/60)
        for event in world_events(&w).breaks {
            testing.expect(t,event.breakable==wall && event.kind==.Impact && event.piece>=0 && event.radius==0)
            if events==0 {
                // The ball: into the wall, on its front face. What it frees leaves with its impulse.
                testing.expect(t,event.vector.z<-1000 && abs(event.point.z-0.2)<0.05 && u64(event.tick)+1==world_tick(&w) && event.piece>=0)
                breakable_pieces(&w,wall,pieces[:])
                for piece in pieces[:count] {
                    if piece.body!=root {thrown=min(thrown,body_linear_velocity(&w,piece.body).z)}
                }
            }
            events+=1
        }
    }
    testing.expect(t,events>0)
    testing.expect(t,test_graph_is_consistent(t,&w,wall))
    breakable_pieces(&w,wall,pieces[:])
    loose:=0
    counted:[64]Body_Handle
    bodies:=0
    total:f32
    for piece in pieces[:count] {
        if piece.body==root {
            total+=2000*piece.volume
            continue
        }
        loose+=1
        testing.expect_value(t,body_type(&w,piece.body),Body_Type.Dynamic)
        seen:=false
        for body in counted[:bodies] {seen||=body==piece.body}
        if seen {continue}
        counted[bodies]=piece.body
        bodies+=1
        total+=body_mass(&w,piece.body)
    }
    testing.expectf(t,loose>0 && loose<count,"%v of %v pieces came off",loose,count)
    testing.expectf(t,abs(total-mass)<1e-3*mass,"mass %v became %v",mass,total)
    testing.expect(t,abs(breakable_mass(&w,wall)-mass)<1e-3*mass)
    testing.expectf(t,thrown<-0.5,"the pieces left at %v",thrown)
    testing.expect(t,body_linear_velocity(&w,ball).z>-30)
    testing.expect_value(t,world_stats(&w).breakable_capacity_exhausted,0)
}

@(test)
disabling_impact_damage_preserves_collision_manual_damage_and_snapshot_replay :: proc(t:^testing.T) {
    w:World
    if !testing.expect(t,test_destruct_world(&w)) {return}
    defer world_destroy(&w)
    test_ground(&w)
    desc:=BREAKABLE_DESC_DEFAULT;desc.impact_damage=false
    wall,error:=test_destructible(&w,{4,2,.4},{0,1,0},24,true,desc)
    if !testing.expect_value(t,error,Breakable_Error.None) {return}
    ball:=test_cannonball(&w,{0,1.2,3},{0,0,-30})
    snapshot:World;defer world_destroy(&snapshot)
    saved:=test_keep(&snapshot,&w)
    if !testing.expect(t,saved) {return}
    for _ in 0..<20 {
        world_step(&w,1.0/60)
        testing.expect_value(t,len(world_events(&w).breaks),0)
    }
    testing.expect(t,body_linear_velocity(&w,ball).z>-30)
    connections:[256]Bond_Info
    count:=breakable_bonds(&w,wall,connections[:])
    for bond in connections[:count] {testing.expect(t,!bond.broken && bond.strain==0)}
    intact:=world_hash(&w)
    testing.expect(t,test_restore(&w,&snapshot))
    test_steps(&w,20)
    testing.expect_value(t,world_hash(&w),intact)
    event,broke:=breakable_strain(&w,wall,{0,1,0},4,10000)
    testing.expect(t,broke && event.kind==.Damage && event.vector=={})
    testing.expect(t,breakable_revision(&w,wall)>0 && test_graph_is_consistent(t,&w,wall))
}

@(test)
a_slow_touch_under_the_damage_threshold_leaves_the_wall_intact :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall:=test_wall(&w)
    test_cannonball(&w,{0,1.2,0.6},{0,0,-0.5})
    for _ in 0..<60 {
        world_step(&w,1.0/60)
        testing.expect_value(t,len(world_events(&w).breaks),0)
    }
    connections:[256]Bond_Info
    count:=breakable_bonds(&w,wall,connections[:])
    for c in connections[:count] {testing.expect(t,!c.broken && c.strain==0 && c.area>0)}
}

@(test)
pieces_left_without_support_fall :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    // A beam that sticks out sideways from its anchored end, three meters over the ground.
    desc:=BREAKABLE_DESC_DEFAULT
    desc.strength,desc.rotation=10,math.quat_axis_angle({0,0,1},-0.5*PI)
    pillar,error:=test_destructible(&w,{0.5,3,0.5},{0,3,0},14,true,desc)
    testing.expect_value(t,error,Breakable_Error.None)
    root:=breakable_body(&w,pillar)
    event,broke:=breakable_damage(&w,pillar,{-1,3,0},0.5,{0,-60,0})
    testing.expect(t,broke && event.kind==.Damage && u64(event.tick)==world_tick(&w) && event.piece==-1)
    testing.expect(t,test_graph_is_consistent(t,&w,pillar))
    pieces:[32]Piece_Info
    count:=breakable_pieces(&w,pillar,pieces[:])
    top:Body_Handle
    for piece in pieces[:count] {
        if piece.center.y>-0.4 {
            testing.expectf(t,piece.body!=root,"the piece at %v still hangs from the static body",piece.center)
            if piece.center.y>1 {top=piece.body}
        }
        if .Anchor in piece.flags {testing.expect_value(t,piece.body,root)}
    }
    testing.expect(t,top!={})
    height:=body_center(&w,top).y
    test_steps(&w,30)
    testing.expectf(t,body_center(&w,top).y<height-0.8,"the free end went from %v to %v",height,body_center(&w,top).y)
    // Out of the radius nothing happens, and a dead handle does nothing.
    _,again:=breakable_damage(&w,pillar,{5,5,5},0.5,{1e5,0,0})
    testing.expect(t,!again)
    breakable_destroy(&w,pillar)
    testing.expect(t,!breakable_valid(&w,pillar) && !body_valid(&w,root) && !body_valid(&w,top))
    _,dead:=breakable_damage(&w,pillar,{-1,3,0},0.5,{0,-60,0})
    testing.expect(t,!dead && !break_event_apply(&w,event))
    stats,world:=world_stats(&w),world_stats(&w)
    testing.expect(t,stats.pieces==0 && stats.breakables==0 && world.bodies==1 && world.shapes==1)
}

@(test)
the_same_event_on_two_equal_worlds_gives_equal_hashes :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_destruct_world(&a) && test_destruct_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    walls:[2]Breakable_Handle
    for w,i in ([2]^World{&a,&b}) {
        test_ground(w)
        walls[i]=test_wall(w)
        test_body(w,Box{{0.3,0.3,0.3}},{0.5,2.4,0})
        test_steps(w,5)
    }
    testing.expect_value(t,walls[0],walls[1])
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    event,broke:=breakable_damage(&a,walls[0],{0.3,1.1,0.2},0.7,{0,0,-3000})
    testing.expect(t,broke)
    testing.expect(t,world_hash(&a)!=world_hash(&b))
    testing.expect(t,break_event_apply(&b,event))
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    for step in 0..<60 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"the worlds diverged %v steps after the fracture",step)
            return
        }
    }
    testing.expect(t,test_graph_is_consistent(t,&a,walls[0]))
}

@(test)
restoring_before_a_fracture_and_applying_its_event_reproduces_it :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall:=test_wall(&w)
    crate,_:=test_destructible(&w,{1,1,1},{3,0.5,3},1,false)
    test_cannonball(&w,{-1,1,3},{0,0,-25})
    test_steps(&w,3)
    buffer:World
    defer world_destroy(&buffer)
    ok:=test_keep(&buffer,&w)
    testing.expect(t,ok)
    before:=world_hash(&w)
    events:[2]Break_Event
    done:[2]bool
    events[0],done[0]=breakable_damage(&w,wall,{1,1,0},0.6,{0,200,-2000})
    events[1],done[1]=breakable_slice(&w,crate,{3,0.6,3},{0.2,1,0.1})
    testing.expect(t,done[0] && done[1])
    hashes:[40]u64
    recorded:[40]int
    for &hash,i in hashes {
        world_step(&w,1.0/60)
        hash=world_hash(&w)
        recorded[i]=len(world_events(&w).breaks)
    }
    pieces:=world_stats(&w).pieces
    testing.expect(t,test_restore(&w,&buffer))
    testing.expect_value(t,world_hash(&w),before)
    testing.expect(t,test_graph_is_consistent(t,&w,wall))
    for event in events {testing.expect(t,break_event_apply(&w,event))}
    for hash,i in hashes {
        world_step(&w,1.0/60)
        if world_hash(&w)!=hash || len(world_events(&w).breaks)!=recorded[i] {
            testing.expectf(t,false,"the replay diverged %v steps after the fracture",i)
            return
        }
    }
    testing.expect_value(t,world_stats(&w).pieces,pieces)
}

@(test)
debris_touches_only_static_bodies_raises_no_events_and_expires :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    desc:=BREAKABLE_DESC_DEFAULT
    desc.debris_volume,desc.debris_ticks=0.06,50
    block,error:=test_destructible(&w,{0.5,0.5,0.5},{0,0.26,0},8,false,desc)
    testing.expect_value(t,error,Breakable_Error.None)
    box:=test_body(&w,Box{{0.25,0.25,0.25}},{0.9,0.25,0})
    test_steps(&w,20)
    rest:=body_position(&w,box)
    bodies:=world_stats(&w).bodies
    whole:=breakable_mass(&w,block)
    _,broke:=breakable_damage(&w,block,body_center(&w,breakable_body(&w,block)),2,{4000,500,0})
    testing.expect(t,broke)
    pieces:[16]Piece_Info
    count:=breakable_pieces(&w,block,pieces[:])
    debris:=0
    for piece in pieces[:count] {
        if .Debris in piece.flags {debris+=1}
    }
    testing.expect_value(t,debris,count-1)
    testing.expect_value(t,world_stats(&w).bodies,bodies+debris)
    lowest:f32
    for _ in 0..<40 {
        world_step(&w,1.0/60)
        events:=world_events(&w)
        for event in events.contact_begin {
            for piece in pieces[:count] {
                if .Debris in piece.flags {testing.expect(t,event.body_a!=piece.body && event.body_b!=piece.body)}
            }
        }
        for piece in pieces[:count] {
            if .Debris in piece.flags {lowest=min(lowest,body_center(&w,piece.body).y)}
        }
    }
    // The debris flew through the box, which did not notice, and landed on the ground.
    testing.expectf(t,length(body_position(&w,box)-rest)<1e-4,"the box moved %v",body_position(&w,box)-rest)
    testing.expectf(t,lowest>-0.05,"debris sank to %v",lowest)
    passed:=false
    for piece in pieces[:count] {
        if .Debris in piece.flags {passed||=body_center(&w,piece.body).x>1.3}
    }
    testing.expect(t,passed)
    // Queries skip debris unless asked.
    filter:=QUERY_FILTER_DEFAULT
    for piece in pieces[:count] {
        if .Debris not_in piece.flags {continue}
        from:=body_center(&w,piece.body)+Vec3{0,3,0}
        hit,_:=ray_cast_closest(&w,from,{0,-4,0})
        filter.debris=true
        seen,_:=ray_cast_closest(&w,from,{0,-4,0},filter)
        for other in pieces[:count] {
            if .Debris in other.flags {testing.expect(t,hit.body!=other.body)}
        }
        testing.expect(t,hit.body!={} && seen.body!={} && seen.body!=hit.body && seen.fraction<hit.fraction)
        break
    }
    test_steps(&w,15)
    testing.expect_value(t,world_stats(&w).bodies,bodies)
    after:[16]Piece_Info
    breakable_pieces(&w,block,after[:])
    for piece,i in after[:count] {
        if .Debris in pieces[i].flags {testing.expect(t,.Gone in piece.flags && piece.body=={} && !body_valid(&w,pieces[i].body))}
    }
    testing.expect(t,breakable_mass(&w,block)<whole)
}

@(test)
a_slice_produces_two_closed_pieces_whose_volumes_add_up :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    crate,error:=test_destructible(&w,{1,1,1},{2,3,1},1,false)
    testing.expect_value(t,error,Breakable_Error.None)
    root:=breakable_body(&w,crate)
    body_set_velocity(&w,root,{3,0,0},{0,2,0})
    mass:=body_mass(&w,root)
    testing.expect(t,abs(mass-2000)<1)
    event,cut:=breakable_slice(&w,crate,{2.2,3,1},{1,0.3,0})
    testing.expect(t,cut && event.kind==.Slice)
    pieces:[8]Piece_Info
    testing.expect_value(t,breakable_pieces(&w,crate,pieces[:]),3)
    testing.expect(t,.Gone in pieces[0].flags && pieces[0].body=={})
    mesh:geom.Mesh_Buffer
    geom.mesh_buffer_init(&mesh)
    defer geom.mesh_buffer_destroy(&mesh)
    volume:f32
    momentum:Vec3
    for piece in pieces[1:3] {
        testing.expect(t,breakable_piece_mesh(&w,crate,piece.id,&mesh))
        testing.expect(t,geom.mesh_is_closed(mesh.positions[:],mesh.indices[:]))
        testing.expectf(t,abs(geom.mesh_volume(mesh.positions[:],mesh.indices[:])-piece.volume)<1e-4,"volume %v",piece.volume)
        testing.expect(t,piece.volume>0.1 && body_valid(&w,piece.body))
        volume+=piece.volume
        momentum+=body_mass(&w,piece.body)*body_linear_velocity(&w,piece.body)
        testing.expect_value(t,body_angular_velocity(&w,piece.body),Vec3{0,2,0})
    }
    testing.expectf(t,abs(volume-1)<1e-4,"the halves add up to %v",volume)
    testing.expect(t,pieces[1].body!=pieces[2].body && (pieces[1].body==root || pieces[2].body==root))
    testing.expect(t,abs(body_mass(&w,pieces[1].body)+body_mass(&w,pieces[2].body)-mass)<0.5)
    testing.expectf(t,length(momentum-mass*Vec3{3,0,0})<1,"momentum %v",momentum)
    // A plane that misses cuts nothing.
    _,missed:=breakable_slice(&w,crate,{9,9,9},{0,1,0})
    testing.expect(t,!missed)
    _,flat:=breakable_slice(&w,crate,{2,3,1},{})
    testing.expect(t,!flat)
    testing.expect_value(t,breakable_pieces(&w,crate,nil),3)
}

@(test)
slicing_an_anchored_wall_frees_the_side_without_anchors :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall:=test_wall(&w)
    root:=breakable_body(&w,wall)
    mass:=breakable_mass(&w,wall)
    _,cut:=breakable_slice(&w,wall,{0,1.1,0},{0,1,0})
    testing.expect(t,cut)
    testing.expect(t,test_graph_is_consistent(t,&w,wall))
    pieces:=make([]Piece_Info,breakable_pieces(&w,wall,nil))
    defer delete(pieces)
    breakable_pieces(&w,wall,pieces)
    top:Body_Handle
    for piece in pieces {
        if .Gone in piece.flags {continue}
        if piece.center.y>0.1+1e-3 {
            testing.expect(t,piece.body!=root)
            if top=={} {top=piece.body}
            testing.expect_value(t,piece.body,top)
        } else {
            testing.expect_value(t,piece.body,root)
        }
    }
    testing.expect(t,abs(breakable_mass(&w,wall)-mass)<1e-3*mass)
    testing.expectf(t,abs(body_mass(&w,top)-0.45*mass)<0.01*mass,"the top weighs %v of %v",body_mass(&w,top),mass)
    test_steps(&w,30)
    testing.expect(t,body_is_awake(&w,top) || body_center(&w,top).y<1.6)
}

@(test)
breakable_capacities_and_descriptions_are_checked :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w,12,12))
    defer world_destroy(&w)
    test_ground(&w)
    none,error:=breakable_create(&w,{})
    testing.expect(t,none=={} && error==.Invalid_Desc)
    none,error=test_destructible(&w,{1,1,1},{0,2,0},20,false)
    testing.expect(t,none=={} && error==.Capacity)
    stats:=world_stats(&w)
    testing.expect(t,stats.breakable_capacity_exhausted==1 && stats.pieces==0 && stats.breakables==0 && world_stats(&w).bodies==1)
    // The hull slots of a destroyed breakable serve the next one.
    last:Breakable_Handle
    for round in 0..<6 {
        h,built:=test_destructible(&w,{1,1,1},{0,2,0},10,false)
        testing.expectf(t,built==.None && h!={} && h!=last,"round %v: %v",round,built)
        testing.expect(t,!breakable_valid(&w,last))
        last=h
        test_steps(&w,2)
        breakable_destroy(&w,h)
    }
    stats=world_stats(&w)
    world:=world_stats(&w)
    testing.expect(t,stats.pieces==0 && world.bodies==1 && world.geometry_capacity_exhausted==0)
    // A cut needs two free piece slots per piece it crosses.
    h,_:=test_destructible(&w,{1,1,1},{0,2,0},10,false)
    _,cut:=breakable_slice(&w,h,{0,2,0},{0,1,0})
    testing.expect(t,!cut)
    testing.expect_value(t,world_stats(&w).breakable_capacity_exhausted,2)
    testing.expect_value(t,breakable_pieces(&w,h,nil),world_stats(&w).pieces)
}

// Each cut keeps the piece it replaced: the slots run out after as many cuts as the capacity holds.
@(test)
repeated_cuts_work_until_the_pieces_run_out_and_replay_after_a_restore :: proc(t:^testing.T) {
    w:World
    if !testing.expect(t,test_destruct_world(&w,24,64)) {return}
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    crate,_:=test_destructible(&w,{1,1,1},{0,3,0},1,false)
    snapshot:World;defer world_destroy(&snapshot)
    size:int
    events:[16]Break_Event
    hash:u64
    for i in 0..<16 {
        if i==5 {
            saved:bool
            saved=test_keep(&snapshot,&w)
            testing.expect(t,saved)
        }
        cut:bool
        events[i],cut=breakable_slice(&w,crate,{0.45-0.06*f32(i),3,0},{1,0,0})
        _,refused:=breakable_shortfall(&w,crate)
        if i<11 {
            testing.expectf(t,cut && refused=={},"cut %v",i)
            world_step(&w,1.0/60)
            hash=world_hash(&w)
            continue
        }
        testing.expectf(t,!cut && refused==Break_Capacities{.Pieces},"cut %v needs two more slots: %v",i,refused)
    }
    testing.expect_value(t,breakable_pieces(&w,crate,nil),23)
    testing.expect(t,test_restore(&w,&snapshot))
    for event in events[5:11] {
        testing.expect(t,break_event_apply(&w,event))
        world_step(&w,1.0/60)
    }
    testing.expect_value(t,world_hash(&w),hash)
}

@(test)
impacts_beyond_the_events_of_a_step_count_against_their_destructible :: proc(t:^testing.T) {
    w:World
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=64,128,1024,4
    desc.hull_capacity,desc.event_capacity=32,1
    desc.breakable_capacity,desc.piece_capacity,desc.bond_capacity=4,32,64
    if !testing.expect(t,world_init(&w,desc)) {return}
    defer world_destroy(&w)
    // One crate falls on the other: their hit is one event of the step and damages both.
    crates:[2]Breakable_Handle
    for &crate,i in crates {
        crate,_=test_destructible(&w,{1,1,1},{0,0.5+f32(i)*2,0},1,i==0)
    }
    for _ in 0..<30 {
        world_step(&w,1.0/60)
        if len(world_events(&w).breaks)==0 {continue}
        lost:=0
        for crate in crates {
            events,_:=breakable_shortfall(&w,crate)
            lost+=events
        }
        testing.expect_value(t,len(world_events(&w).breaks),1)
        testing.expect_value(t,lost,1)
        return
    }
    testing.expect(t,false,"the crates did not hit")
}
