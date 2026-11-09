package mirai_anim

import "core:testing"
import math "mirai:std/math"

Body_Test_Bone :: struct {name,parent:string,position:math.Vec3}
Body_Test_Rig :: struct {parents:[]i32,names:[]string,rest,world:[]math.Transform}

// A rig from bones at world positions, each parented by name to an earlier one.
body_test_rig :: proc(bones:[]Body_Test_Bone) -> (rig:Body_Test_Rig) {
    n:=len(bones)
    rig={make([]i32,n,context.temp_allocator),make([]string,n,context.temp_allocator),make([]math.Transform,n,context.temp_allocator),make([]math.Transform,n,context.temp_allocator)}
    for bone,i in bones {
        rig.names[i]=bone.name;rig.parents[i]=-1
        for other,j in bones[:i] {if other.name==bone.parent {rig.parents[i]=i32(j)}}
        origin:math.Vec3
        if rig.parents[i]>=0 {origin=bones[rig.parents[i]].position}
        rig.rest[i]={bone.position-origin,1,{1,1,1}}
    }
    return
}
body_test_bone :: proc(rig:Body_Test_Rig,name:string) -> i32 {
    for value,i in rig.names {if value==name {return i32(i)}}
    return -2
}
body_test_expect :: proc(t:^testing.T,rig:Body_Test_Rig,map_:Body_Map,part:Body_Part,name:string,loc:=#caller_location) {
    bone:=map_.bones[part]
    found:=rig.names[bone] if bone>=0 else "(none)"
    testing.expectf(t,found==name,"%v: expected %s, found %s",part,name,found,loc=loc)
}

// A humanoid rig with the bone names of common game skeletons (pelvis, spine_01 to 05),
// facing -Z with its left at -X, in meters.
body_test_humanoid :: proc() -> Body_Test_Rig {
    side :: proc(bones:^[dynamic]Body_Test_Bone,s:string,x:f32) {
        n :: proc(base,s:string) -> string {return body_test_concat(base,s)}
        append(bones,
            Body_Test_Bone{n("clavicle_",s),"spine_05",{x*.03,1.45,0}},
            Body_Test_Bone{n("upperarm_",s),n("clavicle_",s),{x*.17,1.42,0}},
            Body_Test_Bone{n("upperarm_twist_01_",s),n("upperarm_",s),{x*.25,1.42,0}},
            Body_Test_Bone{n("lowerarm_",s),n("upperarm_",s),{x*.45,1.42,.02}},
            Body_Test_Bone{n("lowerarm_twist_01_",s),n("lowerarm_",s),{x*.55,1.42,0}},
            Body_Test_Bone{n("hand_",s),n("lowerarm_",s),{x*.70,1.42,0}},
            Body_Test_Bone{n("index_01_",s),n("hand_",s),{x*.78,1.42,-.02}},
            Body_Test_Bone{n("thumb_01_",s),n("hand_",s),{x*.74,1.41,-.04}},
            Body_Test_Bone{n("thigh_",s),"pelvis",{x*.09,.93,0}},
            Body_Test_Bone{n("thigh_twist_01_",s),n("thigh_",s),{x*.09,.75,0}},
            Body_Test_Bone{n("calf_",s),n("thigh_",s),{x*.10,.50,-.02}},
            Body_Test_Bone{n("foot_",s),n("calf_",s),{x*.11,.08,.02}},
            Body_Test_Bone{n("ball_",s),n("foot_",s),{x*.12,.02,-.12}},
        )
    }
    bones:=make([dynamic]Body_Test_Bone,context.temp_allocator)
    append(&bones,
        Body_Test_Bone{"Skeleton","",{}},Body_Test_Bone{"root","Skeleton",{}},
        Body_Test_Bone{"pelvis","root",{0,.96,0}},
        Body_Test_Bone{"spine_01","pelvis",{0,1.00,0}},Body_Test_Bone{"spine_02","spine_01",{0,1.07,0}},
        Body_Test_Bone{"spine_03","spine_02",{0,1.14,0}},Body_Test_Bone{"spine_04","spine_03",{0,1.22,0}},
        Body_Test_Bone{"spine_05","spine_04",{0,1.32,0}},
        Body_Test_Bone{"neck_01","spine_05",{0,1.48,0}},Body_Test_Bone{"neck_02","neck_01",{0,1.53,0}},
        Body_Test_Bone{"head","neck_02",{0,1.58,0}},
    )
    side(&bones,"l",-1);side(&bones,"r",1)
    append(&bones,
        Body_Test_Bone{"ik_foot_root","root",{}},Body_Test_Bone{"ik_foot_l","ik_foot_root",{-.11,.08,0}},
        Body_Test_Bone{"ik_hand_root","root",{}},Body_Test_Bone{"ik_hand_gun","ik_hand_root",{.7,1.4,0}},
        Body_Test_Bone{"interaction","root",{}},Body_Test_Bone{"center_of_mass","root",{0,1,0}},
    )
    return body_test_rig(bones[:])
}
body_test_concat :: proc(a,b:string) -> string {
    out:=make([]u8,len(a)+len(b),context.temp_allocator)
    copy(out,a);copy(out[len(a):],b)
    return string(out)
}

