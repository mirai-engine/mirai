package ragdoll_editor

import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import aa "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"
import rag "plugins:ragdoll/runtime"

@(test_world)
Setup_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(erender.Mesh_Renderer),
    sources:core.Table(anim.Pose_Source),
    animations:core.Table(anim.Animation),
    rigids:core.Table(phys.Rigid_Body),
    colliders:core.Table(phys.Collider),
    joints:core.Table(phys.Joint),
    configs:core.Table(rag.Ragdoll),
    bones:core.Table(rag.Ragdoll_Bone),
    hierarchy:core.Hierarchy, // a body goes with the entity of its joint
}
Setup_Test :: struct {
    root:string,
    assets:host.Assets,
    app:host.App,
    world:Setup_Test_World,
    session:editor.Session,
    selection:history.Selection,
    edits:history.Edits,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    document:^editor.Document,
    server:api.Server,
    out:serial.Writer,
    figure,plain:core.Entity, // a rig whose skeleton has a body, and one whose skeleton has none
}

// A standing figure facing -Z with its left at -X, with three spine bones and a bone outside the body.
@(private)
setup_test_bones :: proc() -> []aa.Skeleton_Bone {
    Row :: struct {name:string,parent:i32,at:[3]f32}
    rows:=[?]Row{
        {"root",-1,{}},{"pelvis",0,{0,1,0}},{"spine_01",1,{0,1.12,0}},{"spine_02",2,{0,1.25,0}},{"spine_03",3,{0,1.38,0}},{"neck_01",4,{0,1.5,0}},{"head",5,{0,1.6,0}},
        {"clavicle_l",4,{-.05,1.45,0}},{"upperarm_l",7,{-.2,1.45,0}},{"lowerarm_l",8,{-.45,1.45,.02}},{"hand_l",9,{-.7,1.45,0}},
        {"clavicle_r",4,{.05,1.45,0}},{"upperarm_r",11,{.2,1.45,0}},{"lowerarm_r",12,{.45,1.45,.02}},{"hand_r",13,{.7,1.45,0}},
        {"thigh_l",1,{-.1,.95,0}},{"calf_l",15,{-.1,.5,-.02}},{"foot_l",16,{-.1,.08,0}},{"ball_l",17,{-.1,.02,-.12}},
        {"thigh_r",1,{.1,.95,0}},{"calf_r",19,{.1,.5,-.02}},{"foot_r",20,{.1,.08,0}},{"ball_r",21,{.1,.02,-.12}},
        {"ik_hand_root",0,{}},
    }
    bones:=make([]aa.Skeleton_Bone,len(rows),context.temp_allocator)
    for row,i in rows {
        bone:=&bones[i]
        base.text_set(bone.name[:],row.name)
        path:=row.name if row.parent<0 else fmt.tprintf("%s/%s",base.text_get(bones[row.parent].path[:]),row.name)
        base.text_set(bone.path[:],path);bone.target=base.name_hash(path)
        bone.parent=row.parent;bone.rotation=1;bone.scale={1,1,1}
        bone.translation=row.at-(rows[row.parent].at if row.parent>=0 else {})
    }
    return bones
}

// A rig showing a skinned mesh of a skeleton, with its body when body is set.
@(private)
setup_test_rig :: proc(f:^Setup_Test,t:^testing.T,name:string,id:base.Entity_Id,ids:u64,body:bool,pose:mm.Transform) -> core.Entity {
    skeleton_id,mesh_id:=base.Asset_Id{ids,1},base.Asset_Id{ids,2}
    bones:=setup_test_bones()
    desc:=aa.Skeleton_Desc{id=skeleton_id,bones=bones}
    found:aa.Skeleton_Body
    rows:[len(lib.Body_Part)]aa.Skeleton_Body_Part
    if body {
        map_,detected:=aa.skeleton_body_detect(bones,lib.body_map_empty())
        testing.expect(t,detected)
        count,_:=aa.skeleton_body_rows(bones,map_,&found,&rows)
        desc.body,desc.body_parts=&found,rows[:count]
    }
    testing.expect_value(t,aa.skeleton_save(fmt.tprintf("%s/%s.skeleton",f.root,name),&f.assets.types,desc),aa.Error.None)
    vertices:=[3]aa.Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    skin:[3]aa.Skin_Vertex;for &vertex in skin {vertex.weights[0]=255}
    indices:=[3]u32{0,1,2}
    mesh:=aa.Mesh_Desc{id=mesh_id,skeleton=skeleton_id,joints={{node=0,inverse_bind=1}}}
    testing.expect(t,aa.mesh_build({vertices=vertices[:],skin=skin[:]},indices[:],nil,&mesh.geometry,context.temp_allocator))
    testing.expect_value(t,aa.mesh_save(fmt.tprintf("%s/%s.mesh",f.root,name),&f.assets.types,mesh),aa.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    w:=&f.world
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{id});core.add(&w.names,e,core.name_make(name));core.add(&w.transforms,e,core.from_math(pose))
    core.add(&w.meshes,e,erender.Mesh_Renderer{mesh=mesh_id});core.add(&w.animations,e,anim.ANIMATION_DEFAULT)
    test_world_settle(w)
    return e
}

