package main

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:core"
import render "mirai:engine/render"
import inp "mirai:engine/input"
import cam "mirai:engine/camera"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import animation_editor "plugins:animation/editor"

@(private)
gallery_spider :: proc(g:^Gallery_Build,place:Gallery_Place) -> base.Entity_Id {
    o,s:=g.o,g.s
    folder:="assets/characters/spider";os.make_directory_all(path(o,folder))
    skeleton_id,mesh_id:=id_of("skeleton","spider"),id_of("mesh","spider")
    bones:[25]asset.Skeleton_Bone
    rest:[25]mm.Transform
    joints:[25]asset.Rig_Joint
    for &bone in bones {bone.rotation,bone.scale=1,{1,1,1}}
    bones[0].parent=-1;bones[0].translation={0,.6,0};base.text_set(bones[0].name[:],"body");base.text_set(bones[0].path[:],"body")
    for i in 0..<8 {
        side:=f32(-1) if i<4 else f32(1)
        row:=i%4
        hip,knee,foot:=1+i*3,2+i*3,3+i*3
        bones[hip].parent,bones[knee].parent,bones[foot].parent=0,i32(hip),i32(knee)
        bones[hip].translation={side*.22,0,f32(row)*.3-.45}
        bones[knee].translation={side*.35,.1,(f32(row)-1.5)*.09}
        bones[foot].translation={side*.35,-.67,(f32(row)-1.5)*.09}
        for name,j in ([]string{fmt.tprintf("hip.%d",i),fmt.tprintf("knee.%d",i),fmt.tprintf("foot.%d",i)}) {
            index:=hip+j;base.text_set(bones[index].name[:],name)
            base.text_set(bones[index].path[:],fmt.tprintf("%s/%s",base.text_get(bones[bones[index].parent].path[:]),name))
        }
    }
    for &bone,i in bones {
        bone.target=base.name_hash(base.text_get(bone.path[:]))
        rest[i]={bone.translation,bone.rotation,bone.scale}
        if bone.parent>=0 {rest[i]=mm.transform_compose(rest[bone.parent],rest[i])}
        joints[i]={node=u32(i),inverse_bind=linalg.inverse(mm.transform_matrix(rest[i]))}
    }
    check(o,"spider.skeleton",asset.skeleton_save(path(o,fmt.tprintf("%s/spider.skeleton",folder)),&o.types,{id=skeleton_id,bones=bones[:]}))
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube,context.temp_allocator);geom.cube_build(&cube)
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator);indices:=make([dynamic]u32,context.temp_allocator);skin:=make([dynamic]asset.Skin_Vertex,context.temp_allocator)
    gallery_skin_box(&cube,&vertices,&indices,&skin,{rest[0].position,1,{.5,.24,1.1}},0,0xff70b3e6)
    for i in 0..<8 {
        for segment in 0..<2 {
            a:=1+i*3+segment;b:=a+1
            delta:=rest[b].position-rest[a].position
            gallery_skin_box(&cube,&vertices,&indices,&skin,{(rest[a].position+rest[b].position)*.5,mm.quat_between({0,1,0},linalg.normalize(delta)),{.07,linalg.length(delta),.07}},u16(a),0xffe5bb60)
        }
        foot:=3+i*3;gallery_skin_box(&cube,&vertices,&indices,&skin,{rest[foot].position,1,{.14,.06,.14}},u16(foot),0xff39302d)
    }
    if !asset.mesh_tangents(&vertices,indices[:],&skin) {check(o,"spider.mesh",.Out_Of_Memory);return {}}
    mesh_write_built(o,"spider.mesh",fmt.tprintf("%s/spider.mesh",folder),{id=mesh_id,joints=joints[:],skeleton=skeleton_id},{vertices=vertices[:],skin=skin[:]},indices[:])
    root:=entity(s,"Procedural eight leg spider",place.origin+mm.Vec3{0,0,1.2})
    put(s,root,"Mesh_Renderer",&render.Mesh_Renderer{mesh=mesh_id})
    grounding:=anim.FOOT_GROUNDING_DEFAULT;grounding.mode=.Procedural;grounding.count=8;grounding.body=anim.bone_ref("body")
    grounding.cycle_duration=.6;grounding.prediction=.12;grounding.body_height=.57;grounding.trace_above=.6;grounding.trace_below=1.2;grounding.max_swinging=4;grounding.max_drop=.25;grounding.max_rise=.25
    for i in 0..<8 {
        leg:=anim.GROUNDED_LEG_DEFAULT;leg.hip=anim.bone_ref(fmt.tprintf("hip.%d",i));leg.knee=anim.bone_ref(fmt.tprintf("knee.%d",i));leg.foot=anim.bone_ref(fmt.tprintf("foot.%d",i))
        leg.phase=f32((i+i/4)%2)*.5;leg.step_distance=.3;leg.step_height=.15;leg.sole_height=.03;leg.pole_offset={-1 if i<4 else 1,.2,0}
        grounding.legs[i]=leg
    }
    gallery_profile(o,s,root,"characters/spider","spider_grounding",{grounding={grounding}})
    capsule:=phys.collider_character(.22,.8);put(s,root,"Collider",&capsule)
    character:=phys.character_default();character.step_height=.22;character.move_relative_to=.Game
    walk:=phys.WALK_DEFAULT;walk.max_speed=1;walk.acceleration=6;walk.braking=8;walk.jump_height=.5
    put(s,root,"Character",&character);put(s,root,"Walk",&walk)
    camera:=entity(s,"Spider camera")
    lens:=render.CAMERA_DEFAULT;lens.active=false;lens.fov=60*mm.RAD_PER_DEG;put(s,camera,"Camera",&lens)
    follow:=cam.CAMERA_FOLLOW_DEFAULT;follow.target=core.Entity(root);follow.offset={0,.5,0};follow.distance=3;follow.pitch=.3;follow.min_pitch=-.5;follow.max_pitch=1.1;follow.turn=true
    put(s,camera,"Camera_Follow",&follow);put(s,root,"Drivable",&inp.Drivable{camera=core.Entity(camera)})
    gallery_cube(s,"Spider low step",place.origin+mm.Vec3{0,.06,-.5},{1.7,.2,.45},{.2,.3,.3,1},true)
    gallery_item(g,root,.Spider,place,"5.1  Procedural eight leg gait","no clips / eight contact anchors / E: drive it")
    return root
}

