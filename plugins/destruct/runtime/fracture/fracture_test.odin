package fracture

import "core:testing"
import sim "plugins:physics/runtime/sim"
import math "mirai:std/math"
import "mirai:std/geom"

@(private)
test_destruct_world :: proc(w:^World,pieces:=512,hulls:=256) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=256,512,4096,16
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=hulls,4,2,256
    desc.character_capacity=4
    return world_init(w,desc,{destructibles=8,pieces=pieces,connections=4096})
}

// A box of `size` centered at `position`, fractured at `count` sites; the pieces that reach its bottom
// 5 cm are anchors when `anchored`.
@(private)
test_destructible :: proc(w:^World,size,position:Vec3,count:int,anchored:bool,desc:=Destructible_Desc{}) -> (Destructible_Handle,Destructible_Error) {
    d:=desc
    if d.density==0 {d=DESTRUCTIBLE_DESC_DEFAULT}
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
    return destructible_create(&w.fracture,&w.sim,d)
}

@(private)
test_wall :: proc(w:^World,count:=24) -> Destructible_Handle {
    desc:=DESTRUCTIBLE_DESC_DEFAULT
    desc.damage_radius=1
    h,_:=test_destructible(w,{4,2,0.4},{0,1,0},count,true,desc)
    return h
}

