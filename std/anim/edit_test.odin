package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

// Runs an edit with the buffers it asks for.
body_test_edit :: proc(rig:Body_Rig,edit:Clip_Edit,input:Frames) -> (Frames,Edit_Result) {
    layout,error:=clip_edit_layout(edit,input,1<<20)
    if error!=.None {return {},{error=error}}
    output:=Frames{rate=layout.rate,bones=input.bones,curves=input.curves,loop=layout.loop,local=make([]math.Transform,layout.count*input.bones,context.temp_allocator),values=make([]math.Vec4,layout.count*input.curves,context.temp_allocator)}
    transforms,contacts,heights:=clip_edit_buffers(edit,input)
    buffers:=Edit_Buffers{make([]math.Transform,transforms,context.temp_allocator),make([]Contact,contacts,context.temp_allocator),make([]f32,heights,context.temp_allocator)}
    return output,clip_edit(rig,edit,input,output,buffers)
}
body_test_close :: proc(a,b:math.Transform,tolerance:f32=1e-4) -> bool {
    return linalg.length(a.position-b.position)<=tolerance && math.quat_angle(a.rotation,b.rotation)<=tolerance*10 && linalg.length(a.scale-b.scale)<=tolerance
}
body_test_world :: proc(rig:Body_Rig,f:Frames,frame:int) -> []math.Transform {
    world:=make([]math.Transform,f.bones,context.temp_allocator)
    pose_world(rig.parents,frames_pose(f,frame),world)
    return world
}

@(test)
retime_hold_and_extend_move_time_and_carry_the_root :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    walk,rig:=body_test_walk(test_rig,map_,{root_motion=true,loop=true})
    root:=body_test_bone(test_rig,"root")

    slow,result:=body_test_edit(rig,Retime{duration=2},walk)
    if !testing.expect_value(t,result.error,Edit_Error.None) {return}
    testing.expect_value(t,frames_count(slow),121)
    testing.expect(t,slow.loop && abs(frames_duration(slow)-2)<1e-5)
    testing.expect(t,body_test_close(frames_pose(slow,60)[root],frames_pose(walk,30)[root]))
    testing.expect(t,body_test_close(frames_pose(slow,120)[root],frames_pose(walk,60)[root]))
    times:[4]f32
    testing.expect(t,clip_edit_times(Retime{duration=2},walk,.5,times[:])==1 && abs(times[0]-1)<1e-4)

    // Twice as fast in the middle: the ends keep their speed and the range eases.
    fast,_:=body_test_edit(rig,Retime{range={.25,.75},factor=2},walk)
    testing.expect(t,abs(frames_duration(fast)-.75)<1e-5)
    testing.expect(t,body_test_close(frames_pose(fast,6)[root],frames_pose(walk,6)[root]))
    testing.expect(t,body_test_close(frames_pose(fast,30)[root],frames_pose(walk,45)[root],1e-3))
    testing.expect(t,clip_edit_times(Retime{range={.25,.75},factor=2},walk,.9,times[:])==1 && abs(times[0]-.65)<1e-3)
    previous:=f32(1)
    for frame in 0..<frames_count(fast) {
        z:=frames_pose(fast,frame)[root].position.z
        testing.expect(t,z<=previous+1e-5)
        previous=z
    }

    held,_:=body_test_edit(rig,Hold{at=.5,seconds=1},walk)
    testing.expect(t,abs(frames_duration(held)-2)<1e-5)
    for frame in 40..=80 {testing.expect(t,body_test_close(frames_pose(held,frame)[root],frames_pose(walk,30)[root],1e-3))}
    testing.expect(t,body_test_close(frames_pose(held,108)[root],frames_pose(walk,48)[root],1e-3))

    // Two more passes of the cycle: the root carries on over the ground.
    long,_:=body_test_edit(rig,Extend{seconds=2},walk)
    testing.expect(t,abs(frames_duration(long)-3)<1e-5)
    testing.expectf(t,abs(frames_pose(long,150)[root].position.z+2)<1e-3,"root at %v",frames_pose(long,150)[root].position)
    metrics:=body_test_metrics(rig,long)
    testing.expect(t,abs(metrics.travel.z+.8)<.01 && metrics.foot_slide[.Left].mean<.03)
    testing.expect_value(t,clip_edit_times(Extend{seconds=2},walk,.25,times[:]),3)
    testing.expect(t,abs(times[1]-1.25)<1e-4 && abs(times[2]-2.25)<1e-4)
    // With frames after the range, the time rounds to whole passes.
    layout,_:=clip_edit_layout(Extend{range={0,.5},seconds=.7},walk,1<<20)
    testing.expect_value(t,layout.count,91)

    _,result=body_test_edit(rig,Retime{factor=-1},walk);testing.expect_value(t,result.error,Edit_Error.Invalid_Amount)
    _,result=body_test_edit(rig,Retime{factor=2,duration=1},walk);testing.expect_value(t,result.error,Edit_Error.Invalid_Amount)
    _,result=body_test_edit(rig,Retime{range={.8,.2},factor=2},walk);testing.expect_value(t,result.error,Edit_Error.Invalid_Range)
    _,result=body_test_edit(rig,Hold{at=3,seconds=1},walk);testing.expect_value(t,result.error,Edit_Error.Invalid_Range)
    _,result=body_test_edit(rig,Extend{seconds=cmath.inf_f32(1)},walk);testing.expect_value(t,result.error,Edit_Error.Invalid_Amount)
    _,error:=clip_edit_layout(Retime{duration=2},walk,100);testing.expect_value(t,error,Edit_Error.Too_Long)
}

