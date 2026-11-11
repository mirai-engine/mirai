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
        append(&state.rest,rest[i]);append(&state.local,rest[i]);append(&state.sampled,rest[i]);append(&state.world,rest[i]);append(&state.previous,rest[i])
        append(&state.bindings,Binding{target=target,entity=entity if i==0 else core.NONE,rest=rest[i],parent=parents[i]})
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
    leader,follower:=constraint_playing(&playback,body),constraint_playing(&playback,head)
    follower.leader=body
    leader.local[3].rotation=mm.quat_axis_angle({0,0,1},.3)
    leader.local[4].rotation=mm.quat_axis_angle({1,0,0},.2)
    leader.local[5].rotation=mm.quat_axis_angle({0,1,0},.4)
    jaw_own:=mm.quat_axis_angle({0,1,0},.1)
    follower.local[4].rotation=jaw_own
    append(&leader.curves,Curve_Output{target=base.name_hash("jawOpen"),property=.Float,value={.5,0,0,0},weight=1})
    append(&follower.curves,Curve_Output{target=base.name_hash("jawOpen"),property=.Float,value={.1,0,0,0},weight=1})
    append(&follower.curves,Curve_Output{target=base.name_hash("blink"),property=.Float,value={1,0,0,0},weight=1})
    head_sampled:[6]mm.Transform;copy(head_sampled[:],follower.local[:])

    // A capture curve drives the curve of a pose of the face, which opens the jaw.
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    drive:=CURVE_DRIVE_DEFAULT;drive.rig,drive.scale=head,2
    base.text_set(drive.from[:],"jawOpen");base.text_set(drive.to[:],"jaw_open_pose")
    open:=mm.quat_axis_angle({1,0,0},.6)
    pose:=CURVE_POSE_DEFAULT;pose.rig,pose.bone=head,bone_ref("jaw")
    base.text_set(pose.curve[:],"jaw_open_pose");pose.delta.rotation=open
    testing.expect(t,modifier_append(&modifiers.curve_drives,head,drive) && modifier_append(&modifiers.curve_poses,head,pose))
    testing.expect(t,modifier_controls_prepare(&modifiers,&Modifier_Runtime{}))

    cache:Animation_Constraints;defer constraints_free(&cache)
    problems:core.Problems
    tick :: proc(playback:^Playback,cache:^Animation_Constraints,modifiers:^Modifier_Runtime,transforms:^core.Table(core.Transform),parents:^core.Table(core.Parent),problems:^core.Problems,sampled:[]mm.Transform,head:core.Entity) {
        playback.frame+=1
        for &state in playback.states {state.seen=playback.frame}
        copy(constraint_playing(playback,head).local[:],sampled)
        animation_finish(playback,{problems=problems},cache,transforms,parents,1.0/60,nil,{},modifiers)
    }
    check :: proc(t:^testing.T,playback:^Playback,body,head:core.Entity,body_place,holder_place:mm.Transform,jaw:mm.Quat) -> bool {
        leader,follower:=constraint_playing(playback,body),constraint_playing(playback,head)
        body_world,head_world:[7]mm.Transform
        if !lib.pose_world(leader.parents[:],leader.local[:],body_world[:]) || !lib.pose_world(follower.parents[:],follower.local[:],head_world[:6],holder_place) {return false}
        same:=true
        for pair in ([3][2]int{{1,1},{2,4},{3,5}}) {
            same &&=linalg.length(head_world[pair[0]].position-body_world[pair[1]].position)<1e-4 && mm.quat_angle(head_world[pair[0]].rotation,body_world[pair[1]].rotation)<1e-3
        }
        same &&=mm.quat_angle(follower.local[4].rotation,jaw)<1e-4 && follower.local[4].position==mm.Vec3{0,-.05,.05}
        same &&=animation_curve(playback,head,"jawOpen")==.5 && animation_curve(playback,head,"blink")==1 && animation_curve(playback,head,"jaw_open_pose")==1
        return same
    }
    tick(&playback,&cache,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,check(t,&playback,body,head,body_place,holder_place,open*jaw_own),"the shared bones lie on the body's, the jaw keeps its own turn and opens by the curve of its pose")
    testing.expect_value(t,problems.count,0)

    // Later ticks pair nothing again and allocate nothing.
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<8 {
        tick(&playback,&cache,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
        stable &&=check(t,&playback,body,head,body_place,holder_place,open*jaw_own)
    }
    context=saved
    testing.expect(t,stable && problems.count==0)

    // Half the drive opens half the jaw; a disabled pose leaves the jaw its own turn.
    modifiers.curve_drives.values[0].scale=.5
    tick(&playback,&cache,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,abs(mm.quat_angle(follower.local[4].rotation,jaw_own)-.15)<1e-3)
    modifiers.curve_poses.values[0].enabled=false
    tick(&playback,&cache,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,mm.quat_angle(follower.local[4].rotation,jaw_own)<1e-5)
    modifiers.curve_poses.values[0].enabled=true

    // A pose of a bone the head lacks, a body that is not finite, a head that follows
    // itself through the body and skeletons without a name in common are problems.
    // A new profile is a new geometry of the modifiers, as modifier_prepare publishes it.
    modifiers.curve_poses.values[0].bone=bone_ref("tail");modifiers.geometry+=1
    tick(&playback,&cache,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,follow_problem(&problems,head,"animation.curve_pose_bone"))
    modifiers.curve_poses.values[0].bone=bone_ref("jaw");modifiers.geometry+=1
    nan:=f32(0);nan/=nan
    held:=leader.local[5];leader.local[5].position.x=nan
    tick(&playback,&cache,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,follow_problem(&problems,head,"animation.follow_pose") && lib.pose_world(follower.parents[:],follower.local[:],follower.world[:]))
    leader.local[5]=held
    leader.leader=head
    tick(&playback,&cache,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,follow_problem(&problems,head,"animation.follow_rig") || follow_problem(&problems,body,"animation.follow_rig"),"a loop of rigs that follow each other")
    leader.leader=core.NONE
    for &alias in follower.aliases {alias=alias~1}
    for &target in follower.targets {target=target~1 if target!=0 else 0}
    follower.bound+=10
    tick(&playback,&cache,&modifiers,&w.transforms,&w.parents,&problems,head_sampled[:],head)
    testing.expect(t,follow_problem(&problems,head,"animation.follow_bones"))
}

