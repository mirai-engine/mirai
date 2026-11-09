package mirai_anim

import cmath "core:math"
import "core:testing"
import math "mirai:std/math"

Body_Test_Walk :: struct {
    root_motion,backward_knees,loop:bool,
    duration:f32, // 1 s when zero: one cycle
    slide:f32, // m/s the left foot drifts toward -Z while it stands
    sink:f32, // m the feet go under the floor while they stand
    jitter:f32, // m of noise on the pelvis
    clearance:f32, // m the foot rises while it swings; 0.1 when zero
    // m/s each foot pushes back at for .3 of the cycle, touching the floor only halfway through,
    // in the air the rest: a run with a flight phase whose feet never stand
    run:f32,
}

// The humanoid walking toward -Z at 0.8 m/s, a cycle a second, its legs posed by IK.
body_test_walk :: proc(rig:Body_Test_Rig,map_:Body_Map,options:Body_Test_Walk) -> (Frames,Body_Rig) {
    rate:=f32(60)
    duration:=options.duration if options.duration>0 else 1
    count:=int(cmath.round(duration*rate))+1
    n:=len(rig.parents)
    frames:=Frames{rate=rate,bones=n,loop=options.loop,local=make([]math.Transform,count*n,context.temp_allocator)}
    names:=make([]u64,n,context.temp_allocator)
    for &name,i in names {name=u64(i+1)}
    skeleton:=Skeleton{rig.parents,names,rig.rest}
    world:=make([]math.Transform,n,context.temp_allocator)
    rest_world:=make([]math.Transform,n,context.temp_allocator)
    pose_world(rig.parents,rig.rest,rest_world)
    root,pelvis:=body_test_bone(rig,"root"),map_.bones[.Pelvis]
    state:=u64(12345)
    noise :: proc(state:^u64) -> f32 {state^=state^*6364136223846793005+1442695040888963407;return f32(state^>>40)/f32(1<<24)*2-1}
    speed:=f32(.8)
    for frame in 0..<count {
        t:=f32(frame)/rate
        pose:=frames_pose(frames,frame)
        copy(pose,rig.rest)
        pose[pelvis].position.y-=.05
        if options.jitter>0 {pose[pelvis].position+=math.Vec3{noise(&state),noise(&state),noise(&state)}*options.jitter}
        travel:=math.Vec3{0,0,-speed*t} if options.root_motion else {}
        pose[root].position=travel
        legs:=[2][3]Body_Part{{.Hip_L,.Knee_L,.Foot_L},{.Hip_R,.Knee_R,.Foot_R}}
        for leg,side in legs {
            hip,knee,foot:=map_.bones[leg[0]],map_.bones[leg[1]],map_.bones[leg[2]]
            phase:=t+(.5 if side==1 else 0)
            phase-=cmath.floor(phase)
            rest:=rest_world[foot].position
            target:math.Vec3
            if options.run>0 {
                if phase<.3 {
                    d:=phase-.15
                    target={rest.x,rest.y+.3*cmath.sqrt(abs(d)/.15),options.run*d}
                } else {
                    s:=(phase-.3)/.7
                    target={rest.x,rest.y+.3+.1*cmath.sin(cmath.PI*s),-options.run*.15*(2*math.smoothstep(0,1,s)-1)}
                }
            } else if phase<.5 {
                target={rest.x,rest.y-options.sink,-.2+speed*phase}
                if side==0 {target.z-=options.slide*phase}
            } else {
                s:=(phase-.5)/.5
                clearance:=options.clearance if options.clearance>0 else .1
                target={rest.x,rest.y+clearance*cmath.sin(cmath.PI*s),.2-.4*math.smoothstep(0,1,s)}
            }
            target+=travel
            pose_world(rig.parents,pose,world)
            pole:=world[knee].position+math.Vec3{0,0,1 if options.backward_knees else -1}
            skeleton_ik(skeleton,pose,world,int(hip),int(knee),int(foot),target,pole)
        }
    }
    return frames,Body_Rig{parents=rig.parents,rest=rig.rest,body=map_,root=-1}
}