@(private)
gallery_skin_box :: proc(cube:^geom.Mesh_Buffer,vertices:^[dynamic]asset.Vertex,indices:^[dynamic]u32,skin:^[dynamic]asset.Skin_Vertex,pose:mm.Transform,bone:u16,color:u32) {
    first:=u32(len(vertices))
    for point,i in cube.positions {
        normal:=mm.quat_rotate(pose.rotation,cube.normals[i])
        append(vertices,asset.Vertex{position=pose.position+mm.quat_rotate(pose.rotation,point*pose.scale),normal=mm.normal_pack(normal),uv=cube.uvs[i],color=color})
        append(skin,asset.Skin_Vertex{joints={bone,0,0,0,0,0,0,0},weights={255,0,0,0,0,0,0,0}})
    }
    for index in cube.indices {append(indices,first+index)}
}

// How much taller the Mirai of the retarget is: its body and legs, not its arms.
@(private) GALLERY_TALL :: 1.25

// A Mirai stretched upward, with its skeleton stretched the same, and the clips of the gallery
// baked for it: the same paths, with the translations scaled to its proportions.
@(private)
gallery_retarget :: proc(o:^Out,s:^Scene_Out,model:^importer.Imported_Model,source:string,root:base.Entity_Id) {
    folder:="assets/characters/tall_mirai";os.make_directory_all(path(o,folder))
    skeleton_id,mesh_id:=id_of("skeleton","tall_mirai"),id_of("mesh","tall_mirai")
    rig,valid:=mirai_rig(model)
    body:=-1
    for node in model.nodes {if node.mesh>=0 {body=node.mesh;break}}
    if !valid || body<0 {o.failed=true;return}
    bones:=make([]asset.Skeleton_Bone,len(model.skeletons[0].bones),context.temp_allocator);copy(bones,model.skeletons[0].bones)
    world:=make([]mm.Transform,len(bones),context.temp_allocator);copy(world,rig.rest_world)
    for &placed in world {placed.position.y*=GALLERY_TALL}
    for &bone,i in bones {
        if bone.parent<0 {bone.translation.y*=GALLERY_TALL;continue}
        parent:=world[bone.parent]
        bone.translation=mm.quat_rotate(mm.quat_inverse(parent.rotation),world[i].position-parent.position)/parent.scale
    }
    check(o,"tall_mirai.skeleton",asset.skeleton_save(path(o,fmt.tprintf("%s/tall_mirai.skeleton",folder)),&o.types,{id=skeleton_id,bones=bones}))
    mesh:=model.meshes[body]
    vertices:=make([]asset.Vertex,len(mesh.vertices),context.temp_allocator);copy(vertices,mesh.vertices)
    joints:=make([]asset.Rig_Joint,len(mesh.joints),context.temp_allocator);copy(joints,mesh.joints)
    for &vertex in vertices {
        vertex.position.y*=GALLERY_TALL
        normal:=mm.normal_unpack(vertex.normal);normal.y/=GALLERY_TALL;vertex.normal=mm.normal_pack(linalg.normalize0(normal))
        tangent,sign:=mm.tangent_unpack(vertex.tangent);tangent.y*=GALLERY_TALL;vertex.tangent=mm.tangent_pack(linalg.normalize0(tangent),sign)
    }
    for &joint in joints {
        bind:=linalg.inverse(joint.inverse_bind)
        bind[1,3]*=GALLERY_TALL
        joint.inverse_bind=linalg.inverse(bind)
    }
    slots:=make([]asset.Material_Slot,len(mesh.slots),context.temp_allocator)
    for slot,i in mesh.slots {
        slots[i].id=slot.id;base.text_set(slots[i].label[:],slot.label)
        if slot.material>=0 {slots[i].material=imported_id(o,source,asset.KIND_MATERIAL,model.materials[slot.material].name)}
    }
    // Its levels as the importer makes those of the Mirai it stretches.
    levels:=importer.mesh_levels(vertices,mesh.indices,mesh.skin,mesh.submeshes,true,context.temp_allocator,mesh.morphs,mesh.morph_deltas)
    desc:=asset.Mesh_Desc{id=mesh_id,joints=joints,skeleton=skeleton_id,slots=slots}
    if importer.levels_geometry(levels,mesh.flags,&desc.geometry,context.temp_allocator) {
        check(o,"tall_mirai.mesh",asset.mesh_save(path(o,fmt.tprintf("%s/tall_mirai.mesh",folder)),&o.types,desc))
    } else {check(o,"tall_mirai.mesh",.Invalid)}
    put(s,root,"Mesh_Renderer",&render.Mesh_Renderer{mesh=mesh_id})
    constraint:=anim.RETARGET_MAPPING_DEFAULT;constraint.mode=.Paths;constraint.translation=.Scaled
    profile:=anim.Pose_Profile{retarget={constraint}}
    input:asset.Asset
    if error:=asset.asset_load(&input,path(o,"assets/characters/mirai/mirai_gallery.anim"));error!=.None {check(o,"mirai retarget input",error);return}
    defer asset.asset_close(&input)
    clips,read:=asset.animation_view(&input,&o.types)
    if read!=.None {check(o,"mirai retarget clips",read);return}
    source_info:=asset.Skeleton_Info{u32(len(model.skeletons[0].bones))};target_info:=asset.Skeleton_Info{u32(len(bones))}
    baked:asset.Document
    baked_id:=id_of("animation","tall_mirai")
    error:=animation_editor.retarget_bake(&baked,&o.types,baked_id,clips,{info=&source_info,bones=model.skeletons[0].bones},{info=&target_info,bones=bones},profile,skeleton=skeleton_id)
    if error!=.None {check(o,"mirai retarget bake",error);return}
    defer asset.document_destroy(&baked)
    check(o,"tall_mirai.anim",asset.document_save(&baked,path(o,"assets/characters/tall_mirai/tall_mirai.anim")))
    player:=anim.ANIMATION_DEFAULT;player.asset=baked_id;base.text_set(player.clip[:],"walk")
    put(s,root,"Animation",&player)
}