@(private)
setup_test_init :: proc(f:^Setup_Test,t:^testing.T,name:string) -> bool {
    f.root=base.test_folder(t,fmt.tprintf("ragdoll-%s",name))
    if f.root=="" {return false}
    if !testing.expect(t,host.assets_init(&f.assets,{root=f.root,capacity=8,error_capacity=8})) {return false}
    f.app.assets,f.app.allocator=&f.assets,context.allocator
    w:=&f.world
    if !test_world_init(t,w) {return false}
    f.document=new(editor.Document)
    f.session=editor.Session{app=&f.app,assets_root=f.root,mode=.Edit,headless=true,info=test_world_info(w),edit_world=&f.world,selection=&f.selection,edits=&f.edits,viewport=&f.viewport,gui=&f.gui,document=f.document,id_state=977}
    history.edits_reset(&f.edits,test_world_ref(&f.world))
    if !testing.expect_value(t,api.server_init(&f.server,{max_connections=1,max_methods=4}),api.Init_Error.None) {return false}
    serial.writer_init(&f.out,1<<20)
    defaults:=new(Ragdoll_Setup_Params,context.temp_allocator);defaults^={mode=rag.RAGDOLL_DEFAULT.mode}
    testing.expect_value(t,api.method_register(&f.server,{name="ragdoll.setup",params=Ragdoll_Setup_Params,params_info=type_info_of(Ragdoll_Setup_Params),result=Ragdoll_Setup_Result,result_info=type_info_of(Ragdoll_Setup_Result),defaults=defaults,user=&f.session,handler=proc(call:^api.Call) {setup((^editor.Session)(call.user),call)}}),api.Register_Error.None)
    turned:=mm.Transform{{2,0,3},mm.quat_axis_angle({0,1,0},.5),{1,1,1}}
    f.figure=setup_test_rig(f,t,"figure",0x11,701,true,turned)
    f.plain=setup_test_rig(f,t,"plain",0x12,702,false,mm.TRANSFORM_IDENTITY)
    history.edits_reset(&f.edits,test_world_ref(&f.world))
    return true
}

@(private)
setup_test_destroy :: proc(f:^Setup_Test) {
    test_world_destroy(&f.world)
    history.edits_free(&f.edits);delete(f.selection.entities);free(f.document)
    host.app_content_destroy(&f.app)
    serial.writer_destroy(&f.out);api.server_destroy(&f.server);host.assets_destroy(&f.assets)
}

@(private)
setup_test_call :: proc(f:^Setup_Test,params:string) -> (api.Error,string) {
    base.arena_reset(&f.server.scratch);serial.writer_reset(&f.out)
    error,_:=api.method_execute(&f.server,api.method_find(&f.server,"ragdoll.setup"),params,&f.out)
    core.hierarchy_settle(&f.world.hierarchy,core.read(&f.world.parents),&f.world.entities)
    return error,string(serial.writer_bytes(&f.out))
}

// The bodies of a rig by the path of their bone.
@(private)
setup_test_bodies :: proc(f:^Setup_Test,rig:core.Entity) -> map[string]core.Entity {
    found:=make(map[string]core.Entity,32,context.temp_allocator)
    for &value,row in f.world.bones.values {
        if value.rig!=rig {continue}
        path:=strings.clone(base.text_get(value.bone.path[:]),context.temp_allocator)
        found[path[strings.last_index_byte(path,'/')+1:]]=f.world.bones.entities[row]
    }
    return found
}

// The Joint of a body: on a child of it.
@(private)
setup_test_joint :: proc(w:^Setup_Test_World,body:core.Entity) -> (e:core.Entity,joint:phys.Joint,found:bool) {
    for row in 0..<len(w.joints.values) {
        e=w.joints.entities[row]
        if parent,ok:=core.get(&w.parents,e);ok && parent.entity==body {return e,w.joints.values[row],true}
    }
    return core.NONE,{},false
}

