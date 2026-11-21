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
    for point,i in points {spline.controls[i]=spatial_definition_point(point)}
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
    if !testing.expect_value(t,character_document(&doc,&types,{3,4},{match={info=MATCH_INFO_DEFAULT},motion={warp=POSE_WARP_PROFILE_DEFAULT},pose=profile}),asset.Error.None) {return}
    testing.expect_value(t,doc.kind_version,u16(CHARACTER_VERSION))
    path:=fmt.tprintf("%s/shapes.character",base.test_folder(t,"rig-shapes"))
    testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&file,path),asset.Error.None) {return}
    defer asset.asset_close(&file)
    set,read:=character_view(&file,&types);view:=set.pose
    testing.expect_value(t,read,asset.Error.None)
    testing.expect(t,len(view.spline_ik)==1 && view.spline_ik[0].controls[3].position==mm.Vec3{1,3,0} && view.correctives[0].samples[1].curve_value==1 && view.follow[0].target.kind==.Socket)
    testing.expect(t,len(view.curve_poses)==1 && view.curve_poses[0]==pose && len(view.curve_drives)==1 && view.curve_drives[0]==drive)
    // A set of the current version without curve poses, drives and materials is incomplete, and
    // one of another version is refused.
    for name in ([3]string{"curve_poses","curve_drives","curve_materials"}) {
        if table,found:=asset.document_table(&doc,name);found {asset.document_table_remove(&doc,table)}
    }
    for version,i in ([2]u16{CHARACTER_VERSION,CHARACTER_VERSION+1}) {
        doc.kind_version=version
        bytes,written:=asset.document_bytes(&doc,context.temp_allocator)
        if !testing.expect_value(t,written,asset.Error.None) {continue}
        old:asset.Asset
        if !testing.expect_value(t,asset.asset_open(&old,bytes,context.temp_allocator),asset.Error.None) {continue}
        defer asset.asset_close(&old)
        _,error:=character_view(&old,&types)
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
    characters:Character_Assets;defer character_assets_free(&characters)
    corrective:=rig_shapes_corrective()
    playing_pose(&state,.Sampled)[2].rotation=corrective.samples[1].rotation
    splines:=[1]Spline_IK_Constraint{rig_shapes_spline({{0,0,0},{.4,.5,0},{.4,1,0},{0,1.5,0}})}
    prepared:=test_modifier_profile(&modifiers,&characters,rig,{spline_ik=splines[:],correctives={corrective}})
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    expected:=playing_pose(&state,.World)[4]
    testing.expect(t,abs(playing_pose(&state,.Local)[3].scale.x-1.5)<1e-5 && abs(animation_corrective_curve(&modifiers,rig,base.name_hash("bulge"))-1)<1e-5)
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<32 {
        copy(playing_pose(&state,.Local),state.rest[:])
        stable &&=test_rigs_apply(&state,&copied,&characters,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60)
        stable &&=linalg.length(playing_pose(&state,.World)[4].position-expected.position)<1e-5 && animation_corrective_curve(&copied,rig,base.name_hash("bulge"))==1
    }
    context=saved
    testing.expect(t,stable)
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=rig,kind=.Spline_IK,target=spatial_point({1,2,0}),weight=1,enabled=true,goal=true},"tail","end")
    modifier_take(&modifiers,&characters,&requests,nil,0)
    testing.expect_value(t,modifier_override(prepared,.Spline_IK,0,3).target.position,mm.Vec3{1,2,0})
    modifier_states(prepared,.Corrective)[0].base_enabled=false
    copy(playing_pose(&state,.Local),state.rest[:])
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60) && animation_corrective_curve(&modifiers,rig,base.name_hash("bulge"))==0)
    controls:=SPLINE_CONTROLS
    // Out of reach the chain lies along the curve, and says so.
    for point,i in ([4]mm.Vec3{{0,0,0},{0,1,0},{0,2,0},{0,20,0}}) {modifier(&requests,{rig=rig,kind=.Spline_IK,target=spatial_point(point),weight=1,enabled=true,goal=true},"tail",controls[i])}
    modifier_take(&modifiers,&characters,&requests,nil,0)
    copy(playing_pose(&state,.Local),state.rest[:])
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    diagnostic,available:=animation_rig_diagnostic(&modifiers,rig,.Spline_IK,base.name_hash("tail"))
    testing.expect(t,available && diagnostic.valid && !diagnostic.reached && diagnostic.residual>1)
    for point,i in ([4]mm.Vec3{{0,0,0},{0,.5,0},{0,1,0},{0,1.5,0}}) {modifier(&requests,{rig=rig,kind=.Spline_IK,target=spatial_point(point),weight=1,enabled=true,goal=true},"tail",controls[i])}
    modifier_take(&modifiers,&characters,&requests,nil,0)
    copy(playing_pose(&state,.Local),state.rest[:])
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    diagnostic,available=animation_rig_diagnostic(&modifiers,rig,.Spline_IK,base.name_hash("tail"))
    testing.expect(t,available && diagnostic.valid && diagnostic.reached && diagnostic.residual<=.001)
}

