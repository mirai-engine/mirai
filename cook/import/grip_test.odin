package importer

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"

// A hand in the frame of its palm: X toward the fingertips from the wrist at the origin, Y across
// and Z out of the palm. A box palm, four fingers that droop toward the palm at their tips, a
// thumb off its side and a forearm skinned to the bone above.
@(private="file")
Grip_Hand :: struct {
    model:Imported_Model,
    palm:mm.Quat, // the palm frame in the space of the hand bone
}

@(private="file")
grip_box :: proc(points:^[dynamic]mm.Vec3,joints:^[dynamic]u16,joint:u16,lo,hi:mm.Vec3) {
    STEP :: 0.005
    for x:=lo.x;x<=hi.x+1e-6;x+=STEP {
        for y:=lo.y;y<=hi.y+1e-6;y+=STEP {
            for z:=lo.z;z<=hi.z+1e-6;z+=STEP {append(points,mm.Vec3{x,y,z});append(joints,joint)}
        }
    }
}

@(private="file")
grip_hand :: proc(skinned_hand:bool) -> (hand:Grip_Hand) {
    bones:=make([]asset.Skeleton_Bone,3,context.temp_allocator)
    for name,i in ([3]string{"forearm_r","hand_r","index_r"}) {
        base.text_set(bones[i].name[:],name);base.text_set(bones[i].path[:],name)
        bones[i].target=base.name_hash(name)
        bones[i].parent=i32(i)-1
        bones[i].rotation=1
        bones[i].scale={1,1,1}
    }
    bones[0].translation,bones[0].scale={.4,1.3,0},{2,2,2}
    bones[0].rotation=linalg.quaternion_angle_axis_f32(.3,{0,1,0})
    bones[1].translation={.12,0,0}
    bones[1].rotation=linalg.quaternion_angle_axis_f32(-.2,{0,0,1})
    bones[2].translation={.09,0,0}
    // The palm turned 45 degrees about the bone and 10 off its length.
    hand.palm=linalg.quaternion_angle_axis_f32(math.PI/18,{0,0,1})*linalg.quaternion_angle_axis_f32(math.PI/4,{1,0,0})

    points:=make([dynamic]mm.Vec3,context.temp_allocator)
    owners:=make([dynamic]u16,context.temp_allocator)
    grip_box(&points,&owners,0,{-.1,-.03,-.01},{-.01,.03,.01})
    if skinned_hand {
        grip_box(&points,&owners,1,{.005,-.04,-.01},{.09,.04,.01})
        grip_box(&points,&owners,1,{.02,.045,0},{.06,.06,.015})
        for y in ([4]f32{-.03,-.01,.01,.03}) {
            grip_box(&points,&owners,2,{.09,y-.007,-.007},{.13,y+.007,.007})
            grip_box(&points,&owners,2,{.135,y-.007,.008},{.17,y+.007,.022})
        }
    }
    world:=make([]mm.Transform,len(bones),context.temp_allocator)
    joints:=make([]asset.Rig_Joint,len(bones),context.temp_allocator)
    for &bone,i in bones {
        world[i]={bone.translation,bone.rotation,bone.scale}
        if bone.parent>=0 {world[i]=mm.transform_compose(world[bone.parent],world[i])}
        joints[i]={node=u32(i),inverse_bind=linalg.inverse(mm.transform_matrix(world[i]))}
    }
    vertices:=make([]asset.Vertex,len(points),context.temp_allocator)
    skin:=make([]asset.Skin_Vertex,len(points),context.temp_allocator)
    for p,v in points {
        frame:=world[1] if owners[v]>0 else world[0]
        local:=mm.quat_rotate(hand.palm,p) if owners[v]>0 else p
        vertices[v].position=mm.transform_point(frame,local)
        skin[v]={joints={owners[v],0,0,0,0,0,0,0},weights={255,0,0,0,0,0,0,0}}
    }
    meshes:=make([]Imported_Mesh,1,context.temp_allocator)
    meshes[0]={name="arm",vertices=vertices,skin=skin,joints=joints,skeleton=0,flags={.Skinned}}
    skeletons:=make([]Imported_Skeleton,1,context.temp_allocator)
    skeletons[0]={name="arm",bones=bones}
    hand.model={source="hand.glb",meshes=meshes,skeletons=skeletons}
    return
}

@(test)
a_grip_lies_across_the_palm_of_a_hand_turned_against_its_bone :: proc(t:^testing.T) {
    hand:=grip_hand(true)
    socket,found,error:=hand_grip_socket(&hand.model,0,1,"grip_right")
    if !testing.expectf(t,found && error.code==.None,"the hand is measured: %s",error.message) {return}
    testing.expect_value(t,base.text_get(socket.bone[:]),"hand_r")
    testing.expect_value(t,base.text_get(socket.name[:]),"grip_right")
    axes:=[3]mm.Vec3{{1,0,0},{0,1,0},{0,0,1}}
    names:=[3]string{"X along the hand","Y across the palm","Z out of the palm"}
    for axis,i in axes {
        got,want:=mm.quat_rotate(socket.offset.rotation,axis),mm.quat_rotate(hand.palm,axis)
        testing.expectf(t,linalg.dot(got,want)>math.cos(f32(8*math.PI/180)),"%s: %v, the palm's is %v",names[i],got,want)
    }
    // It touches the palm (its face at z=0.01) between a quarter and a half of the way to the
    // fingertips (at x=0.17), in the middle of its width. The drooping fingers lean the measured
    // length a few degrees toward the palm, and with it where the half is.
    contact:=mm.quat_rotate(linalg.quaternion_inverse(hand.palm),socket.offset.position)
    testing.expectf(t,abs(contact.z-.01)<.003,"on the face of the palm: %v",contact)
    testing.expectf(t,contact.x>.25*.17 && contact.x<.55*.17,"between a quarter and a half of the hand: %v",contact)
    testing.expectf(t,abs(contact.y)<.01,"in the middle of the palm: %v",contact)
    testing.expectf(t,linalg.length(socket.offset.scale-{.5,.5,.5})<1e-4,"what hangs from it is in meters: %v",socket.offset.scale)
    sockets:=[]asset.Skeleton_Socket{socket}
    info:=asset.Skeleton_Info{u32(len(hand.model.skeletons[0].bones))}
    testing.expect(t,asset.skeleton_check({info=&info,bones=hand.model.skeletons[0].bones,sockets=sockets}),"it is a socket a skeleton can hold")
}

@(test)
a_grip_needs_a_hand_with_skinned_vertices :: proc(t:^testing.T) {
    hand:=grip_hand(false)
    _,found,error:=hand_grip_socket(&hand.model,0,1,"grip_right")
    testing.expect(t,!found && error.code==.Unsupported,"a skinned arm whose hand has no vertices is an error")
    hand.model.meshes=nil
    _,found,error=hand_grip_socket(&hand.model,0,1,"grip_right")
    testing.expect(t,!found && error.code==.None,"a skeleton no mesh skins has nothing to measure")
    _,_,error=hand_grip_socket(&hand.model,0,7,"grip_right")
    testing.expect_value(t,error.code,Error_Code.Malformed)
}
