package pcg_physics

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"
import phys "plugins:physics/runtime"
import "mirai:std/jobs"

@(test_world)
Keep_Out_World :: struct {
    using world:Test_World,
    keep_outs:core.Table(Pcg_Physics_Keep_Out),
    parts:core.Table(Pcg_Keep_Out_Part),
    colliders:core.Table(phys.Collider),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    worlds:core.Table(core.World_Transform),
    zones:core.Table(pcg.Pcg_Zone),
    volumes:core.Table(volume.Volume),
    splines:core.Table(volume.Spline),
    state:Pcg_Physics_Seen,
}

@(private="file")
Keep_Out_Test :: struct {
    using w:Keep_Out_World,
    problems:core.Problems,
}

// A tick of the bridge, then the places of the children it made under their parents.
@(private="file")
test_step :: proc(f:^Keep_Out_Test) {
    w:=&f.w
    pcg_physics_keep_out(&w.state,core.read(&w.keep_outs),core.read(&w.parts),core.read(&w.colliders),core.read(&w.parents),core.commands(w,test_world_info(w)),&f.problems)
    test_world_settle(w)
    for row in 0..<core.count(&w.parts) {
        child:=core.entity_at(&w.parts,row)
        parent,_:=core.get(&w.parents,child)
        place,_:=core.get(&w.worlds,parent.entity)
        local,_:=core.get(&w.transforms,child)
        world:=core.World_Transform{transform=mm.transform_compose(place.transform,{local.position,local.rotation,local.scale})}
        if row:=core.edit(&w.worlds,child);row!=nil {row^=world} else {core.add(&w.worlds,child,world)}
    }
    test_world_settle(w)
}

@(private="file")
keep_out :: proc(f:^Keep_Out_Test,c:phys.Collider,margin:f32,place:=mm.TRANSFORM_IDENTITY) -> core.Entity {
    e:=core.create(&f.entities)
    core.add(&f.keep_outs,e,Pcg_Physics_Keep_Out{margin=margin})
    core.add(&f.colliders,e,c)
    core.add(&f.worlds,e,core.World_Transform{transform=place})
    test_world_settle(&f.w)
    return e
}

@(private="file")
children_of :: proc(f:^Keep_Out_Test,parent:core.Entity) -> (out:[dynamic]core.Entity) {
    out=make([dynamic]core.Entity,context.temp_allocator)
    for row in 0..<core.count(&f.parts) {
        child:=core.entity_at(&f.parts,row)
        if p,_:=core.get(&f.parents,child);p.entity==parent {append(&out,child)}
    }
    return
}

@(private="file")
excluded :: proc(f:^Keep_Out_Test,p:[3]f32) -> bool {
    at:=volume.Where{volumes=core.read(&f.volumes),worlds=core.read(&f.worlds),splines=core.read(&f.splines)}
    out:=make([dynamic]pcg.Exclusion,context.temp_allocator)
    pcg.exclusions_gather(core.read(&f.zones),at,&out,&f.problems)
    for &x in out {if pcg.exclusion_holds(&x,p) {return true}}
    return false
}

@(private="file")
collider_of :: proc(kind:phys.Collider_Kind,size:[3]f32,center:=[3]f32{}) -> phys.Collider {
    c:=phys.COLLIDER_DEFAULT
    c.kind,c.size,c.center=kind,size,center
    return c
}

