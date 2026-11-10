package ragdoll_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import aa "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"
import rag "plugins:ragdoll/runtime"

@(storage)
Ragdoll_Api :: struct {provider:editor.Api_Provider}

RAGDOLL_API_DEFAULT :: Ragdoll_Api{provider={register=register}}

// The bodies of a humanoid ragdoll. Spine and Chest split the chain between
// the pelvis and the neck; neck, clavicles and toes have none.
Ragdoll_Part :: enum u8 {Pelvis,Spine,Chest,Head,Upper_Arm_L,Forearm_L,Hand_L,Upper_Arm_R,Forearm_R,Hand_R,Thigh_L,Shin_L,Foot_L,Thigh_R,Shin_R,Foot_R}
// How a body turns from its parent, as limits of a SixDOF Joint, the kind a Driven ragdoll moves.
Ragdoll_Joint_Kind :: enum u8 {None,Hinge,Swing_Twist}

Ragdoll_Setup_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The rig: the entity with the Animation and the Mesh_Renderer of a skinned mesh"`,
    mass:f32 `mirai:"optional,min=0,max=100000,unit=kg,label=Total mass, split by volume; 0 weighs each body as water"`,
    mode:rag.Ragdoll_Mode `mirai:"optional"`,
}
Ragdoll_Setup_Body :: struct {
    id:base.Entity_Id,
    part:Ragdoll_Part,
    bone:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=Path of the bone it moves"`,
    shape:phys.Collider_Kind,
    size:mm.Vec3 `mirai:"unit=m,label=Collider.size in the space of the body: half extents of a box, radius in x of a sphere, radius in x and half height in y of a capsule"`,
    mass:f32 `mirai:"unit=kg"`,
    joint:Ragdoll_Joint_Kind `mirai:"label=None for the root"`,
    parent:base.Entity_Id `mirai:"label=The body its Joint targets; 0 for the root"`,
}
Ragdoll_Setup_Result :: struct {
    id:base.Entity_Id `mirai:"label=The rig"`,
    removed:u32 `mirai:"label=Bodies of the ragdoll it replaced"`,
    bodies:[len(Ragdoll_Part)]Ragdoll_Setup_Body `mirai:"trim"`,
}

@(private)
register :: proc(s:^editor.Session) {
    defaults:=Ragdoll_Setup_Params{mode=rag.RAGDOLL_DEFAULT.mode}
    editor.api_method_register(s,Ragdoll_Setup_Params,Ragdoll_Setup_Result,{name="ragdoll.setup",summary="Builds the ragdoll of a rig from the body of its skeleton, the one it stores or one found in memory for the call: a dynamic body with collider, Ragdoll_Bone and limited Joint per part, and the Ragdoll of the rig, in one step of undo that also takes away the ragdoll the rig had.",defaults=&defaults,run=setup})
}

// What a part takes from the body: its parent part, its joint with limits in
// radians (twist about the bone, lower and upper about the bend axis, swing
// to the sides) and the radius of its capsule as a share of the height of the bones.
@(private)
Part_Rule :: struct {parent:Ragdoll_Part,joint:Ragdoll_Joint_Kind,twist,lower,upper,swing,radius:f32}
@(private)
PART_RULES :: [Ragdoll_Part]Part_Rule{
    .Pelvis={},
    .Spine={.Pelvis,.Swing_Twist,.25,-.3,.5,.3,0},
    .Chest={.Spine,.Swing_Twist,.25,-.3,.5,.3,0},
    .Head={.Chest,.Swing_Twist,.7,-.5,.6,.4,.065},
    .Upper_Arm_L={.Chest,.Swing_Twist,1,-1.4,1.4,1.4,.03},
    .Forearm_L={.Upper_Arm_L,.Hinge,0,-.05,2.5,0,.025},
    .Hand_L={.Forearm_L,.Swing_Twist,.3,-.8,.8,.4,0},
    .Upper_Arm_R={.Chest,.Swing_Twist,1,-1.4,1.4,1.4,.03},
    .Forearm_R={.Upper_Arm_R,.Hinge,0,-.05,2.5,0,.025},
    .Hand_R={.Forearm_R,.Swing_Twist,.3,-.8,.8,.4,0},
    .Thigh_L={.Pelvis,.Swing_Twist,.4,-1.6,.35,.6,.05},
    .Shin_L={.Thigh_L,.Hinge,0,-.05,2.4,0,.035},
    .Foot_L={.Shin_L,.Swing_Twist,.2,-.4,.7,.3,0},
    .Thigh_R={.Pelvis,.Swing_Twist,.4,-1.6,.35,.6,.05},
    .Shin_R={.Thigh_R,.Hinge,0,-.05,2.4,0,.035},
    .Foot_R={.Shin_R,.Swing_Twist,.2,-.4,.7,.3,0},
}

