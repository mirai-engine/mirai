package multiplayer

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
History_Bench_Table :: core.Table(History_Bench_Row)

// HISTORY_BENCH_EXTRA tables of one row: a world holds each table as a field with its own name.
@(private)
History_Bench_Extra :: struct {
    r00:History_Bench_Table `mirai:"name=History_Bench_Row_00"`,r01:History_Bench_Table `mirai:"name=History_Bench_Row_01"`,
    r02:History_Bench_Table `mirai:"name=History_Bench_Row_02"`,r03:History_Bench_Table `mirai:"name=History_Bench_Row_03"`,
    r04:History_Bench_Table `mirai:"name=History_Bench_Row_04"`,r05:History_Bench_Table `mirai:"name=History_Bench_Row_05"`,
    r06:History_Bench_Table `mirai:"name=History_Bench_Row_06"`,r07:History_Bench_Table `mirai:"name=History_Bench_Row_07"`,
    r08:History_Bench_Table `mirai:"name=History_Bench_Row_08"`,r09:History_Bench_Table `mirai:"name=History_Bench_Row_09"`,
    r10:History_Bench_Table `mirai:"name=History_Bench_Row_10"`,r11:History_Bench_Table `mirai:"name=History_Bench_Row_11"`,
    r12:History_Bench_Table `mirai:"name=History_Bench_Row_12"`,r13:History_Bench_Table `mirai:"name=History_Bench_Row_13"`,
    r14:History_Bench_Table `mirai:"name=History_Bench_Row_14"`,r15:History_Bench_Table `mirai:"name=History_Bench_Row_15"`,
    r16:History_Bench_Table `mirai:"name=History_Bench_Row_16"`,r17:History_Bench_Table `mirai:"name=History_Bench_Row_17"`,
    r18:History_Bench_Table `mirai:"name=History_Bench_Row_18"`,r19:History_Bench_Table `mirai:"name=History_Bench_Row_19"`,
    r20:History_Bench_Table `mirai:"name=History_Bench_Row_20"`,r21:History_Bench_Table `mirai:"name=History_Bench_Row_21"`,
    r22:History_Bench_Table `mirai:"name=History_Bench_Row_22"`,r23:History_Bench_Table `mirai:"name=History_Bench_Row_23"`,
    r24:History_Bench_Table `mirai:"name=History_Bench_Row_24"`,r25:History_Bench_Table `mirai:"name=History_Bench_Row_25"`,
    r26:History_Bench_Table `mirai:"name=History_Bench_Row_26"`,r27:History_Bench_Table `mirai:"name=History_Bench_Row_27"`,
    r28:History_Bench_Table `mirai:"name=History_Bench_Row_28"`,r29:History_Bench_Table `mirai:"name=History_Bench_Row_29"`,
    r30:History_Bench_Table `mirai:"name=History_Bench_Row_30"`,r31:History_Bench_Table `mirai:"name=History_Bench_Row_31"`,
    r32:History_Bench_Table `mirai:"name=History_Bench_Row_32"`,r33:History_Bench_Table `mirai:"name=History_Bench_Row_33"`,
    r34:History_Bench_Table `mirai:"name=History_Bench_Row_34"`,r35:History_Bench_Table `mirai:"name=History_Bench_Row_35"`,
    r36:History_Bench_Table `mirai:"name=History_Bench_Row_36"`,r37:History_Bench_Table `mirai:"name=History_Bench_Row_37"`,
    r38:History_Bench_Table `mirai:"name=History_Bench_Row_38"`,r39:History_Bench_Table `mirai:"name=History_Bench_Row_39"`,
    r40:History_Bench_Table `mirai:"name=History_Bench_Row_40"`,r41:History_Bench_Table `mirai:"name=History_Bench_Row_41"`,
    r42:History_Bench_Table `mirai:"name=History_Bench_Row_42"`,r43:History_Bench_Table `mirai:"name=History_Bench_Row_43"`,
    r44:History_Bench_Table `mirai:"name=History_Bench_Row_44"`,r45:History_Bench_Table `mirai:"name=History_Bench_Row_45"`,
    r46:History_Bench_Table `mirai:"name=History_Bench_Row_46"`,r47:History_Bench_Table `mirai:"name=History_Bench_Row_47"`,
    r48:History_Bench_Table `mirai:"name=History_Bench_Row_48"`,r49:History_Bench_Table `mirai:"name=History_Bench_Row_49"`,
    r50:History_Bench_Table `mirai:"name=History_Bench_Row_50"`,r51:History_Bench_Table `mirai:"name=History_Bench_Row_51"`,
    r52:History_Bench_Table `mirai:"name=History_Bench_Row_52"`,r53:History_Bench_Table `mirai:"name=History_Bench_Row_53"`,
    r54:History_Bench_Table `mirai:"name=History_Bench_Row_54"`,r55:History_Bench_Table `mirai:"name=History_Bench_Row_55"`,
    r56:History_Bench_Table `mirai:"name=History_Bench_Row_56"`,r57:History_Bench_Table `mirai:"name=History_Bench_Row_57"`,
    r58:History_Bench_Table `mirai:"name=History_Bench_Row_58"`,r59:History_Bench_Table `mirai:"name=History_Bench_Row_59"`,
    r60:History_Bench_Table `mirai:"name=History_Bench_Row_60"`,r61:History_Bench_Table `mirai:"name=History_Bench_Row_61"`,
    r62:History_Bench_Table `mirai:"name=History_Bench_Row_62"`,r63:History_Bench_Table `mirai:"name=History_Bench_Row_63"`,
    r64:History_Bench_Table `mirai:"name=History_Bench_Row_64"`,r65:History_Bench_Table `mirai:"name=History_Bench_Row_65"`,
    r66:History_Bench_Table `mirai:"name=History_Bench_Row_66"`,r67:History_Bench_Table `mirai:"name=History_Bench_Row_67"`,
    r68:History_Bench_Table `mirai:"name=History_Bench_Row_68"`,r69:History_Bench_Table `mirai:"name=History_Bench_Row_69"`,
    r70:History_Bench_Table `mirai:"name=History_Bench_Row_70"`,r71:History_Bench_Table `mirai:"name=History_Bench_Row_71"`,
    r72:History_Bench_Table `mirai:"name=History_Bench_Row_72"`,r73:History_Bench_Table `mirai:"name=History_Bench_Row_73"`,
    r74:History_Bench_Table `mirai:"name=History_Bench_Row_74"`,r75:History_Bench_Table `mirai:"name=History_Bench_Row_75"`,
    r76:History_Bench_Table `mirai:"name=History_Bench_Row_76"`,r77:History_Bench_Table `mirai:"name=History_Bench_Row_77"`,
    r78:History_Bench_Table `mirai:"name=History_Bench_Row_78"`,r79:History_Bench_Table `mirai:"name=History_Bench_Row_79"`,
    r80:History_Bench_Table `mirai:"name=History_Bench_Row_80"`,r81:History_Bench_Table `mirai:"name=History_Bench_Row_81"`,
    r82:History_Bench_Table `mirai:"name=History_Bench_Row_82"`,r83:History_Bench_Table `mirai:"name=History_Bench_Row_83"`,
    r84:History_Bench_Table `mirai:"name=History_Bench_Row_84"`,r85:History_Bench_Table `mirai:"name=History_Bench_Row_85"`,
    r86:History_Bench_Table `mirai:"name=History_Bench_Row_86"`,r87:History_Bench_Table `mirai:"name=History_Bench_Row_87"`,
    r88:History_Bench_Table `mirai:"name=History_Bench_Row_88"`,r89:History_Bench_Table `mirai:"name=History_Bench_Row_89"`,
    r90:History_Bench_Table `mirai:"name=History_Bench_Row_90"`,r91:History_Bench_Table `mirai:"name=History_Bench_Row_91"`,
    r92:History_Bench_Table `mirai:"name=History_Bench_Row_92"`,r93:History_Bench_Table `mirai:"name=History_Bench_Row_93"`,
    r94:History_Bench_Table `mirai:"name=History_Bench_Row_94"`,r95:History_Bench_Table `mirai:"name=History_Bench_Row_95"`,
    r96:History_Bench_Table `mirai:"name=History_Bench_Row_96"`,r97:History_Bench_Table `mirai:"name=History_Bench_Row_97"`,
}