@(test)
corrective_curves_drive_the_morph_target_of_their_name :: proc(t:^testing.T) {
    rig:=core.entity_make(1,1)
    state:=rig_test_state(rig,4,.5);defer playing_free(&state)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    corrective:=rig_shapes_corrective();corrective.apply_pose=false
    playing_pose(&state,.Sampled)[2].rotation=corrective.samples[1].rotation
    test_modifier_profile(&modifiers,&characters,rig,{correctives={corrective}})
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,{},nil,{},mm.TRANSFORM_IDENTITY,1.0/60))
    targets:=[2]asset.Morph_Target{{weight=.25},{weight=.5}}
    base.text_set(targets[0].name[:],"bulge");base.text_set(targets[1].name[:],"blink")
    mesh:=Skin_Rig{id={5,7},revision=1,morphs=targets[:]}
    playing:=Morph_Playing{entity=core.entity_make(2,1),source=rig,curve_count=-1};defer morph_playing_free(&playing)
    testing.expect(t,morph_bind(&playing,&mesh,{},base.name_hash("Face"),1) && morph_compose(&playing,&mesh,{},nil,&modifiers))
    testing.expect(t,abs(playing.current[0]-1.25)<1e-5 && playing.current[1]==.5,"the corrective adds to the target it names only")
}

@(test)
spatial_bone_and_socket_targets_read_the_sampled_pose_and_keep_their_binding :: proc(t:^testing.T) {
    source:=core.entity_make(1,1)
    playback:=Playback{frame=3};defer playback_free(&playback)
    append(&playback.states,rig_test_state(source,3,.5));resize(&playback.rows,2);playback.rows[1]=1
    state:=&playback.states[0];state.seen=3;state.skeleton={4,5};playing_pose(state,.Sampled)[0].position={1000,0,0};playing_pose(state,.World)[3].position={999,999,999}
    worlds:core.Table(core.World_Transform);defer core.table_destroy(&worlds)
    testing.expect(t,core.table_append(&worlds,source,core.World_Transform{transform={{20,0,0},1,{1,1,1}}}))
    sockets:=make([]asset.Skeleton_Socket,1)
    base.text_set(sockets[0].name[:],"grip");base.text_set(sockets[0].bone[:],"joint3");sockets[0].offset=mm.TRANSFORM_IDENTITY;sockets[0].offset.position={0,.2,0}
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    append(&skeletons.contents,Skeleton_Content{id=state.skeleton,sockets=sockets})
    target:=spatial_bone(source,"joint3")
    binding:Spatial_Target_Binding;defer delete(binding.path)
    result,ok:=spatial_target_sample(target,&binding,&playback,&skeletons,(^core.Table(core.Transform))(nil),nil,core.read(&worlds))
    testing.expect(t,ok && linalg.length(result.position-mm.Vec3{20,1,0})<1e-5,"the root of a skeleton is its entity, the others its sampled pose")
    target=spatial_socket(source,"grip",{{0,0,.5},1,{1,1,1}})
    result,ok=spatial_target_sample(target,&binding,&playback,&skeletons,(^core.Table(core.Transform))(nil),nil,core.read(&worlds))
    testing.expect(t,ok && linalg.length(result.position-mm.Vec3{20,1.2,.5})<1e-5)
    state.pose_ready=true
    playing_pose(state,.World)[3]=mm.Transform{{6,7,8},mm.quat_axis_angle({0,0,1},mm.PI/2),{1,1,1}}
    cue:=Animation_Cue{anchor=.Bone}
    base.text_set(cue.name[:],"joint3")
    at,found:=cue_pose(&cue,source,&playback,&skeletons,nil,nil,core.read(&worlds))
    testing.expect(t,found && at.position=={6,7,8})
    cue.anchor=.Socket
    base.text_set(cue.name[:],"grip")
    at,found=cue_pose(&cue,source,&playback,&skeletons,nil,nil,core.read(&worlds))
    testing.expect(t,found && linalg.length(at.position-mm.Vec3{5.8,7,8})<1e-5)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<32 {value,valid:=spatial_target_sample(target,&binding,&playback,&skeletons,(^core.Table(core.Transform))(nil),nil,&worlds);stable &&=valid && value==result}
    context=saved
    testing.expect(t,stable)
    state.bound+=1;state.targets[3]=base.name_hash("missing");state.aliases[3]=state.targets[3]
    _,ok=spatial_target_sample(target,&binding,&playback,&skeletons,(^core.Table(core.Transform))(nil),nil,&worlds)
    testing.expect(t,!ok,"a rebound rig without the bone of the socket")
    testing.expect(t,!spatial_target_valid(spatial_entity(core.NONE)) && spatial_target_valid(spatial_entity(core.NONE),false),"a profile names the kind; the goal, the entity")
}

