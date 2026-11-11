package gltf

import "core:strings"
import "core:testing"
import "core:math/linalg"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/rig"
import "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

RIG_FIXTURES :: FIXTURES+"mesh2motion-human/"

@(private="file")
bones_world :: proc(bones:[]asset.Skeleton_Bone) -> []mm.Transform {
    world:=make([]mm.Transform,len(bones),context.temp_allocator)
    for &bone,i in bones {
        world[i]={position=bone.translation,rotation=bone.rotation,scale=bone.scale}
        if bone.parent>=0 {world[i]=mm.transform_compose(world[bone.parent],world[i])}
    }
    return world
}

@(private="file")
bone_named :: proc(bones:[]asset.Skeleton_Bone,name:string) -> int {
    for &bone,i in bones {if base.text_get(bone.name[:])==name {return i}}
    return -1
}

@(test)
a_humanoid_rig_fits_the_joints_a_person_placed_and_rests_as_the_template :: proc(t:^testing.T) {
    placed,placed_ok:=import_ok(t,RIG_FIXTURES+"psx-05.glb",{ignore_stored=true})
    if !placed_ok {return}
    defer importer.model_destroy(&placed)
    rigged,rigged_ok:=import_ok(t,RIG_FIXTURES+"psx-05.glb",{settings={rig=.Humanoid},ignore_stored=true})
    if !rigged_ok {return}
    defer importer.model_destroy(&rigged)
    walk,walk_ok:=import_ok(t,RIG_FIXTURES+"walk.glb",{ignore_stored=true})
    if !walk_ok {return}
    defer importer.model_destroy(&walk)

    testing.expect_value(t,len(rigged.skeletons),1)
    bones:=rigged.skeletons[0].bones
    truth:=bones_world(placed.skeletons[0].bones)
    height:=placed.meshes[0].bounds_max.y-placed.meshes[0].bounds_min.y
    // Where the skin is bound is where the fit put each joint.
    total,worst:f32
    counted:=0
    for joint in rigged.meshes[0].joints {
        bind,ok:=mm.transform_from_matrix(linalg.inverse(joint.inverse_bind))
        testing.expect(t,ok,"an inverse bind is a rigid frame")
        name:=base.text_get(bones[joint.node].name[:])
        if name=="root" || name==asset_root {continue}
        at:=bone_named(placed.skeletons[0].bones,name)
        if !testing.expectf(t,at>=0,"the fixture has the bone %s",name) {continue}
        error:=linalg.length(bind.position-truth[at].position)/height
        total+=error;worst=max(worst,error);counted+=1
    }
    testing.expectf(t,total/f32(counted)<0.03,"the joints are within 3%% of the height of where a person placed them on average: %.3f",total/f32(counted))
    testing.expectf(t,worst<0.06,"and within 6%% each: %.3f",worst)

    // The rest is the template's: the clips of its library name the bones by
    // path, and the bones rest turned as the skeleton those clips animate.
    testing.expect(t,len(walk.animations)>0 && len(walk.animations[0].tracks)>0,"the fixture has a clip")
    for track in walk.animations[0].tracks {
        found:=false
        for &bone in bones {if base.text_get(bone.path[:])==track.target {found=true;break}}
        testing.expectf(t,found,"the rig has the bone %s that the walk animates",track.target)
    }
    // A file of clips gives the skeleton they animate, the source of a bake.
    if !testing.expect_value(t,len(walk.skeletons),1) {return}
    source:=walk.skeletons[0].bones
    testing.expect_value(t,len(source),len(bones))
    rest,source_rest:=bones_world(bones),bones_world(source)
    for &bone,i in bones {
        at:=-1
        for &other,k in source {if other.target==bone.target {at=k;break}}
        if !testing.expectf(t,at>=0,"the walk's skeleton has the path %s",base.text_get(bone.path[:])) {continue}
        testing.expectf(t,abs(linalg.dot(rest[i].rotation,source_rest[at].rotation))>1-1e-4,"%s rests turned as the template",base.text_get(bone.name[:]))
    }

    // Mirror images, and every vertex whole on bones that deform.
    for &bone,i in bones {
        name:=base.text_get(bone.name[:])
        if len(name)<2 || name[len(name)-2:]!="_l" {continue}
        partner:=bone_named(bones,strings.concatenate({name[:len(name)-1],"r"},context.temp_allocator))
        if partner<0 {continue}
        a,_:=mm.transform_from_matrix(linalg.inverse(rigged.meshes[0].joints[i].inverse_bind))
        b,_:=mm.transform_from_matrix(linalg.inverse(rigged.meshes[0].joints[partner].inverse_bind))
        center:=(rigged.meshes[0].bounds_min.x+rigged.meshes[0].bounds_max.x)/2
        testing.expectf(t,close_to({2*center-a.position.x,a.position.y,a.position.z},b.position,1e-4),"%s mirrors its side",name)
    }
    mesh:=&rigged.meshes[0]
    testing.expect(t,.Skinned in mesh.flags)
    testing.expect_value(t,len(mesh.skin),len(mesh.vertices))
    for influence in mesh.skin {
        sum:=0
        for weight,k in influence.weights {
            sum+=int(weight)
            if weight==0 {continue}
            name:=base.text_get(bones[mesh.joints[influence.joints[k]].node].name[:])
            testing.expectf(t,name!="root" && name!=asset_root && !strings.contains(name,"leaf"),"no vertex hangs from %s",name)
        }
        testing.expect_value(t,sum,255)
    }

    // The body is found by its names.
    body,found:=asset.skeleton_body_detect(bones,anim.body_map_empty())
    testing.expect(t,found,"the rig has a body")
    parts:=[?]struct{part:anim.Body_Part,name:string}{{.Pelvis,"pelvis"},{.Head,"head"},{.Hand_L,"hand_l"},{.Foot_R,"foot_r"},{.Elbow_L,"lowerarm_l"}}
    for p in parts {
        bone:=body.bones[p.part]
        testing.expectf(t,bone>=0 && base.text_get(bones[bone].name[:])==p.name,"%v is %s",p.part,p.name)
    }

    // Its skeleton is written with a grip on each hand, measured on its skin.
    report,error,folder:=write_model(t,&rigged,"rig-grips")
    if folder=="" {return}
    defer importer.report_destroy(&report)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    for warning in report.warnings {testing.expectf(t,!strings.contains(warning,"grip"),"%s",warning)}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    skeletons:=0
    for written in report.assets {
        if written.kind!=asset.KIND_SKELETON {continue}
        skeletons+=1
        file:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&file,written.path),asset.Error.None) {return}
        defer asset.asset_close(&file)
        view,view_error:=asset.skeleton_view(&file,&types)
        if !testing.expect_value(t,view_error,asset.Error.None) {return}
        for want in ([2][2]string{{"grip_left","hand_l"},{"grip_right","hand_r"}}) {
            found:=false
            for &socket in view.sockets {
                if base.text_get(socket.name[:])!=want[0] {continue}
                found=base.text_get(bones[skeleton_bone_of(view.bones,socket.bone)].name[:])==want[1]
                // The bones of the template run along their Y, as the hand does.
                along:=mm.quat_rotate(socket.offset.rotation,mm.Vec3{1,0,0})
                testing.expectf(t,along.y>.9,"%s runs along the hand: %v",want[0],along)
            }
            testing.expectf(t,found,"%s hangs from %s",want[0],want[1])
        }
    }
    testing.expect_value(t,skeletons,1)
}