@(test)
ragdoll_setup_builds_a_body_and_limited_joint_per_part_of_a_humanoid_in_one_step_of_undo :: proc(t:^testing.T) {
    f:=new(Setup_Test);defer free(f)
    if !setup_test_init(f,t,"humanoid") {return};defer setup_test_destroy(f)
    w:=&f.world
    result,text:=setup_test_call(f,`{"entity":"0000000000000011","mass":70}`)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    bodies:=setup_test_bodies(f,f.figure)
    testing.expect_value(t,len(bodies),16)
    testing.expect_value(t,len(w.rigids.values),16)
    testing.expect_value(t,len(w.joints.values),15)
    config,configured:=core.get(&w.configs,f.figure)
    testing.expect(t,configured && config.mode==.Simulated && config.max_torque==rag.RAGDOLL_DEFAULT.max_torque)
    testing.expect_value(t,f.edits.cursor,1)
    for want in ([]string{`"part":"Forearm_L"`,`"joint":"Hinge"`,`"joint":"Swing_Twist"`,`"shape":"Capsule"`,`"shape":"Sphere"`,`"bone":"spine_02"`}) {
        testing.expectf(t,strings.contains(strings.join(strings.fields(text,context.temp_allocator),"",context.temp_allocator),want),"%s in %s",want,text)
    }

    // Spine and chest split the chain; the neck, the clavicles and the toes have no body.
    for name in ([]string{"pelvis","spine_01","spine_02","head","upperarm_l","lowerarm_l","hand_l","thigh_r","calf_r","foot_r"}) {testing.expectf(t,name in bodies,"no body on %s",name)}
    for name in ([]string{"neck_01","spine_03","clavicle_l","ball_l","root","ik_hand_root"}) {testing.expectf(t,!(name in bodies),"a body on %s",name)}
    _,_,pelvis_joint:=setup_test_joint(w,bodies["pelvis"])
    testing.expect(t,!pelvis_joint)
    testing.expect_value(t,core.at(&w.colliders,core.row_of(&w.colliders,bodies["pelvis"])).kind,phys.Collider_Kind.Box)
    testing.expect_value(t,core.at(&w.colliders,core.row_of(&w.colliders,bodies["head"])).kind,phys.Collider_Kind.Sphere)
    testing.expect_value(t,core.at(&w.colliders,core.row_of(&w.colliders,bodies["calf_l"])).kind,phys.Collider_Kind.Capsule)
    _,elbow,_:=setup_test_joint(w,bodies["lowerarm_l"])
    testing.expect(t,elbow.b==bodies["upperarm_l"] && elbow.angular[0].motion==.Locked && elbow.angular[2].motion==.Locked)
    testing.expect(t,elbow.angular[1].motion==.Limited && elbow.angular[1].upper>2 && elbow.angular[1].lower<=0)
    _,shoulder,_:=setup_test_joint(w,bodies["upperarm_r"])
    testing.expect(t,shoulder.b==bodies["spine_02"] && shoulder.angular[0].motion==.Limited && shoulder.angular[2].motion==.Limited)
    _,thigh,_:=setup_test_joint(w,bodies["thigh_l"])
    testing.expect_value(t,thigh.b,bodies["pelvis"])
    _,head,_:=setup_test_joint(w,bodies["head"])
    testing.expect_value(t,head.b,bodies["spine_02"])

    // Each joint meets the body of its parent part where they touch and with the same frame, and each body sits where its bone and offset put it.
    rig:=core.to_math(core.at(&w.transforms,core.row_of(&w.transforms,f.figure)))
    bones:=setup_test_bones()
    parents:=make([]i32,len(bones),context.temp_allocator);rest:=make([]mm.Transform,len(bones),context.temp_allocator);world:=make([]mm.Transform,len(bones),context.temp_allocator)
    for &bone,i in bones {parents[i]=bone.parent;rest[i]={bone.translation,bone.rotation,bone.scale}}
    testing.expect(t,lib.pose_world(parents,rest,world,rig))
    mass:f32
    for row in 0..<len(w.bones.values) {
        e:=w.bones.entities[row];binding:=w.bones.values[row]
        pose:=core.to_math(core.at(&w.transforms,core.row_of(&w.transforms,e)))
        rigid:=core.at(&w.rigids,core.row_of(&w.rigids,e));collider:=core.at(&w.colliders,core.row_of(&w.colliders,e))
        testing.expect(t,rigid.type==.Dynamic && rigid.mass>0 && collider.group==f.figure && rag.ragdoll_bone_valid(binding))
        mass+=rigid.mass
        for &bone,i in bones {
            if base.text_get(bone.path[:])!=base.text_get(binding.bone.path[:]) {continue}
            placed:=mm.transform_compose(world[i],binding.offset)
            testing.expectf(t,linalg.length(placed.position-pose.position)<1e-4 && abs(linalg.dot(placed.rotation,pose.rotation))>.9999,"%s: the bone puts its body at %v, it is at %v",base.text_get(bone.name[:]),placed.position,pose.position)
        }
        joint_entity,joint,jointed:=setup_test_joint(w,e)
        if !jointed {continue}
        testing.expect_value(t,phys.joint_configuration_error(joint),phys.Joint_Error.None)
        frame:=mm.transform_compose(pose,core.to_math(core.at(&w.transforms,core.row_of(&w.transforms,joint_entity))))
        target:=core.to_math(core.at(&w.transforms,core.row_of(&w.transforms,joint.b)))
        there:=target.position+mm.quat_rotate(target.rotation,joint.b_anchor)
        testing.expectf(t,linalg.length(frame.position-there)<1e-4,"anchors apart: %v %v",frame.position,there)
        testing.expect(t,abs(linalg.dot(frame.rotation,target.rotation*joint.b_rotation))>.9999)
    }
    testing.expect(t,abs(mass-70)<.01)

    ref:=test_world_ref(&f.world)
    testing.expect(t,history.undo(&f.edits,ref,&f.selection))
    testing.expect(t,len(w.bones.values)==0 && len(w.rigids.values)==0 && len(w.joints.values)==0 && !core.has(&w.configs,f.figure))
    testing.expect(t,history.redo(&f.edits,ref,&f.selection))
    testing.expect(t,len(w.bones.values)==16 && core.has(&w.configs,f.figure))
}

