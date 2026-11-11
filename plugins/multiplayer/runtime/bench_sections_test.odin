package multiplayer

import "core:fmt"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:engine/scene"

@(private) NET_SECTIONS_BENCH :: #config(NET_SECTIONS_BENCH,false)

// What a server spends looking at the boxes of the sections for the objects
// that moved in a tick: sections_of for each, with as many sections as asked,
// on a line of boxes that overlap their neighbours, the objects spread along it.
@(private)
bench_sections_run :: proc(t:^testing.T,sections,objects:int) {
    SAMPLES :: 200
    info,described:=net_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Net_Test_World
    net_test_init(&world,&info)
    defer core.world_destroy(&info,.World,&world)
    references:=make([]core.Entity,sections,context.temp_allocator)
    for &r,i in references {
        r=core.create(&world.entities)
        position:=[3]f32{f32(i)*20,0,0}
        core.add(&world.transforms,r,core.Transform{position=position,rotation=1,scale={1,1,1}})
        core.add(&world.worlds,r,core.World_Transform{transform={position=position,rotation=1,scale={1,1,1}}})
        core.add(&world.references,r,scene.Scene_Reference{extents={12,12,12},loaded={1,1}})
    }
    things:=make([]core.Entity,objects,context.temp_allocator)
    for &e,i in things {
        e=core.create(&world.entities)
        home:=references[i%sections]
        position:=[3]f32{f32(i%sections)*20+f32(i%7)*1.5,0,0}
        core.add(&world.parents,e,core.Parent{home,0})
        core.add(&world.worlds,e,core.World_Transform{transform={position=position,rotation=1,scale={1,1,1}}})
    }
    core.settle(&info,&world,nil)
    session:Net_Session
    problems:core.Problems
    session.problems=&problems
    hierarchy:=core.ref(&world.hierarchy)
    boxes:scene.Section_Boxes
    defer scene.section_boxes_destroy(&boxes)
    testing.expect(t,scene.section_boxes_build(&boxes,core.read(&world.references),core.read(&world.worlds)))
    holding:=make([dynamic]scene.Section_Box,context.temp_allocator)
    samples:[SAMPLES]f64
    held:=0
    for sample in 0..<SAMPLES+16 {
        started:=time.tick_now()
        for e,i in things {
            in_them:=sections_of(&session,&boxes,&holding,&world.worlds,hierarchy,e,references[i%sections])
            held+=int(in_them[1]!=core.NONE)
        }
        if sample>=16 {samples[sample-16]=time.duration_seconds(time.tick_diff(started,time.tick_now()))*1000}
    }
    testing.expect(t,held>0 && problems.count==0)
    for i in 1..<len(samples) {
        value:=samples[i]
        at:=i
        for at>0 && samples[at-1]>value {samples[at]=samples[at-1];at-=1}
        samples[at]=value
    }
    median:=(samples[SAMPLES/2-1]+samples[SAMPLES/2])*.5
    fmt.printfln("NET_SECTIONS_BENCH sections=%d moving=%d median_ms=%.4f best_ms=%.4f ns_per_object=%.0f",sections,objects,median,samples[0],median*1e6/f64(objects))
}

@(test)
bench_sections :: proc(t:^testing.T) {
    if !NET_SECTIONS_BENCH {return}
    for sections in ([3]int{16,64,256}) {
        for objects in ([2]int{256,2000}) {bench_sections_run(t,sections,objects)}
    }
}
