package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

// Seconds of a clip; the zero range is the whole clip.
Time_Range :: struct {start,end:f32}

// The range plays `factor` times faster, or lasts `duration` seconds. Inside
// the clip its speed eases from the speed around it.
Retime :: struct {range:Time_Range,factor,duration:f32}
// The pose at `at` stays for `seconds`, easing into and out of the stop.
Hold :: struct {at,seconds:f32}
// The range (a cycle) repeats after itself for `seconds` more, the root
// carrying on from where each pass leaves it. With frames after the range the
// time rounds to whole passes.
Extend :: struct {range:Time_Range,seconds:f32}
// The regions move `amount` times more around their smoothed motion (0 to 4).
Exaggerate :: struct {amount:f32,regions:Body_Regions,range:Time_Range}
// The regions follow their motion smoothed over up to 0.15 s (amount 0 to 1).
Smooth :: struct {amount:f32,regions:Body_Regions,range:Time_Range}
// The end meets the start in pose and speed, correcting `blend` seconds at
// each end (0 picks a quarter of the clip up to 0.25 s). The root keeps its
// travel and turn.
Make_Loop :: struct {blend:f32}
// A part, or the spine (the region), moves or turns toward a direction of
// the body for the range, fading in and out over `fade` seconds.
Offset_Target :: union {Body_Part,Body_Region}
Offset :: struct {target:Offset_Target,direction:Body_Direction,amount:Body_Amount,range:Time_Range,fade:f32}
// Feet stay where they stand, legs bending (and hips lowering when needed)
// to reach, easing over `blend` seconds at the ends of each contact. The
// contacts are found in the clip, or given by foot and frames in contacts (of
// the clip a retarget was made from, frame by frame), their anchors where the
// feet of this clip stand.
Lock_Feet :: struct {blend:f32,contacts:[]Contact}
// Left becomes right: needs Body_Rig.mirror.
Mirror :: struct {}
// The root joint keeps the rotation about up it has at rest, the rest of the pose as it was: a
// body the clip turns sideways inside faces where it rests. The root joint is the highest of the
// pelvis and its ancestors that the clip turns about up more than FACE_REST_TURN; without one
// the clip stays as it was.
Face_Rest :: struct {}
Clip_Edit :: union {Retime,Hold,Extend,Exaggerate,Smooth,Make_Loop,Offset,Lock_Feet,Mirror,Face_Rest}

Edit_Error :: enum u8 {
    None,
    Invalid_Frames, // not valid frames, or not of the rig
    Invalid_Rig,
    Invalid_Range, // empty, or outside the clip
    Invalid_Amount, // a factor, duration, amount, blend or fade outside its bounds
    Missing_Part, // the body lacks the part in Edit_Result.part
    Missing_Mirror,
    Along_Part, // the part cannot turn toward a direction it already points along
    Too_Long, // more frames than the output takes
    Buffers, // output or scratch of other sizes
    Numeric, // a pose did not compose
}
Edit_Result :: struct {error:Edit_Error,part:Body_Part}
// The shape of the frames an edit gives.
Edit_Layout :: struct {count:int,rate:f32,loop:bool}
// Scratch of an edit: transforms, contacts and heights, as clip_edit_buffers sizes them.
Edit_Buffers :: struct {world:[]math.Transform,contacts:[]Contact,heights:[]f32}

EDIT_MAX_PASSES :: 1<<16
EDIT_MAX_FACTOR :: 100
EDIT_MAX_SECONDS :: 3600

@(private)
edit_range :: proc "contextless" (range:Time_Range,duration,rate:f32) -> (a,b:f32,error:Edit_Error) {
    if range=={} {return 0,duration,.None}
    if !anim_finite(range.start) || !anim_finite(range.end) || range.start<0 || range.end<=range.start || range.start>=duration || range.end>duration+.5/rate {return 0,0,.Invalid_Range}
    return range.start,min(range.end,duration),.None
}
@(private)
edit_seconds_valid :: #force_inline proc "contextless" (seconds:f32) -> bool {return anim_finite(seconds) && seconds>0 && seconds<=EDIT_MAX_SECONDS}