@(private)
test_cannonball :: proc(w:^World,position,velocity:Vec3,radius:f32=0.25) -> Body_Handle {
    desc:=sim.BODY_DESC_DEFAULT
    desc.position,desc.linear_velocity,desc.bullet=position,velocity,true
    body:=sim.body_create(&w.sim,desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Sphere{radius}
    sim.shape_create(&w.sim,body,shape)
    return body
}

// Every unbroken connection joins two pieces of one body; every dynamic body of the destructible is one
// connected group; every group left in a static body has an anchor.
@(private)
test_graph_is_consistent :: proc(t:^testing.T,w:^World,h:Destructible_Handle) -> bool {
    pieces:=make([]Piece_Info,destructible_pieces(&w.fracture,&w.sim,h,nil))
    connections:=make([]Connection_Info,destructible_connections(&w.fracture,h,nil))
    parent:=make([]i32,len(w.fracture.pieces))
    anchored:=make([]bool,len(w.fracture.pieces))
    defer {
        delete(pieces)
        delete(connections)
        delete(parent)
        delete(anchored)
    }
    destructible_pieces(&w.fracture,&w.sim,h,pieces)
    destructible_connections(&w.fracture,h,connections)
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
        sim.union_join(parent,c.a,c.b)
    }
    for piece in pieces {
        if .Anchor in piece.flags {anchored[sim.union_find(parent,piece.id)]=true}
    }
    for a in pieces {
        if a.body=={} {continue}
        root:=sim.union_find(parent,a.id)
        if sim.body_type(&w.sim,a.body)==.Static {
            if !anchored[root] {return false}
            continue
        }
        for b in pieces {
            if b.body==a.body && sim.union_find(parent,b.id)!=root {return false}
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
    testing.expect(t,destructible_valid(&w.fracture,wall))
    root:=destructible_body(&w.fracture,wall)
    testing.expect_value(t,sim.body_type(&w.sim,root),sim.Body_Type.Static)
    pieces:[64]Piece_Info
    count:=destructible_pieces(&w.fracture,&w.sim,wall,pieces[:])
    testing.expect(t,count>=20 && count<=24)
    testing.expect_value(t,fracture_stats(&w.fracture).pieces,count)
    volume:f32
    anchors:=0
    for piece in pieces[:count] {
        volume+=piece.volume
        if .Anchor in piece.flags {anchors+=1}
        testing.expect_value(t,piece.body,root)
    }
    testing.expectf(t,abs(volume-3.2)<0.01,"volume of the pieces %v",volume)
    testing.expect(t,anchors>0 && anchors<count)
    mass:=destructible_mass(&w.fracture,wall)
    testing.expect(t,abs(mass-2000*volume)<1)
    testing.expect(t,destructible_connections(&w.fracture,wall,nil)>count)
    test_steps(&w,10)
    testing.expect_value(t,len(fracture_events(&w.fracture)),0)

    ball:=test_cannonball(&w,{0,1.2,3},{0,0,-30})
    events:=0
    thrown:f32
    for _ in 0..<20 {
        world_step(&w,1.0/60)
        for event in fracture_events(&w.fracture) {
            testing.expect(t,event.destructible==wall && event.kind==.Impact && event.radius==1)
            if events==0 {
                // The ball: into the wall, on its front face. What it frees leaves with its impulse.
                testing.expect(t,event.vector.z<-1000 && abs(event.point.z-0.2)<0.05 && u64(event.tick)+1==sim.world_tick(&w.sim) && event.piece>=0)
                destructible_pieces(&w.fracture,&w.sim,wall,pieces[:])
                for piece in pieces[:count] {
                    if piece.body!=root {thrown=min(thrown,sim.body_linear_velocity(&w.sim,piece.body).z)}
                }
            }
            events+=1
        }
    }
    testing.expect(t,events>0)
    testing.expect(t,test_graph_is_consistent(t,&w,wall))
    destructible_pieces(&w.fracture,&w.sim,wall,pieces[:])
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
        testing.expect_value(t,sim.body_type(&w.sim,piece.body),sim.Body_Type.Dynamic)
        seen:=false
        for body in counted[:bodies] {seen||=body==piece.body}
        if seen {continue}
        counted[bodies]=piece.body
        bodies+=1
        total+=sim.body_mass(&w.sim,piece.body)
    }
    testing.expectf(t,loose>0 && loose<count,"%v of %v pieces came off",loose,count)
    testing.expectf(t,abs(total-mass)<1e-3*mass,"mass %v became %v",mass,total)
    testing.expect(t,abs(destructible_mass(&w.fracture,wall)-mass)<1e-3*mass)
    testing.expectf(t,thrown<-0.5,"the pieces left at %v",thrown)
    testing.expect(t,sim.body_linear_velocity(&w.sim,ball).z>-30)
    testing.expect_value(t,fracture_stats(&w.fracture).capacity_exhausted,0)
}

@(test)
disabling_impact_damage_preserves_collision_manual_damage_and_snapshot_replay :: proc(t:^testing.T) {
    w:World
    if !testing.expect(t,test_destruct_world(&w)) {return}
    defer world_destroy(&w)
    test_ground(&w)
    desc:=DESTRUCTIBLE_DESC_DEFAULT;desc.impact_damage=false;desc.damage_radius=1
    wall,error:=test_destructible(&w,{4,2,.4},{0,1,0},24,true,desc)
    if !testing.expect_value(t,error,Destructible_Error.None) {return}
    ball:=test_cannonball(&w,{0,1.2,3},{0,0,-30})
    snapshot:=make([]u8,world_snapshot_size(&w));defer delete(snapshot)
    _,saved:=world_snapshot(&w,snapshot)
    if !testing.expect(t,saved) {return}
    for _ in 0..<20 {
        world_step(&w,1.0/60)
        testing.expect_value(t,len(fracture_events(&w.fracture)),0)
    }
    testing.expect(t,sim.body_linear_velocity(&w.sim,ball).z>-30)
    connections:[256]Connection_Info
    count:=destructible_connections(&w.fracture,wall,connections[:])
    for connection in connections[:count] {testing.expect(t,!connection.broken && connection.strain==0)}
    intact:=world_hash(&w)
    testing.expect(t,world_restore(&w,snapshot))
    test_steps(&w,20)
    testing.expect_value(t,world_hash(&w),intact)
    event,broke:=destructible_strain(&w.fracture,&w.sim,wall,{0,1,0},4,10000)
    testing.expect(t,broke && event.kind==.Damage && event.vector=={})
    testing.expect(t,destructible_revision(&w.fracture,wall)>0 && test_graph_is_consistent(t,&w,wall))
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
        testing.expect_value(t,len(fracture_events(&w.fracture)),0)
    }
    connections:[256]Connection_Info
    count:=destructible_connections(&w.fracture,wall,connections[:])
    for c in connections[:count] {testing.expect(t,!c.broken && c.strain==0 && c.area>0)}
}