@(test)
smooth_exaggerate_and_make_loop_change_jerk_amplitude_and_seam :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    shaky,rig:=body_test_walk(test_rig,map_,{root_motion=true,loop=true,jitter=.01})
    smooth,result:=body_test_edit(rig,Smooth{amount=.5},shaky)
    if !testing.expect_value(t,result.error,Edit_Error.None) {return}
    before,after:=body_test_metrics(rig,shaky),body_test_metrics(rig,smooth)
    testing.expectf(t,after.jerk.mean<before.jerk.mean/4,"jerk %v to %v",before.jerk,after.jerk)
    testing.expectf(t,abs(after.travel.z+.8)<.01 && after.seam_position<.02,"travel %v seam %v",after.travel,after.seam_position)

    // Only the arms: the legs keep their noise.
    arms,_:=body_test_edit(rig,Smooth{amount=1,regions={.Arm_L,.Arm_R}},shaky)
    knee:=map_.bones[.Knee_L]
    for frame in 0..<frames_count(shaky) {testing.expect(t,frames_pose(arms,frame)[knee]==frames_pose(shaky,frame)[knee])}

    clean,_:=body_test_walk(test_rig,map_,{root_motion=true,loop=true})
    bold,_:=body_test_edit(rig,Exaggerate{amount=1,regions={.Leg_L,.Leg_R}},clean)
    foot:=map_.bones[.Foot_L]
    highest :: proc(rig:Body_Rig,f:Frames,bone:i32) -> (high:f32) {
        for frame in 0..<frames_count(f) {high=max(high,body_test_world(rig,f,frame)[bone].position.y)}
        return
    }
    testing.expectf(t,highest(rig,bold,foot)>highest(rig,clean,foot)+.01,"foot %v against %v",highest(rig,bold,foot),highest(rig,clean,foot))
    _,result=body_test_edit(rig,Exaggerate{amount=0},clean);testing.expect_value(t,result.error,Edit_Error.Invalid_Amount)
    _,result=body_test_edit(rig,Smooth{amount=2},clean);testing.expect_value(t,result.error,Edit_Error.Invalid_Amount)
    armless:=rig;armless.body.bones[.Shoulder_L]=-1
    _,result=body_test_edit(armless,Smooth{amount=.5,regions={.Arm_L}},clean)
    testing.expect(t,result.error==.Missing_Part && result.part==.Shoulder_L)

    cut,_:=body_test_walk(test_rig,map_,{root_motion=true,duration=.75})
    looped,looped_result:=body_test_edit(rig,Make_Loop{},cut)
    testing.expect_value(t,looped_result.error,Edit_Error.None)
    open,closed:=body_test_metrics(rig,cut),body_test_metrics(rig,looped)
    testing.expect(t,looped.loop)
    testing.expectf(t,closed.seam_position<.005 && closed.seam_position<open.seam_position/20,"seam %v to %v",open.seam_position,closed.seam_position)
    testing.expectf(t,closed.seam_velocity<open.seam_velocity/2,"seam speed %v to %v",open.seam_velocity,closed.seam_velocity)
    testing.expectf(t,abs(closed.travel.z-open.travel.z)<.01,"travel %v to %v",open.travel,closed.travel)
    _,result=body_test_edit(rig,Make_Loop{blend=.5},cut);testing.expect_value(t,result.error,Edit_Error.Invalid_Amount)
}

