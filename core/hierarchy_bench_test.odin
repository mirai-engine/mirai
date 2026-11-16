package core

@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"

// Measurements of the hierarchy: mirai test core --release -define:MIRAI_BENCH=true
BENCH :: #config(MIRAI_BENCH,false)

when BENCH {

@(private="file")
BENCH_ROUNDS :: 7

// The fastest of several rounds: other processes can only make one slower.
@(private="file")
Bench :: struct {best:time.Duration,start:time.Tick,round:int}

@(private="file")
bench_round :: proc(b:^Bench) -> bool {
    if b.round>0 {
        elapsed:=time.tick_since(b.start)
        if b.round==1 || elapsed<b.best {b.best=elapsed}
    }
    if b.round>=BENCH_ROUNDS {return false}
    b.round+=1
    b.start=time.tick_now()
    return true
}

@(private="file")
bench_report :: proc(name:string,b:Bench,operations:int) {
    log.infof("%-40s %12.1f ns/op",name,f64(time.duration_nanoseconds(b.best))/f64(operations))
}

// A scene of GROUPS entities under one root, each with ITEMS children and
// those with PARTS children: 1+GROUPS*(1+ITEMS*(1+PARTS)) entities.
@(test)
bench_hierarchy :: proc(t:^testing.T) {
    GROUPS :: 2000
    ITEMS :: 4
    PARTS :: 2
    PASSES :: 64
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    locals:Table(Transform);parents:Table(Parent);worlds:Table(World_Transform)
    table_init(&locals,"Transform");table_init(&parents,"Parent");table_init(&worlds,"World_Transform")
    defer {table_destroy(&locals);table_destroy(&parents);table_destroy(&worlds)}
    h:Hierarchy
    defer value_free(&h,type_info_of(Hierarchy))
    p:Propagation
    defer value_free(&p,type_info_of(Propagation))
    jumps:Jumps
    defer value_free(&jumps,type_info_of(Jumps))
    place :: proc(locals:^Table(Transform),parents:^Table(Parent),es:^Entities,parent:Entity,order:int) -> Entity {
        e:=create(es)
        add(locals,e,Transform{{f32(order),0,0},1,{1,1,1}})
        if parent!=NONE {add(parents,e,Parent{parent,i32(order)})}
        return e
    }
    root:=place(&locals,&parents,&es,NONE,0)
    groups:=make([]Entity,GROUPS);defer delete(groups)
    for &group,g in groups {
        group=place(&locals,&parents,&es,root,g)
        for i in 0..<ITEMS {
            item:=place(&locals,&parents,&es,group,i)
            for k in 0..<PARTS {place(&locals,&parents,&es,item,k)}
        }
    }
    settle :: proc(locals:^Table(Transform),parents:^Table(Parent),worlds:^Table(World_Transform),h:^Hierarchy,es:^Entities) {
        table_settle(parents,es)
        hierarchy_settle(h,parents,es)
        table_settle(locals,es)
        table_settle(worlds,es)
        entities_settle(es)
    }
    tick:=Frame_Time{phase=.Fixed}
    settle(&locals,&parents,&worlds,&h,&es)
    transforms_propagate(read(&locals),ref(&h),&worlds,&p,&jumps,tick)
    settle(&locals,&parents,&worlds,&h,&es)
    log.infof("%d entities",count(&locals))

    // A tick that moves 64 groups and what hangs from them.
    b:Bench
    for bench_round(&b) {
        for pass in 0..<PASSES {
            for k in 0..<64 {edit(&locals,groups[(pass*64+k)%GROUPS]).position.y+=1}
            transforms_propagate(read(&locals),ref(&h),&worlds,&p,&jumps,tick)
        }
    }
    bench_report("propagate, 64 groups moved",b,PASSES)

    // A tick after a part changed parent: its world, and those of what hangs from it.
    b={}
    for bench_round(&b) {
        for pass in 0..<PASSES/8 {
            moved:=entity_at(&parents,count(&parents)-1)
            add(&parents,moved,Parent{groups[pass%GROUPS],100})
            settle(&locals,&parents,&worlds,&h,&es)
            transforms_propagate(read(&locals),ref(&h),&worlds,&p,&jumps,tick)
        }
    }
    bench_report("reparent one, settle and propagate",b,PASSES/8)

    // The settle of a function that did not touch Parent.
    b={}
    for bench_round(&b) {
        for _ in 0..<PASSES*16 {hierarchy_settle(&h,&parents,&es)}
    }
    bench_report("hierarchy_settle, nothing changed",b,PASSES*16)

    // The children of 64 groups.
    b={}
    found:=0
    for bench_round(&b) {
        for pass in 0..<PASSES {
            group:=groups[pass*31%GROUPS]
            for child:=first_child(ref(&h),group);child!=NONE;child=next_sibling(ref(&h),child) {found+=1}
        }
    }
    bench_report("children of a group",b,PASSES)
    testing.expect(t,found>0)
}

}
