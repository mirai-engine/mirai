package mirai_net

import "core:testing"
import "mirai:std/base"

@(test)
spatial_grid_updates_only_changed_cells_and_frees_emptied_ones :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=32,cell_size=8});defer scene_destroy(s)
    connection_set_view(s.server,s.on_server[0],{},4)
    objects:[12]Object
    for &object,i in objects {object,_=object_create(s.server,{type=s.tp.prop,filter=.Spatial,position={f32(i)*16,0,0},radius=1})}
    tick:=u32(0)
    for _ in 0..<12 {scene_tick(s,&tick)}
    r:=&s.server.back.repl
    updates:=r.grid_updates
    for _ in 0..<8 {scene_tick(s,&tick)}
    testing.expect_value(t,r.grid_updates,updates)
    object_set_position(s.server,objects[0],{1,0,1})
    for _ in 0..<8 {scene_tick(s,&tick)}
    testing.expect_value(t,r.grid_updates,updates)
    for move in 0..<300 {
        object_set_position(s.server,objects[0],{f32(move+1)*8,0,-8})
        scene_tick(s,&tick)
        scene_tick(s,&tick)
        o:=base.handle_index(base.Handle(objects[0]))
        if !testing.expect(t,r.grid_listed[o] && r.grid_cell[o]==grid_position_key({f32(move+1)*8,0,-8},8)) {return}
    }
    object_set_filter(s.server,objects[0],.Always)
    for _ in 0..<6 {scene_tick(s,&tick)}
    testing.expect(t,!r.grid_listed[base.handle_index(base.Handle(objects[0]))])
    object_destroy(s.server,objects[1])
    for _ in 0..<12 {scene_tick(s,&tick)}
    testing.expect(t,!r.grid_listed[base.handle_index(base.Handle(objects[1]))])
    for o in 0..<r.high {
        if r.live[o]!=1 || r.filter[o]!=.Spatial {continue}
        head,listed:=base.hash_map_get(&r.grid,r.grid_cell[o])
        testing.expect(t,r.grid_listed[o] && listed)
        found:=0
        for at:=head;at>=0;at=r.grid_next[at] {found+=int(at==i32(o))}
        testing.expect_value(t,found,1)
    }
}

@(test)
spatial_grid_keeps_lookups_short_while_objects_roam_over_new_cells :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=32,cell_size=8,filter_interval=1,hysteresis=1,leave_margin=-1});defer scene_destroy(s)
    connection_set_view(s.server,s.on_server[0],{200,0,200},20)
    objects:[24]Object
    state:=u64(9)
    for &object in objects {
        object,_=object_create(s.server,{type=s.tp.prop,filter=.Spatial,position={f32(rng_unit(&state))*400,0,f32(rng_unit(&state))*400},radius=1})
    }
    r:=&s.server.back.repl
    pr:=&s.server.back.peers[0].repl
    tick:=u32(0)
    seen:=0
    for _ in 0..<300 {
        for object in objects {
            object_set_position(s.server,object,{f32(rng_unit(&state))*400,0,f32(rng_unit(&state))*400})
        }
        scene_tick(s,&tick)
        cells:[24]u64
        occupied:=0
        for o in 0..<r.high {
            if r.live[o]!=1 || r.filter[o]!=.Spatial {continue}
            key:=grid_position_key(r.position[o],8)
            known:=false
            for cell in cells[:occupied] {known||=cell==key}
            if !known {cells[occupied]=key;occupied+=1}
            if !testing.expect(t,r.grid_listed[o] && r.grid_cell[o]==key && base.hash_map_contains(&r.grid,key),"the cell of an object is found") {return}
            inside:=view_reaches(r,pr,o)
            seen+=int(inside)
            if !testing.expectf(t,bitset_test(pr.scope,o)==inside,"object %v is in scope %v, its view reaches it %v",o,bitset_test(pr.scope,o),inside) {return}
        }
        // Only cells that hold objects stay in the grid.
        if !testing.expectf(t,r.grid.count==occupied,"%v cells in the grid for %v occupied",r.grid.count,occupied) {return}
    }
    testing.expect(t,seen>0)
}

