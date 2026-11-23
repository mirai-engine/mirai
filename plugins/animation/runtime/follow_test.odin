package anim

import "base:runtime"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// A rig of named bones (the external root first) placed in a playback, as skeleton_bind leaves one.
@(private="file")
follow_rig :: proc(playback:^Playback,entity:core.Entity,skeleton:u64,names:[]string,parents:[]i32,rest:[]mm.Transform) {
    state:=Playing{entity=entity,clip=-1,skeleton={skeleton,skeleton},bound=skeleton,seen=playback.frame}
    for name,i in names {
        path:=strings.builder_make(context.temp_allocator)
        for at:=i;at>0;at=int(parents[at]) {
            if strings.builder_len(path)>0 {strings.write_string(&path,"/")}
            strings.write_string(&path,names[at])
        }
        target:=base.name_hash(strings.to_string(path)) if i>0 else 0
        append(&state.parents,parents[i]);append(&state.targets,target);append(&state.aliases,base.name_hash(name) if i>0 else 0)
        index:=state.pose_count
        playing_pose_resize(&state,index+1)
        append(&state.rest,rest[i]);playing_pose(&state,.Local)[index]=rest[i];playing_pose(&state,.Sampled)[index]=rest[i];playing_pose(&state,.World)[index]=rest[i];playing_pose(&state,.Previous)[index]=rest[i];
        append(&state.bindings,Binding{target=target,entity=entity if i==0 else core.NONE,parent=parents[i]})
    }
    index:=int(core.entity_index(entity))
    if index>=len(playback.rows) {resize(&playback.rows,index+1)}
    append(&playback.states,state)
    playback.rows[index]=i32(len(playback.states))
}

@(private)
@(test_world)
Follow_World :: struct {
    using world:Test_World,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
}