@(private="file")
skeleton_bone_of :: proc(bones:[]asset.Skeleton_Bone,path:[asset.NODE_PATH_CAPACITY]u8) -> int {
    return max(int(asset.skeleton_bone_index(bones,path)),0)
}

@(private="file")
asset_root :: "Armature"

// The same person with the arms lowered by its own skin, as an A-pose: the
// joints a person placed, lowered with them, are where the fit should find them.
@(test)
a_humanoid_rig_fits_a_person_whose_arms_hang :: proc(t:^testing.T) {
    placed,ok:=import_ok(t,RIG_FIXTURES+"psx-05.glb",{ignore_stored=true})
    if !ok {return}
    defer importer.model_destroy(&placed)
    mesh:=&placed.meshes[0]
    bones:=placed.skeletons[mesh.skeleton].bones
    truth:=bones_world(bones)
    side_of:=make([]f32,len(bones),context.temp_allocator)
    for &bone,i in bones {
        name:=base.text_get(bone.name[:])
        if strings.has_prefix(name,"upperarm_") {side_of[i]=-1 if strings.has_suffix(name,"_l") else 1}
        if bone.parent>=0 && side_of[i]==0 {side_of[i]=side_of[bone.parent]}
    }
    DOWN :: 0.75
    lowered :: proc(bones:[]asset.Skeleton_Bone,truth:[]mm.Transform,side:f32,p:mm.Vec3) -> mm.Vec3 {
        if side==0 {return p}
        shoulder:=truth[bone_named(bones,"upperarm_l" if side<0 else "upperarm_r")].position
        return shoulder+mm.quat_rotate(mm.quat_axis_angle({0,0,1},-side*DOWN),p-shoulder)
    }
    positions:=make([][3]f32,len(mesh.vertices),context.temp_allocator)
    for vertex,v in mesh.vertices {
        for weight,k in mesh.skin[v].weights {
            if weight==0 {continue}
            bone:=int(mesh.joints[mesh.skin[v].joints[k]].node)
            positions[v]+=lowered(bones,truth,side_of[bone],vertex.position)*f32(weight)/255
        }
    }
    meshes:=[1]rig.Mesh{{positions=positions,indices=mesh.indices}}
    made,error:=rig.humanoid(meshes[:],{},context.temp_allocator)
    if !testing.expect_value(t,error,rig.Error.None) {return}
    testing.expectf(t,made.fit.arms_down>rig.ARM_PLANE_ANGLE,"the arms are seen hanging: %.2f rad",made.fit.arms_down)
    height:=mesh.bounds_max.y-mesh.bounds_min.y
    total,worst:f32
    counted:=0
    for joint,i in made.fit.joints {
        name:=rig.HUMANOID[i].name
        if name=="root" {continue}
        at:=bone_named(bones,name)
        if at<0 {continue}
        error:=linalg.length(joint-lowered(bones,truth,side_of[at],truth[at].position))/height
        total+=error;worst=max(worst,error);counted+=1
    }
    testing.expectf(t,total/f32(counted)<0.03,"the joints are within 3%% of the height of the lowered ones on average: %.3f",total/f32(counted))
    testing.expectf(t,worst<0.08,"and within 8%% each: %.3f",worst)
}