// The excluding zones of the children hold every point of a collider grown
// by its margin, as pcg reads them, and none past it: a box, a sphere, a
// capsule (its column and both ends) and a cylinder, placed, scaled and offset.
@(test)
a_keep_out_excludes_the_points_of_its_collider_grown_by_its_margin :: proc(t:^testing.T) {
    Case :: struct {
        collider:phys.Collider,
        margin:f32,
        place:mm.Transform,
        pieces:int,
        inside,outside:[3][3]f32,
    }
    at :: proc(position:[3]f32,scale:f32=1) -> mm.Transform {return {position,1,{scale,scale,scale}}}
    cases:=[?]Case{
        {collider_of(.Box,{1,2,1}),0.5,at({10,0,0}),1,{{11.4,0,0},{10,2.4,0},{9,-2.4,1.4}},{{11.6,0,0},{10,2.6,0},{10,0,1.6}}},
        {collider_of(.Sphere,{1,0,0},{0,1,0}),0.5,at({}),1,{{0,2.4,0},{1.4,1,0},{0,-0.4,0}},{{0,2.6,0},{1.1,2.1,0},{0,-0.6,0}}},
        {collider_of(.Capsule,{0.5,1,0}),0.25,at({0,0,5}),3,{{0,1.7,5},{0.7,0,5},{0,-1.7,5}},{{0,1.8,5},{0.8,0,5},{0.6,1.5,5}}},
        {collider_of(.Cylinder,{1,0.5,0}),0,at({}),1,{{0.99,0.49,0},{0,-0.49,-0.99},{-0.7,0,0.7}},{{0,0.6,0},{1.1,0,0},{0,0,-1.1}}},
        // Scaled by 2, so is the margin: a box of half size 1.5 a side in its frame, 3 in the world.
        {collider_of(.Box,{1,1,1}),0.5,at({0,0,-20},2),1,{{2.9,0,-20},{0,2.9,-20},{0,0,-17.1}},{{3.1,0,-20},{0,3.1,-20},{0,0,-16.9}}},
    }
    for c in cases {
        f:Keep_Out_Test
        if !test_world_init(t,&f.w) {return}
        e:=keep_out(&f,c.collider,c.margin,c.place)
        test_step(&f)
        testing.expectf(t,len(children_of(&f,e))==c.pieces,"%v: %d pieces",c.collider.kind,len(children_of(&f,e)))
        testing.expectf(t,f.problems.count==0,"%v: %v",c.collider.kind,core.problems_list(&f.problems))
        for p in c.inside {testing.expectf(t,excluded(&f,p),"%v keeps %v out",c.collider.kind,p)}
        for p in c.outside {testing.expectf(t,!excluded(&f,p),"%v leaves %v",c.collider.kind,p)}
        test_world_destroy(&f.w)
    }
}

// A collider the bridge cannot hold or a margin that is no length keeps
// nothing out and says why; fixed, it keeps out again.
@(test)
a_keep_out_of_a_collider_without_a_shape_or_with_a_wrong_size_is_a_problem_and_makes_nothing :: proc(t:^testing.T) {
    Case :: struct {collider:phys.Collider,margin:f32,code:string,has:bool}
    cases:=[?]Case{
        {collider_of(.Mesh,{1,1,1}),0,"pcg_physics.kind",true},
        {collider_of(.Box,{1,1,1}),math.nan_f32(),"pcg_physics.margin",true},
        {collider_of(.Box,{1,1,1}),-1,"pcg_physics.margin",true},
        {collider_of(.Box,{1,0,1}),0,"pcg_physics.size",true},
        {collider_of(.Sphere,{math.inf_f32(1),0,0}),0,"pcg_physics.size",true},
        {collider_of(.Capsule,{0.5,-1,0}),0,"pcg_physics.size",true},
        {collider_of(.Box,{1,1,1},{math.nan_f32(),0,0}),0,"pcg_physics.size",true},
        {collider_of(.Box,{1,1,1}),0,"pcg_physics.collider",false},
    }
    for c in cases {
        f:Keep_Out_Test
        if !test_world_init(t,&f.w) {return}
        e:=keep_out(&f,c.collider,c.margin)
        if !c.has {core.remove(&f.colliders,e);test_world_settle(&f.w)}
        test_step(&f)
        testing.expectf(t,core.count(&f.parts)==0,"%s: no children",c.code)
        problems:=core.problems_list(&f.problems)
        testing.expectf(t,len(problems)==1 && string(cstring(&problems[0].code[0]))==c.code && problems[0].entity==e,"%s: %v",c.code,len(problems))
        if c.has {
            core.edit(&f.colliders,e)^=collider_of(.Box,{1,1,1})
            core.edit(&f.keep_outs,e).margin=0
            test_world_settle(&f.w)
            test_step(&f)
            testing.expectf(t,core.count(&f.parts)==1 && excluded(&f,{0.9,0,0}),"%s: fixed, it keeps out",c.code)
        }
        test_world_destroy(&f.w)
    }
}

