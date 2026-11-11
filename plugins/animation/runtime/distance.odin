package anim

import "mirai:core"
import "mirai:std/base"

Animation_Distance_Request :: struct {entity:core.Entity,clip:u64,time:f32,seek:bool,animation:base.Asset_Id}
Distance_Error :: enum u8 {None,Missing_Player,Missing_Clip,Inactive_Clip,Backwards,Unsupported_Clock,Invalid_Time}

animation_distance :: proc(requests:^Animation_Requests,entity:core.Entity,clip:u64,time:f32,seek:bool=false,animation:base.Asset_Id={}) {
    if requests==nil {return}
    if entity==core.NONE || clip==0 || !finite(time) || time<0 {core.refuse(&requests.distances);return}
    core.offer(&requests.distances,Animation_Distance_Request{entity=entity,clip=clip,time=time,seek=seek,animation=animation})
}

motion_play_distance :: proc(requests:^Animation_Requests,rig:core.Entity,profile:Motion_Profile,name:string,distance:f32,seek:bool=false) {
    if requests==nil {return}
    time,clip,ok:=motion_distance_time(profile,name,distance)
    if !ok {core.refuse(&requests.distances);return}
    animation_distance(requests,rig,base.name_hash(base.text_get(clip[:])),time,seek,motion_distance_source(profile,name))
}
