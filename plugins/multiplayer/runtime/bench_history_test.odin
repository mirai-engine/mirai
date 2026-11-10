package multiplayer

import "base:runtime"
import "core:fmt"
import "core:testing"
import "core:time"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:engine/render"
import "mirai:host"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"

// What the history of a client costs on a world the size of the demo: 117
// tables, 2.000 entities with some twenty thousand rows, 300 bodies of which
// 50 move, a level mesh of 20.000 triangles and 32 hulls. Every tick the
// world is copied to its slot of a ring of 32; every half second a
// correction goes back 15 ticks and runs them again, copying each.

@(private) NET_HISTORY_BENCH :: #config(NET_HISTORY_BENCH,false)
@(private) HISTORY_BENCH_ENTITIES :: 2000
@(private) HISTORY_BENCH_EXTRA :: 98
@(private) HISTORY_BENCH_SLOTS :: 32

@(private)
History_Bench_Row :: struct {a,b,c:[3]f32,d:u64,e:[2]f32}

@(private)
History_Bench_World :: struct {
    using net:Net_Test_World,
    extra:[HISTORY_BENCH_EXTRA]core.Table(History_Bench_Row),
    flat:[60][32]u64, // storages of plain data
}

@(private)
history_bench_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^History_Bench_World)data
    if !net_test_init(&w.net,allocator) {return false}
    w.settings={bodies=512,shapes=512,contacts=4096,joints=8,characters=4,hulls=64,meshes=4,heightfields=1}
    return true
}

@(private)
history_bench_destroy :: proc(data:rawptr) {
    w:=cast(^History_Bench_World)data
    for &t in w.extra {core.table_destroy(&t)}
    net_test_destroy(&w.net)
}

@(private)
history_bench_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^History_Bench_World)dst,cast(^History_Bench_World)src
    if !net_test_copy(&d.net,&s.net) {return false}
    if d.es.generation.allocator.procedure!=nil {context.allocator=d.es.generation.allocator}
    for &t,i in d.extra {if !core.table_copy(&t,&s.extra[i]) {return false}}
    d.flat=s.flat
    return true
}

@(private)
history_bench_copy_changed :: proc(dst,src:rawptr,marks:[]core.Copy_Mark) -> bool {
    d,s:=cast(^History_Bench_World)dst,cast(^History_Bench_World)src
    if !net_test_copy_changed(&d.net,&s.net,marks) {return false}
    if d.es.generation.allocator.procedure!=nil {context.allocator=d.es.generation.allocator}
    for &t,i in d.extra {if !core.table_copy_changed(&t,&s.extra[i],&marks[HISTORY_BENCH_BASE+i]) {return false}}
    d.flat=s.flat
    return true
}

@(private) HISTORY_BENCH_BASE :: NET_TEST_TABLES

@(private)
history_bench_swap :: proc(a,b:rawptr) {
    x,y:=cast(^History_Bench_World)a,cast(^History_Bench_World)b
    net_test_swap(&x.net,&y.net)
    for &t,i in x.extra {core.table_swap(&t,&y.extra[i])}
    x.flat,y.flat=y.flat,x.flat
}

@(private)
history_bench_settle :: proc(world,shared,editor:rawptr) {
    w:=cast(^History_Bench_World)world
    for &t in w.extra {core.table_settle(&t,&w.es)}
    net_test_settle(&w.net,shared,editor)
}

@(private)
history_bench_info :: proc() -> core.World_Info {
    info:=net_test_info()
    tables:=make([]core.Table_Info,len(info.tables)+HISTORY_BENCH_EXTRA)
    copy(tables,info.tables)
    for k in 0..<HISTORY_BENCH_EXTRA {
        tables[len(info.tables)+k]={name="History_Bench_Row",type=History_Bench_Row,info=type_info_of(History_Bench_Row),offset=offset_of(History_Bench_World,extra)+uintptr(k*size_of(core.Table(History_Bench_Row)))}
    }
    delete(info.tables)
    info.tables=tables
    info.sizes[.World],info.aligns[.World]=size_of(History_Bench_World),align_of(History_Bench_World)
    info.init[.World],info.destroy[.World]=history_bench_init,history_bench_destroy
    info.copy,info.copy_changed,info.swap=history_bench_copy,history_bench_copy_changed,history_bench_swap
    return info
}