@(test)
follow_switches_spaces_without_a_jump_and_keeps_its_channel_masks :: proc(t:^testing.T) {
    rig,anchor:=core.entity_make(1,1),core.entity_make(2,1)
    state:=rig_test_state(rig,3,.5);defer playing_free(&state)
    worlds:core.Table(core.World_Transform);defer core.table_destroy(&worlds)
    testing.expect(t,core.table_append(&worlds,anchor,core.World_Transform{transform={{10,0,0},1,{1,1,1}}}))
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    characters:Character_Assets;defer character_assets_free(&characters)
    follow:=FOLLOW_CONSTRAINT_DEFAULT;base.text_set(follow.name[:],"hand");follow.bone=bone_ref("joint3");follow.target=spatial_definition_point({3,2,0})
    follows:=[1]Follow_Constraint{follow}
    test_modifier_profile(&modifiers,&characters,rig,{follow=follows[:]})
    inputs:=Constraint_Inputs{worlds=core.read(&worlds)}
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,inputs,nil,{},mm.TRANSFORM_IDENTITY,0))
    before:=playing_pose(&state,.World)[3]
    testing.expect(t,linalg.length(before.position-mm.Vec3{3,2,0})<1e-5)
    follows[0].keep_world=true
    requests:Animation_Requests;defer delete(requests.modifiers.items)
    modifier(&requests,{rig=rig,kind=.Follow,target=spatial_entity(anchor),weight=1,enabled=true,goal=true},"hand")
    modifier_take(&modifiers,&characters,&requests,nil,0)
    copy(playing_pose(&state,.Local),state.rest[:])
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,inputs,nil,{},mm.TRANSFORM_IDENTITY,0))
    testing.expect(t,linalg.length(playing_pose(&state,.World)[3].position-before.position)<1e-5,"keep_world: no jump when the target changes")
    worlds.values[0].position.x+=1
    copy(playing_pose(&state,.Local),state.rest[:])
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,inputs,nil,{},mm.TRANSFORM_IDENTITY,0))
    testing.expect(t,linalg.length(playing_pose(&state,.World)[3].position-before.position-mm.Vec3{1,0,0})<1e-5)
    follows[0].position=false
    copy(playing_pose(&state,.Local),state.rest[:])
    testing.expect(t,test_rigs_apply(&state,&modifiers,&characters,inputs,nil,{},mm.TRANSFORM_IDENTITY,0))
    testing.expect(t,linalg.length(playing_pose(&state,.World)[3].position-mm.Vec3{0,1,0})<1e-5)
}