@(test)
offset_moves_and_turns_parts_toward_body_directions :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    walk,rig:=body_test_walk(test_rig,map_,{loop=true})
    height:=body_height(map_,test_rig.world)
    head,pelvis,hand,foot_l,foot_r,knee:=map_.bones[.Head],map_.bones[.Pelvis],map_.bones[.Hand_R],map_.bones[.Foot_L],map_.bones[.Foot_R],map_.bones[.Knee_L]

    turned,result:=body_test_edit(rig,Offset{target=Body_Part.Head,direction=.Left,amount=.Medium},walk)
    if !testing.expect_value(t,result.error,Edit_Error.None) {return}
    for frame in ([3]int{0,20,60}) {
        before,after:=body_test_world(rig,walk,frame),body_test_world(rig,turned,frame)
        a,b:=math.quat_forward(before[head].rotation),math.quat_forward(after[head].rotation)
        testing.expectf(t,abs(anim_angle(a,b)-15*math.RAD_PER_DEG)<1e-3 && b.x<a.x,"head %v to %v",a,b)
    }

    lowered,_:=body_test_edit(rig,Offset{target=Body_Part.Pelvis,direction=.Down,amount=.Medium},walk)
    for frame in ([3]int{0,15,45}) {
        before,after:=body_test_world(rig,walk,frame),body_test_world(rig,lowered,frame)
        testing.expect(t,abs(before[pelvis].position.y-after[pelvis].position.y-.05*height)<1e-4)
        testing.expect(t,linalg.length(before[foot_l].position-after[foot_l].position)<1e-3 && linalg.length(before[foot_r].position-after[foot_r].position)<1e-3)
    }

    raised,_:=body_test_edit(rig,Offset{target=Body_Part.Hand_R,direction=.Left,amount=.Strong,range={.2,.8}},walk)
    middle,outside:=30,3
    before,after:=body_test_world(rig,walk,middle),body_test_world(rig,raised,middle)
    testing.expectf(t,abs(after[hand].position.x-before[hand].position.x+.1*height)<1e-3 && abs(after[hand].position.y-before[hand].position.y)<1e-3,"hand %v to %v",before[hand].position,after[hand].position)
    testing.expect(t,math.quat_angle(before[hand].rotation,after[hand].rotation)<1e-3)
    testing.expect(t,frames_pose(raised,outside)[hand]==frames_pose(walk,outside)[hand])

    leaning,_:=body_test_edit(rig,Offset{target=Body_Region.Spine,direction=.Forward,amount=.Strong},walk)
    testing.expect(t,body_test_world(rig,leaning,0)[head].position.z<body_test_world(rig,walk,0)[head].position.z-.1)

    knee_out,_:=body_test_edit(rig,Offset{target=Body_Part.Knee_L,direction=.Left,amount=.Medium},walk)
    before,after=body_test_world(rig,walk,10),body_test_world(rig,knee_out,10)
    testing.expect(t,after[knee].position.x<before[knee].position.x-.01 && linalg.length(after[foot_l].position-before[foot_l].position)<1e-3)

    _,result=body_test_edit(rig,Offset{target=Body_Part.Shoulder_L,direction=.Left,amount=.Strong},walk)
    testing.expect_value(t,result.error,Edit_Error.Along_Part)
    handless:=rig;handless.body.bones[.Hand_R]=-1
    _,result=body_test_edit(handless,Offset{target=Body_Part.Hand_R,direction=.Up,amount=.Slight},walk)
    testing.expect(t,result.error==.Missing_Part && result.part==.Hand_R)
    _,result=body_test_edit(rig,Offset{target=Body_Region.Arm_L,direction=.Up,amount=.Slight},walk)
    testing.expect_value(t,result.error,Edit_Error.Invalid_Amount)
    _,result=body_test_edit(rig,Offset{target=Body_Part.Head,direction=.Up,amount=.Slight,range={.2,.4},fade=.5},walk)
    testing.expect_value(t,result.error,Edit_Error.Invalid_Amount)
}

