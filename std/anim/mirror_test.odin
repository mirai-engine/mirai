package mirai_anim

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

@(private="file")
mirror_test_same :: proc(a,b:math.Transform) -> bool {
    return linalg.length(a.position-b.position)<1e-4 && abs(abs(linalg.dot(a.rotation,b.rotation))-1)<1e-4 && linalg.length(a.scale-b.scale)<1e-4
}

@(test)
mirror_names_swap_the_side_token_and_keep_its_case :: proc(t:^testing.T) {
    buffer:[64]u8
    cases:=[?][2]string{{"thigh_l","thigh_r"},{"hand.L","hand.R"},{"Bip01 L Thigh","Bip01 R Thigh"},{"l_arm","r_arm"},{"mixamorig:LeftHand","mixamorig:RightHand"},{"RIGHT_ARM","LEFT_ARM"},{"index_01_r","index_01_l"}}
    for pair in cases {
        swapped,ok:=mirror_name(pair[0],buffer[:])
        testing.expectf(t,ok && swapped==pair[1],"%s gives %s",pair[0],swapped)
    }
    for name in ([?]string{"spine","small","L","pelvis_center"}) {_,ok:=mirror_name(name,buffer[:]);testing.expectf(t,!ok,"%s has no side",name)}
    short:[5]u8
    _,fits:=mirror_name("LeftArm",short[:]);testing.expect(t,!fits,"a name that does not fit is refused")
}

@(test)
mirrored_poses_swap_sides_reflect_turns_and_undo_themselves :: proc(t:^testing.T) {
    parents:=[4]i32{-1,0,1,1}
    pairs:=[4]i32{0,1,3,2}
    rest:=[4]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{-.2,-.1,0},1,{1,1,1}},{{.2,-.1,0},1,{1,1,1}}}
    corrections:[4]math.Quat;scratch:[8]math.Transform
    plane,prepared:=mirror_prepare(parents[:],pairs[:],rest[:],corrections[:],scratch[:])
    if !testing.expect(t,prepared && abs(abs(plane.normal.x)-1)<1e-5 && abs(plane.offset)<1e-5) {return}
    out:[4]math.Transform
    testing.expect(t,pose_mirror(parents[:],pairs[:],corrections[:],plane,rest[:],out[:],scratch[:]))
    for value,i in out {testing.expectf(t,mirror_test_same(value,rest[i]),"bone %d keeps its rest",i)}
    pose:=rest
    pose[0].position={5,0,3}
    pose[1].rotation=math.quat_axis_angle({0,1,0},.3)
    pose[2].rotation=math.quat_axis_angle({0,0,1},.5)
    testing.expect(t,pose_mirror(parents[:],pairs[:],corrections[:],plane,pose[:],out[:],scratch[:]))
    testing.expect(t,out[0]==pose[0],"the roots keep their transform")
    testing.expect(t,mirror_test_same(out[1],{{0,1,0},math.quat_axis_angle({0,1,0},-.3),{1,1,1}}),"the pelvis turns the other way")
    testing.expect(t,mirror_test_same(out[3],{{.2,-.1,0},math.quat_axis_angle({0,0,1},-.5),{1,1,1}}),"the right leg takes the roll of the left one")
    testing.expect(t,mirror_test_same(out[2],rest[2]),"the left leg takes the rest of the right one")
    twice:[4]math.Transform
    testing.expect(t,pose_mirror(parents[:],pairs[:],corrections[:],plane,out[:],twice[:],scratch[:]))
    for value,i in twice {testing.expectf(t,mirror_test_same(value,pose[i]),"bone %d comes back",i)}
    copy(twice[:],pose[:])
    testing.expect(t,pose_mirror(parents[:],pairs[:],corrections[:],plane,twice[:],twice[:],scratch[:]))
    for value,i in twice {testing.expectf(t,mirror_test_same(value,out[i]),"bone %d mirrors in place",i)}
}

@(test)
mirrored_poses_keep_rest_offsets_between_sides_with_different_bone_axes :: proc(t:^testing.T) {
    parents:=[4]i32{-1,0,1,1}
    pairs:=[4]i32{0,1,3,2}
    flipped:=math.quat_axis_angle({0,1,0},3.14159265)
    rest:=[4]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{-.2,-.1,0},1,{1,1,1}},{{.2,-.1,0},flipped,{1,1,1}}}
    corrections:[4]math.Quat;scratch:[8]math.Transform
    plane,prepared:=mirror_prepare(parents[:],pairs[:],rest[:],corrections[:],scratch[:])
    if !testing.expect(t,prepared) {return}
    out,twice:[4]math.Transform
    testing.expect(t,pose_mirror(parents[:],pairs[:],corrections[:],plane,rest[:],out[:],scratch[:]))
    for value,i in out {testing.expectf(t,mirror_test_same(value,rest[i]),"bone %d keeps its rest",i)}
    pose:=rest;pose[2].rotation=math.quat_axis_angle({0,0,1},.7)
    testing.expect(t,pose_mirror(parents[:],pairs[:],corrections[:],plane,pose[:],out[:],scratch[:]))
    swing:=math.quat_rotate(out[3].rotation,{0,-1,0})
    original:=math.quat_rotate(pose[2].rotation,{0,-1,0})
    testing.expect(t,linalg.length(swing-math.Vec3{-original.x,original.y,original.z})<1e-4,"the right leg points where the left one does, reflected")
    testing.expect(t,pose_mirror(parents[:],pairs[:],corrections[:],plane,out[:],twice[:],scratch[:]))
    for value,i in twice {testing.expectf(t,mirror_test_same(value,pose[i]),"bone %d comes back",i)}
}

@(test)
mirror_refuses_pairs_that_are_not_mutual_and_buffers_of_other_sizes :: proc(t:^testing.T) {
    parents:=[3]i32{-1,0,0}
    rest:=[3]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    corrections:[3]math.Quat;scratch:[6]math.Transform;out:[3]math.Transform
    for pairs in ([?][3]i32{{0,2,2},{1,0,2},{0,1,5},{0,-1,2}}) {
        pairs:=pairs
        _,ok:=mirror_prepare(parents[:],pairs[:],rest[:],corrections[:],scratch[:])
        testing.expectf(t,!ok,"%v is refused",pairs)
        testing.expect(t,!pose_mirror(parents[:],pairs[:],corrections[:],MIRROR_PLANE_DEFAULT,rest[:],out[:],scratch[:]))
    }
    pairs:=[3]i32{0,2,1}
    _,ok:=mirror_prepare(parents[:],pairs[:],rest[:],corrections[:],scratch[:2])
    testing.expect(t,!ok,"scratch must hold a pose")
    testing.expect(t,!pose_mirror(parents[:],pairs[:],corrections[:],MIRROR_PLANE_DEFAULT,rest[:],out[:2],scratch[:]))
    testing.expect(t,!pose_mirror(parents[:],pairs[:],corrections[:],MIRROR_PLANE_DEFAULT,rest[:],out[:],scratch[:5]))
    testing.expect(t,!pose_mirror(parents[:],pairs[:],corrections[:],{normal={2,0,0}},rest[:],out[:],scratch[:]))
}