// A horse a person rigged on the fox's skeleton: rigged as a fox, its joints
// are near where they were placed, and its rest is the fox's clips'.
@(test)
an_animal_rig_fits_the_joints_a_person_placed_and_rests_as_its_clips :: proc(t:^testing.T) {
    FOX :: FIXTURES+"mesh2motion-fox/"
    placed,placed_ok:=import_ok(t,FOX+"horse.glb",{ignore_stored=true})
    if !placed_ok {return}
    defer importer.model_destroy(&placed)
    rigged,rigged_ok:=import_ok(t,FOX+"horse.glb",{settings={rig=.Fox},ignore_stored=true})
    if !rigged_ok {return}
    defer importer.model_destroy(&rigged)
    walk,walk_ok:=import_ok(t,FOX+"walk.glb",{ignore_stored=true})
    if !walk_ok {return}
    defer importer.model_destroy(&walk)

    if !testing.expect_value(t,len(rigged.skeletons),1) {return}
    bones:=rigged.skeletons[0].bones
    truth:=bones_world(placed.skeletons[0].bones)
    lo,hi:=placed.meshes[0].bounds_min,placed.meshes[0].bounds_max
    for mesh in placed.meshes {lo,hi=linalg.min(lo,mesh.bounds_min),linalg.max(hi,mesh.bounds_max)}
    size:=max(hi.x-lo.x,hi.y-lo.y,hi.z-lo.z)
    total,worst:f32
    counted:=0
    for joint in rigged.meshes[0].joints {
        bind,_:=mm.transform_from_matrix(linalg.inverse(joint.inverse_bind))
        name:=base.text_get(bones[joint.node].name[:])
        at:=bone_named(placed.skeletons[0].bones,name)
        // The person left some bones of the fox out of the horse.
        if name=="root" || at<0 {continue}
        error:=linalg.length(bind.position-truth[at].position)/size
        total+=error;worst=max(worst,error);counted+=1
    }
    testing.expectf(t,counted>40,"most bones are compared: %d",counted)
    testing.expectf(t,total/f32(counted)<0.05,"the joints are within 5%% of its size of where a person placed them on average: %.3f",total/f32(counted))
    testing.expectf(t,worst<0.12,"and within 12%% each: %.3f",worst)

    if !testing.expect_value(t,len(walk.skeletons),1) {return}
    source:=walk.skeletons[0].bones
    testing.expect_value(t,len(source),len(bones))
    rest,source_rest:=bones_world(bones),bones_world(source)
    for &bone,i in bones {
        at:=-1
        for &other,k in source {if other.target==bone.target {at=k;break}}
        if !testing.expectf(t,at>=0,"the walk's skeleton has the path %s",base.text_get(bone.path[:])) {continue}
        testing.expectf(t,abs(linalg.dot(rest[i].rotation,source_rest[at].rotation))>1-1e-4,"%s rests turned as the fox",base.text_get(bone.name[:]))
    }
    for &mesh in rigged.meshes {
        testing.expect(t,.Skinned in mesh.flags)
        for influence in mesh.skin {
            sum:=0
            for weight in influence.weights {sum+=int(weight)}
            testing.expect_value(t,sum,255)
        }
    }
}
