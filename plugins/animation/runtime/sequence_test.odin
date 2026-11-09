package anim

import "core:testing"
import "base:runtime"
import "mirai:core"
import mm "mirai:std/math"

@(test)
animate_sequences_pause_seek_restart_reverse_and_skip_unchanged_transforms :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    animations:core.Table(Keyframe_Path);defer core.table_destroy(&animations)
    states:core.Table(Keyframe_Path_Progress);defer core.table_destroy(&states)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    requests:Keyframe_Path_Requests
    entity:=core.create(&entities)
    value:=keyframe_path_default();value.relative=true;value.frames[1].pose.position.x=4;value.frames[1].duration=2;value.frames[1].hold=1
    placed:=core.TRANSFORM_IDENTITY;placed.position.x=10
    core.add(&animations,entity,value);core.add(&transforms,entity,placed)
    core.table_settle(&animations,&entities);core.table_settle(&transforms,&entities)
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=1})
    core.table_settle(&states,&entities)
    testing.expect(t,transforms.values[0].position.x==12)
    keyframe_path_request(&requests,entity,.Pause)
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=1})
    testing.expect(t,transforms.values[0].position.x==12)
    stamp:=transforms.version
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=1})
    testing.expect_value(t,transforms.version,stamp)
    keyframe_path_request(&requests,entity,.Seek,2.5)
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=1})
    testing.expect(t,transforms.values[0].position.x==14 && states.values[0].time==2.5)
    keyframe_path_request(&requests,entity,.Speed,-1);keyframe_path_request(&requests,entity,.Restart)
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=0.5})
    testing.expect(t,states.values[0].time==3 && !states.values[0].ended)
    saved_context:=context
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=2})
    context=saved_context
    testing.expect(t,transforms.values[0].position.x==12)
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=20})
    testing.expect(t,transforms.values[0].position.x==10 && states.values[0].ended)
    stamp=transforms.version
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=1})
    testing.expect_value(t,transforms.version,stamp)
    snapshot:=states.values[0]
    testing.expect(t,snapshot.origin==mm.Transform{position={10,0,0},rotation=1,scale={1,1,1}})
    core.remove(&animations,entity);core.table_settle(&animations,&entities)
    keyframe_path_evaluate(&animations,&states,&transforms,&requests,{dt=1});core.table_settle(&states,&entities)
    testing.expect_value(t,len(states.values),0)
}

@(test)
animate_request_capacity_and_invalid_frames_do_not_write_transforms :: proc(t:^testing.T) {
    requests:Keyframe_Path_Requests;defer delete(requests.queue.items)
    reserve(&requests.queue.items,4)
    keyframe_path_request(nil,core.Entity(1),.Play)
    keyframe_path_request(&requests,core.NONE,.Play)
    testing.expect_value(t,requests.queue.refused,1)
    for _ in 0..=cap(requests.queue.items) {keyframe_path_request(&requests,core.Entity(1),.Play)}
    testing.expect_value(t,requests.queue.dropped,1)
    value:=keyframe_path_default();value.count=255
    testing.expect_value(t,len(keyframe_path_frames(&value)),0)
    value.count=0;testing.expect_value(t,len(keyframe_path_frames(&value)),0)
}
