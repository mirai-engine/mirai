package anim

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file")
rig_shapes_corrective :: proc() -> Pose_Corrective {
    corrective:=POSE_CORRECTIVE_DEFAULT
    base.text_set(corrective.name[:],"bulge");base.text_set(corrective.curve[:],"bulge")
    corrective.driver,corrective.bone=bone_ref("joint2"),bone_ref("joint3")
    corrective.sample_count=2
    corrective.samples[0],corrective.samples[1]=POSE_CORRECTIVE_SAMPLE_DEFAULT,POSE_CORRECTIVE_SAMPLE_DEFAULT
    corrective.samples[1].rotation=mm.quat_axis_angle({0,0,1},1)
    corrective.samples[1].delta.scale={1.5,1,1}
    corrective.samples[1].curve_value=1
    return corrective
}

@(private="file")
rig_shapes_spline :: proc(points:[4]mm.Vec3) -> Spline_IK_Constraint {
    spline:=SPLINE_IK_CONSTRAINT_DEFAULT
    base.text_set(spline.name[:],"tail")
    spline.root,spline.end,spline.up=bone_ref("joint1"),bone_ref("joint4"),{0,0,1}
    for point,i in points {spline.controls[i]=spatial_point(point)}
    return spline
}

@(test)
rig_shape_profiles_roundtrip_and_refuse_repeated_samples_and_degenerate_splines :: proc(t:^testing.T) {
    follow:=FOLLOW_CONSTRAINT_DEFAULT;base.text_set(follow.name[:],"hand");follow.bone=bone_ref("joint3")
    follow.target.kind=.Socket;base.text_set(follow.target.socket[:],"grip")
    pose:=CURVE_POSE_DEFAULT;base.text_set(pose.curve[:],"jaw_open_pose");pose.bone=bone_ref("jaw");pose.delta.rotation=mm.quat_axis_angle({1,0,0},.5)
    drive:=CURVE_DRIVE_DEFAULT;base.text_set(drive.from[:],"jawOpen");base.text_set(drive.to[:],"jaw_open_pose");drive.scale=.8
    profile:=Pose_Profile{spline_ik={rig_shapes_spline({{0,0,0},{0,1,0},{1,2,0},{1,3,0}})},correctives={rig_shapes_corrective()},follow={follow},curve_poses={pose},curve_drives={drive}}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document;defer asset.document_destroy(&doc)
    if !testing.expect_value(t,pose_profile_document(&doc,&types,{3,4},profile),asset.Error.None) {return}
    testing.expect_value(t,doc.kind_version,u16(POSE_VERSION))
    path:=fmt.tprintf("%s/shapes.pose",base.test_folder(t,"rig-shapes"))
    testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None) {return}
    defer asset.asset_close(&file)
    view,read:=pose_profile_view(&file,&types)
    testing.expect_value(t,read,asset.Error.None)
    testing.expect(t,len(view.spline_ik)==1 && view.spline_ik[0].controls[3].position==mm.Vec3{1,3,0} && view.correctives[0].samples[1].curve_value==1 && view.follow[0].target.kind==.Socket)
    testing.expect(t,len(view.curve_poses)==1 && view.curve_poses[0]==pose && len(view.curve_drives)==1 && view.curve_drives[0]==drive)
    // A profile of the current version without curve poses, drives and materials is incomplete,
    // and one of another version is refused.
    for name in ([3]string{"curve_poses","curve_drives","curve_materials"}) {
        if table,found:=asset.document_table(&doc,name);found {asset.document_table_remove(&doc,table)}
    }
    for version,i in ([2]u16{POSE_VERSION,POSE_VERSION-1}) {
        doc.kind_version=version
        bytes,written:=asset.document_bytes(&doc,context.temp_allocator)
        if !testing.expect_value(t,written,asset.Error.None) {continue}
        old:asset.Asset
        if !testing.expect_value(t,asset.asset_open(&old,bytes,context.temp_allocator),asset.Error.None) {continue}
        defer asset.asset_close(&old)
        _,error:=pose_profile_view(&old,&types)
        switch i {
        case 0: testing.expect_value(t,error,asset.Error.Not_Found)
        case 1: testing.expect_value(t,error,asset.Error.Version)
        }
    }
    nan:=f32(0);nan/=nan
    bad_drive:=drive;bad_drive.to=drive.from
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}),"a curve that drives itself")
    bad_drive=drive;bad_drive.scale=nan
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}))
    bad_drive=drive;bad_drive.from={}
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}))
    bad_drive=drive;bad_drive.combine=.Product
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}),"a product without its second curve")
    bad_drive=drive;base.text_set(bad_drive.with[:],"mouthClose")
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}),"a second curve read by nothing")
    bad_drive.combine=.Min;bad_drive.with=bad_drive.to
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}),"a curve that drives itself through with")
    bad_drive=drive;bad_drive.clamp,bad_drive.low,bad_drive.high=true,1,0
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}))
    bad_drive=drive;bad_drive.offset=nan
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}))
    bad_drive=drive;bad_drive.weight=2
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}))
    bad_drive=drive;bad_drive.mode=Curve_Drive_Mode(7)
    testing.expect(t,!pose_profile_check({curve_drives={bad_drive}}))
    bad_pose:=pose;bad_pose.delta.rotation={}
    testing.expect(t,!pose_profile_check({curve_poses={bad_pose}}))
    bad_pose=pose;bad_pose.weight=2
    testing.expect(t,!pose_profile_check({curve_poses={bad_pose}}))
    bad_pose=pose;bad_pose.curve={}
    testing.expect(t,!pose_profile_check({curve_poses={bad_pose}}))
    invalid:=rig_shapes_corrective();invalid.samples[1].rotation=-invalid.samples[0].rotation
    testing.expect(t,!pose_profile_check({correctives={invalid}}),"two samples of one rotation")
    invalid=rig_shapes_corrective();invalid.sample_count=RIG_POSE_SAMPLES+1
    testing.expect(t,!pose_profile_check({correctives={invalid}}))
    spline:=rig_shapes_spline({{0,0,0},{0,1,0},{1,2,0},{1,3,0}});spline.up={}
    testing.expect(t,!pose_profile_check({spline_ik={spline}}))
    spline=rig_shapes_spline({});testing.expect(t,!pose_profile_check({spline_ik={spline}}),"a spline of fixed points without length")
    spline.controls[3].kind=.Bone;spline.controls[3].bone=bone_ref("hand")
    testing.expect(t,pose_profile_check({spline_ik={spline}}),"a spline with a moving control is checked when it is sampled")
}

