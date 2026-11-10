package anim

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:std/base"

@(test)
distance_playback_requests_select_named_clips_and_times_reject_invalid_data_and_reuse_queue_memory :: proc(t:^testing.T) {
    entity:=core.entity_make(1,1);profile:=motion_test_profile();defer motion_test_free(&profile)
    requests:Animation_Requests;defer delete(requests.distances.items)
    motion_play_distance(&requests,entity,profile,"stop",2)
    testing.expect_value(t,requests.distances.items[0],Animation_Distance_Request{entity=entity,clip=base.name_hash("walk"),time=.5})
    clear(&requests.distances.items)
    motion_play_distance(&requests,entity,profile,"stop",0,true)
    testing.expect_value(t,requests.distances.items[0],Animation_Distance_Request{entity=entity,clip=base.name_hash("walk"),time=2,seek=true})
    animation_distance(nil,entity,1,0);animation_distance(&requests,core.NONE,1,0);animation_distance(&requests,entity,0,0);animation_distance(&requests,entity,1,-1);animation_distance(&requests,entity,1,f32(0h7fc00000))
    motion_play_distance(&requests,entity,profile,"missing",0);motion_play_distance(&requests,entity,profile,"stop",f32(0h7f800000))
    testing.expect_value(t,requests.distances.refused,6)
    clear(&requests.distances.items)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    for _ in 0..=cap(requests.distances.items) {motion_play_distance(&requests,entity,profile,"stop",2)}
    dropped:=requests.distances.dropped
    clear(&requests.distances.items);motion_play_distance(&requests,entity,profile,"stop",1)
    context=saved
    testing.expect(t,dropped==1 && len(requests.distances.items)==1 && requests.distances.items[0].time==1)
}