@(test)
body_detect_finds_the_parts_of_a_game_humanoid_and_its_axes :: proc(t:^testing.T) {
    rig:=body_test_humanoid()
    map_:=body_map_empty()
    facing:math.Vec3
    if !testing.expect(t,body_detect(rig.parents,rig.names,rig.rest,rig.world,&map_,&facing)) {return}
    expected:=[Body_Part]string{
        .Pelvis="pelvis",.Neck="neck_01",.Head="head",
        .Clavicle_L="clavicle_l",.Shoulder_L="upperarm_l",.Elbow_L="lowerarm_l",.Hand_L="hand_l",
        .Clavicle_R="clavicle_r",.Shoulder_R="upperarm_r",.Elbow_R="lowerarm_r",.Hand_R="hand_r",
        .Hip_L="thigh_l",.Knee_L="calf_l",.Foot_L="foot_l",.Toe_L="ball_l",
        .Hip_R="thigh_r",.Knee_R="calf_r",.Foot_R="foot_r",.Toe_R="ball_r",
    }
    for name,part in expected {
        body_test_expect(t,rig,map_,part,name)
        testing.expectf(t,map_.confidence[part]>=.8,"%v confidence %v",part,map_.confidence[part])
    }
    testing.expect_value(t,map_.up,math.Vec3{0,1,0})
    testing.expect_value(t,facing,math.Vec3{0,0,-1})
    testing.expect(t,map_.axes_confidence>=.8)
    testing.expect(t,body_map_valid(map_,len(rig.parents)))

    spine:[8]i32
    count,ok:=body_spine(rig.parents,map_,spine[:])
    testing.expect(t,ok && count==5 && rig.names[spine[0]]=="spine_01" && rig.names[spine[4]]=="spine_05")
    _,short:=body_spine(rig.parents,map_,spine[:2]);testing.expect(t,!short)

    regions:=make([]i8,len(rig.parents),context.temp_allocator)
    testing.expect(t,body_regions(rig.parents,map_,regions))
    region :: proc(rig:Body_Test_Rig,regions:[]i8,name:string) -> i8 {return regions[body_test_bone(rig,name)]}
    testing.expect_value(t,region(rig,regions,"index_01_l"),i8(Body_Region.Arm_L))
    testing.expect_value(t,region(rig,regions,"clavicle_r"),i8(Body_Region.Arm_R))
    testing.expect_value(t,region(rig,regions,"thigh_twist_01_r"),i8(Body_Region.Leg_R))
    testing.expect_value(t,region(rig,regions,"spine_03"),i8(Body_Region.Spine))
    testing.expect_value(t,region(rig,regions,"neck_02"),i8(Body_Region.Head))
    testing.expect_value(t,region(rig,regions,"root"),i8(Body_Region.Hips))
    testing.expect_value(t,region(rig,regions,"ik_foot_l"),i8(-1))

    unassigned:[16]i32
    total,listed:=body_unassigned(rig.parents,map_,regions,unassigned[:])
    testing.expect(t,listed && total==6)
    for bone in unassigned[:total] {testing.expect(t,rig.names[bone]=="ik_foot_root" || rig.names[bone]=="ik_foot_l" || rig.names[bone]=="ik_hand_root" || rig.names[bone]=="ik_hand_gun" || rig.names[bone]=="interaction" || rig.names[bone]=="center_of_mass")}

    mask:=make([]f32,len(rig.parents),context.temp_allocator)
    testing.expect(t,body_mask(rig.parents,map_,{.Arm_L,.Arm_R},regions,mask))
    testing.expect(t,mask[body_test_bone(rig,"hand_r")]==1 && mask[body_test_bone(rig,"head")]==0 && mask[body_test_bone(rig,"ik_hand_gun")]==0)
    testing.expect(t,body_mask(rig.parents,map_,BODY_REGIONS_ALL,regions,mask))
    for value in mask {testing.expect_value(t,value,f32(1))}

    height:=body_height(map_,rig.world)
    testing.expect(t,height>1.5 && height<1.6)
}

