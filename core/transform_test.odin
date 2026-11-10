package core

import "core:math"
import "core:math/linalg"
import "core:testing"
import mm "mirai:std/math"

@(test)
a_jump_carries_where_an_entity_and_what_hangs_from_it_were :: proc(t:^testing.T) {
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    locals:Table(Transform)
    table_init(&locals,"Transform")
    defer table_destroy(&locals)
    parents:Table(Parent)
    table_init(&parents,"Parent")
    defer table_destroy(&parents)
    worlds:Table(World_Transform)
    table_init(&worlds,"World_Transform")
    defer table_destroy(&worlds)
    hierarchy:Hierarchy
    defer value_free(&hierarchy,type_info_of(Hierarchy))
    propagation:Propagation
    defer value_free(&propagation,type_info_of(Propagation))
    jumps:Jumps
    defer value_free(&jumps,type_info_of(Jumps))

    body,hand,bystander:=create(&es),create(&es),create(&es)
    held:=TRANSFORM_IDENTITY
    held.position={0,1,0}
    add(&locals,body,TRANSFORM_IDENTITY)
    add(&locals,hand,held)
    add(&parents,hand,Parent{entity=body})
    add(&locals,bystander,TRANSFORM_IDENTITY)
    table_settle(&locals,&es)
    table_settle(&parents,&es)
    tick:=Frame_Time{phase=.Fixed}
    propagate :: proc(locals:^Table(Transform),parents:^Table(Parent),worlds:^Table(World_Transform),hierarchy:^Hierarchy,propagation:^Propagation,jumps:^Jumps,es:^Entities,tick:Frame_Time) {
        hierarchy_settle(hierarchy,read(parents),es)
        transforms_propagate(read(locals),ref(hierarchy),worlds,propagation,jumps,tick)
        table_settle(worlds,es)
    }
    near :: proc(a,b:[3]f32) -> bool {return linalg.length(a-b)<1e-4}

    propagate(&locals,&parents,&worlds,&hierarchy,&propagation,&jumps,&es,tick)
    edit(&locals,body).position={1,0,0}
    edit(&locals,bystander).position={0,0,3}
    propagate(&locals,&parents,&worlds,&hierarchy,&propagation,&jumps,&es,tick)
    carried,_:=get(&worlds,hand)
    testing.expect(t,near(carried.previous.position,{0,1,0}) && near(carried.position,{1,1,0}))

    // The body is put a quarter turn away and ten metres off: its hand was, for whoever draws between the ticks, where that takes where it was.
    by:=mm.Transform{{10,0,0},mm.quat_axis_angle({0,1,0},math.PI/2),{1,1,1}}
    there:=mm.transform_compose(by,mm.Transform{{1,0,0},1,{1,1,1}})
    placed:=edit(&locals,body)
    placed.position,placed.rotation=there.position,there.rotation
    jump(&jumps,body,by)
    propagate(&locals,&parents,&worlds,&hierarchy,&propagation,&jumps,&es,tick)
    carried,_=get(&worlds,hand)
    testing.expect(t,near(carried.position,mm.transform_point(by,{1,1,0})))
    testing.expect(t,near(carried.previous.position,carried.position),"the hand was drawn between the two places")
    moved,_:=get(&worlds,body)
    testing.expect(t,near(moved.previous.position,moved.position))
    // Nothing else jumps, and a jump lasts its tick.
    other,_:=get(&worlds,bystander)
    testing.expect(t,near(other.previous.position,{0,0,3}) && near(other.position,{0,0,3}))
    testing.expect_value(t,len(jumps.queue.items),0)
    edit(&locals,body).position+={0,0,1}
    propagate(&locals,&parents,&worlds,&hierarchy,&propagation,&jumps,&es,tick)
    moved,_=get(&worlds,body)
    testing.expect(t,near(moved.position-moved.previous.position,{0,0,1}))
}

@(private="file")
Hierarchy_Fixture :: struct {
    using world:Test_World,
    disabled:Table(Disabled),
    locals:Table(Transform),
    parents:Table(Parent),
    worlds:Table(World_Transform),
    hierarchy:Hierarchy,
    propagation:Propagation,
    jumps:Jumps,
}

@(private="file")
fixture_propagate :: proc(f:^Hierarchy_Fixture,phase:Phase) {
    transforms_propagate(read(&f.locals),ref(&f.hierarchy),&f.worlds,&f.propagation,&f.jumps,Frame_Time{phase=phase})
    test_world_settle(f)
}