@(test)
ragdoll_setup_finds_a_body_the_skeleton_does_not_store_and_leaves_the_skeleton_as_it_is :: proc(t:^testing.T) {
    f:=new(Setup_Test);defer free(f)
    if !setup_test_init(f,t,"no-body") {return};defer setup_test_destroy(f)
    result,_:=setup_test_call(f,`{"entity":"0000000000000012"}`)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    testing.expect_value(t,len(setup_test_bodies(f,f.plain)),16)
    testing.expect(t,core.has(&f.world.configs,f.plain))
    testing.expect_value(t,f.edits.cursor,1)
    testing.expect_value(t,len(host.assets_unsaved(&f.assets)),0)
    core.remove(&f.world.animations,f.figure);test_world_settle(&f.world)
    result,_=setup_test_call(f,`{"entity":"0000000000000011"}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Missing_Component"`))
    f.session.mode=.Play
    result,_=setup_test_call(f,`{"entity":"0000000000000011"}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Missing_Component"`),"the document is what it validates while a game plays")
    testing.expect_value(t,f.edits.cursor,1)
}

@(test)
ragdoll_setup_replaces_the_ragdoll_of_a_rig_in_one_step_of_undo :: proc(t:^testing.T) {
    f:=new(Setup_Test);defer free(f)
    if !setup_test_init(f,t,"replace") {return};defer setup_test_destroy(f)
    w:=&f.world
    result,_:=setup_test_call(f,`{"entity":"0000000000000011"}`)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    first:=setup_test_bodies(f,f.figure)
    text:string
    result,text=setup_test_call(f,`{"entity":"0000000000000011","mode":"Driven","mass":80}`)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    testing.expectf(t,strings.contains(strings.join(strings.fields(text,context.temp_allocator),"",context.temp_allocator),`"removed":16`),"%s",text)
    for _,e in first {testing.expect(t,!core.alive(&w.entities,e))}
    testing.expectf(t,len(w.bones.values)==16 && len(w.rigids.values)==16 && len(w.joints.values)==15,"%v %v %v",len(w.bones.values),len(w.rigids.values),len(w.joints.values))
    testing.expect(t,core.at(&w.configs,core.row_of(&w.configs,f.figure)).mode==.Driven && f.edits.cursor==2)
    testing.expect(t,history.undo(&f.edits,test_world_ref(&f.world),&f.selection))
    testing.expect(t,len(w.bones.values)==16 && core.at(&w.configs,core.row_of(&w.configs,f.figure)).mode==.Simulated)
}