@(test)
pieces_left_without_support_fall :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    // A beam that sticks out sideways from its anchored end, three meters over the ground.
    desc:=DESTRUCTIBLE_DESC_DEFAULT
    desc.strength,desc.rotation=10,math.quat_axis_angle({0,0,1},-0.5*sim.PI)
    pillar,error:=test_destructible(&w,{0.5,3,0.5},{0,3,0},14,true,desc)
    testing.expect_value(t,error,Destructible_Error.None)
    root:=destructible_body(&w.fracture,pillar)
    event,broke:=destructible_damage(&w.fracture,&w.sim,pillar,{-1,3,0},0.5,{0,-60,0})
    testing.expect(t,broke && event.kind==.Damage && u64(event.tick)==sim.world_tick(&w.sim) && event.piece==-1)
    testing.expect(t,test_graph_is_consistent(t,&w,pillar))
    pieces:[32]Piece_Info
    count:=destructible_pieces(&w.fracture,&w.sim,pillar,pieces[:])
    top:Body_Handle
    for piece in pieces[:count] {
        if piece.center.y>-0.4 {
            testing.expectf(t,piece.body!=root,"the piece at %v still hangs from the static body",piece.center)
            if piece.center.y>1 {top=piece.body}
        }
        if .Anchor in piece.flags {testing.expect_value(t,piece.body,root)}
    }
    testing.expect(t,top!={})
    height:=sim.body_center(&w.sim,top).y
    test_steps(&w,30)
    testing.expectf(t,sim.body_center(&w.sim,top).y<height-0.8,"the free end went from %v to %v",height,sim.body_center(&w.sim,top).y)
    // Out of the radius nothing happens, and a dead handle does nothing.
    _,again:=destructible_damage(&w.fracture,&w.sim,pillar,{5,5,5},0.5,{1e5,0,0})
    testing.expect(t,!again)
    destructible_destroy(&w.fracture,&w.sim,pillar)
    testing.expect(t,!destructible_valid(&w.fracture,pillar) && !sim.body_valid(&w.sim,root) && !sim.body_valid(&w.sim,top))
    _,dead:=destructible_damage(&w.fracture,&w.sim,pillar,{-1,3,0},0.5,{0,-60,0})
    testing.expect(t,!dead && !fracture_event_apply(&w.fracture,&w.sim,event))
    stats,world:=fracture_stats(&w.fracture),sim.world_stats(&w.sim)
    testing.expect(t,stats.pieces==0 && stats.destructibles==0 && world.bodies==1 && world.shapes==1)
}

@(test)
the_same_event_on_two_equal_worlds_gives_equal_hashes :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_destruct_world(&a) && test_destruct_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    walls:[2]Destructible_Handle
    for w,i in ([2]^World{&a,&b}) {
        test_ground(w)
        walls[i]=test_wall(w)
        test_body(w,sim.Box{{0.3,0.3,0.3}},{0.5,2.4,0})
        test_steps(w,5)
    }
    testing.expect_value(t,walls[0],walls[1])
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    event,broke:=destructible_damage(&a.fracture,&a.sim,walls[0],{0.3,1.1,0.2},0.7,{0,0,-3000})
    testing.expect(t,broke)
    testing.expect(t,world_hash(&a)!=world_hash(&b))
    testing.expect(t,fracture_event_apply(&b.fracture,&b.sim,event))
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
    buffer:=make([]byte,world_snapshot_capacity(&w))
    defer delete(buffer)
    size,ok:=world_snapshot(&w,buffer)
    testing.expect(t,ok)
    before:=world_hash(&w)
    events:[2]Fracture_Event
    done:[2]bool
    events[0],done[0]=destructible_damage(&w.fracture,&w.sim,wall,{1,1,0},0.6,{0,200,-2000})
    events[1],done[1]=destructible_slice(&w.fracture,&w.sim,crate,{3,0.6,3},{0.2,1,0.1})
    testing.expect(t,done[0] && done[1])
    hashes:[40]u64
    recorded:[40]int
    for &hash,i in hashes {
        world_step(&w,1.0/60)
        hash=world_hash(&w)
        recorded[i]=len(fracture_events(&w.fracture))
    }
    pieces:=fracture_stats(&w.fracture).pieces
    testing.expect(t,world_restore(&w,buffer[:size]))
    testing.expect_value(t,world_hash(&w),before)
    testing.expect(t,test_graph_is_consistent(t,&w,wall))
    for event in events {testing.expect(t,fracture_event_apply(&w.fracture,&w.sim,event))}
    for hash,i in hashes {
        world_step(&w,1.0/60)
        if world_hash(&w)!=hash || len(fracture_events(&w.fracture))!=recorded[i] {
            testing.expectf(t,false,"the replay diverged %v steps after the fracture",i)
            return
        }
    }
    testing.expect_value(t,fracture_stats(&w.fracture).pieces,pieces)
}