@(test)
spline_ik_and_correctives_replay_goals_and_curves_without_stable_allocations :: proc(t:^testing.T) {
    rig:=core.entity_make(1,1)
    state:=rig_test_state(rig,4,.5);defer playing_free(&state)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    corrective:=rig_shapes_corrective()
    state.sampled[2].rotation=corrective.samples[1].rotation
    testing.expect(t,modifier_append(&modifiers.spline_ik,rig,rig_shapes_spline({{0,0,0},{.4,.5,0},{.4,1,0},{0,1.5,0}})) && modifier_append(&modifiers.correctives,rig,corrective))
    testing.expect(t,modifier_controls_prepare(&modifiers,&Modifier_Runtime{}))
    testing.expect(t,rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    expected:=state.world[4]
    testing.expect(t,abs(state.local[3].scale.x-1.5)<1e-5 && abs(animation_corrective_curve(&modifiers,rig,base.name_hash("bulge"))-1)<1e-5)
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<32 {
        copy(state.local[:],state.rest[:])
        stable &&=rigs_apply(&state,&copied,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
        stable &&=linalg.length(state.world[4].position-expected.position)<1e-5 && animation_corrective_curve(&copied,rig,base.name_hash("bulge"))==1
    }
    context=saved
    testing.expect(t,stable)
    slot,found:=modifier_named_slot(&modifiers,rig,.Spline_IK,"tail")
    testing.expect(t,found && slot==0)
    rigs_apply_goal(&modifiers,{rig=rig,kind=.Spline_IK,slot=slot,effector=3,target=spatial_point({1,2,0})},1,true,nil)
    testing.expect_value(t,modifiers.spline_ik.values[0].controls[3].position,mm.Vec3{1,2,0})
    modifiers.correctives.values[0].enabled=false
    copy(state.local[:],state.rest[:])
    testing.expect(t,rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60) && animation_corrective_curve(&modifiers,rig,base.name_hash("bulge"))==0)
    // Out of reach the chain lies along the curve, and says so.
    for point,i in ([4]mm.Vec3{{0,0,0},{0,1,0},{0,2,0},{0,20,0}}) {modifiers.spline_ik.values[0].controls[i]=spatial_point(point)}
    copy(state.local[:],state.rest[:])
    testing.expect(t,rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    diagnostic,available:=animation_rig_diagnostic(&modifiers,rig,.Spline_IK,0)
    testing.expect(t,available && diagnostic.valid && !diagnostic.reached && diagnostic.residual>1)
    for point,i in ([4]mm.Vec3{{0,0,0},{0,.5,0},{0,1,0},{0,1.5,0}}) {modifiers.spline_ik.values[0].controls[i]=spatial_point(point)}
    copy(state.local[:],state.rest[:])
    testing.expect(t,rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    diagnostic,available=animation_rig_diagnostic(&modifiers,rig,.Spline_IK,0)
    testing.expect(t,available && diagnostic.valid && diagnostic.reached && diagnostic.residual<=.001)
}

@(test)
corrective_curves_drive_the_morph_target_of_their_name :: proc(t:^testing.T) {
    rig:=core.entity_make(1,1)
    state:=rig_test_state(rig,4,.5);defer playing_free(&state)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    corrective:=rig_shapes_corrective();corrective.apply_pose=false
    state.sampled[2].rotation=corrective.samples[1].rotation
    testing.expect(t,modifier_append(&modifiers.correctives,rig,corrective) && rigs_apply(&state,&modifiers,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    targets:=[2]asset.Morph_Target{{weight=.25},{weight=.5}}
    base.text_set(targets[0].name[:],"bulge");base.text_set(targets[1].name[:],"blink")
    mesh:=Skin_Rig{id={5,7},revision=1,morphs=targets[:]}
    playing:=Morph_Playing{entity=core.entity_make(2,1),source=rig,curve_count=-1};defer morph_playing_free(&playing)
    testing.expect(t,morph_bind(&playing,&mesh,{},"Face",1) && morph_compose(&playing,&mesh,{},nil,&modifiers))
    testing.expect(t,abs(playing.current[0]-1.25)<1e-5 && playing.current[1]==.5,"the corrective adds to the target it names only")
}

@(test)
spatial_bone_and_socket_targets_read_the_sampled_pose_and_keep_their_binding :: proc(t:^testing.T) {
    source:=core.entity_make(1,1)
    playback:=Playback{frame=3};defer playback_free(&playback)
    append(&playback.states,rig_test_state(source,3,.5));resize(&playback.rows,2);playback.rows[1]=1
    state:=&playback.states[0];state.seen=3;state.skeleton={4,5};state.sampled[0].position={1000,0,0};state.world[3].position={999,999,999}
    worlds:core.Table(core.World_Transform);defer core.table_destroy(&worlds)
    testing.expect(t,modifier_append(&worlds,source,core.World_Transform{transform={{20,0,0},1,{1,1,1}}}))
    sockets:=make([]asset.Skeleton_Socket,1)
    base.text_set(sockets[0].name[:],"grip");base.text_set(sockets[0].bone[:],"joint3");sockets[0].offset=mm.TRANSFORM_IDENTITY;sockets[0].offset.position={0,.2,0}
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    append(&skeletons.contents,Skeleton_Content{id=state.skeleton,sockets=sockets})
    target:=spatial_bone(source,"joint3")
    binding:Spatial_Target_Binding;defer delete(binding.path)
    result,ok:=spatial_target_sample(target,&binding,&playback,&skeletons,{},{},core.read(&worlds))
    testing.expect(t,ok && linalg.length(result.position-mm.Vec3{20,1,0})<1e-5,"the root of a skeleton is its entity, the others its sampled pose")
    target=spatial_socket(source,"grip",{{0,0,.5},1,{1,1,1}})
    result,ok=spatial_target_sample(target,&binding,&playback,&skeletons,{},{},core.read(&worlds))
    testing.expect(t,ok && linalg.length(result.position-mm.Vec3{20,1.2,.5})<1e-5)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<32 {value,valid:=spatial_target_sample(target,&binding,&playback,&skeletons,{},{},core.read(&worlds));stable &&=valid && value==result}
    context=saved
    testing.expect(t,stable)
    state.bound+=1;state.targets[3]=base.name_hash("missing");state.aliases[3]=state.targets[3]
    _,ok=spatial_target_sample(target,&binding,&playback,&skeletons,{},{},core.read(&worlds))
    testing.expect(t,!ok,"a rebound rig without the bone of the socket")
    testing.expect(t,!spatial_target_valid(spatial_entity(core.NONE)) && spatial_target_valid(spatial_entity(core.NONE),false),"a profile names the kind; the goal, the entity")
}

@(test)
follow_switches_spaces_without_a_jump_and_keeps_its_channel_masks :: proc(t:^testing.T) {
    rig,anchor:=core.entity_make(1,1),core.entity_make(2,1)
    state:=rig_test_state(rig,3,.5);defer playing_free(&state)
    worlds:core.Table(core.World_Transform);defer core.table_destroy(&worlds)
    testing.expect(t,modifier_append(&worlds,anchor,core.World_Transform{transform={{10,0,0},1,{1,1,1}}}))
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    follow:=FOLLOW_CONSTRAINT_DEFAULT;base.text_set(follow.name[:],"hand");follow.bone=bone_ref("joint3");follow.target=spatial_point({3,2,0})
    testing.expect(t,modifier_append(&modifiers.follow,rig,follow))
    inputs:=Constraint_Inputs{worlds=core.read(&worlds)}
    testing.expect(t,rigs_apply(&state,&modifiers,inputs,nil,{},mm.TRANSFORM_IDENTITY,0))
    before:=state.world[3]
    testing.expect(t,linalg.length(before.position-mm.Vec3{3,2,0})<1e-5)
    modifiers.follow.values[0].keep_world=true
    modifiers.follow.values[0].target=spatial_entity(anchor)
    copy(state.local[:],state.rest[:])
    testing.expect(t,rigs_apply(&state,&modifiers,inputs,nil,{},mm.TRANSFORM_IDENTITY,0))
    testing.expect(t,linalg.length(state.world[3].position-before.position)<1e-5,"keep_world: no jump when the target changes")
    worlds.values[0].position.x+=1
    copy(state.local[:],state.rest[:])
    testing.expect(t,rigs_apply(&state,&modifiers,inputs,nil,{},mm.TRANSFORM_IDENTITY,0))
    testing.expect(t,linalg.length(state.world[3].position-before.position-mm.Vec3{1,0,0})<1e-5)
    modifiers.follow.values[0].position=false
    copy(state.local[:],state.rest[:])
    testing.expect(t,rigs_apply(&state,&modifiers,inputs,nil,{},mm.TRANSFORM_IDENTITY,0))
    testing.expect(t,linalg.length(state.world[3].position-mm.Vec3{0,1,0})<1e-5)
}

@(test)
ik_holds_the_rotation_it_is_asked_and_look_keeps_its_up_axis :: proc(t:^testing.T) {
    problems:core.Problems
    rig,helper:=core.entity_make(1,1),core.entity_make(2,1)
    state:=rig_test_state(rig,3,.5);defer playing_free(&state)
    iks:core.Table(IK_Constraint);looks:core.Table(Look_Constraint)
    defer {core.table_destroy(&iks);core.table_destroy(&looks)}
    turn:=mm.quat_axis_angle({0,1,0},.7)
    ik:=IK_CONSTRAINT_DEFAULT;ik.rig=rig;ik.root,ik.joint,ik.end=bone_ref("joint1"),bone_ref("joint2"),bone_ref("joint3")
    ik.target=spatial_world({{.4,.6,0},turn,{1,1,1}});ik.hold=.Target
    testing.expect(t,modifier_append(&iks,helper,ik))
    cache:Animation_Constraints;defer constraints_free(&cache)
    playback:Playback;defer playback_free(&playback)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    constraints_apply(&state,&playback,{ik=core.read(&iks),problems=&problems},&cache,&transforms,{},0)
    testing.expect_value(t,problems.count,0)
    testing.expect(t,linalg.length(state.world[3].position-ik.target.position)<1e-4 && mm.quat_angle(state.world[3].rotation,turn)<1e-4)
    bent:=mm.quat_axis_angle({0,0,1},.4)
    for hold in IK_Hold {
        if hold==.Target {continue}
        copy(state.local[:],state.rest[:]);state.local[3].rotation=bent
        core.edit_at(&iks,0).hold=hold;cache.stamps={}
        testing.expect(t,lib.pose_world(state.parents[:],state.local[:],state.world[:]))
        held:=state.world[3].rotation
        constraints_apply(&state,&playback,{ik=core.read(&iks),problems=&problems},&cache,&transforms,{},0)
        testing.expect(t,linalg.length(state.world[3].position-ik.target.position)<1e-4,"the end reaches whatever it holds")
        kept:=mm.quat_angle(state.local[3].rotation,bent) if hold==.Joint else mm.quat_angle(state.world[3].rotation,held)
        testing.expect(t,kept<1e-4,"Joint keeps the rotation of the end relative to the joint; World, in the world")
    }
    look:=LOOK_CONSTRAINT_DEFAULT;look.rig=rig;look.bone=bone_ref("joint3")
    look.target=spatial_point({0,.75,-5});look.forward,look.up,look.world_up,look.use_up={0,0,-1},{1,0,0},{0,1,0},true
    testing.expect(t,modifier_append(&looks,helper,look))
    copy(state.local[:],state.rest[:])
    cache.stamps={}
    constraints_apply(&state,&playback,{look=core.read(&looks),problems=&problems},&cache,&transforms,{},0)
    testing.expect_value(t,problems.count,0)
    aimed:=linalg.normalize(look.target.position-state.world[3].position)
    up:=mm.quat_rotate(state.world[3].rotation,{1,0,0})
    wanted:=linalg.normalize(look.world_up-aimed*linalg.dot(look.world_up,aimed))
    testing.expect(t,linalg.dot(mm.quat_rotate(state.world[3].rotation,look.forward),aimed)>.9999 && linalg.dot(up,wanted)>.9999,"the bone aims and its up axis turns to world_up around the aim")
}

@(private="file")
Rig_Shapes_World :: struct {
    using world:core.Test_World,
    configs:core.Table(Pose_Modifiers),
    animations:core.Table(Animation),
    attachments:core.Table(Bone_Attachment),
    playback:Playback,
    modifiers:Modifier_Runtime,
    requests:Modifier_Requests,
}

@(test)
named_modifier_goals_follow_their_operation_through_a_reordered_profile :: proc(t:^testing.T) {
    problems:core.Problems
    directory:=base.test_folder(t,"modifier-identity")
    path:=fmt.tprintf("%s/rig.pose",directory)
    head,eyes:=LOOK_CONSTRAINT_DEFAULT,LOOK_CONSTRAINT_DEFAULT
    head.bone,eyes.bone=bone_ref("head"),bone_ref("eyes")
    hands:=MULTI_IK_CONSTRAINT_DEFAULT;base.text_set(hands.name[:],"hands");hands.root=bone_ref("joint1")
    hands.joint_count,hands.effector_count=1,2;hands.joints[0]=MULTI_IK_JOINT_DEFAULT;hands.joints[0].bone=hands.root
    for &effector,i in hands.effectors[:2] {effector=MULTI_IK_EFFECTOR_DEFAULT;effector.bone=bone_ref("joint2" if i==0 else "joint3");base.text_set(effector.name[:],"Left" if i==0 else "Right")}
    id:=base.Asset_Id{817,819}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    if !testing.expect_value(t,pose_profile_save(path,&types,id,{look={head,eyes},multi_ik={hands}}),asset.Error.None) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_Shapes_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.configs,rig,Pose_Modifiers{profile=id,weight=1,enabled=true});core.test_world_settle(&w)
    profiles:Pose_Assets;defer pose_assets_free(&profiles)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    prepare :: proc(w:^Rig_Shapes_World,profiles:^Pose_Assets,skeletons:^Skeleton_Assets,app:^host.App) -> bool {
        return modifier_prepare(&w.modifiers,core.read(&w.configs),core.read(&w.animations),core.read(&w.attachments),profiles,skeletons,&w.playback,app.assets,app.allocator,nil)
    }
    if !testing.expect(t,prepare(&w,&profiles,&skeletons,&app)) {return}
    modifier_goal(&w.requests,{rig=rig,kind=.Look,target=spatial_point({1,2,3}),weight=1,enabled=true})
    modifier_control(&w.requests,{rig=rig,kind=.Look,weight=.25,enabled=true})
    modifier_goal(&w.requests,{rig=rig,kind=.Multi_IK,target=spatial_point({7,8,9}),weight=1,enabled=true})
    modifier_take(&w.modifiers,&w.requests,core.read(&w.configs),&problems)
    testing.expect(t,len(w.modifiers.goals)==2 && w.modifiers.look.values[0].weight==.25)
    modifier_goal_named(&w.requests,&w.modifiers,{rig=rig,kind=.Look,target=spatial_point({3,4,5}),weight=1,enabled=true},"head")
    modifier_control_named(&w.requests,&w.modifiers,{rig=rig,kind=.Look,weight=.6,enabled=true},"head")
    modifier_goal_named(&w.requests,&w.modifiers,{rig=rig,kind=.Multi_IK,target=spatial_point({9,8,7}),weight=1,enabled=true},"hands")
    // The profile reorders its looks and effectors: what was asked by slot goes; by name, follows.
    hands.effectors[0],hands.effectors[1]=hands.effectors[1],hands.effectors[0]
    testing.expect_value(t,pose_profile_save(path,&types,id,{look={eyes,head},multi_ik={hands}}),asset.Error.None)
    record,found:=asset.registry_find(&assets.registry,id)
    if !testing.expect(t,found) {return}
    record.time+=1;assets.revision+=1
    if !testing.expect(t,prepare(&w,&profiles,&skeletons,&app)) {return}
    testing.expect(t,len(w.modifiers.goals)==0 && w.modifiers.look.values[0].weight==1 && w.modifiers.look.values[1].weight==1)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    modifier_take(&w.modifiers,&w.requests,core.read(&w.configs),&problems)
    context=saved
    testing.expect(t,w.modifiers.look.values[0].target.position=={} && w.modifiers.look.values[1].target.position==mm.Vec3{3,4,5} && w.modifiers.look.values[1].weight==.6)
    testing.expect(t,w.modifiers.multi_ik.values[0].effectors[1].target.position==mm.Vec3{9,8,7} && w.modifiers.multi_ik.values[0].effectors[0].target.position=={} && problems.count==0)
    controls:Modifier_Requests;defer delete(controls.controls.items)
    modifier_goal_named(&w.requests,&w.modifiers,{rig=rig,kind=.Multi_IK,effector=1,target=spatial_point({}),weight=1,enabled=true},"hands")
    modifier_control_named(&controls,&w.modifiers,{rig=rig,kind=.Look,weight=0},"head")
    hands.effector_count=1
    testing.expect_value(t,pose_profile_save(path,&types,id,{look={eyes},multi_ik={hands}}),asset.Error.None)
    record.time+=1;assets.revision+=1
    if !testing.expect(t,prepare(&w,&profiles,&skeletons,&app)) {return}
    modifier_take(&w.modifiers,&w.requests,core.read(&w.configs),&problems)
    testing.expect(t,problems.count==1 && core.problem_find(&problems,rig,"animation.modifier_effector")!=nil && modifier_request_error(&w.modifiers,rig)==.Missing_Effector)
    modifier_controls_take(&w.modifiers,&controls,&problems,0)
    testing.expect(t,problems.count==2 && core.problem_find(&problems,rig,"animation.modifier_name")!=nil && modifier_request_error(&w.modifiers,rig)==.Missing_Operation && w.modifiers.look.values[0].weight==1)
}
