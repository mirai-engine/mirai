package core

@(require) import "core:log"
@(require) import "core:testing"
@(require) import "core:time"

// What a reader of changes and a join of tables cost:
// mirai test core bench_changes bench_join --release -define:MIRAI_BENCH=true
when BENCH {

@(private="file") ROUNDS :: 9
@(private="file") Small :: struct {a:[4]f32}
@(private="file") Mesh :: struct {mesh,material:u64,flags:u32,layer:u32}

@(private="file")
fill :: proc(t:^Table($T),es:^Entities,all:[]Entity,every:int) {
    for e,i in all {if i%every==0 {add(t,e,T{})}}
    table_settle(t,es)
}

// The rows changed since a reader looked, at 100,000 and 1,000,000 rows with
// none, 1 in 1000, 1 in 100 and all of them written: each_changed, which
// skips the pages written before, against a walk of every stamp. And what
// the stamp of its page adds to a write of every row.
@(test)
bench_changes :: proc(t:^testing.T) {
    found:=0
    for rows in ([?]int{100_000,1_000_000}) {
        es:Entities
        entities_init(&es)
        defer entities_destroy(&es)
        table:Table(Small)
        table_init(&table,"Small")
        defer table_destroy(&table)
        all:=make([]Entity,rows);defer delete(all)
        for &e in all {e=create(&es)}
        fill(&table,&es,all,1)
        entities_settle(&es)
        seen:Seen
        _=changes(&table,&seen)
        for every in ([?]int{0,1000,100,1}) {
            pages,scan:f64
            hits,scanned:=0,0
            for round in 0..<ROUNDS {
                if every>0 {for row:=round%every;row<count(&table);row+=every {edit_at(&table,row).a.x+=1}}
                c:=changes(&table,&seen)
                started:=time.tick_now()
                hits=0
                for _ in each_changed(&table,&c) {hits+=1}
                ns:=f64(time.duration_nanoseconds(time.tick_since(started)))
                if round==0 || ns<pages {pages=ns}
                started=time.tick_now()
                scanned=0
                for stamp in table.stamps[:table.on] {if stamp>c.since {scanned+=1}}
                ns=f64(time.duration_nanoseconds(time.tick_since(started)))
                if round==0 || ns<scan {scan=ns}
            }
            found+=hits+1
            testing.expect_value(t,hits,scanned)
            log.infof("changes %8d rows, 1 in %4d written (%7d changed): each_changed %9.1f us, a walk of every stamp %9.1f us",rows,every,hits,pages/1e3,scan/1e3)
        }
        write:f64
        for round in 0..<ROUNDS {
            started:=time.tick_now()
            for row in 0..<count(&table) {edit_at(&table,row).a.x+=1}
            ns:=f64(time.duration_nanoseconds(time.tick_since(started)))
            if round==0 || ns<write {write=ns}
        }
        log.infof("write every one of %d rows by row: %.1f us (%.2f ns/row)",rows,write/1e3,write/f64(rows))
    }
    testing.expect(t,found>0)
}

// Every mesh with its world transform and its tint when it has one, by
// entity: through tables received to read, and through the same tables
// received to write, which a read stamps no row of.
@(test)
bench_join :: proc(t:^testing.T) {
    N :: 100_000
    es:Entities
    entities_init(&es)
    defer entities_destroy(&es)
    worlds:Table(World_Transform);meshes:Table(Mesh);tints:Table(Small)
    table_init(&worlds,"World_Transform");table_init(&meshes,"Mesh");table_init(&tints,"Tint")
    defer {table_destroy(&worlds);table_destroy(&meshes);table_destroy(&tints)}
    all:=make([]Entity,N);defer delete(all)
    for &e in all {e=create(&es)}
    fill(&worlds,&es,all,1);fill(&meshes,&es,all,2);fill(&tints,&es,all,20)
    entities_settle(&es)
    sum:f32
    through_read,through_table:f64
    for round in 0..<ROUNDS {
        started:=time.tick_now()
        m,w,ti:=&meshes,&worlds,&tints
        for row in 0..<count(m) {
            e:=entity_at(m,row)
            world,found:=get(w,e)
            if !found {continue}
            sum+=world.position.x+f32(at(m,row).flags)
            if tint,tinted:=get(ti,e);tinted {sum+=tint.a.x}
        }
        ns:=f64(time.duration_nanoseconds(time.tick_since(started)))
        if round==0 || ns<through_read {through_read=ns}
    }
    before:=worlds.version+meshes.version+tints.version
    for round in 0..<ROUNDS {
        started:=time.tick_now()
        for row in 0..<count(&meshes) {
            e:=entity_at(&meshes,row)
            world,found:=get(&worlds,e)
            if !found {continue}
            sum+=world.position.x+f32(at(&meshes,row).flags)
            if tint,tinted:=get(&tints,e);tinted {sum+=tint.a.x}
        }
        ns:=f64(time.duration_nanoseconds(time.tick_since(started)))
        if round==0 || ns<through_table {through_table=ns}
    }
    stamped:=(worlds.version+meshes.version+tints.version-before)/ROUNDS
    log.infof("join of %d meshes with 2 tables by entity: read-only tables %.1f us (%.2f ns/mesh); tables received to write %.1f us (%.2f ns/mesh), %d rows stamped by a pass",
        count(&meshes),through_read/1e3,through_read/f64(count(&meshes)),through_table/1e3,through_table/f64(count(&meshes)),stamped)
    testing.expect(t,sum==sum)
}

}