@(test)
lock_feet_and_mirror_fix_sliding_and_swap_sides :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    sliding,rig:=body_test_walk(test_rig,map_,{root_motion=true,loop=true,slide=.15})
    locked,result:=body_test_edit(rig,Lock_Feet{},sliding)
    if !testing.expect_value(t,result.error,Edit_Error.None) {return}
    before,after:=body_test_metrics(rig,sliding),body_test_metrics(rig,locked)
    testing.expectf(t,after.foot_slide[.Left].mean<before.foot_slide[.Left].mean/4,"slide %v to %v",before.foot_slide[.Left],after.foot_slide[.Left])
    // Locked feet do not make the body shake: the hips ease as the feet reach.
    testing.expectf(t,after.jerk.mean<before.jerk.mean*1.5+20,"jerk %v to %v",before.jerk,after.jerk)
    for stat in after.limits {testing.expect_value(t,stat.frames,i32(0))}

    in_place,_:=body_test_walk(test_rig,map_,{loop=true,slide=.15})
    locked,_=body_test_edit(rig,Lock_Feet{},in_place)
    before,after=body_test_metrics(rig,in_place),body_test_metrics(rig,locked)
    testing.expectf(t,after.foot_slide[.Left].mean<before.foot_slide[.Left].mean/2,"in place slide %v to %v",before.foot_slide[.Left],after.foot_slide[.Left])

    // Contacts given by foot and frames lock as those found, with their anchors placed where the
    // feet of the clip stand; frames outside the clip are refused.
    contacts:=make([]Contact,32,context.temp_allocator)
    measured,measured_ok:=clip_metrics(rig,sliding,{contacts=contacts},make([]math.Transform,frames_scratch_size(sliding),context.temp_allocator))
    if !testing.expect(t,measured_ok && measured.contacts>0 && measured.contacts<=len(contacts)) {return}
    given:=contacts[:measured.contacts]
    for &contact in given {contact.anchors={}}
    found,_:=body_test_edit(rig,Lock_Feet{},sliding)
    placed,placed_result:=body_test_edit(rig,Lock_Feet{contacts=given},sliding)
    testing.expect_value(t,placed_result.error,Edit_Error.None)
    for value,i in placed.local {testing.expect(t,body_test_close(value,found.local[i]))}
    given[0].last=i32(frames_count(sliding))
    _,placed_result=body_test_edit(rig,Lock_Feet{contacts=given},sliding)
    testing.expect_value(t,placed_result.error,Edit_Error.Invalid_Range)

    _,result=body_test_edit(rig,Mirror{},sliding);testing.expect_value(t,result.error,Edit_Error.Missing_Mirror)
    n:=len(rig.parents)
    pairs:=make([]i32,n,context.temp_allocator)
    for name,i in test_rig.names {
        pairs[i]=i32(i)
        buffer:[64]u8
        other,sided:=mirror_name(name,buffer[:])
        if !sided {continue}
        for candidate,j in test_rig.names {if candidate==other {pairs[i]=i32(j)}}
    }
    corrections:=make([]math.Quat,n,context.temp_allocator)
    scratch:=make([]math.Transform,n,context.temp_allocator)
    plane,prepared:=mirror_prepare(rig.parents,pairs,rig.rest,corrections,scratch)
    if !testing.expect(t,prepared) {return}
    rig.mirror={pairs,corrections,plane}
    mirrored,mirror_result:=body_test_edit(rig,Mirror{},sliding)
    testing.expect_value(t,mirror_result.error,Edit_Error.None)
    swapped:=body_test_metrics(rig,mirrored)
    testing.expectf(t,abs(swapped.foot_slide[.Right].mean-.15)<.03 && swapped.foot_slide[.Left].mean<.03,"mirrored slides %v",swapped.foot_slide)
    again,_:=body_test_edit(rig,Mirror{},mirrored)
    for frame in 0..<frames_count(sliding) {
        for value,bone in frames_pose(sliding,frame) {testing.expect(t,body_test_close(value,frames_pose(again,frame)[bone],1e-3))}
    }

    footless:=rig;footless.body.bones[.Foot_L]=-1;footless.body.bones[.Foot_R]=-1
    _,result=body_test_edit(footless,Lock_Feet{},sliding)
    testing.expect(t,result.error==.Missing_Part)
}