// Seconds the timing edits add or remove, after checking them.
@(private)
edit_timing :: proc "contextless" (edit:Clip_Edit,duration,rate:f32) -> (added:f32,error:Edit_Error) {
    #partial switch e in edit {
    case Retime:
        a,b:=edit_range(e.range,duration,rate) or_return
        length:=edit_retime_length(e,b-a)
        if length<=0 || length>EDIT_MAX_SECONDS {return 0,.Invalid_Amount}
        return length-(b-a),.None
    case Hold:
        if !edit_seconds_valid(e.seconds) || !anim_finite(e.at) || e.at<0 || e.at>duration {return 0,.Invalid_Amount if anim_finite(e.at) && e.at>=0 && e.at<=duration else .Invalid_Range}
        return e.seconds,.None
    case Extend:
        a,b:=edit_range(e.range,duration,rate) or_return
        if !edit_seconds_valid(e.seconds) {return 0,.Invalid_Amount}
        seconds:=edit_extend_seconds(e.seconds,b-a,b<duration)
        if seconds/(b-a)>EDIT_MAX_PASSES {return 0,.Too_Long}
        return seconds,.None
    }
    return 0,.None
}
@(private)
edit_retime_length :: proc "contextless" (e:Retime,length:f32) -> f32 {
    if e.duration!=0 {return e.duration if e.factor==0 && anim_finite(e.duration) && e.duration>0 else -1}
    if !anim_finite(e.factor) || e.factor<=0 || e.factor>EDIT_MAX_FACTOR || e.factor<1.0/EDIT_MAX_FACTOR {return -1}
    return length/e.factor
}
@(private)
edit_extend_seconds :: proc "contextless" (seconds,length:f32,followed:bool) -> f32 {
    if !followed {return seconds}
    return max(cmath.round(seconds/length),1)*length
}

// The frames an edit gives from f: their count and rate, and whether they loop.
clip_edit_layout :: proc "contextless" (edit:Clip_Edit,f:Frames,max_count:int) -> (layout:Edit_Layout,error:Edit_Error) {
    if !frames_valid(f) {return {},.Invalid_Frames}
    duration:=frames_duration(f)
    layout={frames_count(f),f.rate,f.loop}
    if _,is_loop:=edit.(Make_Loop);is_loop {layout.loop=true}
    added:=edit_timing(edit,duration,f.rate) or_return
    if added!=0 {
        count,rate:=frames_layout(duration+added,f.rate,max_count)
        if count==0 {return {},.Too_Long if duration+added>0 else .Invalid_Amount}
        layout.count,layout.rate=count,rate
    }
    if layout.count>max_count {return {},.Too_Long}
    return layout,.None
}

// The scratch an edit needs: transforms of world, contacts and heights.
clip_edit_buffers :: proc "contextless" (edit:Clip_Edit,f:Frames) -> (transforms,contacts,heights:int) {
    #partial switch e in edit {
    case Lock_Feet: return frames_scratch_size(f),max(frames_count(f)+4,len(e.contacts)),2*frames_count(f)
    case Offset,Mirror,Face_Rest: return 2*max(f.bones,0),0,0
    }
    return 0,0,0
}