#assert(size_of(History_Bench_Extra)==HISTORY_BENCH_EXTRA*size_of(History_Bench_Table))

// Storages of plain data.
@(private)
History_Bench_Flat :: struct {words:[60][32]u64}

@(private)
History_Bench_World :: struct {
    using world:core.Test_World,
    using net:Net_Test_Tables,
    using extra:History_Bench_Extra,
    flat:History_Bench_Flat,
}

@(private)
history_bench_init :: proc(w:^History_Bench_World,info:^core.World_Info) -> bool {
    if !net_test_init(w,info) {return false}
    w.settings={bodies=512,shapes=512,contacts=4096,joints=8,characters=4,hulls=64,meshes=4,heightfields=1}
    return true
}

// One of the extra tables, the last ones of the World.
@(private)
history_bench_extra :: proc(w:^History_Bench_World,info:^core.World_Info,k:int) -> ^History_Bench_Table {
    return cast(^History_Bench_Table)core.world_table_at(core.world_ref(w,info),&info.tables[len(info.tables)-HISTORY_BENCH_EXTRA+k])
}

@(private)
history_bench_world :: proc(w:^History_Bench_World,shared:^Net_Test_Shared,app:^host.App) {
    history_bench_init(w,shared.info)
    for i in 0..<HISTORY_BENCH_ENTITIES {
        e:=core.create(&w.entities)
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
        if i%4!=0 {core.add(&w.statics,e,render.Mesh_Renderer{shape=.Cube})}
        for k in 0..<HISTORY_BENCH_EXTRA {
            if (i+k)%10==0 {core.add(history_bench_extra(w,shared.info,k),e,History_Bench_Row{d=u64(i)})}
        }
    }
    core.settle(shared.info,w,nil)
    net_test_physics(w,shared,app)
    world:=&w.state.world
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
    info,described:=core.test_info(t,History_Bench_World,net_test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    shared:=Net_Test_Shared{info=&info}
    defer phys.collider_meshes_destroy(&shared.colliders)
    app:=host.App{info=&info,allocator=context.allocator,tick_dt=1.0/60,shared=&shared}
    defer {host.app_world_scratch_free(&app);delete(app.worlds)}
    world:=new(History_Bench_World)
    defer free(world)
    history_bench_world(world,&shared,&app)
    defer info.destroy[.World](world)
    whole:=make([]History_Bench_World,HISTORY_BENCH_SLOTS)
    defer delete(whole)
    changed:=make([]History_Bench_World,HISTORY_BENCH_SLOTS)
    defer delete(changed)
    marks:=make([][]core.Copy_Mark,HISTORY_BENCH_SLOTS)
    defer delete(marks)
    physics:=make([]phys.Physics_State,HISTORY_BENCH_SLOTS)
    defer delete(physics)
    for i in 0..<HISTORY_BENCH_SLOTS {
        history_bench_init(&whole[i],&info)
        history_bench_init(&changed[i],&info)
        marks[i]=make([]core.Copy_Mark,core.copy_marks_count(&info))
    }
    defer for i in 0..<HISTORY_BENCH_SLOTS {info.destroy[.World](&whole[i]);info.destroy[.World](&changed[i]);delete(marks[i])}
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
                net_test_physics(world,&shared,&app)
            }
        }
        world.time.tick=u64(tick)
        slot:=tick%HISTORY_BENCH_SLOTS
        copies(t,&info,world,&whole[slot],&changed[slot],marks[slot],tick,tick>=2*HISTORY_BENCH_SLOTS,&steady_whole,&steady_changed)
        started:=time.tick_now()
        testing.expect(t,phys.state_copy(&physics[slot],&world.state))
        if tick>=2*HISTORY_BENCH_SLOTS {history_bench_add(&physics_cost,started)}
        net_test_physics(world,&shared,&app)
        bodies=int(world.state.world.state.body_high)
    }
    rows:=0
    for &table in info.tables {rows+=int((cast(^core.Raw_Table)(uintptr(world)+table.offset)).values.len)}
    fmt.printf("history of a client: %d tables, %d rows, %d bodies, ring of %d\n",len(info.tables),rows,bodies,HISTORY_BENCH_SLOTS)
    fmt.printf("| Copy of a tick | %.1f µs | %.1f µs |\n",history_bench_micro(steady_whole),history_bench_micro(steady_changed))
    fmt.printf("| Copy of a replayed tick | %.1f µs | %.1f µs |\n",history_bench_micro(replay_whole),history_bench_micro(replay_changed))
    fmt.printf("| Physics state, in both | %.1f µs | |\n",history_bench_micro(physics_cost))
}
