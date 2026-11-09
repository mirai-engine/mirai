package ragdoll_editor

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import aa "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"
import rag "plugins:ragdoll/runtime"

Setup_Test_World :: struct {
    entities:core.Entities,
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
}
Setup_Test :: struct {
    root:string,
    assets:host.Assets,
    app:host.App,
    world:Setup_Test_World,
    tables:[12]core.Table_Info,
    info:core.World_Info,
    session:editor.Session,
    selection:editor.Selection,
    edits:editor.Edits,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    document:^editor.Document,
    server:api.Server,
    out:serial.Writer,
    figure,plain:core.Entity, // a rig whose skeleton has a body, and one whose skeleton has none
}

@(private)
setup_test_settle :: proc(data,shared,ed:rawptr) {
    w:=(^Setup_Test_World)(data)
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities);core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.meshes,&w.entities);core.table_settle(&w.sources,&w.entities);core.table_settle(&w.animations,&w.entities)
    core.table_settle(&w.rigids,&w.entities);core.table_settle(&w.colliders,&w.entities);core.table_settle(&w.joints,&w.entities)
    core.table_settle(&w.configs,&w.entities);core.table_settle(&w.bones,&w.entities)
    core.entities_settle(&w.entities)
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
    setup_test_settle(w,nil,nil)
    return e
}

@(private)
setup_test_init :: proc(f:^Setup_Test,t:^testing.T,name:string) -> bool {
    temp,_:=os.temp_directory(context.temp_allocator)
    f.root=fmt.tprintf("%s/mirai-ragdoll-%d-%s",temp,os.get_pid(),name)
    os.remove_all(f.root);os.make_directory_all(f.root)
    f.root=project.path_absolute(f.root,context.temp_allocator)
    if !testing.expect(t,host.assets_init(&f.assets,{root=f.root,capacity=8,error_capacity=8})) {return false}
    f.app.assets,f.app.allocator=&f.assets,context.allocator
    w:=&f.world
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id");core.table_init(&w.names,"Name");core.table_init(&w.transforms,"Transform");core.table_init(&w.parents,"Parent")
    core.table_init(&w.meshes,"Mesh_Renderer");core.table_init(&w.sources,"Pose_Source");core.table_init(&w.animations,"Animation")
    core.table_init(&w.rigids,"Rigid_Body");core.table_init(&w.colliders,"Collider");core.table_init(&w.joints,"Joint")
    core.table_init(&w.configs,"Ragdoll");core.table_init(&w.bones,"Ragdoll_Bone")
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Setup_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Setup_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Setup_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Setup_Test_World,parents)},
        {name="Mesh_Renderer",type=erender.Mesh_Renderer,info=type_info_of(erender.Mesh_Renderer),offset=offset_of(Setup_Test_World,meshes)},
        {name="Pose_Source",type=anim.Pose_Source,info=type_info_of(anim.Pose_Source),offset=offset_of(Setup_Test_World,sources)},
        {name="Animation",type=anim.Animation,info=type_info_of(anim.Animation),offset=offset_of(Setup_Test_World,animations)},
        {name="Rigid_Body",type=phys.Rigid_Body,info=type_info_of(phys.Rigid_Body),offset=offset_of(Setup_Test_World,rigids)},
        {name="Collider",type=phys.Collider,info=type_info_of(phys.Collider),offset=offset_of(Setup_Test_World,colliders)},
        {name="Joint",type=phys.Joint,info=type_info_of(phys.Joint),offset=offset_of(Setup_Test_World,joints)},
        {name="Ragdoll",type=rag.Ragdoll,info=type_info_of(rag.Ragdoll),offset=offset_of(Setup_Test_World,configs)},
        {name="Ragdoll_Bone",type=rag.Ragdoll_Bone,info=type_info_of(rag.Ragdoll_Bone),offset=offset_of(Setup_Test_World,bones)},
    }
    f.info=core.World_Info{entities=offset_of(Setup_Test_World,entities),tables=f.tables[:],settle=setup_test_settle}
    f.document=new(editor.Document)
    f.session=editor.Session{app=&f.app,assets_root=f.root,mode=.Edit,headless=true,info=&f.info,edit_world=&f.world,selection=&f.selection,edits=&f.edits,viewport=&f.viewport,gui=&f.gui,document=f.document,id_state=977}
    editor.edits_reset(&f.edits,core.world_ref(&f.world,&f.info))
    if !testing.expect_value(t,api.server_init(&f.server,{max_connections=1,max_methods=4}),api.Init_Error.None) {return false}
    serial.writer_init(&f.out,1<<20)
    defaults:=new(Ragdoll_Setup_Params,context.temp_allocator);defaults^={mode=rag.RAGDOLL_DEFAULT.mode}
    testing.expect_value(t,api.method_register(&f.server,{name="ragdoll.setup",params=Ragdoll_Setup_Params,params_info=type_info_of(Ragdoll_Setup_Params),result=Ragdoll_Setup_Result,result_info=type_info_of(Ragdoll_Setup_Result),defaults=defaults,user=&f.session,handler=proc(call:^api.Call) {setup((^editor.Session)(call.user),call)}}),api.Register_Error.None)
    turned:=mm.Transform{{2,0,3},mm.quat_axis_angle({0,1,0},.5),{1,1,1}}
    f.figure=setup_test_rig(f,t,"figure",0x11,701,true,turned)
    f.plain=setup_test_rig(f,t,"plain",0x12,702,false,mm.TRANSFORM_IDENTITY)
    editor.edits_reset(&f.edits,core.world_ref(&f.world,&f.info))
    return true
}