@(test)
clip_edit_rejects_buffers_and_frames_that_do_not_fit :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    walk,rig:=body_test_walk(test_rig,map_,{loop=true})
    output:=Frames{rate=walk.rate,bones=walk.bones,loop=walk.loop,local=make([]math.Transform,len(walk.local),context.temp_allocator)}
    testing.expect_value(t,clip_edit(rig,Smooth{amount=.5},walk,output,{}).error,Edit_Error.None)
    testing.expect_value(t,clip_edit(rig,Smooth{amount=.5},walk,walk,{}).error,Edit_Error.Buffers)
    testing.expect_value(t,clip_edit(rig,Lock_Feet{},walk,output,{}).error,Edit_Error.Buffers)
    testing.expect_value(t,clip_edit(rig,Retime{duration=2},walk,output,{}).error,Edit_Error.Buffers)
    short:=output;short.local=short.local[:walk.bones*3]
    testing.expect_value(t,clip_edit(rig,Smooth{amount=.5},walk,short,{}).error,Edit_Error.Buffers)
    broken:=walk;broken.rate=cmath.nan_f32()
    testing.expect_value(t,clip_edit(rig,Smooth{amount=.5},broken,output,{}).error,Edit_Error.Invalid_Frames)
    wrong:=rig;wrong.root=9999
    testing.expect_value(t,clip_edit(wrong,Smooth{amount=.5},walk,output,{}).error,Edit_Error.Invalid_Rig)
    testing.expect_value(t,clip_edit(rig,nil,walk,output,{}).error,Edit_Error.Invalid_Amount)
}

@(private="file") EDIT_HOSTILE_ROUNDS :: #config(ANIM_HOSTILE_ROUNDS,400)

@(test)
hostile_edits_metrics_and_detection_return :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    walk,rig:=body_test_walk(test_rig,map_,{loop=true,duration=.25})
    state:=u64(99)
    next :: proc(state:^u64) -> u64 {state^=state^*6364136223846793005+1442695040888963407;return state^>>33}
    number :: proc(state:^u64) -> f32 {
        switch next(state)%10 {
        case 0: return cmath.nan_f32()
        case 1: return cmath.inf_f32(1)
        case 2: return -1
        case 3: return 0
        case 4: return 1e30
        }
        return f32(next(state)%400)/100
    }
    for _ in 0..<EDIT_HOSTILE_ROUNDS {
        range:=Time_Range{number(&state),number(&state)}
        edit:Clip_Edit
        switch next(&state)%10 {
        case 0: edit=Retime{range,number(&state),number(&state)}
        case 1: edit=Hold{number(&state),number(&state)}
        case 2: edit=Extend{range,number(&state)}
        case 3: edit=Exaggerate{number(&state),transmute(Body_Regions)u8(next(&state)),range}
        case 4: edit=Smooth{number(&state),transmute(Body_Regions)u8(next(&state)),range}
        case 5: edit=Make_Loop{number(&state)}
        case 6: edit=Offset{Body_Part(next(&state)%20),Body_Direction(next(&state)%7),Body_Amount(next(&state)%4),range,number(&state)}
        case 7: edit=Lock_Feet{blend=number(&state)}
        case 8: edit=Mirror{}
        case 9: edit=Face_Rest{}
        }
        layout,error:=clip_edit_layout(edit,walk,4096)
        if error!=.None {continue}
        output:=Frames{rate=layout.rate,bones=walk.bones,loop=layout.loop,local=make([]math.Transform,layout.count*walk.bones,context.temp_allocator)}
        transforms,contacts,heights:=clip_edit_buffers(edit,walk)
        clip_edit(rig,edit,walk,output,{make([]math.Transform,transforms,context.temp_allocator),make([]Contact,contacts,context.temp_allocator),make([]f32,heights,context.temp_allocator)})
        times:[4]f32
        clip_edit_times(edit,walk,number(&state),times[:])
        broken:=rig;broken.body.bones[Body_Part(next(&state)%19)]=i32(next(&state)%200)-50
        scratch:=make([]math.Transform,frames_scratch_size(walk),context.temp_allocator)
        clip_metrics(broken,walk,{},scratch)
        free_all(context.temp_allocator)
        test_rig,map_=body_test_detected()
        walk,rig=body_test_walk(test_rig,map_,{loop=true,duration=.25})
    }
    testing.expect(t,true)
}