@(test)
a_head_of_its_own_skeleton_follows_the_body_and_its_curves_pose_its_face_without_stable_allocations :: proc(t:^testing.T) {
    w:Follow_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    body,holder,head:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    body_place:=mm.Transform{{1,0,0},mm.quat_axis_angle({0,1,0},.7),{1,1,1}}
    holder_place:=mm.Transform{{0,2,3},mm.quat_axis_angle({1,0,0},.3),{1,1,1}}
    head_place:=mm.Transform{{5,0,0},mm.quat_axis_angle({0,0,1},-.4),{1,1,1}}
    core.add(&w.transforms,body,core.from_math(body_place));core.add(&w.transforms,holder,core.from_math(holder_place));core.add(&w.transforms,head,core.from_math(head_place))
    core.add(&w.parents,head,{entity=holder})
    test_world_settle(&w)

    step:=mm.Transform{{0,.2,0},1,{1,1,1}}
    playback:Playback;defer playback_free(&playback)
    playback.frame=1
    follow_rig(&playback,body,1,{"","root","pelvis","spine","neck","head","hand_l"},{-1,0,1,2,3,4,3},{body_place,step,step,step,step,step,step})
    // The head has neck right under root, and bones of its face the body lacks.
    jaw_rest:=mm.Transform{{0,-.05,.05},1,{1,1,1}}
    follow_rig(&playback,head,2,{"","root","neck","head","jaw","eye_l"},{-1,0,1,2,3,3},{head_place,step,{{0,.8,0},1,{1,1,1}},step,jaw_rest,step})
    leader,follower:=constraint_playing(core.ref(&playback),body),constraint_playing(core.ref(&playback),head)
    follower.leader=body
    playing_pose(leader,.Local)[3].rotation=mm.quat_axis_angle({0,0,1},.3)
    playing_pose(leader,.Local)[4].rotation=mm.quat_axis_angle({1,0,0},.2)
    playing_pose(leader,.Local)[5].rotation=mm.quat_axis_angle({0,1,0},.4)
    jaw_own:=mm.quat_axis_angle({0,1,0},.1)
    playing_pose(follower,.Local)[4].rotation=jaw_own
    append(&leader.curves,Curve_Output{target=base.name_hash("jawOpen"),property=.Float,value={1,0,0,0},weight=1});leader.curves_ready=true
    append(&follower.curves,Curve_Output{target=base.name_hash("jawOpen"),property=.Float,value={.1,0,0,0},weight=1})
    append(&follower.curves,Curve_Output{target=base.name_hash("blink"),property=.Float,value={1,0,0,0},weight=1})
    head_sampled:[6]mm.Transform;copy(head_sampled[:],playing_pose(follower,.Local))

    // The capture curve the body plays opens the jaw of the head by a pose of its face: the head
    // reads the curves of the body over its own.
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    open:=mm.quat_axis_angle({1,0,0},.6)
    pose:=CURVE_POSE_DEFAULT;pose.bone=bone_ref("jaw")
    base.text_set(pose.curve[:],"jawOpen");pose.delta.rotation=open
    poses:=[1]Curve_Pose{pose}
    profile:=Pose_Profile{curve_poses=poses[:]}
    test_modifier_profile(&modifiers,&characters,head,profile)
    problems:core.Problems
    tick :: proc(playback:^Playback,characters:^Character_Assets,modifiers:^Modifier_Runtime,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent),problems:^core.Problems,sampled:[]mm.Transform,head:core.Entity) {
        playback.frame+=1
        for &state in playback.states {state.seen=playback.frame}
        copy(playing_pose(constraint_playing(core.ref(playback),head),.Local),sampled)
        animation_finish(playback,{problems=problems},modifiers,transforms,parents,1.0/60,characters=characters)
    }
    check :: proc(t:^testing.T,playback:^Playback,body,head:core.Entity,body_place,holder_place:mm.Transform,jaw:mm.Quat) -> bool {
        leader,follower:=constraint_playing(core.ref(playback),body),constraint_playing(core.ref(playback),head)
        body_world,head_world:[7]mm.Transform
        if !lib.pose_world(leader.parents[:],playing_pose(leader,.Local),body_world[:]) || !lib.pose_world(follower.parents[:],playing_pose(follower,.Local),head_world[:6],holder_place) {return false}
        same:=true
        for pair in ([3][2]int{{1,1},{2,4},{3,5}}) {
            same &&=linalg.length(head_world[pair[0]].position-body_world[pair[1]].position)<1e-4 && mm.quat_angle(head_world[pair[0]].rotation,body_world[pair[1]].rotation)<1e-3
        }
        same &&=mm.quat_angle(playing_pose(follower,.Local)[4].rotation,jaw)<1e-4 && playing_pose(follower,.Local)[4].position==mm.Vec3{0,-.05,.05}
        same &&=animation_curve(core.ref(playback),head,"jawOpen")==1 && animation_curve(core.ref(playback),head,"blink")==1
        return same
    }
    tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,check(t,&playback,body,head,body_place,holder_place,open*jaw_own),"the shared bones lie on the body's, the jaw keeps its own turn and opens by the curve of its pose")
    testing.expect_value(t,problems.count,0)

    // Later ticks pair nothing again and allocate nothing.
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<8 {
        tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
        stable &&=check(t,&playback,body,head,body_place,holder_place,open*jaw_own)
    }
    context=saved
    testing.expect(t,stable && problems.count==0)

    // A quarter of the curve of the body opens a quarter of the jaw; while the body does not
    // animate it, the head reads its own; a disabled pose leaves the jaw its own turn.
    leader.curves[0].value.x=.25
    tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,abs(mm.quat_angle(playing_pose(follower,.Local)[4].rotation,jaw_own)-.15)<1e-3)
    leader.curves[0].weight=0
    tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,abs(mm.quat_angle(playing_pose(follower,.Local)[4].rotation,jaw_own)-.06)<1e-3)
    leader.curves[0].value.x,leader.curves[0].weight=1,1
    poses[0].enabled=false
    tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,mm.quat_angle(playing_pose(follower,.Local)[4].rotation,jaw_own)<1e-5)
    poses[0].enabled=true

    // A pose of a bone the head lacks, a body that is not finite, a head that follows
    // itself through the body and skeletons without a name in common are problems.
    // A new profile is a new geometry of the modifiers, as modifier_prepare publishes it.
    poses[0].bone=bone_ref("tail");test_modifier_profile(&modifiers,&characters,head,profile)
    tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,follow_problem(&problems,head,"animation.curve_pose_bone"))
    poses[0].bone=bone_ref("jaw");test_modifier_profile(&modifiers,&characters,head,profile)
    nan:=f32(0);nan/=nan
    held:=playing_pose(leader,.Local)[5];playing_pose(leader,.Local)[5].position.x=nan
    tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,follow_problem(&problems,head,"animation.follow_pose") && lib.pose_world(follower.parents[:],playing_pose(follower,.Local),playing_pose(follower,.World)[:]))
    playing_pose(leader,.Local)[5]=held
    leader.leader=head
    tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,follow_problem(&problems,head,"animation.follow_rig") || follow_problem(&problems,body,"animation.follow_rig"),"a loop of rigs that follow each other")
    leader.leader=core.NONE
    for &alias in follower.aliases {alias=alias~1}
    for &target in follower.targets {target=target~1 if target!=0 else 0}
    follower.bound+=10
    tick(&playback,&characters,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,follow_problem(&problems,head,"animation.follow_bones"))
}