// A body to make, in world space but its collider and joint, which are in its own.
@(private)
Plan_Body :: struct {
    present:bool,
    bone:i32,
    parent:Ragdoll_Part,
    pose:mm.Transform, // scale: that of its bone, uniform
    offset:mm.Transform,
    collider:phys.Collider,
    joint:phys.Joint,
    volume,mass:f32,
}
@(private)
Plan_Failure :: struct {path,code,expected,actual,message,fix:string}

@(private)
failure :: proc(call:^api.Call,f:Plan_Failure,rpc_code:=api.INVALID_PARAMS) {
    writer:serial.Writer
    serial.writer_init(&writer,256,call.allocator)
    defer serial.writer_destroy(&writer)
    serial.text_write_raw(&writer,"{")
    api.write_text(&writer,"path",f.path,true);api.write_text(&writer,"code",f.code)
    api.write_text(&writer,"expected",f.expected);api.write_text(&writer,"actual",f.actual);api.write_text(&writer,"fix",f.fix)
    serial.text_write_raw(&writer,"}")
    api.call_fail(call,rpc_code,f.message,string(serial.writer_bytes(&writer)))
}

@(private)
setup :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ragdoll_Setup_Params)
    if s.app==nil || s.app.assets==nil {failure(call,{"asset","Unavailable","an asset registry","none","Assets are unavailable",""},api.SERVER_ERROR);return}
    if !(p.mass>=0 && p.mass<=max(f32)) || p.mode>max(rag.Ragdoll_Mode) {failure(call,{"mass","Invalid_Value","a finite mass of 0 or more and a mode",fmt.tprintf("mass %v mode %v",p.mass,p.mode),"The mass or the mode is not valid","Pass mass in kg, or omit it"});return}
    w:=editor.edited_world(s)
    configs:=core.world_table_of(w,rag.Ragdoll)
    bindings:=core.world_table_of(w,rag.Ragdoll_Bone)
    rigids:=core.world_table_of(w,phys.Rigid_Body)
    colliders:=core.world_table_of(w,phys.Collider)
    joints:=core.world_table_of(w,phys.Joint)
    parents:=core.world_table_of(w,core.Parent)
    ids:=core.world_table_of(w,core.Id)
    if configs==nil || bindings==nil || rigids==nil || colliders==nil || joints==nil || parents==nil || ids==nil || core.world_table_of(w,core.Transform)==nil {
        failure(call,{"plugins","Unavailable","the tables of ragdoll, animation and physics","missing","The world has no ragdoll or physics components","Activate the plugin ragdoll in project.mirai and rebuild"},api.SERVER_ERROR)
        return
    }
    rig,problem:=editor.api_entity_select(w,base.text_get(p.entity[:]),"entity",false,call.allocator)
    if problem!="" {failure(call,{"entity","Missing_Entity","an entity of the edited scene",base.text_get(p.entity[:]),"The rig does not exist",problem});return}
    if source,shared:=editor.entity_get(w,rig,anim.Pose_Source);shared && source.rig!=core.NONE {rig=source.rig}
    if !editor.entity_has(w,rig,anim.Animation) {failure(call,{"entity","Missing_Component","a rig with an Animation","no Animation","The rig has no Animation, so a ragdoll could not follow its pose","Give it an Animation, for example with animation.play"});return}
    skeleton_id:base.Asset_Id
    if shown,has:=editor.entity_get(w,rig,erender.Mesh_Renderer);has && shown.mesh!={} {
        file:aa.Asset
        if host.assets_file(s.app.assets,shown.mesh,aa.KIND_MESH,&file)==.None {
            if view,error:=aa.mesh_view(&file,&s.app.assets.types);error==.None && view.info!=nil {skeleton_id=view.info.skeleton}
            aa.asset_close(&file)
        }
    }
    if skeleton_id=={} {failure(call,{"entity","Missing_Skeleton","a rig whose Mesh_Renderer shows a skinned mesh","none","The rig has no skeleton","Pass the id of the entity with the Mesh_Renderer of a skinned mesh"});return}
    file:aa.Asset;defer aa.asset_close(&file)
    if error:=host.assets_file(s.app.assets,skeleton_id,aa.KIND_SKELETON,&file);error!=.None {failure(call,{"skeleton","Read_Error","a readable .skeleton",fmt.tprintf("%v",error),"The skeleton of the rig could not be read",""},api.SERVER_ERROR);return}
    view,error:=aa.skeleton_view(&file,&s.app.assets.types)
    if error!=.None {failure(call,{"skeleton","Invalid_Asset","a valid .skeleton",fmt.tprintf("%v",error),"The skeleton of the rig is not valid",""});return}
    body_map:=aa.skeleton_body_map(view.bones,view.body,view.body_parts)
    if view.body==nil {
        detected,found:=aa.skeleton_body_detect(view.bones,lib.body_map_empty(),call.allocator)
        if !found {failure(call,{"skeleton","Missing_Body_Map","a skeleton whose body parts can be found","detection failed","The body of the skeleton could not be found","Name its parts with skeleton.body.set, then call ragdoll.setup again"});return}
        body_map=detected
    }
    previous:=make([dynamic]core.Entity,0,16,call.allocator)
    for row in 0..<core.count(bindings) {if bindings.values[row].rig==rig {append(&previous,core.entity_at(bindings,row))}}
    for body in previous {
        for at,depth:=rig,0;at!=core.NONE && depth<1024;depth+=1 {
            if at==body {failure(call,{"entity","Invalid_Replace","bodies apart from the rig","a body that holds the rig","A body of the ragdoll holds the rig, and replacing it would remove the rig","Take the rig out of that body, or remove its Ragdoll_Bone"});return}
            parent,placed:=core.get(core.read(parents),at)
            at=parent.entity if placed else core.NONE
        }
    }
    bodies,fail:=plan(view.bones,body_map,editor.entity_world(w,rig),p.mass,call.allocator)
    if fail.code!="" {failure(call,fail);return}
    config:=rag.RAGDOLL_DEFAULT;config.mode=p.mode
    stem:=editor.entity_name(w,rig)
    stem=fmt.tprintf("%s ragdoll",stem) if stem!="" else "Ragdoll"
    if !editor.api_edit_begin(s,call,"Ragdoll setup") {return}
    if len(previous)>0 {editor.entities_delete(s,previous[:])}
    for body in previous {
        if editor.entity_alive(w,body) {
            failure(call,{"entity","Locked_Body","bodies the scene can remove",fmt.tprintf("%x",core.id_of(core.read(ids),body)),"A body of the previous ragdoll could not be removed","Unlock it: it is a member of a prefab instance or of a section that is not edited"})
            editor.api_edit_end(s,call,false)
            return
        }
    }
    made:[Ragdoll_Part]core.Entity
    for &body,part in bodies {
        if !body.present {continue}
        e:=editor.entity_create(s,{preset=.Empty,name=fmt.tprintf("%s %s",stem,strings.to_lower(fmt.tprintf("%v",part),call.allocator)),transform=core.from_math(body.pose)})
        if e==core.NONE {
            failure(call,{"entity","Edit_Refused","a scene that takes new entities","refused","The bodies could not be made in the edited scene","Edit the section the rig is in, or save and reopen the scene"})
            editor.api_edit_end(s,call,false)
            return
        }
        made[part]=e
        rigid:=phys.RIGID_BODY_DYNAMIC;rigid.mass,rigid.linear_damping,rigid.angular_damping=body.mass,.1,.1
        collider:=body.collider;collider.group=rig
        core.add(rigids,e,rigid);core.add(colliders,e,collider)
        core.add(bindings,e,rag.Ragdoll_Bone{rig=rig,bone=bone_named(view.bones,int(body.bone)),offset=body.offset})
        if part!=.Pelvis {joint:=body.joint;joint.target=made[body.parent];core.add(joints,e,joint)}
    }
    core.add(configs,rig,config)
    core.world_settle(w)
    if !editor.api_edit_end(s,call,true) {return}
    out:=api.call_result(call,Ragdoll_Setup_Result)
    out.id,out.removed=core.id_of(core.read(ids),rig),u32(len(previous))
    rules:=PART_RULES
    count:=0
    for &body,part in bodies {
        if !body.present {continue}
        row:=&out.bodies[count];count+=1
        row.id,row.part,row.shape,row.size,row.mass,row.joint=core.id_of(core.read(ids),made[part]),part,body.collider.kind,body.collider.size,body.mass,rules[part].joint
        named:=bone_named(view.bones,int(body.bone));base.text_set(row.bone[:],base.text_get(named.path[:]))
        if part!=.Pelvis {row.parent=core.id_of(core.read(ids),made[body.parent])}
    }
}