@(test)
propagating_writes_only_the_world_transforms_that_change :: proc(t:^testing.T) {
    f:Hierarchy_Fixture
    if !test_world_init(t,&f) {return}
    defer test_world_destroy(&f)
    body,hand,bystander:=create(&f.entities),create(&f.entities),create(&f.entities)
    add(&f.locals,body,TRANSFORM_IDENTITY);add(&f.locals,hand,TRANSFORM_IDENTITY);add(&f.locals,bystander,TRANSFORM_IDENTITY)
    add(&f.parents,hand,Parent{entity=body})
    test_world_settle(&f)
    fixture_propagate(&f,.Fixed)
    fixture_propagate(&f,.Fixed)
    seen:=version(&f.worlds)

    // Asked for and left as it was: neither it nor what hangs from it is written.
    _=edit(&f.locals,body)
    fixture_propagate(&f,.Fixed)
    fixture_propagate(&f,.Late)
    testing.expect_value(t,version(&f.worlds),seen)

    edit(&f.locals,body).position={1,0,0}
    fixture_propagate(&f,.Late)
    for e in ([]Entity{body,hand}) {testing.expect(t,stamp(&f.worlds,row_of(&f.worlds,e))>seen)}
    testing.expect(t,stamp(&f.worlds,row_of(&f.worlds,bystander))<=seen)
}

@(test)
a_chain_of_parents_that_goes_round_ends_and_a_deep_one_composes_whole :: proc(t:^testing.T) {
    f:Hierarchy_Fixture
    if !test_world_init(t,&f) {return}
    defer test_world_destroy(&f)
    // a and b are each other's parent, c hangs from a, and the tree under root goes 200 deep.
    a,b,c,root,other:=create(&f.entities),create(&f.entities),create(&f.entities),create(&f.entities),create(&f.entities)
    step:=TRANSFORM_IDENTITY
    step.position={1,0,0}
    for e in ([]Entity{a,b,c,root,other}) {add(&f.locals,e,step)}
    add(&f.parents,a,Parent{entity=b});add(&f.parents,b,Parent{entity=a});add(&f.parents,c,Parent{entity=a})
    deepest:=root
    for _ in 0..<200 {
        child:=create(&f.entities)
        add(&f.locals,child,step)
        add(&f.parents,child,Parent{entity=deepest})
        deepest=child
    }
    test_world_settle(&f)
    fixture_propagate(&f,.Fixed)
    edit(&f.locals,a).position={2,0,0}
    fixture_propagate(&f,.Late)

    world,placed:=world_of(read(&f.locals),read(&f.parents),deepest)
    testing.expect(t,placed && abs(world.position.x-201)<1e-3,"world_of composes every parent of a chain within HIERARCHY_DEPTH")
    propagated,_:=get(&f.worlds,deepest)
    testing.expect(t,abs(propagated.position.x-201)<1e-3)
    _,placed=world_of(read(&f.locals),read(&f.parents),c)
    testing.expect(t,placed)

    // The Parent of b closed the cycle, so b is the root of the tree above a.
    destroy_tree(&f.entities,ref(&f.hierarchy),a)
    testing.expect(t,!alive(&f.entities,a) && !alive(&f.entities,c) && alive(&f.entities,b))
    testing.expect(t,alive(&f.entities,root) && alive(&f.entities,other))
    test_world_settle(&f)
    destroy_tree(&f.entities,ref(&f.hierarchy),root)
    testing.expect(t,!alive(&f.entities,deepest) && alive(&f.entities,other))
}

