package mirai_net

import "base:runtime"
import "core:math"
import "core:mem"
import mm "mirai:std/math"

// Hides corrections from the eye: when the simulated pose jumps, the offset
// to where it was shown is kept and fades out, while the simulation itself
// stays exactly where the correction put it.
Smoothing :: struct {
    offset:[3]f32,
    rotation:quaternion128,
    half_life:f32,     // seconds for an error to halve, default 0.08
    snap_distance:f32, // meters beyond which the error is not smoothed, default 4
}

smoothing_init :: proc "contextless" (s:^Smoothing,half_life:f32=0.08,snap_distance:f32=4) {
    s^={rotation=quaternion(w=1,x=0,y=0,z=0),half_life=half_life,snap_distance=snap_distance}
}
// The simulated pose went from before to after without the object having moved: a correction.
smoothing_correct :: proc "contextless" (s:^Smoothing,before_position,after_position:[3]f32,before_rotation,after_rotation:quaternion128) {
    s.offset+=before_position-after_position
    s.rotation=s.rotation*before_rotation*conj(after_rotation)
    if s.offset.x*s.offset.x+s.offset.y*s.offset.y+s.offset.z*s.offset.z>s.snap_distance*s.snap_distance {
        s.offset,s.rotation={},quaternion(w=1,x=0,y=0,z=0)
    }
}
smoothing_update :: proc "contextless" (s:^Smoothing,dt:f32) {
    keep:=s.half_life>0?math.pow(0.5,dt/s.half_life):0
    s.offset*=keep
    s.rotation=mm.quat_nlerp(1,s.rotation,keep)
}
// Where to draw an object whose simulated pose is position and rotation.
smoothing_apply :: proc "contextless" (s:^Smoothing,position:[3]f32,rotation:quaternion128) -> ([3]f32,quaternion128) {
    return position+s.offset,s.rotation*rotation
}

// Snapshots of remote objects by server tick, to draw them between two known
// states a little behind the newest one instead of jumping when one arrives.
Interpolation_Desc :: struct {
    state_size:int,
    capacity:int, // objects
    depth:int,    // snapshots kept per object, default 8
    allocator:runtime.Allocator,
}
Interpolation_Status :: enum u8 {
    Empty,
    Between, // a and b surround the tick: blend with alpha
    Before,  // the tick is older than everything kept: a and b are the oldest
    After,   // newer than everything kept: a and b are the newest, and alpha is how many ticks past it the tick is
}
Interpolation :: struct {
    desc:Interpolation_Desc,
    data:[]u8,
    ticks:[]u32,
    spacing:[]f32, // per slot: ticks between its snapshots
    head,count:[]u8,
    used:[]bool,
    free:[]u32,
    free_count:int,
}