// Where a moment of the clip lands after a timing edit, for its markers:
// once, or once per pass inside an extended range. Writes as many as fit and
// returns how many there are.
clip_edit_times :: proc "contextless" (edit:Clip_Edit,f:Frames,time:f32,out:[]f32) -> int {
    duration:=frames_duration(f)
    if !anim_finite(time) {return 0}
    put :: proc "contextless" (out:[]f32,count:^int,value:f32) {
        if count^<len(out) {out[count^]=value}
        count^+=1
    }
    count:=0
    #partial switch e in edit {
    case Retime,Hold:
        added,error:=edit_timing(edit,duration,f.rate)
        if error!=.None {return 0}
        // The first new time whose source reaches it.
        low,high:=f32(0),duration+added
        for _ in 0..<48 {
            middle:=(low+high)*.5
            if source,_:=edit_source_time(edit,duration,f.rate,middle);source<time {low=middle} else {high=middle}
        }
        put(out,&count,high)
    case Extend:
        a,b,error:=edit_range(e.range,duration,f.rate)
        if error!=.None || !edit_seconds_valid(e.seconds) {return 0}
        length:=b-a
        seconds:=edit_extend_seconds(e.seconds,length,b<duration)
        if time>b {put(out,&count,time+seconds);break}
        put(out,&count,time)
        if time<a {break}
        for pass:=f32(0);;pass+=1 {
            at:=b+pass*length+(time-a)
            if at>b+seconds || pass>=EDIT_MAX_PASSES {break}
            if at>b {put(out,&count,at)}
        }
    case:
        put(out,&count,time)
    }
    return count
}

// The time of the source a new time samples, and the passes of an extended
// range the root has carried on by.
@(private)
edit_source_time :: proc "contextless" (edit:Clip_Edit,duration,rate:f32,time:f32) -> (source:f32,passes:int) {
    #partial switch e in edit {
    case Retime:
        a,b,_:=edit_range(e.range,duration,rate)
        length:=b-a
        new_length:=edit_retime_length(e,length)
        if time<a {return time,0}
        if time>a+new_length {return time-new_length+length,0}
        // Hermite time: inside the clip the range starts and ends at the speed around it.
        ratio:=new_length/length
        m0:=clamp(ratio,0,3) if a>0 else 1
        m1:=clamp(ratio,0,3) if b<duration else 1
        u:=(time-a)/new_length
        u2,u3:=u*u,u*u*u
        g:=(u3-2*u2+u)*m0+(-2*u3+3*u2)+(u3-u2)*m1
        return a+length*g,0
    case Hold:
        ease:=min(f32(.15),e.seconds/4)
        e0:=min(ease,e.at) if e.at>0 else 0
        e1:=min(ease,duration-e.at) if e.at<duration else 0
        flat_end:=e.at+e.seconds-e1
        switch {
        case time<=e.at-e0: return time,0
        case time<e.at+e0: u:=(time-(e.at-e0))/(2*e0);return e.at-e0+e0*(2*u-u*u),0
        case time<flat_end: return e.at,0
        case time<flat_end+2*e1: u:=(time-flat_end)/(2*e1);return e.at+e1*u*u,0
        }
        return time-e.seconds,0
    case Extend:
        a,b,_:=edit_range(e.range,duration,rate)
        length:=b-a
        seconds:=edit_extend_seconds(e.seconds,length,b<duration)
        if time<=b {return time,0}
        if time>b+seconds {return time-seconds,int(cmath.round(seconds/length))}
        x:=time-b
        pass:=int(x/length)
        return min(a+(x-f32(pass)*length),b),pass+1
    }
    return time,0
}