@(test)
debris_touches_only_static_bodies_raises_no_events_and_expires :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    desc:=DESTRUCTIBLE_DESC_DEFAULT
    desc.debris_volume,desc.debris_ticks=0.06,50
    block,error:=test_destructible(&w,{0.5,0.5,0.5},{0,0.26,0},8,false,desc)
    testing.expect_value(t,error,Destructible_Error.None)
    box:=test_body(&w,sim.Box{{0.25,0.25,0.25}},{0.9,0.25,0})
    test_steps(&w,20)
    rest:=sim.body_position(&w.sim,box)
    bodies:=sim.world_stats(&w.sim).bodies
    whole:=destructible_mass(&w.fracture,block)
    _,broke:=destructible_damage(&w.fracture,&w.sim,block,sim.body_center(&w.sim,destructible_body(&w.fracture,block)),2,{4000,500,0})
    testing.expect(t,broke)
    pieces:[16]Piece_Info
    count:=destructible_pieces(&w.fracture,&w.sim,block,pieces[:])
    debris:=0
    for piece in pieces[:count] {
        if .Debris in piece.flags {debris+=1}
    }
    testing.expect_value(t,debris,count-1)
    testing.expect_value(t,sim.world_stats(&w.sim).bodies,bodies+debris)
    lowest:f32
    for _ in 0..<40 {
        world_step(&w,1.0/60)
        events:=sim.world_events(&w.sim)
        for event in events.contact_begin {
            for piece in pieces[:count] {
                if .Debris in piece.flags {testing.expect(t,event.body_a!=piece.body && event.body_b!=piece.body)}
            }
        }
        for piece in pieces[:count] {
            if .Debris in piece.flags {lowest=min(lowest,sim.body_center(&w.sim,piece.body).y)}
        }
    }
    // The debris flew through the box, which did not notice, and landed on the ground.
    testing.expectf(t,length(sim.body_position(&w.sim,box)-rest)<1e-4,"the box moved %v",sim.body_position(&w.sim,box)-rest)
    testing.expectf(t,lowest>-0.05,"debris sank to %v",lowest)
    passed:=false
    for piece in pieces[:count] {
        if .Debris in piece.flags {passed||=sim.body_center(&w.sim,piece.body).x>1.3}
    }
    testing.expect(t,passed)
    // Queries skip debris unless asked.
    filter:=sim.QUERY_FILTER_DEFAULT
    for piece in pieces[:count] {
        if .Debris not_in piece.flags {continue}
        from:=sim.body_center(&w.sim,piece.body)+Vec3{0,3,0}
        hit,_:=sim.ray_cast_closest(&w.sim,from,{0,-4,0})
        filter.debris=true
        seen,_:=sim.ray_cast_closest(&w.sim,from,{0,-4,0},filter)
        for other in pieces[:count] {
            if .Debris in other.flags {testing.expect(t,hit.body!=other.body)}
        }
        testing.expect(t,hit.body!={} && seen.body!={} && seen.body!=hit.body && seen.fraction<hit.fraction)
        break
    }
    test_steps(&w,15)
    testing.expect_value(t,sim.world_stats(&w.sim).bodies,bodies)
    after:[16]Piece_Info
    destructible_pieces(&w.fracture,&w.sim,block,after[:])
    for piece,i in after[:count] {
        if .Debris in pieces[i].flags {testing.expect(t,.Gone in piece.flags && piece.body=={} && !sim.body_valid(&w.sim,pieces[i].body))}
    }
    testing.expect(t,destructible_mass(&w.fracture,block)<whole)
}