@(test)
body_detect_reads_mixamo_biped_and_motion_capture_names :: proc(t:^testing.T) {
    mixamo:=body_test_rig({
        {"mixamorig:Hips","",{0,1,0}},{"mixamorig:Spine","mixamorig:Hips",{0,1.1,0}},{"mixamorig:Spine1","mixamorig:Spine",{0,1.2,0}},
        {"mixamorig:Neck","mixamorig:Spine1",{0,1.5,0}},{"mixamorig:Head","mixamorig:Neck",{0,1.6,0}},{"mixamorig:HeadTop_End","mixamorig:Head",{0,1.8,0}},
        {"mixamorig:LeftShoulder","mixamorig:Spine1",{.05,1.45,0}},{"mixamorig:LeftArm","mixamorig:LeftShoulder",{.18,1.42,0}},
        {"mixamorig:LeftForeArm","mixamorig:LeftArm",{.45,1.42,0}},{"mixamorig:LeftHand","mixamorig:LeftForeArm",{.7,1.42,0}},
        {"mixamorig:LeftHandIndex1","mixamorig:LeftHand",{.78,1.42,0}},
        {"mixamorig:RightShoulder","mixamorig:Spine1",{-.05,1.45,0}},{"mixamorig:RightArm","mixamorig:RightShoulder",{-.18,1.42,0}},
        {"mixamorig:RightForeArm","mixamorig:RightArm",{-.45,1.42,0}},{"mixamorig:RightHand","mixamorig:RightForeArm",{-.7,1.42,0}},
        {"mixamorig:LeftUpLeg","mixamorig:Hips",{.09,.95,0}},{"mixamorig:LeftLeg","mixamorig:LeftUpLeg",{.1,.5,0}},
        {"mixamorig:LeftFoot","mixamorig:LeftLeg",{.1,.08,0}},{"mixamorig:LeftToeBase","mixamorig:LeftFoot",{.1,.02,.12}},
        {"mixamorig:LeftToe_End","mixamorig:LeftToeBase",{.1,.02,.2}},
        {"mixamorig:RightUpLeg","mixamorig:Hips",{-.09,.95,0}},{"mixamorig:RightLeg","mixamorig:RightUpLeg",{-.1,.5,0}},
        {"mixamorig:RightFoot","mixamorig:RightLeg",{-.1,.08,0}},{"mixamorig:RightToeBase","mixamorig:RightFoot",{-.1,.02,.12}},
    })
    map_:=body_map_empty()
    facing:math.Vec3
    if !testing.expect(t,body_detect(mixamo.parents,mixamo.names,mixamo.rest,mixamo.world,&map_,&facing)) {return}
    body_test_expect(t,mixamo,map_,.Pelvis,"mixamorig:Hips")
    body_test_expect(t,mixamo,map_,.Head,"mixamorig:Head")
    body_test_expect(t,mixamo,map_,.Clavicle_L,"mixamorig:LeftShoulder")
    body_test_expect(t,mixamo,map_,.Shoulder_L,"mixamorig:LeftArm")
    body_test_expect(t,mixamo,map_,.Elbow_R,"mixamorig:RightForeArm")
    body_test_expect(t,mixamo,map_,.Hand_L,"mixamorig:LeftHand")
    body_test_expect(t,mixamo,map_,.Knee_L,"mixamorig:LeftLeg")
    body_test_expect(t,mixamo,map_,.Toe_L,"mixamorig:LeftToeBase")
    body_test_expect(t,mixamo,map_,.Foot_R,"mixamorig:RightFoot")
    // A rig from a source that faces the other way: its left is at +X and it faces +Z, so the detector is covered in both directions.
    testing.expect_value(t,facing,math.Vec3{0,0,1})
    testing.expect(t,map_.up==math.Vec3{0,1,0} && body_map_valid(map_,len(mixamo.parents)),"its map stands on its up whatever it faces")

    // A body that lies along the forward has no up across it: the map keeps +Y as a guess.
    lying:=body_test_rig({
        {"hips","",{0,.2,0}},{"neck","hips",{0,.2,-.5}},{"head","neck",{0,.2,-.6}},
        {"thigh_l","hips",{-.1,.2,.05}},{"calf_l","thigh_l",{-.1,.2,.5}},{"foot_l","calf_l",{-.1,.2,.9}},
        {"thigh_r","hips",{.1,.2,.05}},{"calf_r","thigh_r",{.1,.2,.5}},{"foot_r","calf_r",{.1,.2,.9}},
    })
    map_=body_map_empty()
    if !testing.expect(t,body_detect(lying.parents,lying.names,lying.rest,lying.world,&map_,&facing)) {return}
    testing.expect(t,map_.bones[.Foot_L]>=0 && map_.up==math.Vec3{0,1,0} && map_.axes_confidence<=.1 && abs(facing.z)<1e-3,"a lying body keeps its parts and a valid up")

    // Biped hangs the thighs from the spine, below the pelvis.
    biped:=body_test_rig({
        {"Bip01","",{0,1,0}},{"Bip01 Pelvis","Bip01",{0,1,0}},{"Bip01 Spine","Bip01 Pelvis",{0,1.05,0}},
        {"Bip01 L Thigh","Bip01 Spine",{-.1,.95,0}},{"Bip01 L Calf","Bip01 L Thigh",{-.1,.5,0}},{"Bip01 L Foot","Bip01 L Calf",{-.1,.08,0}},{"Bip01 L Toe0","Bip01 L Foot",{-.1,.02,-.12}},
        {"Bip01 R Thigh","Bip01 Spine",{.1,.95,0}},{"Bip01 R Calf","Bip01 R Thigh",{.1,.5,0}},{"Bip01 R Foot","Bip01 R Calf",{.1,.08,0}},{"Bip01 R Toe0","Bip01 R Foot",{.1,.02,-.12}},
        {"Bip01 Spine1","Bip01 Spine",{0,1.25,0}},{"Bip01 Neck","Bip01 Spine1",{0,1.5,0}},{"Bip01 Head","Bip01 Neck",{0,1.6,0}},
        {"Bip01 L Clavicle","Bip01 Neck",{-.05,1.48,0}},{"Bip01 L UpperArm","Bip01 L Clavicle",{-.18,1.45,0}},{"Bip01 L Forearm","Bip01 L UpperArm",{-.45,1.45,0}},{"Bip01 L Hand","Bip01 L Forearm",{-.7,1.45,0}},
    })
    map_=body_map_empty()
    if !testing.expect(t,body_detect(biped.parents,biped.names,biped.rest,biped.world,&map_,&facing)) {return}
    body_test_expect(t,biped,map_,.Pelvis,"Bip01 Pelvis")
    body_test_expect(t,biped,map_,.Hip_R,"Bip01 R Thigh")
    body_test_expect(t,biped,map_,.Toe_L,"Bip01 L Toe0")
    body_test_expect(t,biped,map_,.Clavicle_L,"Bip01 L Clavicle")
    body_test_expect(t,biped,map_,.Hand_L,"Bip01 L Hand")
    body_test_expect(t,biped,map_,.Hand_R,"(none)")
    // This one faces -Z: its left is at -X.
    testing.expect_value(t,facing,math.Vec3{0,0,-1})

    // Motion capture glues the side to the word and calls the wrist before the hand.
    capture:=body_test_rig({
        {"root","",{0,1,0}},{"lowerback","root",{0,1.1,0}},{"thorax","lowerback",{0,1.3,0}},{"neck","thorax",{0,1.5,0}},{"head","neck",{0,1.6,0}},
        {"lhipjoint","root",{-.05,.98,0}},{"lfemur","lhipjoint",{-.1,.95,0}},{"ltibia","lfemur",{-.1,.5,0}},{"lfoot","ltibia",{-.1,.08,0}},{"ltoes","lfoot",{-.1,.02,-.12}},
        {"rhipjoint","root",{.05,.98,0}},{"rfemur","rhipjoint",{.1,.95,0}},{"rtibia","rfemur",{.1,.5,0}},{"rfoot","rtibia",{.1,.08,0}},{"rtoes","rfoot",{.1,.02,-.12}},
        {"lclavicle","thorax",{-.05,1.45,0}},{"lhumerus","lclavicle",{-.18,1.42,0}},{"lradius","lhumerus",{-.45,1.42,0}},{"lwrist","lradius",{-.7,1.42,0}},{"lhand","lwrist",{-.75,1.42,0}},
    })
    map_=body_map_empty()
    if !testing.expect(t,body_detect(capture.parents,capture.names,capture.rest,capture.world,&map_)) {return}
    body_test_expect(t,capture,map_,.Pelvis,"root")
    body_test_expect(t,capture,map_,.Hip_L,"lfemur")
    body_test_expect(t,capture,map_,.Knee_R,"rtibia")
    body_test_expect(t,capture,map_,.Shoulder_L,"lhumerus")
    body_test_expect(t,capture,map_,.Elbow_L,"lradius")
    body_test_expect(t,capture,map_,.Hand_L,"lwrist")
    testing.expect(t,map_.confidence[.Pelvis]<1)
}