@(private)
setup_test_destroy :: proc(f:^Setup_Test) {
    w:=&f.world
    core.table_destroy(&w.ids);core.table_destroy(&w.names);core.table_destroy(&w.transforms);core.table_destroy(&w.parents)
    core.table_destroy(&w.meshes);core.table_destroy(&w.sources);core.table_destroy(&w.animations)
    core.table_destroy(&w.rigids);core.table_destroy(&w.colliders);core.table_destroy(&w.joints)
    core.table_destroy(&w.configs);core.table_destroy(&w.bones);core.entities_destroy(&w.entities)
    editor.edits_free(&f.edits);delete(f.selection.entities);free(f.document)
    host.app_content_destroy(&f.app)
    serial.writer_destroy(&f.out);api.server_destroy(&f.server);host.assets_destroy(&f.assets);os.remove_all(f.root)
}

@(private)
setup_test_call :: proc(f:^Setup_Test,params:string) -> (api.Error,string) {
    base.arena_reset(&f.server.scratch);serial.writer_reset(&f.out)
    error,_:=api.method_execute(&f.server,api.method_find(&f.server,"ragdoll.setup"),params,&f.out)
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
    config,configured:=core.get(core.read(&w.configs),f.figure)
    testing.expect(t,configured && config.mode==.Simulated && config.max_torque==rag.RAGDOLL_DEFAULT.max_torque)
    testing.expect_value(t,f.edits.cursor,1)
    for want in ([]string{`"part":"Forearm_L"`,`"joint":"Hinge"`,`"joint":"Swing_Twist"`,`"shape":"Capsule"`,`"shape":"Sphere"`,`"bone":"spine_02"`}) {
        testing.expectf(t,strings.contains(strings.join(strings.fields(text,context.temp_allocator),"",context.temp_allocator),want),"%s in %s",want,text)
    }

    // Spine and chest split the chain; the neck, the clavicles and the toes have no body.
    for name in ([]string{"pelvis","spine_01","spine_02","head","upperarm_l","lowerarm_l","hand_l","thigh_r","calf_r","foot_r"}) {testing.expectf(t,name in bodies,"no body on %s",name)}
    for name in ([]string{"neck_01","spine_03","clavicle_l","ball_l","root","ik_hand_root"}) {testing.expectf(t,!(name in bodies),"a body on %s",name)}
    testing.expect(t,!core.has(&w.joints,bodies["pelvis"]))
    testing.expect_value(t,core.get(&w.colliders,bodies["pelvis"]).kind,phys.Collider_Kind.Box)
    testing.expect_value(t,core.get(&w.colliders,bodies["head"]).kind,phys.Collider_Kind.Sphere)
    testing.expect_value(t,core.get(&w.colliders,bodies["calf_l"]).kind,phys.Collider_Kind.Capsule)
    elbow:=core.get(&w.joints,bodies["lowerarm_l"])^
    testing.expect(t,elbow.kind==.SixDOF && elbow.target==bodies["upperarm_l"] && elbow.angular[0].motion==.Locked && elbow.angular[2].motion==.Locked)
    testing.expect(t,elbow.angular[1].motion==.Limited && elbow.angular[1].upper>2 && elbow.angular[1].lower<=0)
    shoulder:=core.get(&w.joints,bodies["upperarm_r"])^
    testing.expect(t,shoulder.target==bodies["spine_02"] && shoulder.angular[0].motion==.Limited && shoulder.angular[2].motion==.Limited)
    testing.expect_value(t,core.get(&w.joints,bodies["thigh_l"]).target,bodies["pelvis"])
    testing.expect_value(t,core.get(&w.joints,bodies["head"]).target,bodies["spine_02"])

    // Each joint meets its target where they touch and with the same frame, and each body sits where its bone and offset put it.
    rig:=core.to_math(core.get(&w.transforms,f.figure)^)
    bones:=setup_test_bones()
    parents:=make([]i32,len(bones),context.temp_allocator);rest:=make([]mm.Transform,len(bones),context.temp_allocator);world:=make([]mm.Transform,len(bones),context.temp_allocator)
    for &bone,i in bones {parents[i]=bone.parent;rest[i]={bone.translation,bone.rotation,bone.scale}}
    testing.expect(t,lib.pose_world(parents,rest,world,rig))
    mass:f32
    for row in 0..<len(w.bones.values) {
        e:=w.bones.entities[row];binding:=w.bones.values[row]
        pose:=core.to_math(core.get(&w.transforms,e)^)
        rigid:=core.get(&w.rigids,e)^;collider:=core.get(&w.colliders,e)^
        testing.expect(t,rigid.type==.Dynamic && rigid.mass>0 && collider.group==f.figure && rag.ragdoll_bone_valid(binding))
        mass+=rigid.mass
        for &bone,i in bones {
            if base.text_get(bone.path[:])!=base.text_get(binding.bone.path[:]) {continue}
            placed:=mm.transform_compose(world[i],binding.offset)
            testing.expectf(t,linalg.length(placed.position-pose.position)<1e-4 && abs(linalg.dot(placed.rotation,pose.rotation))>.9999,"%s: the bone puts its body at %v, it is at %v",base.text_get(bone.name[:]),placed.position,pose.position)
        }
        joint,jointed:=core.get(core.read(&w.joints),e)
        if !jointed {continue}
        testing.expect_value(t,phys.joint_configuration_error(joint),phys.Joint_Error.None)
        target:=core.to_math(core.get(&w.transforms,joint.target)^)
        here:=pose.position+mm.quat_rotate(pose.rotation,pose.scale*joint.anchor)
        there:=target.position+mm.quat_rotate(target.rotation,target.scale*joint.target_anchor)
        testing.expectf(t,linalg.length(here-there)<1e-4,"anchors apart: %v %v",here,there)
        testing.expect(t,abs(linalg.dot(pose.rotation*joint.rotation,target.rotation*joint.target_rotation))>.9999)
    }
    testing.expect(t,abs(mass-70)<.01)

    ref:=core.world_ref(&f.world,&f.info)
    testing.expect(t,editor.undo(&f.edits,ref,&f.selection))
    testing.expect(t,len(w.bones.values)==0 && len(w.rigids.values)==0 && len(w.joints.values)==0 && !core.has(&w.configs,f.figure))
    testing.expect(t,editor.redo(&f.edits,ref,&f.selection))
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
    core.remove(&f.world.animations,f.figure);setup_test_settle(&f.world,nil,nil)
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
    testing.expect(t,len(w.bones.values)==16 && len(w.rigids.values)==16 && len(w.joints.values)==15)
    testing.expect(t,core.get(&w.configs,f.figure).mode==.Driven && f.edits.cursor==2)
    testing.expect(t,editor.undo(&f.edits,core.world_ref(&f.world,&f.info),&f.selection))
    testing.expect(t,len(w.bones.values)==16 && core.get(&w.configs,f.figure).mode==.Simulated)
}