// Applies an edit to input, writing output, whose rate, count and loop come
// from clip_edit_layout and whose bones and curves are those of input.
// buffers holds what clip_edit_buffers asks. The input stays as it is.
clip_edit :: proc "contextless" (rig:Body_Rig,edit:Clip_Edit,input,output:Frames,buffers:Edit_Buffers) -> Edit_Result {
    if !body_rig_valid(rig) {return {error=.Invalid_Rig}}
    if !frames_valid(input) || input.bones!=len(rig.parents) {return {error=.Invalid_Frames}}
    layout,error:=clip_edit_layout(edit,input,max(int))
    if error!=.None {return {error=error}}
    if output.bones!=input.bones || output.curves!=input.curves || frames_count(output)!=layout.count || output.rate!=layout.rate || output.loop!=layout.loop || len(output.values)!=layout.count*output.curves {return {error=.Buffers}}
    if inertial_buffers_overlap(input.local,output.local) || len(input.values)>0 && inertial_buffers_overlap(input.values,output.values) {return {error=.Buffers}}
    transforms,contacts,heights:=clip_edit_buffers(edit,input)
    if len(buffers.world)<transforms || len(buffers.contacts)<contacts || len(buffers.heights)<heights {return {error=.Buffers}}
    if transforms>0 && inertial_buffers_overlap(buffers.world,output.local) {return {error=.Buffers}}
    switch e in edit {
    case Retime,Hold,Extend: return edit_time(rig,edit,input,output)
    case Exaggerate: return edit_filter(rig,input,output,e.regions,e.range,.12,e.amount,true)
    case Smooth: return edit_filter(rig,input,output,e.regions,e.range,.15*e.amount,e.amount,false)
    case Make_Loop: return edit_loop(rig,e,input,output)
    case Offset: return edit_offset(rig,e,input,output,buffers.world)
    case Lock_Feet: return edit_lock_feet(rig,e,input,output,buffers)
    case Mirror: return edit_mirror(rig,input,output,buffers.world)
    case Face_Rest: return edit_face_rest(rig,input,output,buffers.world)
    }
    return {error=.Invalid_Amount}
}

@(private)
edit_time :: proc "contextless" (rig:Body_Rig,edit:Clip_Edit,input,output:Frames) -> Edit_Result {
    duration:=frames_duration(input)
    root:=frames_root(rig,input)
    // How the root moves over one pass of an extended range.
    cycle:=math.TRANSFORM_IDENTITY
    if e,extend:=edit.(Extend);extend {
        a,b,_:=edit_range(e.range,duration,input.rate)
        start,end:math.Transform
        start,end=edit_sample_bone(input,root,a),edit_sample_bone(input,root,b)
        inverse,ok:=math.transform_inverse(start)
        if !ok {return {error=.Numeric}}
        cycle=math.transform_compose(end,inverse)
        cycle.scale={1,1,1}
    }
    carried,power:=0,math.TRANSFORM_IDENTITY
    output_duration:=frames_duration(output)
    for frame in 0..<frames_count(output) {
        time:=min(f32(frame)/output.rate,output_duration)
        source,passes:=edit_source_time(edit,duration,input.rate,time)
        pose:=frames_pose(output,frame)
        frames_sample(input,source,pose,frames_values(output,frame) if output.curves>0 else nil)
        if passes<carried {carried,power=0,math.TRANSFORM_IDENTITY}
        for carried<passes {power=math.transform_compose(cycle,power);carried+=1}
        if passes>0 {pose[root]=math.transform_compose(power,pose[root])}
        if !anim_transform_valid(pose[root]) {return {error=.Numeric}}
    }
    return {}
}
@(private)
edit_sample_bone :: proc "contextless" (f:Frames,bone:i32,time:f32) -> math.Transform {
    count:=frames_count(f)
    at:=clamp(time*f.rate,0,f32(count-1))
    i:=min(int(at),count-2)
    value:=math.transform_interpolate(frames_pose(f,i)[bone],frames_pose(f,i+1)[bone],at-f32(i))
    value.rotation=linalg.normalize0(value.rotation)
    return value
}

// The weight of an edit over a range at a time: 1 inside, easing to 0 over
// `fade` at the ends that lie inside the clip.
@(private)
edit_weight :: proc "contextless" (a,b,duration,fade,time:f32) -> f32 {
    if time<a-1e-5 || time>b+1e-5 {return 0}
    if fade<=0 {return 1}
    w:=f32(1)
    if a>0 {w=min(w,math.smoothstep(a,a+fade,time))}
    if b<duration {w=min(w,1-math.smoothstep(b-fade,b,time))}
    return w
}