@(test)
body_detect_sides_unnamed_limbs_by_position_and_keeps_manual_parts :: proc(t:^testing.T) {
    rig:=body_test_rig({
        {"hips","",{0,1,0}},{"chest","hips",{0,1.3,0}},{"neck","chest",{0,1.5,0}},{"head","neck",{0,1.6,0}},
        {"thigh_a","hips",{-.1,.95,0}},{"shin_a","thigh_a",{-.1,.5,0}},{"foot_a","shin_a",{-.1,.08,0}},{"toe_a","foot_a",{-.1,.02,-.12}},
        {"thigh_b","hips",{.1,.95,0}},{"shin_b","thigh_b",{.1,.5,0}},{"foot_b","shin_b",{.1,.08,0}},{"toe_b","foot_b",{.1,.02,-.12}},
        {"prop","hips",{0,1,-.3}},
    })
    map_:=body_map_empty()
    facing:math.Vec3
    if !testing.expect(t,body_detect(rig.parents,rig.names,rig.rest,rig.world,&map_,&facing)) {return}
    testing.expect_value(t,facing,math.Vec3{0,0,-1})
    body_test_expect(t,rig,map_,.Foot_L,"foot_a")
    body_test_expect(t,rig,map_,.Knee_R,"shin_b")
    testing.expect(t,map_.confidence[.Foot_L]<1 && map_.confidence[.Foot_L]>.5)
    body_test_expect(t,rig,map_,.Hand_L,"(none)")

    // A person points the left foot at another bone; detecting again keeps it.
    map_.bones[.Foot_L]=body_test_bone(rig,"toe_a");map_.confidence[.Foot_L]=1;map_.manual={.Foot_L}
    map_.bones[.Toe_L]=-1;map_.confidence[.Toe_L]=0
    if !testing.expect(t,body_detect(rig.parents,rig.names,rig.rest,rig.world,&map_)) {return}
    body_test_expect(t,rig,map_,.Foot_L,"toe_a")
    body_test_expect(t,rig,map_,.Toe_L,"(none)")
    testing.expect(t,map_.manual=={.Foot_L} && map_.confidence[.Foot_L]==1)
}