@(test)
a_slice_produces_two_closed_pieces_whose_volumes_add_up :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    sim.world_set_gravity(&w.sim,{})
    crate,error:=test_destructible(&w,{1,1,1},{2,3,1},1,false)
    testing.expect_value(t,error,Destructible_Error.None)
    root:=destructible_body(&w.fracture,crate)
    sim.body_set_velocity(&w.sim,root,{3,0,0},{0,2,0})
    mass:=sim.body_mass(&w.sim,root)
    testing.expect(t,abs(mass-2000)<1)
    event,cut:=destructible_slice(&w.fracture,&w.sim,crate,{2.2,3,1},{1,0.3,0})
    testing.expect(t,cut && event.kind==.Slice)
    pieces:[8]Piece_Info
    testing.expect_value(t,destructible_pieces(&w.fracture,&w.sim,crate,pieces[:]),3)
    testing.expect(t,.Gone in pieces[0].flags && pieces[0].body=={})
    mesh:geom.Mesh_Buffer
    geom.mesh_buffer_init(&mesh)
    defer geom.mesh_buffer_destroy(&mesh)
    volume:f32
    momentum:Vec3
    for piece in pieces[1:3] {
        testing.expect(t,destructible_piece_mesh(&w.fracture,&w.sim,crate,piece.id,&mesh))
        testing.expect(t,geom.mesh_is_closed(mesh.positions[:],mesh.indices[:]))
        testing.expectf(t,abs(geom.mesh_volume(mesh.positions[:],mesh.indices[:])-piece.volume)<1e-4,"volume %v",piece.volume)
        testing.expect(t,piece.volume>0.1 && sim.body_valid(&w.sim,piece.body))
        volume+=piece.volume
        momentum+=sim.body_mass(&w.sim,piece.body)*sim.body_linear_velocity(&w.sim,piece.body)
        testing.expect_value(t,sim.body_angular_velocity(&w.sim,piece.body),Vec3{0,2,0})
    }
    testing.expectf(t,abs(volume-1)<1e-4,"the halves add up to %v",volume)
    testing.expect(t,pieces[1].body!=pieces[2].body && (pieces[1].body==root || pieces[2].body==root))
    testing.expect(t,abs(sim.body_mass(&w.sim,pieces[1].body)+sim.body_mass(&w.sim,pieces[2].body)-mass)<0.5)
    testing.expectf(t,length(momentum-mass*Vec3{3,0,0})<1,"momentum %v",momentum)
    // A plane that misses cuts nothing.
    _,missed:=destructible_slice(&w.fracture,&w.sim,crate,{9,9,9},{0,1,0})
    testing.expect(t,!missed)
    _,flat:=destructible_slice(&w.fracture,&w.sim,crate,{2,3,1},{})
    testing.expect(t,!flat)
    testing.expect_value(t,destructible_pieces(&w.fracture,&w.sim,crate,nil),3)
}

@(test)
slicing_an_anchored_wall_frees_the_side_without_anchors :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    wall:=test_wall(&w)
    root:=destructible_body(&w.fracture,wall)
    mass:=destructible_mass(&w.fracture,wall)
    _,cut:=destructible_slice(&w.fracture,&w.sim,wall,{0,1.1,0},{0,1,0})
    testing.expect(t,cut)
    testing.expect(t,test_graph_is_consistent(t,&w,wall))
    pieces:=make([]Piece_Info,destructible_pieces(&w.fracture,&w.sim,wall,nil))
    defer delete(pieces)
    destructible_pieces(&w.fracture,&w.sim,wall,pieces)
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
    testing.expect(t,abs(destructible_mass(&w.fracture,wall)-mass)<1e-3*mass)
    testing.expectf(t,abs(sim.body_mass(&w.sim,top)-0.45*mass)<0.01*mass,"the top weighs %v of %v",sim.body_mass(&w.sim,top),mass)
    test_steps(&w,30)
    testing.expect(t,sim.body_is_awake(&w.sim,top) || sim.body_center(&w.sim,top).y<1.6)
}