@(test)
face_rest_turns_the_root_back_to_its_rest_facing :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    walk,rig:=body_test_walk(test_rig,map_,{loop=true})
    root,pelvis:=body_test_bone(test_rig,"root"),map_.bones[.Pelvis]
    // Turned sideways at its root, as a 2.5D game turns its body inside the clip, with a sway of
    // the pelvis of its own.
    sideways:=math.quat_axis_angle({0,1,0},cmath.PI/2)
    for frame in 0..<frames_count(walk) {
        pose:=frames_pose(walk,frame)
        pose[root].rotation=sideways*pose[root].rotation
        pose[pelvis].rotation=math.quat_axis_angle({0,1,0},.1*cmath.sin(f32(frame)/10))*pose[pelvis].rotation
    }
    turned:=body_test_metrics(rig,walk)
    testing.expectf(t,abs(abs(turned.travel.x)-.8)<.05,"turned walk travels %v",turned.travel)
    faced,result:=body_test_edit(rig,Face_Rest{},walk)
    if !testing.expect_value(t,result.error,Edit_Error.None) {return}
    metrics:=body_test_metrics(rig,faced)
    testing.expectf(t,abs(metrics.travel.z+.8)<.05 && abs(metrics.travel.x)<.05,"faced walk travels %v",metrics.travel)
    for frame in 0..<frames_count(walk) {
        testing.expect(t,math.quat_angle(frames_pose(faced,frame)[root].rotation,rig.rest[root].rotation)<1e-4)
        for value,bone in frames_pose(walk,frame) {if i32(bone)!=root {testing.expect(t,body_test_close(value,frames_pose(faced,frame)[bone]))}}
    }
    // Turned sideways above the root while the root turns back toward a camera on top, as a stop
    // of a 2.5D game does: the root faces its rest every frame and the pelvis keeps its sway.
    split:=Frames{rate=walk.rate,bones=walk.bones,curves=walk.curves,loop=walk.loop,local=make([]math.Transform,len(walk.local),context.temp_allocator),values=walk.values}
    copy(split.local,walk.local)
    top:=body_test_bone(test_rig,"Skeleton")
    count:=frames_count(split)
    for frame in 0..<count {
        pose:=frames_pose(split,frame)
        pose[top].rotation=sideways*pose[top].rotation
        pose[root].rotation=math.quat_axis_angle({0,1,0},-cmath.PI/2*f32(frame)/f32(count-1))*rig.rest[root].rotation
    }
    stopped,split_result:=body_test_edit(rig,Face_Rest{},split)
    if !testing.expect_value(t,split_result.error,Edit_Error.None) {return}
    world:=make([]math.Transform,split.bones,context.temp_allocator)
    rest_world:=make([]math.Transform,split.bones,context.temp_allocator)
    pose_world(rig.parents,rig.rest,rest_world)
    for frame in 0..<count {
        pose_world(rig.parents,frames_pose(stopped,frame),world)
        testing.expectf(t,math.quat_angle(world[root].rotation,rest_world[root].rotation)<1e-3,"frame %d: the root turns %v from its rest",frame,math.quat_angle(world[root].rotation,rest_world[root].rotation))
        testing.expect(t,body_test_close(frames_pose(split,frame)[pelvis],frames_pose(stopped,frame)[pelvis]))
    }
    // Nothing turned: the clip stays as it was. Without a pelvis there is no root joint to find.
    again,_:=body_test_edit(rig,Face_Rest{},faced)
    for frame in 0..<frames_count(faced) {
        for value,bone in frames_pose(faced,frame) {testing.expect(t,body_test_close(value,frames_pose(again,frame)[bone]))}
    }
    headless:=rig;headless.body.bones[.Pelvis]=-1
    _,result=body_test_edit(headless,Face_Rest{},walk)
    testing.expect(t,result.error==.Missing_Part && result.part==.Pelvis)
}