@(test)
body_detect_and_queries_reject_inputs_of_other_sizes :: proc(t:^testing.T) {
    rig:=body_test_humanoid()
    map_:=body_map_empty()
    testing.expect(t,!body_detect(rig.parents,rig.names[:3],rig.rest,rig.world,&map_))
    testing.expect(t,!body_detect(rig.parents,rig.names,rig.rest,rig.world[:2],&map_))
    testing.expect(t,!body_detect(nil,nil,nil,nil,&map_))
    testing.expect(t,map_==body_map_empty())
    nameless:=make([]string,len(rig.names),context.temp_allocator)
    testing.expect(t,body_detect(rig.parents,nameless,rig.rest,rig.world,&map_))
    for bone in map_.bones {testing.expect_value(t,bone,i32(-1))}
    broken:=map_;broken.bones[.Head]=999;testing.expect(t,!body_map_valid(broken,len(rig.parents)))
    broken=map_;broken.bones[.Head]=0;broken.bones[.Neck]=0;testing.expect(t,!body_map_valid(broken,len(rig.parents)))
    regions:=make([]i8,len(rig.parents),context.temp_allocator)
    testing.expect(t,!body_regions(rig.parents,broken,regions))
    for name,part in BODY_PART_NAMES {value,ok:=body_part_parse(name);testing.expect(t,ok && value==part)}
    _,known:=body_part_parse("tail");testing.expect(t,!known)
    legs,_:=body_regions_parse("legs");testing.expect_value(t,legs,Body_Regions{.Leg_L,.Leg_R})
    for part in Body_Part {testing.expect_value(t,body_part_mirror(body_part_mirror(part)),part)}
    testing.expect_value(t,body_part_mirror(.Toe_L),Body_Part.Toe_R)
}