@(test)
ik_holds_the_rotation_it_is_asked_and_look_keeps_its_up_axis :: proc(t:^testing.T) {
    problems:core.Problems
    rig:=core.entity_make(1,1)
    state:=rig_test_state(rig,3,.5);defer playing_free(&state)
    turn:=mm.quat_axis_angle({0,1,0},.7)
    ik:=IK_CONSTRAINT_DEFAULT;ik.root,ik.joint,ik.end=bone_ref("joint1"),bone_ref("joint2"),bone_ref("joint3")
    ik.target={position={.4,.6,0},rotation=turn,scale={1,1,1}};ik.hold=.Target
    iks:=[1]IK_Constraint{ik}
    cache:Modifier_Runtime;defer modifier_runtime_free(&cache)
    characters:Character_Assets;defer character_assets_free(&characters)
    test_modifier_profile(&cache,&characters,rig,{ik=iks[:]})
    playback:Playback;defer playback_free(&playback)
    transforms:core.Table(core.Transform);defer core.table_destroy(&transforms)
    constraints_apply(&state,&playback,{problems=&problems},&cache,&transforms,{},0,characters=&characters)
    testing.expect_value(t,problems.count,0)
    testing.expect(t,linalg.length(playing_pose(&state,.World)[3].position-ik.target.position)<1e-4 && mm.quat_angle(playing_pose(&state,.World)[3].rotation,turn)<1e-4)
    bent:=mm.quat_axis_angle({0,0,1},.4)
    for hold in IK_Hold {
        if hold==.Target {continue}
        copy(playing_pose(&state,.Local),state.rest[:]);playing_pose(&state,.Local)[3].rotation=bent
        iks[0].hold=hold
        testing.expect(t,lib.pose_world(state.parents[:],playing_pose(&state,.Local),playing_pose(&state,.World)))
        held:=playing_pose(&state,.World)[3].rotation
        constraints_apply(&state,&playback,{problems=&problems},&cache,&transforms,{},0,characters=&characters)
        testing.expect(t,linalg.length(playing_pose(&state,.World)[3].position-ik.target.position)<1e-4,"the end reaches whatever it holds")
        kept:=mm.quat_angle(playing_pose(&state,.Local)[3].rotation,bent) if hold==.Joint else mm.quat_angle(playing_pose(&state,.World)[3].rotation,held)
        testing.expect(t,kept<1e-4,"Joint keeps the rotation of the end relative to the joint; World, in the world")
    }
    look:=LOOK_CONSTRAINT_DEFAULT;look.bone=bone_ref("joint3")
    look.target=spatial_definition_point({0,.75,-5});look.forward,look.up,look.world_up,look.use_up={0,0,-1},{1,0,0},{0,1,0},true
    test_modifier_profile(&cache,&characters,rig,{look={look}})
    copy(playing_pose(&state,.Local),state.rest[:])
    constraints_apply(&state,&playback,{problems=&problems},&cache,&transforms,{},0,characters=&characters)
    testing.expect_value(t,problems.count,0)
    aimed:=linalg.normalize(look.target.position-playing_pose(&state,.World)[3].position)
    up:=mm.quat_rotate(playing_pose(&state,.World)[3].rotation,{1,0,0})
    wanted:=linalg.normalize(look.world_up-aimed*linalg.dot(look.world_up,aimed))
    testing.expect(t,linalg.dot(mm.quat_rotate(playing_pose(&state,.World)[3].rotation,look.forward),aimed)>.9999 && linalg.dot(up,wanted)>.9999,"the bone aims and its up axis turns to world_up around the aim")
}

@(private)
@(test_world)
Rig_Shapes_World :: struct {
    using world:Test_World,
    animations:core.Table(Animation),
    attachments:core.Table(Bone_Attachment),
    playback:Playback,
    modifiers:Modifier_Runtime,
    requests:Animation_Requests,
}

