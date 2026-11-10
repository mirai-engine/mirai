package editor

import "core:fmt"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"

// The time of a Save, which derives the overrides of every instance, and of
// placing one instance more, in a scene that holds many. Run with
//   mirai test editor prefab_save_and_placing_in_a_scene_of_many_instances -define:EDITOR_PREFAB_BENCH=true

@(private="file") EDITOR_PREFAB_BENCH :: #config(EDITOR_PREFAB_BENCH,false)
@(private="file") INSTANCES :: #config(EDITOR_PREFAB_INSTANCES,2000)

@(test)
prefab_save_and_placing_in_a_scene_of_many_instances :: proc(t:^testing.T) {
    if !EDITOR_PREFAB_BENCH {return}
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"bench")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    w:=edited_world(s)
    crate,_,_:=prefab_test_crate(f)
    history.edits_reset(&f.edits,w)
    id,created:=prefab_create(s,crate,"crate")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    filling:=time.tick_now()
    for at in 1..<INSTANCES {
        if _,placed:=prefab_instantiate(s,id,{position={f32(at),0,0}});!testing.expect_value(t,placed,Prefab_Error.None) {return}
        free_all(context.temp_allocator)
    }
    filled:=time.tick_since(filling)
    // Every tenth instance holds something on its own.
    lamps:=&f.world.lamps
    for row:=0;row<core.count(lamps);row+=10 {core.at(lamps,row).intensity=9}
    prefab_fixture_step(f)

    placing:=time.tick_now()
    _,placed:=prefab_instantiate(s,id,{position={-1,0,0}})
    one:=time.tick_since(placing)
    testing.expect_value(t,placed,Prefab_Error.None)

    saving:=time.tick_now()
    captured:asset.Scene
    saved:=document_capture(s,&captured,{0xbe,0xbe})
    save:=time.tick_since(saving)
    if !testing.expect_value(t,saved,Document_Error.None) {return}
    defer asset.scene_destroy(&captured)
    plain:=time.tick_now()
    data,_:=asset.scene_bytes(&captured,context.temp_allocator)
    encode:=time.tick_since(plain)
    fmt.printfln("prefab bench: %d instances of 3 entities, %d overrides in the file of %d bytes",core.count(&f.world.instances),len(captured.overrides),len(data))
    fmt.printfln("  placing them one by one  %.1f ms (%.3f ms each)",time.duration_milliseconds(filled),time.duration_milliseconds(filled)/f64(INSTANCES))
    fmt.printfln("  placing one more         %.3f ms",time.duration_milliseconds(one))
    fmt.printfln("  capture with overrides   %.1f ms",time.duration_milliseconds(save))
    fmt.printfln("  encoding the file        %.1f ms",time.duration_milliseconds(encode))
}