@(private="file")
follow_problem :: proc(problems:^core.Problems,e:core.Entity,code:string) -> bool {
    for &entry in problems.entries[:problems.count] {if entry.entity==e && base.text_get(entry.code[:])==code {return true}}
    return false
}

@(test)
curve_drives_combine_clamp_and_replace_and_full_poses_blend_before_additive_ones :: proc(t:^testing.T) {
    face:=core.entity_make(1,1)
    playback:Playback;defer playback_free(&playback)
    playback.frame=1
    step:=mm.Transform{{0,.1,0},1,{1,1,1}}
    follow_rig(&playback,face,3,{"","root","jaw","lid"},{-1,0,1,1},{mm.TRANSFORM_IDENTITY,step,step,step})
    state:=constraint_playing(&playback,face)
    values:=[4]f32{.8,.5,.3,.9}
    for name,i in ([4]string{"jawOpen","mouthClose","smileL","smileR"}) {
        append(&state.curves,Curve_Output{target=base.name_hash(name),property=.Float,value={values[i],0,0,0},weight=1})
    }
    slice.sort_by(state.curves[:],curve_order)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    drive :: proc(modifiers:^Modifier_Runtime,rig:core.Entity,from,with,to:string,combine:Curve_Combine=.From,mode:Curve_Drive_Mode=.Add,scale:f32=1,offset:f32=0,clamped:=false,weight:f32=1) -> bool {
        row:=CURVE_DRIVE_DEFAULT
        base.text_set(row.from[:],from);base.text_set(row.with[:],with);base.text_set(row.to[:],to)
        row.rig,row.combine,row.mode,row.scale,row.offset,row.clamp,row.weight=rig,combine,mode,scale,offset,clamped,weight
        return pose_profile_check({curve_drives={row}}) && modifier_append(&modifiers.curve_drives,rig,row)
    }
    testing.expect(t,drive(&modifiers,face,"jawOpen","mouthClose","jaw_close",.Product))
    testing.expect(t,drive(&modifiers,face,"smileL","smileR","smile",.Min))
    testing.expect(t,drive(&modifiers,face,"smileR","","smile",mode=.Max))
    testing.expect(t,drive(&modifiers,face,"jawOpen","","jaw",scale=2,offset=-.2,clamped=true))
    testing.expect(t,drive(&modifiers,face,"mouthClose","","jawOpen",mode=.Replace,weight=.5))
    full_a:=CURVE_POSE_DEFAULT;full_a.rig,full_a.bone,full_a.full=face,bone_ref("lid"),true
    base.text_set(full_a.curve[:],"jaw");full_a.delta.position={1,0,0}
    full_b:=full_a;base.text_set(full_b.curve[:],"smile");full_b.delta.position={0,1,0}
    additive:=CURVE_POSE_DEFAULT;additive.rig,additive.bone=face,bone_ref("lid")
    base.text_set(additive.curve[:],"jaw_close");additive.delta.position={0,0,1}
    // The additive row first: full poses still go before it.
    testing.expect(t,modifier_append(&modifiers.curve_poses,face,additive) && modifier_append(&modifiers.curve_poses,face,full_a) && modifier_append(&modifiers.curve_poses,face,full_b))
    problems:core.Problems
    testing.expect(t,curve_poses_apply(state,&playback,&modifiers,false,&problems) && problems.count==0)
    value :: proc(playback:^Playback,e:core.Entity,name:string) -> f32 {return animation_curve(playback,e,name)}
    state.seen=playback.frame
    testing.expect(t,abs(value(&playback,face,"jaw_close")-.4)<1e-5,"the product of both")
    testing.expect(t,abs(value(&playback,face,"smile")-.9)<1e-5,"their least, then the most of that and smileR")
    testing.expect(t,abs(value(&playback,face,"jaw")-1)<1e-5,"clamped to 1")
    testing.expect(t,abs(value(&playback,face,"jawOpen")-.65)<1e-5,"replaced by half its weight")
    testing.expect(t,slice.is_sorted_by(state.driven[:],curve_order),"the curves drives write are laid out in order")
    // lid: (1*{1,0,0} + .9*{0,1,0}) / 1.9, then .4 along Z.
    expected:=mm.Vec3{1/1.9,.9/1.9,.4}
    testing.expectf(t,linalg.length(state.local[3].position-expected)<1e-4,"full poses normalized, then the additive one: %v",state.local[3].position)
    testing.expect(t,modifiers.curve_full[3]=={},"the sums start over")

    // The rows of the poses in another order (a new profile) give the same pose, and
    // laying the curves out again within their room reserves nothing.
    state.local[3]=step
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    laid:=raw_data(state.driven)
    modifiers.curve_poses.values[0],modifiers.curve_poses.values[2]=modifiers.curve_poses.values[2],modifiers.curve_poses.values[0]
    modifiers.geometry+=1
    stable:=curve_poses_apply(state,&playback,&modifiers,false,&problems)
    context=saved
    testing.expect(t,stable && raw_data(state.driven)==laid && abs(value(&playback,face,"jaw_close")-.4)<1e-5 && linalg.length(state.local[3].position-expected)<1e-4)

    // A curve renamed in place lays the curves out again: smileR is gone, so smile is
    // the least of smileL and nothing.
    for &curve in state.curves {if curve.target==base.name_hash("smileR") {curve.target=base.name_hash("browUp")}}
    slice.sort_by(state.curves[:],curve_order)
    state.local[3]=step
    testing.expect(t,curve_poses_apply(state,&playback,&modifiers,false,&problems))
    testing.expect(t,abs(value(&playback,face,"browUp")-.9)<1e-5 && abs(value(&playback,face,"smile"))<1e-5 && abs(value(&playback,face,"jaw_close")-.4)<1e-5)
}