@(test)
body_detect_keeps_hip_and_knee_of_a_leg_without_foot :: proc(t:^testing.T) {
    rig:=body_test_rig({
        {"hips","",{0,1,0}},{"chest","hips",{0,1.3,0}},{"head","chest",{0,1.6,0}},
        {"left shoulder","chest",{-.2,1.45,0}},{"left elbow","left shoulder",{-.45,1.45,0}},{"left wrist","left elbow",{-.7,1.45,0}},
        {"right shoulder","chest",{.2,1.45,0}},{"right elbow","right shoulder",{.45,1.45,0}},{"right wrist","right elbow",{.7,1.45,0}},
        {"left hip","hips",{-.1,.95,0}},{"left knee","left hip",{-.1,.5,0}},{"right hip","hips",{.1,.95,0}},{"right knee","right hip",{.1,.5,0}},
    })
    map_:=body_map_empty()
    facing:math.Vec3
    if !testing.expect(t,body_detect(rig.parents,rig.names,rig.rest,rig.world,&map_,&facing)) {return}
    body_test_expect(t,rig,map_,.Hip_L,"left hip")
    body_test_expect(t,rig,map_,.Knee_R,"right knee")
    body_test_expect(t,rig,map_,.Foot_L,"(none)")
    body_test_expect(t,rig,map_,.Shoulder_L,"left shoulder")
    body_test_expect(t,rig,map_,.Hand_R,"right wrist")
    testing.expect_value(t,facing,math.Vec3{0,0,-1})
}