// Only a change of the collider or the margin makes children again, only the
// pieces that changed, and a keep-out that goes takes its children with it.
// A world without any does nothing, and a tick nothing changed in allocates
// nothing.
@(test)
keep_out_children_follow_their_collider_and_a_clean_tick_does_nothing :: proc(t:^testing.T) {
    f:Keep_Out_Test
    if !test_world_init(t,&f.w) {return}
    defer test_world_destroy(&f.w)
    test_step(&f)
    test_step(&f)
    passes:=f.state.passes
    test_step(&f)
    testing.expect(t,f.state.passes==passes && core.count(&f.parts)==0,"a world without keep-outs does nothing")
    e:=keep_out(&f,collider_of(.Capsule,{0.5,1,0}),0.25)
    test_step(&f)
    first:=children_of(&f,e)
    testing.expect_value(t,len(first),3)
    // Its own children settling is the last change it looks at.
    test_step(&f)
    passes=f.state.passes
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    {
        context.allocator=mem.tracking_allocator(&track)
        context.temp_allocator=context.allocator
        pcg_physics_keep_out(&f.state,core.read(&f.keep_outs),core.read(&f.parts),core.read(&f.colliders),core.read(&f.parents),core.commands(&f.w,test_world_info(&f.w)),&f.problems)
    }
    testing.expect(t,f.state.passes==passes && track.total_allocation_count==0,"a clean tick compares nothing and allocates nothing")
    // The margin changes every piece; the same collider written again changes none.
    core.edit(&f.colliders,e)^=collider_of(.Capsule,{0.5,1,0})
    test_world_settle(&f.w)
    test_step(&f)
    same:=children_of(&f,e)
    testing.expect(t,len(same)==3 && same[0]==first[0] && same[1]==first[1] && same[2]==first[2],"rewritten alike, the children stay")
    core.edit(&f.colliders,e)^=collider_of(.Capsule,{0.5,0,0})
    test_world_settle(&f.w)
    test_step(&f)
    sphere:=children_of(&f,e)
    testing.expect_value(t,len(sphere),1)
    testing.expect(t,excluded(&f,{0,0.7,0}) && !excluded(&f,{0,0.8,0}),"a capsule of half height 0 is a sphere")
    // A child that is destroyed by something else (a rollback) is made again, once.
    core.destroy(&f.entities,sphere[0])
    test_world_settle(&f.w)
    test_step(&f)
    testing.expect_value(t,len(children_of(&f,e)),1)
    core.remove(&f.keep_outs,e)
    test_world_settle(&f.w)
    test_step(&f)
    testing.expect_value(t,core.count(&f.parts),0)
}

// A static box of 2 by 1 by 2 standing on y = 0 (a table) at x of the frame.
@(private="file")
table_state :: proc(state:^phys.Physics_State,x:f32) -> bool {
    settings:=phys.Physics_Settings{bodies=4,shapes=4,contacts=4}
    job_system:jobs.Job_System
    problems:core.Problems
    if !phys.state_make(state,&settings,&job_system,&problems) {return false}
    body,error:=phys.owned_body_create(state,{owner=1,entity=core.Entity(7)},{x,0.5,0},1)
    if error!=.None {return false}
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    return phys.owned_shape_create(state,&collision,body,{collider=phys.collider_box({1,0.5,1}),rotation=1})!={}
}

// What would stand inside a collider is taken out and the rest kept in
// order: a box on the table stays, one inside it goes, and the frame of the
// graph places them. Half extents that are no size, a frame that is not a
// number or no physics takes nothing out and says so.
@(test)
filter_overlaps_takes_out_what_stands_inside_a_collider_in_order :: proc(t:^testing.T) {
    for x in ([2]f32{0,100}) {
        state:phys.Physics_State
        if !testing.expect(t,table_state(&state,x)) {return}
        frame:=mm.Transform{{x,0,0},1,{1,1,1}}
        placed:=[?]pcg.Placed{
            {position={0,1.05,0},rotation=1,scale={1,1,1},id=1}, // on the table
            {position={0,0.2,0},rotation=1,scale={1,1,1},id=2},  // inside it
            {position={5,0,0},rotation=1,scale={1,1,1},id=3},    // beside it
            {position={0.9,0.5,0},rotation=1,scale={0.1,0.1,0.1},id=4}, // small, inside its edge
            {position={-0.5,1.01,0.5},rotation=mm.quat_axis_angle({0,1,0},0.7),scale={2,2,2},id=5}, // larger, turned, on it
        }
        kept,ok:=pcg_physics_filter_overlaps(core.ref(&state),placed[:],frame,{0.25,0.25,0.25})
        testing.expectf(t,ok && kept==3 && placed[0].id==1 && placed[1].id==3 && placed[2].id==5,"%v: %d %v",x,kept,placed)
        bad:=[?]struct {half:[3]f32,frame:mm.Transform}{
            {{0,1,1},frame},
            {{math.nan_f32(),1,1},frame},
            {{1,1,1},{{math.inf_f32(1),0,0},1,{1,1,1}}},
            {{1,1,1},{{0,0,0},1,{math.nan_f32(),1,1}}},
        }
        for b in bad {
            again:=[2]pcg.Placed{{position={0,0.2,0},rotation=1,scale={1,1,1},id=2},{position={5,0,0},rotation=1,scale={1,1,1},id=3}}
            n,valid:=pcg_physics_filter_overlaps(core.ref(&state),again[:],b.frame,b.half)
            testing.expectf(t,!valid && n==2 && again[0].id==2,"%v",b)
        }
        phys.state_destroy(&state)
    }
    none:[1]pcg.Placed
    n,ok:=pcg_physics_filter_overlaps({},none[:],mm.TRANSFORM_IDENTITY,{1,1,1})
    testing.expect(t,!ok && n==1,"without physics nothing is taken out")
}
