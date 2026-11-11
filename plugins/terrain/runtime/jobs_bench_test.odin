package terrain

@(require) import "core:fmt"
@(require) import "core:log"
@(require) import "core:os"
@(require) import "core:slice"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import "mirai:asset"
@(require) import "mirai:core"
@(require) import render "mirai:engine/render"
@(require) import "mirai:host"
@(require) import "mirai:std/base"
@(require) import "mirai:std/jobs"

// ./mirai test plugins/terrain/runtime --release -define:MIRAI_BENCH=true -define:ODIN_TEST_THREADS=1 bench_terrain_update_while_a_brush_edits
BENCH :: #config(MIRAI_BENCH,false)

when BENCH {

// The time of terrain_update in each tick while a brush raises a Heightfield
// across the corner of four chunks, with the rest of a frame between ticks.
@(test)
bench_terrain_update_while_a_brush_edits :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,600*time.Second)
    for kind in ([2]Source_Kind{.Heightfield,.Volume}) {
        root:=base.test_folder(t,"terrain")
        samples:=kind==.Heightfield?[3]int{1025,1,1025}:[3]int{129,129,129}
        cells:=kind==.Heightfield?64:32
        source:Source;testing.expect(t,source_make(&source,kind,samples,1,cells));defer source_destroy(&source)
        source.revision=1
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        id:=base.Asset_Id{61,62}
        testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
        assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=1024}));defer host.assets_destroy(&assets)
        app:=host.App{assets=&assets,allocator=context.allocator}
        testing.expect(t,jobs.system_init(&app.jobs,{threads=jobs.THREADS_AUTO}));defer jobs.system_destroy(&app.jobs)
        w:Terrain_Test_World
        if !terrain_test_world_init(t,&w) {return}
        defer terrain_test_world_free(&w)
        resident:Terrain_Resident;defer terrain_resident_free(&resident)
        owner:=core.create(&w.entities)
        core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
        core.add(&w.terrains,owner,Terrain{source=id,solid=true})
        test_world_settle(&w.w)
        w.settings={heightfields=1024,meshes=1024}
        settings:=Terrain_Settings{samples=64*1024*1024,lod_distance=-1}
        for _ in 0..<3 {terrain_bench_tick(&w,&resident,&app,settings)}
        TICKS :: 90
        times:[TICKS]f64
        for tick in 0..<TICKS {
            // Strokes at the corner of four chunks, moving along it.
            corner:=f32(cells)*(kind==.Heightfield?4:1)-f32(samples.x-1)*0.5
            center:=[3]f32{corner+f32(tick%8)*0.25,0,corner}
            brush:=Brush{kind=kind==.Heightfield?.Raise:.Carve,center=center,radius=6,amount=0.05}
            dig(&w.terrain_requests,brush,owner)
            times[tick]=terrain_bench_tick(&w,&resident,&app,settings)
            // The rest of a frame of 60 Hz, in which the jobs may run.
            time.sleep(12*time.Millisecond)
        }
        stable:[TICKS]f64
        for _ in 0..<3 {terrain_bench_tick(&w,&resident,&app,settings)}
        for &value in stable {value=terrain_bench_tick(&w,&resident,&app,settings)}
        slice.sort(times[:]);slice.sort(stable[:])
        mean:=f64(0)
        for value in times {mean+=value}
        mean/=TICKS
        log.infof("terrain bench %v %v samples, %d workers: edit ticks mean %.3f ms, median %.3f, p95 %.3f, max %.3f; stable median %.4f ms; problems %d",
            kind,samples,jobs.worker_count(&app.jobs),mean,times[TICKS/2],times[TICKS*95/100],times[TICKS-1],stable[TICKS/2],w.problems.count)
        for &p in core.problems_list(&w.problems) {log.infof("%s",core.problem_text(&p))}
    }
}

@(private="file")
terrain_bench_tick :: proc(w:^Terrain_Test_World,resident:^Terrain_Resident,app:^host.App,settings:Terrain_Settings) -> f64 {
    commands:=core.commands_of(test_world_ref(&w.w))
    start:=time.tick_now()
    test_step(&w.terrain,commands,resident,app,&w.problems,settings)
    elapsed:=time.duration_milliseconds(time.tick_since(start))
    test_world_settle(&w.w)
    return elapsed
}

}