@(test)
destructible_capacities_and_descriptions_are_checked :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w,12,12))
    defer world_destroy(&w)
    test_ground(&w)
    none,error:=destructible_create(&w.fracture,&w.sim,{})
    testing.expect(t,none=={} && error==.Invalid_Desc)
    none,error=test_destructible(&w,{1,1,1},{0,2,0},20,false)
    testing.expect(t,none=={} && error==.Capacity)
    stats:=fracture_stats(&w.fracture)
    testing.expect(t,stats.capacity_exhausted==1 && stats.pieces==0 && stats.destructibles==0 && sim.world_stats(&w.sim).bodies==1)
    // The hull slots of a destroyed destructible serve the next one.
    last:Destructible_Handle
    for round in 0..<6 {
        h,built:=test_destructible(&w,{1,1,1},{0,2,0},10,false)
        testing.expectf(t,built==.None && h!={} && h!=last,"round %v: %v",round,built)
        testing.expect(t,!destructible_valid(&w.fracture,last))
        last=h
        test_steps(&w,2)
        destructible_destroy(&w.fracture,&w.sim,h)
    }
    stats=fracture_stats(&w.fracture)
    world:=sim.world_stats(&w.sim)
    testing.expect(t,stats.pieces==0 && world.bodies==1 && world.geometry_capacity_exhausted==0)
    // A cut needs two free piece slots per piece it crosses.
    h,_:=test_destructible(&w,{1,1,1},{0,2,0},10,false)
    _,cut:=destructible_slice(&w.fracture,&w.sim,h,{0,2,0},{0,1,0})
    testing.expect(t,!cut)
    testing.expect_value(t,fracture_stats(&w.fracture).capacity_exhausted,2)
    testing.expect_value(t,destructible_pieces(&w.fracture,&w.sim,h,nil),fracture_stats(&w.fracture).pieces)
}

// Each cut keeps the piece it replaced: the slots run out after as many cuts as the capacity holds.
@(test)
repeated_cuts_work_until_the_pieces_run_out_and_replay_after_a_restore :: proc(t:^testing.T) {
    w:World
    if !testing.expect(t,test_destruct_world(&w,24,64)) {return}
    defer world_destroy(&w)
    sim.world_set_gravity(&w.sim,{})
    crate,_:=test_destructible(&w,{1,1,1},{0,3,0},1,false)
    snapshot:=make([]u8,world_snapshot_capacity(&w));defer delete(snapshot)
    size:int
    events:[16]Fracture_Event
    hash:u64
    for i in 0..<16 {
        if i==5 {
            saved:bool
            size,saved=world_snapshot(&w,snapshot)
            testing.expect(t,saved)
        }
        cut:bool
        events[i],cut=destructible_slice(&w.fracture,&w.sim,crate,{0.45-0.06*f32(i),3,0},{1,0,0})
        _,refused:=destructible_shortfall(&w.fracture,crate)
        if i<11 {
            testing.expectf(t,cut && refused=={},"cut %v",i)
            world_step(&w,1.0/60)
            hash=world_hash(&w)
            continue
        }
        testing.expectf(t,!cut && refused==Capacities{.Pieces},"cut %v needs two more slots: %v",i,refused)
    }
    testing.expect_value(t,destructible_pieces(&w.fracture,&w.sim,crate,nil),23)
    testing.expect(t,world_restore(&w,snapshot[:size]))
    for event in events[5:11] {
        testing.expect(t,fracture_event_apply(&w.fracture,&w.sim,event))
        world_step(&w,1.0/60)
    }
    testing.expect_value(t,world_hash(&w),hash)
}

@(test)
impacts_beyond_the_events_of_a_step_count_against_their_destructible :: proc(t:^testing.T) {
    w:World
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=64,128,1024,4
    desc.hull_capacity,desc.event_capacity=32,16
    if !testing.expect(t,world_init(&w,desc,{destructibles=4,pieces=32,connections=64,events=1})) {return}
    defer world_destroy(&w)
    crates:[2]Destructible_Handle
    for &crate,i in crates {
        crate,_=test_destructible(&w,{1,1,1},{f32(i)*6-3,0.5,0},1,true)
        test_cannonball(&w,{f32(i)*6-3,3,0},{0,-20,0})
    }
    for _ in 0..<30 {
        world_step(&w,1.0/60)
        if len(fracture_events(&w.fracture))==0 {continue}
        lost:=0
        for crate in crates {
            events,_:=destructible_shortfall(&w.fracture,crate)
            lost+=events
        }
        testing.expect_value(t,len(fracture_events(&w.fracture)),1)
        testing.expect_value(t,lost,1)
        return
    }
    testing.expect(t,false,"the balls hit nothing")
}