// Whether a bone is inside the regions, by walking up to the bone that
// starts its region (as body_regions decides it).
@(private)
edit_in_regions :: proc "contextless" (parents:[]i32,map_:Body_Map,regions:Body_Regions,bone:i32) -> bool {
    if regions=={} || regions==BODY_REGIONS_ALL {return true}
    pelvis:=map_.bones[.Pelvis]
    neck:=map_.bones[.Neck] if map_.bones[.Neck]>=0 else map_.bones[.Head]
    at:=bone
    for at>=0 {
        region:=-1
        switch {
        case at==map_.bones[.Neck] || map_.bones[.Neck]<0 && at==map_.bones[.Head]: region=int(Body_Region.Head)
        case at==map_.bones[.Clavicle_L] || map_.bones[.Clavicle_L]<0 && at==map_.bones[.Shoulder_L]: region=int(Body_Region.Arm_L)
        case at==map_.bones[.Clavicle_R] || map_.bones[.Clavicle_R]<0 && at==map_.bones[.Shoulder_R]: region=int(Body_Region.Arm_R)
        case at==map_.bones[.Hip_L]: region=int(Body_Region.Leg_L)
        case at==map_.bones[.Hip_R]: region=int(Body_Region.Leg_R)
        case at==pelvis: region=int(Body_Region.Hips)
        case pelvis>=0 && body_is_ancestor(parents,at,pelvis): return at==bone && .Hips in regions
        case pelvis>=0 && neck>=0 && at!=neck && body_is_ancestor(parents,at,neck) && body_is_ancestor(parents,pelvis,at): region=int(Body_Region.Spine)
        }
        if region>=0 {return Body_Region(region) in regions}
        at=parents[at]
    }
    return false
}
@(private)
edit_regions_mapped :: proc "contextless" (map_:Body_Map,regions:Body_Regions) -> (Body_Part,bool) {
    if regions=={} || regions==BODY_REGIONS_ALL {return .Pelvis,true}
    needs:=[Body_Region]Body_Part{.Hips=.Pelvis,.Spine=.Pelvis,.Head=.Head,.Arm_L=.Shoulder_L,.Arm_R=.Shoulder_R,.Leg_L=.Hip_L,.Leg_R=.Hip_R}
    for region in regions {if map_.bones[needs[region]]<0 {return needs[region],false}}
    if .Spine in regions && map_.bones[.Neck]<0 && map_.bones[.Head]<0 {return .Neck,false}
    return .Pelvis,true
}

// A frame of the clip past its ends: in a loop the next or previous pass,
// whose root moved by a pass; else the clip mirrored in time around its end,
// which keeps a steady motion steady.
@(private)
edit_tap :: proc "contextless" (f:Frames,bone,root:i32,frame:int,cycle:math.Transform) -> math.Transform {
    count:=frames_count(f)
    if frame>=0 && frame<count {return frames_pose(f,frame)[bone]}
    if f.loop {
        period:=count-1
        passes:=frame/period if frame>=0 else -((-frame+period-1)/period)
        value:=frames_pose(f,frame-passes*period)[bone]
        if bone!=root {return value}
        step:=cycle
        if passes<0 {inverse,_:=math.transform_inverse(cycle);step=inverse}
        for _ in 0..<abs(passes) {value=math.transform_compose(step,value)}
        return value
    }
    edge,other:=0,-frame
    if frame>=count {edge,other=count-1,2*(count-1)-frame}
    other=clamp(other,0,count-1)
    e,o:=frames_pose(f,edge)[bone],frames_pose(f,other)[bone]
    return {2*e.position-o.position,linalg.normalize0(e.rotation*conj(o.rotation)*e.rotation),2*e.scale-o.scale}
}