@(private)
history_bench_world :: proc(w:^History_Bench_World,shared:^Net_Test_Shared,app:^host.App) {
    history_bench_init(w,context.allocator)
    for i in 0..<HISTORY_BENCH_ENTITIES {
        e:=core.create(&w.es)
        position:=[3]f32{f32(i%50)*2,0,f32(i/50)*2}
        core.add(&w.identities,e,core.Id{base.Entity_Id(i+1)})
        if i<300 {
            moving:=i>=250
            if moving {position.y=3}
            core.add(&w.transforms,e,core.Transform{position=position,rotation=1,scale={1,1,1}})
            rigid:=moving?phys.RIGID_BODY_DYNAMIC:phys.RIGID_BODY_STATIC
            rigid.mass=1
            core.add(&w.rigids,e,rigid)
            core.add(&w.colliders,e,phys.collider_box({0.5,0.5,0.5}))
            if moving {core.add(&w.values,e,Net_Test_Value{force=f32(i%7)-3})}
        } else {
            core.add(&w.transforms,e,core.Transform{position=position,rotation=1,scale={1,1,1}})
        }
        core.add(&w.worlds,e,core.World_Transform{})
        if i%4!=0 {core.add(&w.meshes,e,render.Mesh_Renderer{shape=.Cube})}
        for k in 0..<HISTORY_BENCH_EXTRA {
            if (i+k)%10==0 {core.add(&w.extra[k],e,History_Bench_Row{d=u64(i)})}
        }
    }
    history_bench_settle(w,nil,nil)
    net_test_physics(&w.net,shared,app)
    world:=&w.physics.world
    vertices:=make([][3]f32,101*101)
    defer delete(vertices)
    indices:=make([]u32,100*100*6)
    defer delete(indices)
    for z in 0..<101 {for x in 0..<101 {vertices[z*101+x]={f32(x)-50,-1+f32((x*7+z*13)%5)*0.01,f32(z)-50}}}
    for z in 0..<100 {
        for x in 0..<100 {
            at:=(z*100+x)*6
            a:=u32(z*101+x)
            indices[at+0],indices[at+1],indices[at+2]=a,a+101,a+1
            indices[at+3],indices[at+4],indices[at+5]=a+1,a+101,a+102
        }
    }
    sim.mesh_create(world,{vertices=vertices,indices=indices})
    corners:=[4][3]f32{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    counts:=[4]u8{3,3,3,3};faces:=[12]u8{0,2,1,0,1,3,0,3,2,1,2,3}
    for k in 0..<32 {
        tetra:=corners
        for &v in tetra {v*=1+f32(k)*0.01}
        sim.hull_create(world,{tetra[:],counts[:],faces[:]})
    }
}

@(private)
History_Bench_Cost :: struct {copies:int,seconds:f64}

@(private)
history_bench_add :: proc(cost:^History_Bench_Cost,started:time.Tick) {
    cost.copies+=1
    cost.seconds+=time.duration_seconds(time.tick_since(started))
}

@(private)
history_bench_micro :: proc(cost:History_Bench_Cost) -> f64 {return cost.copies>0?cost.seconds/f64(cost.copies)*1e6:0}

// Opt-in: mirai test plugins/multiplayer/runtime cost_of_the_history_of_a_client --release -define:NET_HISTORY_BENCH=true
@(test)
cost_of_the_history_of_a_client :: proc(t:^testing.T) {
    when !NET_HISTORY_BENCH {return}
    info:=history_bench_info()
    defer delete(info.tables)
    defer delete(info.storages)
    shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    world:=new(History_Bench_World)
    defer free(world)
    history_bench_world(world,&shared,&app)
    defer history_bench_destroy(world)
    whole:=make([]History_Bench_World,HISTORY_BENCH_SLOTS)
    defer delete(whole)
    changed:=make([]History_Bench_World,HISTORY_BENCH_SLOTS)
    defer delete(changed)
    marks:=make([][]core.Copy_Mark,HISTORY_BENCH_SLOTS)
    defer delete(marks)
    physics:=make([]phys.Physics_State,HISTORY_BENCH_SLOTS)
    defer delete(physics)
    for i in 0..<HISTORY_BENCH_SLOTS {
        history_bench_init(&whole[i],context.allocator)
        history_bench_init(&changed[i],context.allocator)
        marks[i]=make([]core.Copy_Mark,len(info.tables))
    }
    defer for i in 0..<HISTORY_BENCH_SLOTS {history_bench_destroy(&whole[i]);history_bench_destroy(&changed[i]);delete(marks[i])}
    defer for &state in physics {phys.state_destroy(&state)}
    // Each tick copies its world whole to one ring and what changed to another, in turns.
    copies :: proc(t:^testing.T,info:^core.World_Info,world:^History_Bench_World,whole,changed:^History_Bench_World,marks:[]core.Copy_Mark,tick:int,measured:bool,full,part:^History_Bench_Cost) {
        for turn in 0..<2 {
            started:=time.tick_now()
            if (turn+tick)%2==0 {
                testing.expect(t,info.copy(whole,world))
                if measured {history_bench_add(full,started)}
            } else {
                testing.expect(t,info.copy_changed(changed,world,marks))
                if measured {history_bench_add(part,started)}
            }
        }
    }
    steady_whole,steady_changed,replay_whole,replay_changed,physics_cost:History_Bench_Cost
    bodies:=0
    for tick in 1..=600 {
        if tick%30==0 && tick>HISTORY_BENCH_SLOTS {
            start:=tick-15
            from:=start%HISTORY_BENCH_SLOTS
            if !testing.expect(t,host.app_world_replace(&app,world,&changed[from])) {return}
            for other,k in marks {if k!=from {core.copy_marks_follow(core.world_ref(world,&info),marks[from],other)}}
            core.copy_marks_follow(core.world_ref(world,&info),marks[from],marks[from])
            for again in start..<tick {
                world.time.tick=u64(again)
                slot:=again%HISTORY_BENCH_SLOTS
                copies(t,&info,world,&whole[slot],&changed[slot],marks[slot],again,again>=2*HISTORY_BENCH_SLOTS,&replay_whole,&replay_changed)
                net_test_physics(&world.net,&shared,&app)
            }
        }
        world.time.tick=u64(tick)
        slot:=tick%HISTORY_BENCH_SLOTS
        copies(t,&info,world,&whole[slot],&changed[slot],marks[slot],tick,tick>=2*HISTORY_BENCH_SLOTS,&steady_whole,&steady_changed)
        started:=time.tick_now()
        testing.expect(t,phys.state_copy(&physics[slot],&world.physics))
        if tick>=2*HISTORY_BENCH_SLOTS {history_bench_add(&physics_cost,started)}
        net_test_physics(&world.net,&shared,&app)
        bodies=int(world.physics.world.state.body_high)
    }
    rows:=0
    for &table in info.tables {rows+=int((cast(^core.Raw_Table)(uintptr(world)+table.offset)).values.len)}
    fmt.printf("history of a client: %d tables, %d rows, %d bodies, ring of %d\n",len(info.tables),rows,bodies,HISTORY_BENCH_SLOTS)
    fmt.printf("| Copy of a tick | %.1f µs | %.1f µs |\n",history_bench_micro(steady_whole),history_bench_micro(steady_changed))
    fmt.printf("| Copy of a replayed tick | %.1f µs | %.1f µs |\n",history_bench_micro(replay_whole),history_bench_micro(replay_changed))
    fmt.printf("| Physics state, in both | %.1f µs | |\n",history_bench_micro(physics_cost))
}