// On random hierarchies, a pass that computes only what changed leaves every
// world as a pass that computes all of them: after entities move, gain and
// lose a Transform, change parent, are made and destroyed, in ticks and in
// frames. A reader that fell behind the links that moved reads the tree whole.
@(test)
propagating_what_changed_equals_propagating_all_on_random_hierarchies :: proc(t:^testing.T) {
    World :: struct {
        es:Entities,
        locals:Table(Transform),parents:Table(Parent),worlds:Table(World_Transform),
        hierarchy:Hierarchy,propagation:Propagation,jumps:Jumps,
    }
    world_free :: proc(w:^World) {
        table_destroy(&w.locals);table_destroy(&w.parents);table_destroy(&w.worlds)
        value_free(&w.hierarchy,type_info_of(Hierarchy));value_free(&w.propagation,type_info_of(Propagation));value_free(&w.jumps,type_info_of(Jumps))
        entities_destroy(&w.es)
    }
    pass :: proc(w:^World,tick:bool,whole:bool) {
        table_settle(&w.parents,&w.es)
        hierarchy_settle(&w.hierarchy,read(&w.parents),&w.es)
        table_settle(&w.locals,&w.es);table_settle(&w.worlds,&w.es)
        entities_settle(&w.es)
        // The pass of the other World has seen nothing: it computes every row.
        if whole {w.propagation.seen_locals.gone=max(u64)}
        transforms_propagate(read(&w.locals),ref(&w.hierarchy),&w.worlds,&w.propagation,&w.jumps,Frame_Time{phase=tick?.Fixed:.Late})
        table_settle(&w.worlds,&w.es)
    }
    for seed in u64(1)..=6 {
        a,b:World
        for w in ([2]^World{&a,&b}) {
            entities_init(&w.es)
            table_init(&w.locals,"Transform");table_init(&w.parents,"Parent");table_init(&w.worlds,"World_Transform")
        }
        defer {world_free(&a);world_free(&b)}
        rng:=mm.rng_make(seed,1)
        live:[dynamic]Entity;defer delete(live)
        for step in 0..<400 {
            // The same change in both Worlds: their entities are made alike, so they are the same handles.
            pick:=int(mm.rng_u32(&rng)%10)
            e:=len(live)>0?live[int(mm.rng_u32(&rng))%len(live)]:NONE
            local:=Transform{{(f32(mm.rng_u32(&rng)%1024)/1024)*4-2,(f32(mm.rng_u32(&rng)%1024)/1024)*4-2,(f32(mm.rng_u32(&rng)%1024)/1024)},mm.quat_axis_angle({0,1,0},(f32(mm.rng_u32(&rng)%1024)/1024)*6),{1,1,1}}
            for w in ([2]^World{&a,&b}) {
                switch {
                case pick<3 || e==NONE:
                    made:=create(&w.es)
                    if w==&a {append(&live,made)}
                    if pick!=1 {add(&w.locals,made,local)}
                    if e!=NONE {add(&w.parents,made,Parent{e,i32(step)})}
                case pick<6:
                    if row:=edit(&w.locals,e);row!=nil {row^=local}
                case pick==6:
                    other:=live[(int(entity_index(e))*7+step)%len(live)]
                    add(&w.parents,e,Parent{other,i32(step%3)}) // also under itself or its own child: left a root
                case pick==7:
                    if has(&w.locals,e) {remove(&w.locals,e)} else {add(&w.locals,e,local)}
                case pick==8:
                    remove(&w.parents,e)
                case:
                    destroy(&w.es,e)
                }
            }
            if pick==9 && e!=NONE {
                for at,k in live {if at==e {unordered_remove(&live,k);break}}
            }
            if step%3!=0 {continue}
            tick:=step%2==0
            pass(&a,tick,false);pass(&b,tick,true)
            if !testing.expect_value(t,count(&a.worlds),count(&b.worlds)) {return}
            for row in 0..<count(&a.worlds) {
                at:=entity_at(&a.worlds,row)
                other,found:=get(&b.worlds,at)
                if !testing.expectf(t,found && other==at_row(&a.worlds,row),"seed %d step %d: entity %v is %v, and all of them computed leaves it %v",seed,step,at,at_row(&a.worlds,row),other) {return}
            }
        }
        // A reader that reads after every settle is told each link, however many moved before;
        // one that read none of more than the log holds is told to read the tree whole.
        seen,behind:u64
        _,_=hierarchy_moved(ref(&a.hierarchy),&seen)
        _,_=hierarchy_moved(ref(&a.hierarchy),&behind)
        homes:=[2]Entity{create(&a.es),create(&a.es)}
        child:=create(&a.es)
        for k in 0..<3*HIERARCHY_MOVED {
            add(&a.parents,child,Parent{homes[k%2],0})
            table_settle(&a.parents,&a.es)
            hierarchy_settle(&a.hierarchy,read(&a.parents),&a.es)
            moved,whole:=hierarchy_moved(ref(&a.hierarchy),&seen)
            if !testing.expect(t,!whole && len(moved)==1 && moved[0]==child) {break}
        }
        _,whole:=hierarchy_moved(ref(&a.hierarchy),&behind)
        testing.expect(t,whole)
    }
}

@(private="file")
at_row :: proc(worlds:^Table(World_Transform),row:int) -> World_Transform {return at(worlds,row)}
