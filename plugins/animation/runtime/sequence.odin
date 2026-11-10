package anim

import "mirai:core"
import lib "mirai:std/anim"
import mm "mirai:std/math"

KEYFRAME_PATH_FRAMES :: 16

@(component,description="Moves the entity transform along a sequence of timed keyframes.")
Keyframe_Path :: struct {
    frames:[KEYFRAME_PATH_FRAMES]lib.Transform_Frame `mirai:"hidden"`,
    count:u8 `mirai:"min=1,max=16"`,
    speed:f32,
    loop:lib.Loop,
    playing:bool,
    relative:bool,
}

keyframe_path_default :: proc() -> Keyframe_Path {
    result:=Keyframe_Path{count=2,speed=1,playing=true}
    for &frame in result.frames {frame=lib.TRANSFORM_FRAME_DEFAULT}
    return result
}

Keyframe_Path_Progress :: struct {
    origin:mm.Transform `mirai:"transient"`,
    time:f32 `mirai:"transient"`,
    ended:bool `mirai:"transient"`,
    ready:bool `mirai:"transient"`,
    version:u64 `mirai:"transient"`,
}

Keyframe_Path_Command_Kind :: enum u8 {Play,Pause,Restart,Seek,Speed}
Keyframe_Path_Command :: struct {entity:core.Entity,kind:Keyframe_Path_Command_Kind,value:f32}

@(storage,queue)
Keyframe_Path_Requests :: struct {queue:core.Queue(Keyframe_Path_Command)}

keyframe_path_request :: proc(requests:^Keyframe_Path_Requests,entity:core.Entity,kind:Keyframe_Path_Command_Kind,value:f32=0) {
    if requests==nil {return}
    if entity==core.NONE || kind<.Play || kind>.Speed || !(abs(value)<=max(f32)) {core.refuse(&requests.queue);return}
    core.offer(&requests.queue,Keyframe_Path_Command{entity,kind,value})
}

keyframe_path_frames :: proc(value:^Keyframe_Path) -> []lib.Transform_Frame {
    if value==nil || value.count==0 || int(value.count)>len(value.frames) {return nil}
    return value.frames[:value.count]
}


keyframe_path_evaluate :: proc(animations:^core.Table(Keyframe_Path),progress:^core.Table(Keyframe_Path_Progress),transforms:^core.Table(core.Transform),requests:^Keyframe_Path_Requests,time:core.Time,paces:core.Read(core.Own_Pace)={},clock:=core.CLOCK_DEFAULT) {
    if !(abs(time.dt)<=max(f32)) {return}
    for &value,row in animations.values[:core.count(animations)] {
        e:=animations.entities[row]
        local,has:=core.get(core.read(transforms),e)
        if !has {continue}
        state,exists:=core.get(core.read(progress),e)
        fresh:=!exists || !state.ready
        requested:=false
        for command in requests.queue.items {if command.entity==e {requested=true;break}}
        changed:=fresh || state.version!=core.stamp(animations,row)
        if !changed && !requested && (!value.playing || value.speed==0 || state.ended) {continue}
        frames:=keyframe_path_frames(&value)
        duration,valid:=lib.sequence_duration(frames)
        if !valid || !(abs(value.speed)<=max(f32)) {continue}
        if fresh {
            state={origin=core.to_math(local),time=value.speed<0?duration:0,ready=true}
        }
        speed,playing:=value.speed,value.playing
        sought:=false
        for command in requests.queue.items {
            if command.entity!=e {continue}
            switch command.kind {
            case .Play: playing=true
            case .Pause: playing=false
            case .Speed: speed=command.value
            case .Restart: state.time=speed<0?duration:0;state.ended=false;playing=true;sought=true
            case .Seek: state.time=command.value;state.ended=false;sought=true
            }
        }
        if speed!=value.speed || playing!=value.playing {
            written:=core.edit_at(animations,row)
            written.speed,written.playing=speed,playing
        }
        state.version=core.stamp(animations,row)
        if playing && !sought {
            next:=f64(state.time)+f64(time.dt*core.pace_of(clock,paces,e))*f64(speed)
            if abs(next)>f64(max(f32)) {continue}
            state.time=f32(next)
        }
        if value.loop==.Once {
            state.ended=duration<=0 || speed<0 && state.time<=0 || speed>=0 && state.time>=duration
            state.time=clamp(state.time,0,duration)
        } else {
            period:=lib.loop_period(value.loop,duration)
            if period>0 {state.time=lib.loop_wrap(state.time,period)}
            state.ended=duration<=0
        }
        pose,sampled:=lib.sequence_sample(frames,state.time,value.loop)
        if !sampled {continue}
        if value.relative {pose=mm.transform_compose(state.origin,pose)}
        result:=core.from_math(pose)
        if result!=local {if written:=core.free(transforms,e);written!=nil {written^=result}}
        if !exists {core.add(progress,e,state)} else {old,_:=core.get(core.read(progress),e);if state!=old {core.edit(progress,e)^=state}}
    }
    core.queue_clear(&requests.queue)
    for e in progress.entities[:core.count(progress)] {if !core.has(animations,e) {core.remove(progress,e)}}
}

@(storage,free="keyframe_path_playback_free")
Keyframe_Path_Playback :: struct {states:core.Table(Keyframe_Path_Progress)}

keyframe_path_playback_free :: proc(playback:^Keyframe_Path_Playback) {core.table_destroy(&playback.states)}

keyframe_path_progress :: proc(playback:^Keyframe_Path_Playback,entity:core.Entity) -> (Keyframe_Path_Progress,bool) {
    if playback==nil {return {},false}
    return core.get(core.read(&playback.states),entity)
}

@(step="fixed",stage="apply",before="animation_sample")
keyframe_path_advance :: proc(animations:^core.Table(Keyframe_Path),playback:^Keyframe_Path_Playback,transforms:^core.Table(core.Transform),requests:^Keyframe_Path_Requests,time:core.Time,paces:core.Read(core.Own_Pace),clock:core.Clock,entities:core.Ref(core.Entities)) {
    keyframe_path_evaluate(animations,&playback.states,transforms,requests,time,paces,clock)
    core.table_settle(&playback.states,entities.ptr)
}