body_test_detected :: proc() -> (Body_Test_Rig,Body_Map) {
    rig:=body_test_humanoid()
    map_:=body_map_empty()
    body_detect(rig.parents,rig.names,rig.rest,rig.world,&map_)
    return rig,map_
}

body_test_metrics :: proc(rig:Body_Rig,frames:Frames,request:Metric_Request={}) -> Clip_Metrics {
    scratch:=make([]math.Transform,frames_scratch_size(frames),context.temp_allocator)
    metrics,_:=clip_metrics(rig,frames,request,scratch)
    return metrics
}

@(test)
clip_metrics_tell_travel_contacts_and_slide_of_a_walk :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    walk,rig:=body_test_walk(test_rig,map_,{root_motion=true,loop=true})
    contacts:[16]Contact
    scratch:=make([]math.Transform,frames_scratch_size(walk),context.temp_allocator)
    metrics,ok:=clip_metrics(rig,walk,{contacts=contacts[:]},scratch)
    if !testing.expect(t,ok) {return}
    testing.expect(t,!metrics.in_place)
    testing.expectf(t,abs(metrics.travel.z+.8)<.01 && abs(metrics.travel.x)<.01,"travel %v",metrics.travel)
    testing.expect_value(t,test_rig.names[metrics.root],"root")
    testing.expectf(t,metrics.contacts>=2 && metrics.contacts<=4,"contacts %d",metrics.contacts)
    for foot in Foot {testing.expectf(t,metrics.foot_slide[foot].mean<.03,"%v slides %v",foot,metrics.foot_slide[foot])}
    testing.expectf(t,metrics.penetration.max<.002,"penetration %v",metrics.penetration)
    testing.expectf(t,metrics.seam_position<.01,"seam %v",metrics.seam_position)
    for stat,part in metrics.limits {testing.expectf(t,stat.frames==0,"%v %v",part,stat)}
    left:=0
    for contact in contacts[:min(metrics.contacts,len(contacts))] {
        if contact.foot!=.Left {continue}
        left+=1
        testing.expect(t,contact.first<=2 && contact.last>=25 && contact.last<=34)
    }
    testing.expect_value(t,left,1)

    // In place the ground moves under the feet at the speed the body travels.
    in_place,_:=body_test_walk(test_rig,map_,{loop=true})
    metrics=body_test_metrics(rig,in_place)
    testing.expect(t,metrics.in_place)
    testing.expectf(t,abs(metrics.travel.z+.8)<.05,"travel %v",metrics.travel)
    for foot in Foot {testing.expectf(t,metrics.foot_slide[foot].mean<.05,"%v slides %v",foot,metrics.foot_slide[foot])}
    // Retargeting can raise the whole walk above the rest pose; the ground
    // of the animation is still where its own feet reach their lowest point.
    raised,_:=body_test_walk(test_rig,map_,{loop=true})
    for frame in 0..<frames_count(raised) {frames_pose(raised,frame)[map_.bones[.Pelvis]].position.y+=.12}
    metrics=body_test_metrics(rig,raised)
    testing.expectf(t,abs(metrics.travel.z+.8)<.05 && metrics.contacts>=2,"raised walk: travel %v, contacts %d",metrics.travel,metrics.contacts)
    testing.expectf(t,metrics.penetration.max<.002,"raised walk penetration %v",metrics.penetration)
    still,_:=body_test_walk(test_rig,map_,{loop=true})
    for frame in 1..<frames_count(still) {copy(frames_pose(still,frame),frames_pose(still,0))}
    metrics=body_test_metrics(rig,still)
    testing.expectf(t,abs(metrics.travel.z)<.01,"stationary pose travels %v",metrics.travel)
    // A foot that swings low passes near the floor, faster than the ground.
    shuffle,_:=body_test_walk(test_rig,map_,{loop=true,clearance=.01})
    metrics=body_test_metrics(rig,shuffle)
    testing.expectf(t,abs(metrics.travel.z+.8)<.05 && metrics.contacts>=2,"travel %v, %d contacts",metrics.travel,metrics.contacts)

    // A run whose feet touch the floor a frame between flights: the body travels as fast as the
    // foot that touches pushes back, not as far as the feet sweep over the whole cycle.
    run,_:=body_test_walk(test_rig,map_,{loop=true,run=2})
    metrics=body_test_metrics(rig,run)
    testing.expectf(t,metrics.in_place && metrics.contacts==0 && abs(metrics.travel.z+2)<.1 && abs(metrics.travel.x)<.05,"run: travel %v, %d contacts",metrics.travel,metrics.contacts)
    twice,_:=body_test_walk(test_rig,map_,{loop=true,run=2,duration=2})
    metrics=body_test_metrics(rig,twice)
    testing.expectf(t,abs(metrics.travel.z+2)<.1,"two cycles of a run: travel %v",metrics.travel)

    sliding,_:=body_test_walk(test_rig,map_,{root_motion=true,loop=true,slide=.15})
    metrics=body_test_metrics(rig,sliding)
    testing.expectf(t,abs(metrics.foot_slide[.Left].mean-.15)<.03 && metrics.foot_slide[.Right].mean<.03,"slides %v",metrics.foot_slide)

    sunk,_:=body_test_walk(test_rig,map_,{root_motion=true,loop=true,sink=.03})
    metrics=body_test_metrics(rig,sunk)
    testing.expectf(t,abs(metrics.penetration.max-.025)<.003,"penetration %v",metrics.penetration)
}