// The bodies of the ragdoll of a skeleton at rest, posed by the transform of
// its rig. Each body is centered on its segment with +Y along it and +X to
// the left of the body.
@(private)
plan :: proc(bones:[]aa.Skeleton_Bone,body_map:lib.Body_Map,rig:mm.Transform,total_mass:f32,allocator:=context.temp_allocator) -> (bodies:[Ragdoll_Part]Plan_Body,fail:Plan_Failure) {
    n:=len(bones)
    parents:=make([]i32,n,allocator);rest:=make([]mm.Transform,n,allocator);world:=make([]mm.Transform,n,allocator)
    for &bone,i in bones {parents[i]=bone.parent;rest[i]={bone.translation,bone.rotation,bone.scale}}
    if n==0 || !lib.pose_world(parents,rest,world,rig) {fail={"skeleton","Invalid_Skeleton","a rest pose that composes","no pose","The rest pose of the skeleton does not compose","Check its bones with animation.asset.inspect section=bones"};return}
    up:=linalg.normalize(mm.quat_rotate(rig.rotation,body_map.up));forward:=linalg.normalize(mm.quat_rotate(rig.rotation,mm.FORWARD))
    left:=linalg.cross(up,forward)
    low,high:=max(f32),-max(f32)
    for t in world {h:=linalg.dot(t.position,up);low,high=min(low,h),max(high,h)}
    height:=high-low
    if !(height>1e-4 && height<1e6) {fail={"skeleton","Invalid_Skeleton","bones spread along the up of the body",fmt.tprintf("%v m",height),"The bones of the skeleton have no height to size the bodies","Check the up of the body with skeleton.body.set"};return}
    mapped:=body_map.bones
    if mapped[.Pelvis]<0 {fail={"skeleton","Missing_Part","a body with a pelvis","no pelvis","The body of the skeleton has no pelvis, the root of the ragdoll","Set it with skeleton.body.set, for example {\"parts\":[{\"part\":\"Pelvis\",\"bone\":\"<path>\"}]}"};return}
    of:[Ragdoll_Part]i32
    for &bone in of {bone=-1}
    spine:[64]i32
    count,_:=lib.body_spine(parents,body_map,spine[:])
    if count==1 {of[.Chest]=spine[0]} else if count>=2 {of[.Spine],of[.Chest]=spine[0],spine[count/2]}
    of[.Pelvis],of[.Head]=mapped[.Pelvis],mapped[.Head]
    of[.Upper_Arm_L],of[.Forearm_L],of[.Hand_L]=mapped[.Shoulder_L],mapped[.Elbow_L],mapped[.Hand_L]
    of[.Upper_Arm_R],of[.Forearm_R],of[.Hand_R]=mapped[.Shoulder_R],mapped[.Elbow_R],mapped[.Hand_R]
    of[.Thigh_L],of[.Shin_L],of[.Foot_L]=mapped[.Hip_L],mapped[.Knee_L],mapped[.Foot_L]
    of[.Thigh_R],of[.Shin_R],of[.Foot_R]=mapped[.Hip_R],mapped[.Knee_R],mapped[.Foot_R]
    at :: proc(world:[]mm.Transform,bone:i32) -> mm.Vec3 {return world[bone].position}
    // The first child of a bone away from it, for a segment whose next part is missing.
    child :: proc(parents:[]i32,world:[]mm.Transform,bone:i32,near:f32) -> (mm.Vec3,bool) {
        for parent,i in parents {if parent==bone && linalg.length(world[i].position-world[bone].position)>near {return world[i].position,true}}
        return {},false
    }
    toward :: proc(from,to,fallback:mm.Vec3) -> mm.Vec3 {
        d:=to-from
        l:=linalg.length(d)
        return d/l if l>1e-6 else fallback
    }
    // A unit vector along hint, perpendicular to axis; other when hint runs along axis.
    across :: proc(axis,hint,other:mm.Vec3) -> mm.Vec3 {
        v:=hint-axis*linalg.dot(axis,hint)
        if linalg.length(v)<1e-3 {v=other-axis*linalg.dot(axis,other)}
        return linalg.normalize(v)
    }
    basis :: proc(x,y,z:mm.Vec3) -> mm.Quat {
        m:mm.Mat3
        m[0,0],m[1,0],m[2,0]=x.x,x.y,x.z
        m[0,1],m[1,1],m[2,1]=y.x,y.y,y.z
        m[0,2],m[1,2],m[2,2]=z.x,z.y,z.z
        return linalg.normalize(mm.quat_from_mat3(m))
    }
    near:=height*1e-3
    neck:=mapped[.Neck] if mapped[.Neck]>=0 else mapped[.Head]
    next_part:=#partial [Ragdoll_Part]lib.Body_Part{.Upper_Arm_L=.Elbow_L,.Forearm_L=.Hand_L,.Upper_Arm_R=.Elbow_R,.Forearm_R=.Hand_R,.Thigh_L=.Knee_L,.Shin_L=.Foot_L,.Thigh_R=.Knee_R,.Shin_R=.Foot_R}
    rules:=PART_RULES
    hips_l,hips_r:=mapped[.Hip_L],mapped[.Hip_R]
    sum:f32
    for &body,part in bodies {
        bone:=of[part]
        if bone<0 {continue}
        path:=base.text_get(bones[bone].path[:])
        if _,valid:=anim.bone_ref(path);!valid {fail={"skeleton","Invalid_Bone",fmt.tprintf("a bone path shorter than %d bytes",aa.NODE_PATH_CAPACITY),path,"A bone of the body has a path a Ragdoll_Bone cannot hold","Rename the bones of the skeleton with shorter names"};return}
        body.present,body.bone=true,bone
        rule:=rules[part]
        start:=at(world,bone)
        end:=start
        center:mm.Vec3
        placed,has_end:=false,false
        size:mm.Vec3
        kind:=phys.Collider_Kind.Box
        switch part {
        case .Pelvis:
            if hips_l>=0 && hips_r>=0 {start=(at(world,hips_l)+at(world,hips_r))*.5}
            switch {
            case of[.Spine]>=0: end=at(world,of[.Spine])
            case of[.Chest]>=0: end=at(world,of[.Chest])
            case neck>=0: end=at(world,neck)
            case: end=start+up*height*.1
            }
            has_end=true
            width:=linalg.length(at(world,hips_l)-at(world,hips_r))*.5+height*.03 if hips_l>=0 && hips_r>=0 else height*.1
            size={width,max(linalg.length(end-start)*.5,height*.04),height*.06}
        case .Spine,.Chest:
            if part==.Spine {end,has_end=at(world,of[.Chest]),true} else if neck>=0 {end,has_end=at(world,neck),true}
            if !has_end {end,has_end=child(parents,world,bone,near)}
            size={height*.1,max(linalg.length(end-start)*.5,height*.03),height*.065}
        case .Head:
            // The head bone sits where the skull starts: the sphere goes above it, and the joint at the neck.
            r:=height*rule.radius
            direction:=up
            if mapped[.Neck]>=0 {direction=toward(at(world,mapped[.Neck]),start,up);start=at(world,mapped[.Neck])}
            center=at(world,bone)+direction*r*.8
            kind,size,end,placed,has_end=.Sphere,{r,0,0},center,true,true
        case .Hand_L,.Hand_R:
            forearm:=of[.Forearm_L] if part==.Hand_L else of[.Forearm_R]
            direction:=-up
            if forearm>=0 {direction=toward(at(world,forearm),start,-up)} else if tip,found:=child(parents,world,bone,near);found {direction=toward(start,tip,-up)}
            end,has_end=start+direction*height*.1,true
            size={height*.03,height*.05,height*.013}
        case .Foot_L,.Foot_R:
            toe:=mapped[.Toe_L] if part==.Foot_L else mapped[.Toe_R]
            if toe>=0 {end=at(world,toe);end+=toward(start,end,forward)*height*.03} else {end=start+forward*height*.12}
            has_end=true
            size={height*.03,max(linalg.length(end-start)*.5,height*.03),height*.025}
        case .Upper_Arm_L,.Forearm_L,.Upper_Arm_R,.Forearm_R,.Thigh_L,.Shin_L,.Thigh_R,.Shin_R:
            if next:=mapped[next_part[part]];next>=0 {end,has_end=at(world,next),true} else {end,has_end=child(parents,world,bone,near)}
            if !has_end {end=start}
            r:=height*rule.radius
            half:=linalg.length(end-start)*.5
            if half-r>r*.1 {kind,size=.Capsule,{r,half-r,0}} else {kind,size=.Sphere,{max(r,half),0,0}}
        }
        if !placed {center=(start+end)*.5}
        along:=toward(start,end,up)
        side:=across(along,linalg.cross(left,along),forward)
        rotation:=basis(linalg.cross(along,side),along,side)
        // The bone passes its scale to the body, so that Ragdoll_Bone.offset stays rigid.
        scale:=world[bone].scale
        if !(scale.x>1e-6 && abs(scale.y-scale.x)<=scale.x*1e-3 && abs(scale.z-scale.x)<=scale.x*1e-3) {
            fail={"skeleton","Invalid_Scale","bones of a uniform positive scale",fmt.tprintf("%s with %v",path,scale),"A bone of the body has a scale that is not uniform","Give the rig and the bones of the body a uniform scale"}
            return
        }
        k:=scale.x
        body.pose={center,rotation,{k,k,k}}
        inverse:=mm.quat_inverse(world[bone].rotation)
        body.offset={mm.quat_rotate(inverse,center-world[bone].position)/k,linalg.normalize(inverse*rotation),{1,1,1}}
        #partial switch kind {
        case .Box: body.volume=8*size.x*size.y*size.z
        case .Sphere: body.volume=4.0/3*math.PI*size.x*size.x*size.x
        case .Capsule: body.volume=math.PI*size.x*size.x*(2*size.y+4.0/3*size.x)
        }
        sum+=body.volume
        body.collider=phys.COLLIDER_DEFAULT
        body.collider.kind,body.collider.size=kind,size/k
        if part==.Pelvis {continue}
        // Parents come before their children in Ragdoll_Part, and the pelvis is always made.
        parent:=rule.parent
        for !bodies[parent].present {parent=rules[parent].parent}
        body.parent=parent
        // The frame of the joint: X along the body, Y the axis it bends about.
        x:=along
        bend:=-forward if part==.Shin_L || part==.Shin_R else forward
        y:=linalg.normalize(linalg.cross(x,bend)) if rule.joint==.Hinge && linalg.length(linalg.cross(x,bend))>1e-3 else across(x,left,forward)
        frame:=basis(x,y,linalg.cross(x,y))
        target:=bodies[parent].pose
        joint:=phys.joint_sixdof(core.NONE)
        joint.auto_target=false
        joint.anchor=mm.quat_rotate(mm.quat_inverse(rotation),start-center)/k
        joint.rotation=linalg.normalize(mm.quat_inverse(rotation)*frame)
        joint.target_anchor=mm.quat_rotate(mm.quat_inverse(target.rotation),start-target.position)/target.scale.x
        joint.target_rotation=linalg.normalize(mm.quat_inverse(target.rotation)*frame)
        joint.angular[1]={motion=.Limited,lower=rule.lower,upper=rule.upper}
        if rule.joint==.Swing_Twist {
            joint.angular[0]={motion=.Limited,lower=-rule.twist,upper=rule.twist}
            joint.angular[2]={motion=.Limited,lower=-rule.swing,upper=rule.swing}
        }
        if error:=phys.joint_configuration_error(joint);error!=.None {
            fail={"skeleton","Invalid_Joint","a joint the physics accepts",fmt.tprintf("%v: %v",part,error),"The joint of a body could not be made from the rest pose","Check the rest pose of the skeleton with animation.asset.inspect section=bones"}
            return
        }
        body.joint=joint
    }
    for &body in bodies {
        if !body.present {continue}
        body.mass=total_mass*body.volume/sum if total_mass>0 else body.volume*body.collider.density
        if !(body.mass>0 && body.mass<max(f32)) {fail={"mass","Invalid_Value","a mass each body can take",fmt.tprintf("%v kg",body.mass),"A body of the ragdoll would weigh nothing","Pass a larger mass"};return}
    }
    return
}

// A bone by its name when no other bone of the skeleton has it, as a clip of
// another skeleton with the same names finds it, else by its path.
@(private)
bone_named :: proc(bones:[]aa.Skeleton_Bone,index:int) -> anim.Bone_Ref {
    name:=base.text_get(bones[index].name[:])
    for &other,i in bones {
        if i!=index && base.text_get(other.name[:])==name {return anim.bone_ref(base.text_get(bones[index].path[:]))}
    }
    return anim.bone_ref(name)
}