// A world a scene is saved from, with the look of its entities.
@(private)
@(test_world)
Look_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    looks:core.Table(erender.Material_Values),
    hierarchy:core.Hierarchy,
}

@(test)
curve_materials_are_live_over_what_the_entity_authors_and_no_scene_saves_them :: proc(t:^testing.T) {
    w:Look_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    face,bare:=core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,face,core.Id{1});core.add(&w.ids,bare,core.Id{2})
    own:=erender.MATERIAL_VALUES_DEFAULT
    erender.material_value(&own,base.name_hash("frame"),{9,9,9,9},1) // the entity's own, which the curve goes over
    core.add(&w.looks,face,own)
    test_world_settle(&w)
    playback:Playback;defer playback_free(&playback)
    playback.frame=1
    follow_rig(&playback,face,3,{"","root"},{-1,0},{mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY})
    state:=constraint_playing(&playback,face)
    append(&state.curves,Curve_Output{target=base.name_hash("mouth_frame"),property=.Float,value={2.6,0,0,0},weight=1})
    append(&state.curves,Curve_Output{target=base.name_hash("blush"),property=.Float,value={.5,0,0,0},weight=1})
    slice.sort_by(state.curves[:],curve_order)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    frame:=CURVE_MATERIAL_DEFAULT;frame.rig,frame.slot,frame.step=face,1,1
    base.text_set(frame.curve[:],"mouth_frame");base.text_set(frame.parameter[:],"frame")
    blush:=CURVE_MATERIAL_DEFAULT;blush.rig,blush.every,blush.scale,blush.offset=face,true,{0,0,1,0},{0,0,0,1}
    base.text_set(blush.curve[:],"blush");base.text_set(blush.parameter[:],"emission")
    testing.expect(t,pose_profile_check({curve_materials={frame,blush}}))
    testing.expect(t,modifier_append(&modifiers.curve_materials,face,frame) && modifier_append(&modifiers.curve_materials,face,blush))
    apply :: proc(modifiers:^Modifier_Runtime,state:^Playing,w:^Look_World,e:core.Entity,playing:=false) -> (live:erender.Material_Live,fits:bool) {
        fits=curve_materials_apply(modifiers,state,2,&w.looks,e,playing)
        test_world_settle(w)
        look,_:=core.get(&w.looks,e)
        return look.live,fits
    }
    find :: proc(o:^erender.Material_Live,slot:int,name:string) -> (value:[4]f32,found:bool) {
        at:=erender.material_value_find(o,slot,base.name_hash(name))
        return at>=0?o.values[at]:{},at>=0
    }
    drawn,applied:=apply(&modifiers,state,&w,face)
    value,found:=find(&drawn,1,"frame")
    testing.expect(t,applied && found && value==[4]f32{3,3,3,3} && drawn.count==3,"rounded to its step")
    value,found=find(&drawn,0,"emission");testing.expect(t,found && value==[4]f32{0,0,.5,1})
    value,found=find(&drawn,1,"emission");testing.expect(t,found && value==[4]f32{0,0,.5,1},"every slot")
    // The tick of the animation hashes their names and finds their curves once; the
    // drawing reads them, and a curve renamed in the row is found again by its name.
    problems:core.Problems
    testing.expect(t,curve_poses_apply(state,&playback,&modifiers,false,&problems) && len(modifiers.curve_material_states)==2)
    bound:=modifiers.curve_material_states[0]
    testing.expect(t,bound.ready && bound.rig==face && bound.to==base.name_hash("frame") && bound.slot>=0 && state.curves[bound.slot].target==base.name_hash("mouth_frame"))
    drawn,applied=apply(&modifiers,state,&w,face)
    value,found=find(&drawn,1,"frame");testing.expect(t,applied && found && value==[4]f32{3,3,3,3})
    base.text_set(modifiers.curve_materials.values[0].curve[:],"blush");modifiers.geometry+=1
    testing.expect(t,curve_poses_apply(state,&playback,&modifiers,false,&problems))
    drawn,_=apply(&modifiers,state,&w,face)
    value,found=find(&drawn,1,"frame");testing.expect(t,found && value==[4]f32{1,1,1,1},"blush .5 rounded to its step")
    // A curve that does not play takes its values away.
    for &curve in state.curves {curve.weight=0}
    drawn,applied=apply(&modifiers,state,&w,face)
    testing.expect(t,applied && drawn.count==0)
    for &curve in state.curves {curve.weight=1}
    // A scene saves what the entities author: neither the values a curve moved nor the screen
    // one shows, and no component where a step found none.
    drawn,applied=apply(&modifiers,state,&w,face)
    _,bare_applied:=apply(&modifiers,state,&w,bare)
    erender.material_live(&w.looks,face,false).screen={texture=7,lit=true,emission=200}
    test_world_settle(&w)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
    testing.expect(t,applied && bare_applied && drawn.count==3 && !core.has(&w.looks,bare),"a step authors nothing")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    document:asset.Scene
    _,error:=scene.capture(test_world_ref(&w),&document,&types,{id={1,2}})
    if testing.expect_value(t,error,scene.Error.None) {
        saved,kept:=asset.scene_get(&document,1,"Material_Values",erender.Material_Values)
        testing.expect(t,kept && saved==own,"the scene keeps what the entity authored")
        _,kept=asset.scene_get(&document,2,"Material_Values",erender.Material_Values)
        testing.expect(t,!kept,"and none where none was authored")
        asset.scene_destroy(&document)
    }
    // In a world that plays, the entity without them takes them.
    drawn,applied=apply(&modifiers,state,&w,bare,true)
    testing.expect(t,applied && drawn.count==3)
    // A live part that is full keeps what fits and says so; a bad row is refused by the profile.
    live:=erender.material_live(&w.looks,face,false)
    live^={}
    for i in 0..<erender.MATERIAL_VALUES_CAPACITY {erender.material_value(live,u64(i+1),{},0)}
    drawn,applied=apply(&modifiers,state,&w,face)
    testing.expect(t,!applied && int(drawn.count)==erender.MATERIAL_VALUES_CAPACITY)
    nan:=f32(0);nan/=nan
    bad:=frame;bad.step=-1
    testing.expect(t,!pose_profile_check({curve_materials={bad}}))
    bad=frame;bad.scale.y=nan
    testing.expect(t,!pose_profile_check({curve_materials={bad}}))
    bad=frame;bad.slot=u8(erender.MATERIAL_SLOTS)
    testing.expect(t,!pose_profile_check({curve_materials={bad}}))
    bad=frame;bad.parameter={}
    testing.expect(t,!pose_profile_check({curve_materials={bad}}))
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