// Smooths a motion with a Gaussian of `sigma` seconds and either takes the
// smoothed motion or pushes away from it by amount times the difference
// (exaggerate), easing at the ends of a range.
@(private)
edit_filter :: proc "contextless" (rig:Body_Rig,input,output:Frames,regions:Body_Regions,range:Time_Range,sigma,amount:f32,exaggerate:bool) -> Edit_Result {
    limit:=f32(4) if exaggerate else 1
    if !anim_finite(amount) || amount<=0 || amount>limit {return {error=.Invalid_Amount}}
    if part,mapped:=edit_regions_mapped(rig.body,regions);!mapped {return {error=.Missing_Part,part=part}}
    duration:=frames_duration(input)
    a,b,error:=edit_range(range,duration,input.rate)
    if error!=.None {return {error=error}}
    copy(output.local,input.local);copy(output.values,input.values)
    count:=frames_count(input)
    spread:=sigma*input.rate
    radius:=min(int(cmath.ceil(3*spread)),count-1,512)
    if radius<1 {return {}}
    fade:=min(f32(.1),(b-a)/4) if range!={} else 0
    root:=frames_root(rig,input)
    cycle:=math.TRANSFORM_IDENTITY
    if input.loop {
        inverse,ok:=math.transform_inverse(frames_pose(input,0)[root])
        if !ok {return {error=.Numeric}}
        cycle=math.transform_compose(frames_pose(input,count-1)[root],inverse)
    }
    for bone in 0..<len(rig.parents) {
        if !edit_in_regions(rig.parents,rig.body,regions,i32(bone)) {continue}
        for frame in 0..<count {
            w:=edit_weight(a,b,duration,fade,f32(frame)/input.rate)
            if w<=0 {continue}
            center:=frames_pose(input,frame)[bone]
            position,scale,turn:math.Vec3
            total:f32
            for k in -radius..=radius {
                weight:=cmath.exp(-.5*(f32(k)/spread)*(f32(k)/spread))
                value:=edit_tap(input,i32(bone),root,frame+k,cycle)
                position+=value.position*weight;scale+=value.scale*weight
                turn+=quat_log(conj(center.rotation)*vec4_quat(quat_align(quat_vec4(value.rotation),quat_vec4(center.rotation))))*weight
                total+=weight
            }
            smoothed:=math.Transform{position/total,linalg.normalize0(center.rotation*quat_exp(turn/total)),scale/total}
            out:=&frames_pose(output,frame)[bone]
            if exaggerate {
                push:=amount*w
                out^={center.position+(center.position-smoothed.position)*push,linalg.normalize0(center.rotation*quat_exp(quat_log(edit_relative(smoothed.rotation,center.rotation))*push)),center.scale+(center.scale-smoothed.scale)*push}
            } else {
                out^={center.position+(smoothed.position-center.position)*w,math.quat_slerp(center.rotation,smoothed.rotation,w),center.scale+(smoothed.scale-center.scale)*w}
            }
            if !anim_transform_valid(out^) {return {error=.Numeric}}
        }
    }
    return {}
}
// The turn from a to b in the frame of a, on the short arc.
@(private)
edit_relative :: #force_inline proc "contextless" (a,b:math.Quat) -> math.Quat {
    r:=conj(a)*b
    return -r if r.w<0 else r
}

// Hermite bases on 0..1.
@(private)
edit_h00 :: #force_inline proc "contextless" (u:f32) -> f32 {return 2*u*u*u-3*u*u+1}
@(private)
edit_h10 :: #force_inline proc "contextless" (u:f32) -> f32 {return u*u*u-2*u*u+u}
@(private)
edit_h01 :: #force_inline proc "contextless" (u:f32) -> f32 {return -2*u*u*u+3*u*u}
@(private)
edit_h11 :: #force_inline proc "contextless" (u:f32) -> f32 {return u*u*u-u*u}

