package anim

import "core:fmt"
import "core:log"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:engine/save"
import "mirai:engine/scene"
import "mirai:std/base"
import "mirai:std/serial"

@(private)
@(test_world)
Save_Bench_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    disabled:core.Table(core.Disabled),
    hierarchy:core.Hierarchy,
    animations:core.Table(Animation),
    progress:core.Table(Animation_Progress),
    playback:Playback,
}

when #config(MIRAI_BENCH,false) {

// What a save costs the frame that asks for it: the capture of a world of characters whose bones
// are entities, against a copy of that world and the compression of the slot, which a job makes.
@(test)
bench_save_capture_of_animated_characters :: proc(t:^testing.T) {
    CHARACTERS :: 200
    BONES :: 80
    REPEATS :: 5
    w:Save_Bench_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    id:=u64(1)
    for c in 0..<CHARACTERS {
        root:=core.create(&w.entities)
        core.add(&w.ids,root,{base.Entity_Id(id)});id+=1
        core.add(&w.names,root,core.name_make(fmt.tprintf("character %d",c)))
        core.add(&w.transforms,root,core.TRANSFORM_IDENTITY)
        core.add(&w.animations,root,ANIMATION_DEFAULT)
        parent:=root
        for b in 0..<BONES {
            bone:=core.create(&w.entities)
            core.add(&w.ids,bone,{base.Entity_Id(id)});id+=1
            core.add(&w.names,bone,core.name_make(fmt.tprintf("bone %d",b)))
            core.add(&w.transforms,bone,core.TRANSFORM_IDENTITY)
            core.add(&w.parents,bone,core.Parent{entity=parent})
            parent=bone
        }
    }
    test_world_settle(&w)
    for row in 0..<core.count(&w.animations) {
        state:=state_get(&w.playback,core.entity_at(&w.animations,row))
        state.clip,state.time,state.playing,state.speed=0,1.25,true,1
        resize(&state.pose_slab,BONES);resize(&state.bindings,BONES);resize(&state.curves,16)
        resize(&state.parents,BONES);resize(&state.targets,BONES);resize(&state.rest,BONES)
    }
    ref:=test_world_ref(&w)

    best_capture,best_copy,best_pack,best_document,best_write:=max(time.Duration),max(time.Duration),max(time.Duration),max(time.Duration),max(time.Duration)
    bytes,packed:=0,0
    for _ in 0..<REPEATS {
        out:serial.Writer
        serial.writer_init(&out)
        start:=time.tick_now()
        error:=save.capture(ref,nil,context.allocator,&out)
        best_capture=min(best_capture,time.tick_since(start))
        if !testing.expect_value(t,error,save.Error.None) {serial.writer_destroy(&out);return}
        bytes=out.count

        {
            types:asset.Types
            asset.types_init(&types)
            document:asset.Scene
            start=time.tick_now()
            _,capture_error:=scene.capture(ref,&document,&types,{sections=true})
            best_document=min(best_document,time.tick_since(start))
            body:serial.Writer
            serial.writer_init(&body)
            start=time.tick_now()
            write_error:=asset.scene_write(&document,&body)
            best_write=min(best_write,time.tick_since(start))
            testing.expect(t,capture_error==.None && write_error==.None)
            serial.writer_destroy(&body)
            asset.scene_destroy(&document)
            asset.types_destroy(&types)
        }

        copied:=new(Save_Bench_World)
        start=time.tick_now()
        ok:=core.world_init(&w.made_of,.World,copied,context.allocator) && core.world_copy(&w.made_of,copied,&w)
        best_copy=min(best_copy,time.tick_since(start))
        core.world_destroy(&w.made_of,.World,copied)
        free(copied)
        testing.expect(t,ok)

        // The scene document of the slot, past its header.
        body:[]u8
        for at:=serial.WRITER_ALIGNMENT;at<out.count;at+=serial.WRITER_ALIGNMENT {
            if header,header_error:=asset.header_read(serial.writer_bytes(&out)[at:]);header_error==.None {body=serial.writer_bytes(&out)[at:][:header.total_size];break}
        }
        stream:=make([]u8,asset.pack_bound(len(body)))
        encoder:asset.Stream_Encoder
        asset.stream_encoder_init(&encoder)
        start=time.tick_now()
        stored,pack_error:=asset.pack(&encoder,.Fast,.Compressed,body,stream)
        best_pack=min(best_pack,time.tick_since(start))
        packed=stored
        asset.stream_encoder_destroy(&encoder)
        delete(stream)
        serial.writer_destroy(&out)
        testing.expect_value(t,pack_error,asset.Error.None)
    }
    log.infof("save of %d characters of %d bones (%d entities, %d bytes; %d packed): capture %v (of it scene.capture %v and scene_write %v), world copy %v, compression %v",
        CHARACTERS,BONES,int(id-1),bytes,packed,best_capture,best_document,best_write,best_copy,best_pack)
}

}