@(private="file")
follow_problem :: proc(problems:^core.Problems,e:core.Entity,code:string) -> bool {
    for &entry in problems.entries[:problems.count] {if entry.entity==e && base.text_get(entry.code[:])==code {return true}}
    return false
}

@(test)
full_curve_poses_blend_before_additive_ones_in_any_order_without_stable_allocations :: proc(t:^testing.T) {
    face:=core.entity_make(1,1)
    playback:Playback;defer playback_free(&playback)
    playback.frame=1
    step:=mm.Transform{{0,.1,0},1,{1,1,1}}
    follow_rig(&playback,face,3,{"","root","jaw","lid"},{-1,0,1,1},{mm.TRANSFORM_IDENTITY,step,step,step})
    state:=constraint_playing(core.ref(&playback),face)
    values:=[3]f32{1,.9,.4}
    for name,i in ([3]string{"jawOpen","smile","jawClose"}) {
        append(&state.curves,Curve_Output{target=base.name_hash(name),property=.Float,value={values[i],0,0,0},weight=1})
    }
    slice.sort_by(state.curves[:],curve_order)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    full_a:=CURVE_POSE_DEFAULT;full_a.bone,full_a.full=bone_ref("lid"),true
    base.text_set(full_a.curve[:],"jawOpen");full_a.delta.position={1,0,0}
    full_b:=full_a;base.text_set(full_b.curve[:],"smile");full_b.delta.position={0,1,0}
    additive:=CURVE_POSE_DEFAULT;additive.bone=bone_ref("lid")
    base.text_set(additive.curve[:],"jawClose");additive.delta.position={0,0,1}
    // The additive row first: full poses still go before it.
    poses:=[3]Curve_Pose{additive,full_a,full_b}
    profile:=Pose_Profile{curve_poses=poses[:]}
    prepared:=test_modifier_profile(&modifiers,&characters,face,profile)
    problems:core.Problems
    testing.expect(t,curve_poses_apply(state,&playback,&modifiers,prepared,profile,false,&problems) && problems.count==0)
    // lid: (1*{1,0,0} + .9*{0,1,0}) / 1.9, then .4 along Z.
    expected:=mm.Vec3{1/1.9,.9/1.9,.4}
    testing.expectf(t,linalg.length(playing_pose(state,.Local)[3].position-expected)<1e-4,"full poses normalized, then the additive one: %v",playing_pose(state,.Local)[3].position)
    testing.expect(t,modifiers.curve_full[3]=={},"the sums start over")

    // The rows of the poses in another order (a new profile) give the same pose and reserve
    // nothing.
    playing_pose(state,.Local)[3]=step
    poses[0],poses[2]=poses[2],poses[0]
    prepared=test_modifier_profile(&modifiers,&characters,face,profile)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=curve_poses_apply(state,&playback,&modifiers,prepared,profile,false,&problems)
    context=saved
    testing.expect(t,stable && linalg.length(playing_pose(state,.Local)[3].position-expected)<1e-4)

    // A curve renamed in place is found again: smile is gone, so only jawOpen poses fully.
    for &curve in state.curves {if curve.target==base.name_hash("smile") {curve.target=base.name_hash("browUp")}}
    slice.sort_by(state.curves[:],curve_order)
    playing_pose(state,.Local)[3]=step
    testing.expect(t,curve_poses_apply(state,&playback,&modifiers,prepared,profile,false,&problems))
    testing.expect(t,linalg.length(playing_pose(state,.Local)[3].position-mm.Vec3{1,0,.4})<1e-4)
}

@(test)
followers_finish_after_their_leaders_in_the_order_found_once :: proc(t:^testing.T) {
    playback:Playback;defer playback_free(&playback)
    a,b,c,d,e:=core.entity_make(1,1),core.entity_make(2,1),core.entity_make(3,1),core.entity_make(4,1),core.entity_make(5,1)
    // c follows b, which follows a; d and e follow each other.
    append(&playback.rigs,Rig{entity=a,skeleton={1,1}},Rig{entity=b,skeleton={2,2},leader=a},Rig{entity=c,skeleton={3,3},leader=b},Rig{entity=d,skeleton={4,4},leader=e},Rig{entity=e,skeleton={4,5},leader=d})
    testing.expect(t,follow_order_update(&playback) && len(playback.follow_order)==4)
    testing.expect(t,playback.follow_order[0]==Rig_Follow{b,1} && playback.follow_order[1]==Rig_Follow{c,2},"each after the rig it follows")
    testing.expect(t,playback.follow_order[2].depth==max(u32) && playback.follow_order[3].depth==max(u32),"a loop goes last")
    clear(&playback.rigs)
    testing.expect(t,follow_order_update(&playback) && len(playback.follow_order)==0)
}