@(test)
spatial_grid_handles_finite_extreme_positions_without_overflow_or_unbounded_loops :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=32,cell_size=8});defer scene_destroy(s)
    near,_:=object_create(s.server,{type=s.tp.prop,filter=.Spatial,position={1e30,0,1e30},radius=1})
    far,_:=object_create(s.server,{type=s.tp.prop,filter=.Spatial,position={-1e30,0,-1e30},radius=1})
    testing.expect_value(t,connection_set_view(s.server,s.on_server[0],{1e30,0,1e30},1e22),Error.None)
    tick:=u32(0)
    for _ in 0..<30 {scene_tick(s,&tick)}
    pr:=&s.server.back.peers[0].repl
    testing.expect(t,bitset_test(pr.scope,int(base.handle_index(base.Handle(near)))))
    testing.expect(t,!bitset_test(pr.scope,int(base.handle_index(base.Handle(far)))))
    testing.expect_value(t,connection_set_view(s.server,s.on_server[0],{},max(f32)),Error.None)
    for _ in 0..<30 {scene_tick(s,&tick)}
    testing.expect(t,bitset_test(pr.scope,int(base.handle_index(base.Handle(far)))))
    nan:=transmute(f32)u32(0x7fc00000)
    infinity:=transmute(f32)u32(0x7f800000)
    testing.expect_value(t,object_set_position(s.server,near,{nan,0,0}),Error.Invalid)
    testing.expect_value(t,connection_set_view(s.server,s.on_server[0],{},infinity),Error.Invalid)
    _,error:=object_create(s.server,{type=s.tp.prop,filter=.Spatial,position={infinity,0,0}})
    testing.expect_value(t,error,Error.Invalid)
    _,error=object_create(s.server,{type=s.tp.prop,priority=nan})
    testing.expect_value(t,error,Error.Invalid)
    testing.expect_value(t,object_set_priority(s.server,near,infinity),Error.Invalid)
}

@(test)
object_radius_changes_scope_and_maximum_without_rebuilding_spatial_cells :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=32,cell_size=8,filter_interval=1,hysteresis=1});defer scene_destroy(s)
    connection_set_view(s.server,s.on_server[0],{},1)
    near,_:=object_create(s.server,{type=s.tp.prop,filter=.Spatial,position={10,0,0},radius=0})
    objects:[10]Object
    for &object,index in objects {object,_=object_create(s.server,{type=s.tp.prop,filter=.Spatial,position={100+f32(index)*16,0,0},radius=2})}
    tick:=u32(0)
    for _ in 0..<20 {scene_tick(s,&tick)}
    r:=&s.server.back.repl
    pr:=&s.server.back.peers[0].repl
    at:=int(base.handle_index(base.Handle(near)))
    updates:=r.grid_updates
    cell:=r.grid_cell[at]
    testing.expect(t,!bitset_test(pr.scope,at))
    testing.expect_value(t,object_set_radius(s.server,near,10),Error.None)
    for _ in 0..<20 {scene_tick(s,&tick)}
    testing.expect(t,bitset_test(pr.scope,at))
    testing.expect_value(t,r.max_radius,f32(10))
    testing.expect_value(t,r.grid_updates,updates)
    testing.expect_value(t,r.grid_cell[at],cell)
    testing.expect_value(t,object_set_radius(s.server,near,0),Error.None)
    for _ in 0..<20 {scene_tick(s,&tick)}
    testing.expect(t,!bitset_test(pr.scope,at))
    testing.expect_value(t,r.max_radius,f32(2))
    testing.expect_value(t,r.grid_updates,updates)
    nan:=transmute(f32)u32(0x7fc00000)
    infinity:=transmute(f32)u32(0x7f800000)
    testing.expect_value(t,object_set_radius(s.server,near,nan),Error.Invalid)
    testing.expect_value(t,object_set_radius(s.server,near,infinity),Error.Invalid)
    testing.expect_value(t,object_set_radius(s.server,near,-1),Error.Invalid)
    testing.expect_value(t,object_set_parent(s.server,near,near),Error.Invalid)
}

@(test)
hysteresis_is_refused_beyond_what_a_connection_counts_and_the_longest_one_ends :: proc(t:^testing.T) {
    tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
    w:=new(Test_World);defer free(w)
    test_world_init(w,1);defer test_world_destroy(w)
    testing.expect(t,test_host(w,{mode=.Server,protocol=&tp.protocol,replication={hysteresis=257}})==nil)
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=8,filter_interval=1,hysteresis=256,leave_margin=-1});defer scene_destroy(s)
    connection_set_view(s.server,s.on_server[0],{},10)
    object,_:=object_create(s.server,{type=s.tp.prop,filter=.Spatial,position={5,0,0}})
    tick:=u32(0)
    for _ in 0..<10 {scene_tick(s,&tick)}
    pr:=&s.server.back.peers[0].repl
    o:=int(base.handle_index(base.Handle(object)))
    testing.expect(t,bitset_test(pr.scope,o))
    connection_set_view(s.server,s.on_server[0],{1000,0,0},10)
    stayed:=0
    for _ in 0..<300 {
        scene_tick(s,&tick)
        if !bitset_test(pr.scope,o) {break}
        stayed+=1
    }
    testing.expect_value(t,stayed,255)
}