@(test)
clip_metrics_measure_jerk_seams_limits_and_goals :: proc(t:^testing.T) {
    test_rig,map_:=body_test_detected()
    clean,rig:=body_test_walk(test_rig,map_,{root_motion=true,loop=true})
    shaky,_:=body_test_walk(test_rig,map_,{root_motion=true,loop=true,jitter=.01})
    calm,noisy:=body_test_metrics(rig,clean),body_test_metrics(rig,shaky)
    testing.expectf(t,noisy.jerk.mean>5*calm.jerk.mean,"jerk %v against %v",noisy.jerk,calm.jerk)

    cut,_:=body_test_walk(test_rig,map_,{root_motion=true,duration=.75})
    testing.expect(t,body_test_metrics(rig,cut).seam_position>.1)

    backward,_:=body_test_walk(test_rig,map_,{root_motion=true,loop=true,backward_knees=true})
    bent:=body_test_metrics(rig,backward)
    testing.expect(t,bent.limits[.Knee_L].frames>0 && bent.limits[.Knee_R].frames>0 && bent.limits[.Knee_L].worst>.1)

    still,_:=body_test_walk(test_rig,map_,{loop=true})
    hand,head,calf:=map_.bones[.Hand_L],map_.bones[.Head],map_.bones[.Knee_L]
    goals:=[2]Metric_Goal{{.Reach,hand,{},test_rig.world[hand].position},{.Look,head,{0,0,-1},test_rig.world[head].position+{1,0,0}}}
    residuals:[2]Metric_Stat
    limits:=[1]Metric_Limit{{calf,1,{axis={1,0,0},max_swing=0,min_twist=0,max_twist=0}}}
    violations:[1]Limit_Stat
    _=body_test_metrics(rig,still,{goals=goals[:],residuals=residuals[:],limits=limits[:],violations=violations[:]})
    testing.expectf(t,abs(residuals[0].max-.05)<.002,"reach %v",residuals[0])
    testing.expectf(t,abs(residuals[1].mean-cmath.PI/2)<.01,"look %v",residuals[1])
    testing.expect(t,violations[0].frames>0 && violations[0].worst>.1)

    scratch:=make([]math.Transform,frames_scratch_size(clean),context.temp_allocator)
    wrong:=goals;wrong[0].bone=999
    _,ok:=clip_metrics(rig,clean,{goals=wrong[:],residuals=residuals[:]},scratch);testing.expect(t,!ok)
    _,ok=clip_metrics(rig,clean,{goals=goals[:],residuals=residuals[:1]},scratch);testing.expect(t,!ok)
    _,ok=clip_metrics(rig,clean,{},scratch[:10]);testing.expect(t,!ok)
    broken:=clean;broken.rate=0
    _,ok=clip_metrics(rig,broken,{},scratch);testing.expect(t,!ok)
}