// Corrects both ends toward the pose and speed halfway between them, so the
// last frame continues into the first. The root keeps its travel and turn,
// matching only its height and speeds.
@(private)
edit_loop :: proc "contextless" (rig:Body_Rig,e:Make_Loop,input,output:Frames) -> Edit_Result {
    duration:=frames_duration(input)
    count:=frames_count(input)
    blend:=e.blend if e.blend!=0 else min(f32(.25),duration/4)
    if !anim_finite(blend) || blend<0 || blend>duration/2+1e-5 || count<4 {return {error=.Invalid_Amount}}
    window:=min(max(int(cmath.round(blend*input.rate)),1),(count-1)/2)
    span:=f32(window)/input.rate
    copy(output.local,input.local);copy(output.values,input.values)
    root:=frames_root(rig,input)
    up:=frames_up(rig)
    last,rate:=count-1,input.rate
    for bone in 0..<input.bones {
        first,second,before,final:=frames_pose(input,0)[bone],frames_pose(input,1)[bone],frames_pose(input,last-1)[bone],frames_pose(input,last)[bone]
        // Positions and scales meet halfway, the root only in height.
        start_target:=(first.position+final.position)*.5
        end_target:=start_target
        if i32(bone)==root {
            half:=up*linalg.dot(final.position-first.position,up)*.5
            start_target,end_target=first.position+half,final.position-half
        }
        v0,vt:=(second.position-first.position)*rate,(final.position-before.position)*rate
        speed:=(v0+vt)*.5
        scale:=(first.scale+final.scale)*.5
        s0,st:=(second.scale-first.scale)*rate,(final.scale-before.scale)*rate
        scale_speed:=(s0+st)*.5
        // Rotations meet in the turn space of each end; the root keeps its turn.
        w0,wt:=quat_log(edit_relative(first.rotation,second.rotation))*rate,quat_log(edit_relative(before.rotation,final.rotation))*rate
        turn:=(w0+wt)*.5
        r0,rt:math.Vec3
        if i32(bone)!=root {
            middle:=math.quat_slerp(first.rotation,final.rotation,.5)
            r0,rt=quat_log(edit_relative(first.rotation,middle)),quat_log(edit_relative(final.rotation,middle))
        }
        for frame in 0..<count {
            if frame>window && frame<last-window {continue}
            value:=&frames_pose(output,frame)[bone]
            value.position+=edit_loop_delta(frame,window,last,span,start_target-first.position,end_target-final.position,speed-v0,speed-vt)
            value.scale+=edit_loop_delta(frame,window,last,span,scale-first.scale,scale-final.scale,scale_speed-s0,scale_speed-st)
            value.rotation=linalg.normalize0(value.rotation*quat_exp(edit_loop_delta(frame,window,last,span,r0,rt,turn-w0,turn-wt)))
        }
    }
    for curve in 0..<input.curves {
        x0,x1,xp,xt:=frames_values(input,0)[curve],frames_values(input,1)[curve],frames_values(input,last-1)[curve],frames_values(input,last)[curve]
        v0,vt:=(x1-x0)*rate,(xt-xp)*rate
        middle,speed:=(x0+xt)*.5,(v0+vt)*.5
        for frame in 0..<count {
            if frame>window && frame<last-window {continue}
            frames_values(output,frame)[curve]+=edit_loop_delta(frame,window,last,span,middle-x0,middle-xt,speed-v0,speed-vt)
        }
    }
    if !anim_pose_valid(output.local) {return {error=.Numeric}}
    return {}
}

// The correction of a frame inside the window at either end: it reaches the
// value and speed differences at the seam and fades with zero slope inward.
@(private)
edit_loop_delta :: proc "contextless" (frame,window,last:int,span:f32,start_value,end_value,start_speed,end_speed:$T) -> (delta:T) {
    if frame<=window {u:=f32(frame)/f32(window);delta+=start_value*edit_h00(u)+start_speed*(span*edit_h10(u))}
    if frame>=last-window {u:=f32(frame-(last-window))/f32(window);delta+=end_value*edit_h01(u)+end_speed*(span*edit_h11(u))}
    return
}