interpolation_init :: proc(i:^Interpolation,desc:Interpolation_Desc) -> Error {
    i^={desc=desc}
    d:=&i.desc
    if d.state_size<=0 || d.capacity<=0 {return .Invalid}
    d.depth=d.depth<=0?8:min(d.depth,255)
    if d.allocator.procedure==nil {d.allocator=context.allocator}
    error:mem.Allocator_Error
    if i.data,error=make([]u8,d.capacity*d.depth*d.state_size,d.allocator);error!=nil {return .Out_Of_Memory}
    if i.ticks,error=make([]u32,d.capacity*d.depth,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.spacing,error=make([]f32,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.head,error=make([]u8,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.count,error=make([]u8,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.used,error=make([]bool,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.free,error=make([]u32,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    for &slot,index in i.free {slot=u32(d.capacity-1-index)}
    i.free_count=d.capacity
    return .None
}
interpolation_destroy :: proc(i:^Interpolation) {
    a:=i.desc.allocator
    delete(i.data,a);delete(i.ticks,a);delete(i.spacing,a);delete(i.head,a);delete(i.count,a);delete(i.used,a);delete(i.free,a)
    i^={}
}
// Takes a slot for one object. ok is false when every slot is taken.
interpolation_add :: proc(i:^Interpolation) -> (slot:int,ok:bool) {
    if i.free_count==0 {return -1,false}
    i.free_count-=1
    slot=int(i.free[i.free_count])
    i.used[slot],i.head[slot],i.count[slot],i.spacing[slot]=true,0,0,0
    return slot,true
}
interpolation_remove :: proc(i:^Interpolation,slot:int) {
    if slot<0 || slot>=len(i.used) || !i.used[slot] {return}
    i.used[slot]=false
    i.free[i.free_count]=u32(slot)
    i.free_count+=1
}
// Forgets the snapshots of a slot, as after a teleport.
interpolation_clear :: proc(i:^Interpolation,slot:int) {
    if slot>=0 && slot<len(i.used) {i.head[slot],i.count[slot],i.spacing[slot]=0,0,0}
}
// Adds the state of a tick. Snapshots that are not newer than the last one are ignored.
interpolation_push :: proc(i:^Interpolation,slot:int,tick:u32,state:[]u8) -> bool {
    d:=&i.desc
    if slot<0 || slot>=len(i.used) || !i.used[slot] || len(state)!=d.state_size {return false}
    count,head:=int(i.count[slot]),int(i.head[slot])
    if count>0 {
        gap:=i32(tick-i.ticks[slot*d.depth+(head+count-1)%d.depth])
        if gap<=0 {return false}
        // A longer gap counts at once, a shorter one slowly: the states of an object may come less often for a while.
        spacing:=&i.spacing[slot]
        spacing^=f32(gap)>spacing^?f32(gap):spacing^+(f32(gap)-spacing^)*0.125
    }
    at:=(head+count)%d.depth
    if count==d.depth {i.head[slot]=u8((head+1)%d.depth)} else {i.count[slot]+=1}
    i.ticks[slot*d.depth+at]=tick
    copy(i.data[(slot*d.depth+at)*d.state_size:][:d.state_size],state)
    return true
}
// The two snapshots around a tick with fraction and how far between them it lies.
interpolation_sample :: proc(i:^Interpolation,slot:int,tick:f64) -> (a,b:[]u8,alpha:f32,status:Interpolation_Status) {
    d:=&i.desc
    if slot<0 || slot>=len(i.used) || !i.used[slot] || i.count[slot]==0 {return}
    count,head:=int(i.count[slot]),int(i.head[slot])
    entry :: proc(i:^Interpolation,slot,at:int) -> ([]u8,u32) {
        d:=&i.desc
        return i.data[(slot*d.depth+at)*d.state_size:][:d.state_size],i.ticks[slot*d.depth+at]
    }
    newest,newest_tick:=entry(i,slot,(head+count-1)%d.depth)
    oldest,oldest_tick:=entry(i,slot,head)
    behind:=f64(newest_tick)-tick
    if behind<=0 {return newest,newest,f32(-behind),.After}
    if behind>=f64(newest_tick-oldest_tick) {return oldest,oldest,0,.Before}
    for k:=count-1;k>0;k-=1 {
        later,later_tick:=entry(i,slot,(head+k)%d.depth)
        earlier,earlier_tick:=entry(i,slot,(head+k-1)%d.depth)
        span:=f64(later_tick-earlier_tick)
        back:=f64(newest_tick-later_tick)
        if behind<=back+span {return earlier,later,f32(1-(behind-back)/span),.Between}
    }
    return oldest,oldest,0,.Before
}

// The newest snapshot of a slot and its tick; ok is false while it has none.
interpolation_newest :: proc(i:^Interpolation,slot:int) -> (state:[]u8,tick:u32,ok:bool) {
    d:=&i.desc
    if slot<0 || slot>=len(i.used) || !i.used[slot] || i.count[slot]==0 {return}
    at:=slot*d.depth+(int(i.head[slot])+int(i.count[slot])-1)%d.depth
    return i.data[at*d.state_size:][:d.state_size],i.ticks[at],true
}
// Ticks between the snapshots of a slot: at once the longest gap, and slowly a shorter one. 0 before the second.
interpolation_spacing :: proc(i:^Interpolation,slot:int) -> f32 {
    if slot<0 || slot>=len(i.used) || !i.used[slot] {return 0}
    return i.spacing[slot]
}