@(test)
named_modifier_goals_follow_their_operation_through_a_reordered_profile :: proc(t:^testing.T) {
    problems:core.Problems
    directory:=base.test_folder(t,"modifier-identity")
    head,eyes:=LOOK_CONSTRAINT_DEFAULT,LOOK_CONSTRAINT_DEFAULT
    head.bone,eyes.bone=bone_ref("head"),bone_ref("eyes")
    hands:=MULTI_IK_CONSTRAINT_DEFAULT;base.text_set(hands.name[:],"hands");hands.root=bone_ref("joint1")
    hands.joints=make([]Multi_IK_Joint,1,context.temp_allocator);hands.effectors=make([]Multi_IK_Effector,2,context.temp_allocator);hands.joints[0]=MULTI_IK_JOINT_DEFAULT;hands.joints[0].bone=hands.root
    for &effector,i in hands.effectors[:2] {effector=MULTI_IK_EFFECTOR_DEFAULT;effector.bone=bone_ref("joint2" if i==0 else "joint3");base.text_set(effector.name[:],"Left" if i==0 else "Right")}
    id:=base.Asset_Id{817,819}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    if !test_character_save(t,directory,"rig",&types,id,{pose={look={head,eyes},multi_ik={hands}}}) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Rig_Shapes_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    rig:=core.create(&w.entities)
    player:=ANIMATION_DEFAULT;player.asset=id;core.add(&w.animations,rig,player);test_world_settle(&w)
    profiles:Character_Assets;defer character_assets_free(&profiles)
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    prepare :: proc(w:^Rig_Shapes_World,profiles:^Character_Assets,skeletons:^Skeleton_Assets,app:^host.App) -> bool {
        return modifier_prepare(&w.modifiers,&w.animations,&w.attachments,profiles,skeletons,&w.playback,app.assets,app.allocator,nil)
    }
    if !testing.expect(t,prepare(&w,&profiles,&skeletons,&app)) {return}
    modifier(&w.requests,{rig=rig,kind=.Look,target=spatial_point({1,2,3}),weight=1,enabled=true,goal=true},"head")
    modifier(&w.requests,{rig=rig,kind=.Look,weight=.25,enabled=true},"head")
    modifier(&w.requests,{rig=rig,kind=.Multi_IK,target=spatial_point({7,8,9}),weight=1,enabled=true,goal=true},"hands","Left")
    modifier_take(&w.modifiers,&profiles,&w.requests,&problems,0)
    prepared:=modifier_rig(&w.modifiers,rig)
    testing.expect(t,modifier_override(prepared,.Multi_IK,0,0)!=nil && test_modifier_weight(&w.modifiers,rig,.Look,"head")==.25)
    modifier(&w.requests,{rig=rig,kind=.Look,target=spatial_point({3,4,5}),weight=1,enabled=true,goal=true},"head")
    modifier(&w.requests,{rig=rig,kind=.Look,weight=.6,enabled=true},"head")
    modifier(&w.requests,{rig=rig,kind=.Multi_IK,target=spatial_point({9,8,7}),weight=1,enabled=true,goal=true},"hands","Left")
    hands.effectors[0],hands.effectors[1]=hands.effectors[1],hands.effectors[0]
    test_character_save(t,directory,"rig",&types,id,{pose={look={eyes,head},multi_ik={hands}}})
    record,found:=asset.registry_find(&assets.registry,id)
    if !testing.expect(t,found) {return}
    record.time+=1;assets.revision+=1
    if !testing.expect(t,prepare(&w,&profiles,&skeletons,&app)) {return}
    testing.expect(t,modifier_override(prepared,.Multi_IK,0,1)!=nil && test_modifier_weight(&w.modifiers,rig,.Look,"head")==.25)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    modifier_take(&w.modifiers,&profiles,&w.requests,&problems,0)
    context=saved
    testing.expect(t,modifier_override(prepared,.Look,0)==nil && modifier_override(prepared,.Look,1).target.position==mm.Vec3{3,4,5} && test_modifier_weight(&w.modifiers,rig,.Look,"head")==.6)
    testing.expect(t,modifier_override(prepared,.Multi_IK,0,1).target.position==mm.Vec3{9,8,7} && modifier_override(prepared,.Multi_IK,0,0)==nil && problems.count==0)
    controls:Animation_Requests;defer delete(controls.modifiers.items)
    modifier(&w.requests,{rig=rig,kind=.Multi_IK,target=spatial_point({}),weight=1,enabled=true,goal=true},"hands","Left")
    modifier(&controls,{rig=rig,kind=.Look,weight=0},"head")
    hands.effectors=hands.effectors[:1]
    test_character_save(t,directory,"rig",&types,id,{pose={look={eyes},multi_ik={hands}}})
    record.time+=1;assets.revision+=1
    if !testing.expect(t,prepare(&w,&profiles,&skeletons,&app)) {return}
    modifier_take(&w.modifiers,&profiles,&w.requests,&problems,0)
    testing.expect(t,problems.count==1 && core.problem_find(&problems,rig,"animation.modifier_effector")!=nil && modifier_request_error(&w.modifiers,rig)==.Missing_Effector)
    modifier_take(&w.modifiers,&profiles,&controls,&problems,0)
    testing.expect(t,problems.count==2 && core.problem_find(&problems,rig,"animation.modifier_name")!=nil && modifier_request_error(&w.modifiers,rig)==.Missing_Operation && test_modifier_weight(&w.modifiers,rig,.Look,"eyes")==1)
}
