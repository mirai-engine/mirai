package animation_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// Kept on the heap: it overflows the stack of a test thread.
Authoring_Test :: struct {root:string,assets:host.Assets,app:host.App,session:editor.Session,server:api.Server,out:serial.Writer}
Authoring_Test_Entry :: struct {session:^editor.Session,run:editor.Api_Handler}

@(private)
authoring_test_init :: proc(f:^Authoring_Test,t:^testing.T,name:string) -> bool {
    f.root=base.test_folder(t,fmt.tprintf("authoring-%s",name))
    if f.root=="" {return false}
    // As the editor names its files, so that edits stay in the memory of the registry.
    f.root=project.path_absolute(f.root,context.temp_allocator)
    if !testing.expect(t,host.assets_init(&f.assets,{root=f.root,capacity=8,error_capacity=8})) {return false}
    f.app.assets,f.app.allocator=&f.assets,context.allocator
    f.session.app,f.session.assets_root,f.session.mode=&f.app,f.root,.Edit
    if !testing.expect_value(t,api.server_init(&f.server,{max_connections=1,max_methods=32}),api.Init_Error.None) {return false}
    serial.writer_init(&f.out,1<<20)
    return true
}

@(private)
authoring_test_destroy :: proc(f:^Authoring_Test) {
    host.app_content_destroy(&f.app)
    serial.writer_destroy(&f.out);api.server_destroy(&f.server);host.assets_destroy(&f.assets)
}

@(private)
authoring_test_register :: proc(f:^Authoring_Test,t:^testing.T,name:string,$T:typeid,run:editor.Api_Handler,defaults:^T=nil) {
    entry:=new(Authoring_Test_Entry,context.temp_allocator);entry^={&f.session,run}
    testing.expect_value(t,api.method_register(&f.server,{name=name,params=T,params_info=type_info_of(T),defaults=defaults,user=entry,handler=proc(call:^api.Call) {entry:=(^Authoring_Test_Entry)(call.user);entry.run(entry.session,call)}}),api.Register_Error.None)
}

@(private)
authoring_test_execute :: proc(f:^Authoring_Test,name,params:string) -> api.Error {
    base.arena_reset(&f.server.scratch);serial.writer_reset(&f.out)
    method:=api.method_find(&f.server,name)
    if method==nil {return {api.METHOD_NOT_FOUND,"Missing test method",""}}
    error,_:=api.method_execute(&f.server,method,params,&f.out)
    return error
}

@(private)
authoring_test_id :: proc(f:^Authoring_Test,path:string) -> base.Asset_Id {
    record,ok:=asset.registry_find_path(&f.assets.registry,path)
    return record.id if ok else base.Asset_Id{}
}

@(private)
authoring_test_revision :: proc(f:^Authoring_Test,path:string) -> u64 {
    bytes,error:=asset.registry_read(&f.assets.registry,path,context.temp_allocator)
    return base.hash64(bytes) if error==.None else 0
}

// Opens a file of the test as the editor sees it: unsaved in the memory of
// the registry, else on disk.
@(private)
authoring_test_load :: proc(f:^Authoring_Test,path:string,file:^asset.Asset) -> asset.Error {
    data:=asset.registry_read(&f.assets.registry,path) or_return
    return asset.asset_take(file,data)
}

@(private)
authoring_test_exists :: proc(f:^Authoring_Test,path:string) -> bool {
    _,found:=asset.registry_find_path(&f.assets.registry,path)
    return found
}

@(private)
authoring_test_id_text :: proc(id:base.Asset_Id) -> string {buffer:=make([]u8,32,context.temp_allocator);return base.asset_id_format(id,buffer)}

@(test)
skeleton_authoring_preserves_identity_and_validates_sockets :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"skeleton") {return};defer authoring_test_destroy(f)
    authoring_test_register(f,t,"create",Skeleton_Create_Params,authoring_skeleton_create)
    defaults:=Socket_Set_Params{offset=mm.TRANSFORM_IDENTITY}
    authoring_test_register(f,t,"socket",Socket_Set_Params,authoring_socket_set,&defaults)
    inspect:=Authoring_Inspect_Params{limit=1}
    authoring_test_register(f,t,"inspect",Authoring_Inspect_Params,authoring_skeleton_inspect,&inspect)
    result:=authoring_test_execute(f,"create",`{"path":"rig.skeleton","bones":[{"name":"root","path":"root","position":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1]}]}`)
    if !testing.expect_value(t,result.code,0) {return}
    id:=authoring_test_id(f,"rig.skeleton");testing.expect(t,id!={})
    revision:=authoring_test_revision(f,"rig.skeleton")
    result=authoring_test_execute(f,"socket",fmt.tprintf(`{{"asset":"%s","name":"hand","bone":"root"}}`,authoring_test_id_text(id)))
    testing.expect_value(t,result.code,0)
    testing.expect_value(t,authoring_test_id(f,"rig.skeleton"),id)
    changed:=authoring_test_revision(f,"rig.skeleton");testing.expect(t,changed!=revision)
    result=authoring_test_execute(f,"socket",fmt.tprintf(`{{"asset":"%s","name":"missing","bone":"absent"}}`,authoring_test_id_text(id)))
    testing.expect_value(t,result.code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_revision(f,"rig.skeleton"),changed)
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s"}}`,authoring_test_id_text(id)))
    testing.expect_value(t,result.code,0)
    text:=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(text,`"name": "hand"`) && strings.contains(text,`"bones_total":1`))
    result=authoring_test_execute(f,"socket",fmt.tprintf(`{{"asset":"%s","name":"hand","remove":true}}`,authoring_test_id_text(id)))
    testing.expect_value(t,result.code,0)
    f.session.mode=.Play
    result=authoring_test_execute(f,"socket",fmt.tprintf(`{{"asset":"%s","name":"hand","bone":"root"}}`,authoring_test_id_text(id)))
    testing.expect_value(t,result.code,0)
}

@(test)
skeleton_authoring_defaults_reference_poses_to_identity_and_rejects_invalid_rotations :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"skeleton-defaults") {return};defer authoring_test_destroy(f)
    create:=authoring_skeleton_create_defaults()
    bone:=Skeleton_Bone_Set_Params{bone={rotation={0,0,0,1},scale={1,1,1}}}
    socket:=Socket_Set_Params{offset=mm.TRANSFORM_IDENTITY}
    authoring_test_register(f,t,"create",Skeleton_Create_Params,authoring_skeleton_create,create)
    authoring_test_register(f,t,"bone",Skeleton_Bone_Set_Params,authoring_bone_set,&bone)
    authoring_test_register(f,t,"socket",Socket_Set_Params,authoring_socket_set,&socket)
    result:=authoring_test_execute(f,"create",`{"path":"rig.skeleton","bones":[{"name":"root","path":"root"},{"name":"hand","path":"root/hand","parent":"root","position":[0,1,0]}]}`)
    if !testing.expect_value(t,result.code,0) {return}
    id:=authoring_test_id(f,"rig.skeleton");identity:=authoring_test_id_text(id)
    result=authoring_test_execute(f,"socket",fmt.tprintf(`{{"asset":"%s","name":"weapon","bone":"root/hand"}}`,identity))
    if !testing.expect_value(t,result.code,0) {return}
    file:asset.Asset
    if !testing.expect_value(t,authoring_test_load(f,"rig.skeleton",&file),asset.Error.None) {return}
    view,error:=asset.skeleton_view(&file,&f.assets.types)
    if testing.expect_value(t,error,asset.Error.None) {
        testing.expect_value(t,len(view.bones),2)
        testing.expect_value(t,view.bones[0].translation,mm.Vec3{})
        testing.expect_value(t,view.bones[1].translation,mm.Vec3{0,1,0})
        for value in view.bones {testing.expect_value(t,value.rotation,quaternion128(1));testing.expect_value(t,value.scale,mm.Vec3{1,1,1})}
        testing.expect_value(t,len(view.sockets),1)
        testing.expect_value(t,view.sockets[0].offset,mm.TRANSFORM_IDENTITY)
    }
    asset.asset_close(&file)
    result=authoring_test_execute(f,"bone",fmt.tprintf(`{{"asset":"%s","path":"root/hand","bone":{{"name":"palm"}}}}`,identity))
    if !testing.expect_value(t,result.code,0) {return}
    if !testing.expect_value(t,authoring_test_load(f,"rig.skeleton",&file),asset.Error.None) {return};defer asset.asset_close(&file)
    view,error=asset.skeleton_view(&file,&f.assets.types)
    if testing.expect_value(t,error,asset.Error.None) {
        testing.expect_value(t,view.bones[1].translation,mm.Vec3{})
        testing.expect_value(t,view.bones[1].rotation,quaternion128(1))
        testing.expect_value(t,view.bones[1].scale,mm.Vec3{1,1,1})
        testing.expect_value(t,base.text_get(view.bones[1].name[:]),"palm")
        testing.expect_value(t,base.text_get(view.bones[1].path[:]),"root/hand")
        testing.expect_value(t,view.bones[1].parent,i32(0))
    }
    revision:=authoring_test_revision(f,"rig.skeleton")
    result=authoring_test_execute(f,"bone",fmt.tprintf(`{{"asset":"%s","path":"root/hand","bone":{{"name":"palm","rotation":[0,0,0,2]}}}}`,identity))
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect_value(t,authoring_test_revision(f,"rig.skeleton"),revision)
    result=authoring_test_execute(f,"bone",fmt.tprintf(`{{"asset":"%s","path":"root/hand","bone":{{"name":"palm","path":"root/hand","parent":"root"}}}}`,identity))
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect_value(t,authoring_test_revision(f,"rig.skeleton"),revision)
    schema:=authoring_result_schema(Skeleton_Bone_Set_Params,type_info_of(Skeleton_Bone_Set_Params),context.temp_allocator)
    testing.expect(t,!strings.contains(schema,`"parent"`))
    result=authoring_test_execute(f,"create",`{"path":"invalid.skeleton","bones":[{"name":"root","path":"root","rotation":[0,0,0,2]}]}`)
    testing.expect_value(t,result.code,api.INVALID_PARAMS)
    testing.expect(t,!authoring_test_exists(f,"invalid.skeleton"))
    result=authoring_test_execute(f,"create",`{"path":"orphan.skeleton","bones":[{"name":"root","path":"root","parent":"missing"}]}`)
    testing.expect_value(t,result.code,api.INVALID_PARAMS)
    testing.expect(t,!authoring_test_exists(f,"orphan.skeleton"))
}

@(test)
timeline_authoring_edits_curves_keys_markers_and_root_without_partial_writes :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"timeline") {return};defer authoring_test_destroy(f)
    authoring_test_register(f,t,"create",Clip_Create_Params,authoring_clip_create)
    track_defaults:=Track_Set_Params{}
    key_defaults:=Key_Set_Params{}
    marker_defaults:=Marker_Set_Params{}
    clip_defaults:=Clip_Set_Params{}
    inspect:=Track_Inspect_Params{offset=1,limit=1}
    authoring_test_register(f,t,"track",Track_Set_Params,authoring_track_set,&track_defaults)
    authoring_test_register(f,t,"key",Key_Set_Params,authoring_key_set,&key_defaults)
    authoring_test_register(f,t,"marker",Marker_Set_Params,authoring_marker_set,&marker_defaults)
    authoring_test_register(f,t,"clip",Clip_Set_Params,authoring_clip_set,&clip_defaults)
    authoring_test_register(f,t,"inspect",Track_Inspect_Params,authoring_track_inspect,&inspect)
    if !testing.expect_value(t,authoring_test_execute(f,"create",`{"path":"clip.anim","name":"walk"}`).code,0) {return}
    id:=authoring_test_id(f,"clip.anim");identity:=authoring_test_id_text(id)
    params:=fmt.tprintf(`{{"asset":"%s","clip":"walk","target":"pulse","property":"Float","keys":[{{"time":0,"value":[0,0,0,0]}},{{"time":1,"value":[1,0,0,0],"interpolation":"Cubic_Spline","tangents":true,"in_slope":[1,0,0,0],"out_slope":[1,0,0,0]}}]}}`,identity)
    if !testing.expect_value(t,authoring_test_execute(f,"track",params).code,0) {return}
    unchanged:=authoring_test_revision(f,"clip.anim")
    result:=authoring_test_execute(f,"key",fmt.tprintf(`{{"asset":"%s","clip":"walk","target":"pulse","property":"Float","time":-1,"key":{{"value":[2,0,0,0]}}}}`,identity))
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect_value(t,authoring_test_revision(f,"clip.anim"),unchanged)
    result=authoring_test_execute(f,"key",fmt.tprintf(`{{"asset":"%s","clip":"walk","target":"pulse","property":"Float","time":1,"key":{{"value":[2,0,0,0],"interpolation":"Cubic_Spline","tangents":false}}}}`,identity))
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect_value(t,authoring_test_revision(f,"clip.anim"),unchanged)
    result=authoring_test_execute(f,"key",fmt.tprintf(`{{"asset":"%s","clip":"walk","target":"pulse","property":"Float","time":2,"key":{{"value":[2,0,0,0]}}}}`,identity))
    testing.expect_value(t,result.code,0)
    result=authoring_test_execute(f,"marker",fmt.tprintf(`{{"asset":"%s","clip":"walk","name":"step","time":0.5}}`,identity))
    testing.expect_value(t,result.code,0)
    // A marker is named; the key at a time is replaced, another goes in order.
    result=authoring_test_execute(f,"marker",fmt.tprintf(`{{"asset":"%s","clip":"walk","name":"step","time":0.75}}`,identity))
    testing.expect_value(t,result.code,0)
    result=authoring_test_execute(f,"marker",fmt.tprintf(`{{"asset":"%s","clip":"walk","name":"step","time":0.5,"add":true}}`,identity))
    testing.expect_value(t,result.code,0)
    result=authoring_test_execute(f,"marker",fmt.tprintf(`{{"asset":"%s","clip":"walk","name":"step","time":0.6}}`,identity))
    testing.expect_value(t,result.code,api.INVALID_PARAMS)
    result=authoring_test_execute(f,"marker",fmt.tprintf(`{{"asset":"%s","clip":"walk","name":"step","at":0.5,"remove":true}}`,identity))
    testing.expect_value(t,result.code,0)
    result=authoring_test_execute(f,"key",fmt.tprintf(`{{"asset":"%s","clip":"walk","target":"pulse","property":"Float","time":0.5,"key":{{"value":[3,0,0,0]}}}}`,identity))
    testing.expect_value(t,result.code,0)
    result=authoring_test_execute(f,"key",fmt.tprintf(`{{"asset":"%s","clip":"walk","target":"pulse","property":"Float","time":0.5,"key":{{"value":[4,0,0,0]}}}}`,identity))
    testing.expect_value(t,result.code,0)
    result=authoring_test_execute(f,"key",fmt.tprintf(`{{"asset":"%s","clip":"walk","target":"pulse","property":"Float","time":0.5,"remove":true}}`,identity))
    testing.expect_value(t,result.code,0)
    result=authoring_test_execute(f,"clip",fmt.tprintf(`{{"asset":"%s","clip":"walk","name":"stride","root":{{"bone":"root","translation":true,"rotation":false}}}}`,identity))
    testing.expect_value(t,result.code,0)
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s","clip":"stride","target":"pulse","property":"Float"}}`,identity))
    testing.expect_value(t,result.code,0)
    text:=string(serial.writer_bytes(&f.out));testing.expect(t,strings.contains(text,`"keys_total":3`) && strings.contains(text,`"interpolation": "Cubic_Spline"`))
    file:asset.Asset
    testing.expect_value(t,authoring_test_load(f,"clip.anim",&file),asset.Error.None);defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None);testing.expect_value(t,file.blob.header.id,id)
    testing.expect_value(t,len(view.markers),1);testing.expect(t,view.clips[0].root.translation)
    result=authoring_test_execute(f,"track",fmt.tprintf(`{{"asset":"%s","clip":"stride","target":"pulse","property":"Float","remove":true}}`,identity))
    testing.expect_value(t,result.code,0)
    // The clip exists only in memory, unsaved, until it is saved.
    disk:=fmt.tprintf("%s/clip.anim",f.root)
    testing.expect(t,!os.exists(disk) && editor.asset_unsaved(&f.session,id))
    saved,written:=editor.assets_save_all(&f.session)
    testing.expect(t,written && saved==1 && os.exists(disk) && !editor.asset_unsaved(&f.session,id))
    kept:=authoring_test_revision(f,"clip.anim")
    result=authoring_test_execute(f,"marker",fmt.tprintf(`{{"asset":"%s","clip":"stride","name":"lift","time":0.25}}`,identity))
    testing.expect_value(t,result.code,0)
    testing.expect(t,authoring_test_revision(f,"clip.anim")!=kept && editor.asset_unsaved(&f.session,id))
    testing.expect_value(t,editor.assets_discard(&f.session,editor.assets_unsaved_paths(&f.session)),1)
    testing.expect_value(t,authoring_test_revision(f,"clip.anim"),kept)
}

@(test)
pose_profile_authoring_edits_typed_rows_independently_and_rejects_invalid_values :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"profile") {return};defer authoring_test_destroy(f)
    defaults:=Profile_Set_Params{look=anim.LOOK_CONSTRAINT_DEFAULT,limit=anim.ROTATION_CONSTRAINT_DEFAULT};profile_constraints_defaults(&defaults)
    authoring_test_register(f,t,"create",Authoring_Create_Params,authoring_profile_create)
    authoring_test_register(f,t,"set",Profile_Set_Params,authoring_profile_set,&defaults)
    inspect:=Profile_Inspect_Params{limit=16}
    authoring_test_register(f,t,"inspect",Profile_Inspect_Params,authoring_profile_inspect,&inspect)
    if !testing.expect_value(t,authoring_test_execute(f,"create",`{"path":"rig.pose"}`).code,0) {return}
    id:=authoring_test_id(f,"rig.pose");identity:=authoring_test_id_text(id)
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","table":"Look","look":{{"bone":{{"path":"head"}},"target":{{"position":[0,0,0]}},"forward":[0,0,-1],"max_angle":1.5,"weight":0.8,"enabled":true}}}}`,identity))
    testing.expect(t,result.code==0,result.message)
    revision:=authoring_test_revision(f,"rig.pose")
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","table":"Look"}}`,identity))
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect_value(t,authoring_test_revision(f,"rig.pose"),revision)
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","table":"Look","look":{{"bone":{{"path":"head"}},"target":{{"position":[0,0,0]}},"forward":[0,0,-1],"max_angle":1.5,"weight":-1,"enabled":true}}}}`,identity))
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect_value(t,authoring_test_revision(f,"rig.pose"),revision)
    result=authoring_test_execute(f,"inspect",fmt.tprintf(`{{"asset":"%s","table":"Look"}}`,identity))
    testing.expect_value(t,result.code,0);testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"weight": 0.8`))
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","table":"Look","look":{{"bone":{{"path":"head"}},"target":{{"position":[0,0,0]}},"forward":[0,0,-1],"max_angle":1.5,"weight":0.8,"enabled":true}},"remove":true}}`,identity))
    testing.expect_value(t,result.code,0);testing.expect_value(t,authoring_test_id(f,"rig.pose"),id)
}

@(test)
curve_poses_are_made_from_the_frames_of_a_clip_and_replace_those_of_their_curves :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"poses") {return};defer authoring_test_destroy(f)
    authoring_test_register(f,t,"skeleton",Skeleton_Create_Params,authoring_skeleton_create)
    authoring_test_register(f,t,"clip",Clip_Create_Params,authoring_clip_create)
    authoring_test_register(f,t,"track",Track_Set_Params,authoring_track_set)
    authoring_test_register(f,t,"marker",Marker_Set_Params,authoring_marker_set)
    authoring_test_register(f,t,"profile",Authoring_Create_Params,authoring_profile_create)
    poses:=Profile_Poses_Params{tolerance=PROFILE_POSES_TOLERANCE}
    authoring_test_register(f,t,"poses",Profile_Poses_Params,authoring_profile_poses,&poses)
    json:=`{"path":"face.skeleton","bones":[{"name":"root","path":"root","position":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1]},{"name":"jaw","path":"root/jaw","parent":"root","position":[0,1,0],"rotation":[0,0,0,1],"scale":[1,1,1]}]}`
    if !testing.expect_value(t,authoring_test_execute(f,"skeleton",json).code,0) {return}
    if !testing.expect_value(t,authoring_test_execute(f,"clip",`{"path":"poses.anim","name":"poses"}`).code,0) {return}
    if !testing.expect_value(t,authoring_test_execute(f,"profile",`{"path":"face.pose"}`).code,0) {return}
    clip:=authoring_test_id_text(authoring_test_id(f,"poses.anim"))
    skeleton:=authoring_test_id_text(authoring_test_id(f,"face.skeleton"))
    profile:=authoring_test_id_text(authoring_test_id(f,"face.pose"))
    // Frame 0 at rest, frame 1 the jaw open, frame 2 at rest again.
    open:=mm.quat_axis_angle({1,0,0},.5)
    json=fmt.tprintf(`{{"asset":"%s","clip":"poses","target":"root/jaw","property":"Rotation","keys":[{{"time":0,"value":[0,0,0,1],"interpolation":"Step"}},{{"time":1,"value":[%v,%v,%v,%v],"interpolation":"Step"}},{{"time":2,"value":[0,0,0,1],"interpolation":"Step"}}]}}`,clip,open.x,open.y,open.z,open.w)
    if !testing.expect_value(t,authoring_test_execute(f,"track",json).code,0) {return}
    json=fmt.tprintf(`{{"asset":"%s","animation":"%s","clip":"poses","skeleton":"%s","poses":[{{"time":1,"curve":"jaw_open"}},{{"time":2,"curve":"rest"}}]}}`,profile,clip,skeleton)
    result:=authoring_test_execute(f,"poses",json)
    if !testing.expect(t,result.code==0,result.message) {return}
    testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"poses":1,"rows":1,"still":1`),string(serial.writer_bytes(&f.out)))
    // Again: the rows of its curves are replaced, not added.
    if !testing.expect_value(t,authoring_test_execute(f,"poses",json).code,0) {return}
    file:asset.Asset;testing.expect_value(t,authoring_test_load(f,"face.pose",&file),asset.Error.None)
    view,error:=anim.pose_profile_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None)
    if testing.expect_value(t,len(view.curve_poses),1) {
        row:=view.curve_poses[0]
        testing.expect(t,base.text_get(row.curve[:])=="jaw_open" && base.text_get(row.bone.path[:])=="root/jaw" && mm.quat_angle(row.delta.rotation,open)<1e-4 && row.weight==1 && row.enabled)
    }
    asset.asset_close(&file)
    // Full: the row keeps the frame of the bone.
    json=fmt.tprintf(`{{"asset":"%s","animation":"%s","clip":"poses","skeleton":"%s","full":true,"poses":[{{"time":1,"curve":"jaw_open"}}]}}`,profile,clip,skeleton)
    if !testing.expect_value(t,authoring_test_execute(f,"poses",json).code,0) {return}
    testing.expect_value(t,authoring_test_load(f,"face.pose",&file),asset.Error.None)
    view,error=anim.pose_profile_view(&file,&f.assets.types)
    testing.expect(t,error==.None && len(view.curve_poses)==1 && view.curve_poses[0].full && mm.quat_angle(view.curve_poses[0].delta.rotation,open)<1e-4 && view.curve_poses[0].delta.position==mm.Vec3{0,1,0})
    asset.asset_close(&file)
    // Without a list the markers are the poses, and the Float curves at their frames the drives they bring.
    json=fmt.tprintf(`{{"asset":"%s","clip":"poses","name":"jaw_open","time":1}}`,clip)
    if !testing.expect_value(t,authoring_test_execute(f,"marker",json).code,0) {return}
    json=fmt.tprintf(`{{"asset":"%s","clip":"poses","target":"jawOpen","property":"Float","keys":[{{"time":0,"value":[0,0,0,0],"interpolation":"Step"}},{{"time":1,"value":[0.8,0,0,0],"interpolation":"Step"}},{{"time":2,"value":[0,0,0,0],"interpolation":"Step"}}]}}`,clip)
    if !testing.expect_value(t,authoring_test_execute(f,"track",json).code,0) {return}
    json=fmt.tprintf(`{{"asset":"%s","animation":"%s","clip":"poses","skeleton":"%s"}}`,profile,clip,skeleton)
    result=authoring_test_execute(f,"poses",json)
    if !testing.expect(t,result.code==0,result.message) {return}
    testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"poses":1,"rows":1,"still":0,"drives":1`),string(serial.writer_bytes(&f.out)))
    testing.expect_value(t,authoring_test_load(f,"face.pose",&file),asset.Error.None)
    view,error=anim.pose_profile_view(&file,&f.assets.types)
    if testing.expect(t,error==.None && len(view.curve_poses)==1 && len(view.curve_drives)==1) {
        drive:=view.curve_drives[0]
        testing.expect(t,base.text_get(drive.from[:])=="jaw_open" && base.text_get(drive.to[:])=="jawOpen" && abs(drive.scale-.8)<1e-5 && !view.curve_poses[0].full)
    }
    asset.asset_close(&file)
    revision:=authoring_test_revision(f,"face.pose")
    for bad in ([3]string{
        fmt.tprintf(`{{"asset":"%s","animation":"%s","skeleton":"%s","poses":[{{"time":1,"curve":"a"}},{{"time":2,"curve":"a"}}]}}`,profile,clip,skeleton),
        fmt.tprintf(`{{"asset":"%s","animation":"%s","skeleton":"%s","poses":[{{"time":9,"curve":"a"}}]}}`,profile,clip,skeleton),
        fmt.tprintf(`{{"asset":"%s","animation":"%s","skeleton":"%s","base":9}}`,profile,clip,skeleton),
    }) {
        testing.expect(t,authoring_test_execute(f,"poses",bad).code!=0,bad)
    }
    testing.expect_value(t,authoring_test_revision(f,"face.pose"),revision)
}

@(test)
retarget_bake_api_publishes_a_new_valid_clip_and_keeps_its_sources :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"bake") {return};defer authoring_test_destroy(f)
    authoring_test_register(f,t,"skeleton",Skeleton_Create_Params,authoring_skeleton_create)
    authoring_test_register(f,t,"clip",Clip_Create_Params,authoring_clip_create)
    authoring_test_register(f,t,"profile",Authoring_Create_Params,authoring_profile_create)
    profile:=Profile_Set_Params{retarget=anim.RETARGET_MAPPING_DEFAULT};profile_constraints_defaults(&profile)
    bake:=Retarget_Bake_Params{rate=30}
    authoring_test_register(f,t,"track",Track_Set_Params,authoring_track_set)
    authoring_test_register(f,t,"mapping",Profile_Set_Params,authoring_profile_set,&profile)
    authoring_test_register(f,t,"bake",Retarget_Bake_Params,authoring_retarget_bake,&bake)
    for name in ([2]string{"source","destination"}) {
        json:=fmt.tprintf(`{{"path":"%s.skeleton","bones":[{{"name":"root","path":"root","position":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1]}}]}}`,name)
        if !testing.expect_value(t,authoring_test_execute(f,"skeleton",json).code,0) {return}
    }
    if !testing.expect_value(t,authoring_test_execute(f,"clip",`{"path":"source.anim","name":"walk"}`).code,0) {return}
    if !testing.expect_value(t,authoring_test_execute(f,"profile",`{"path":"mapping.pose"}`).code,0) {return}
    clip:=authoring_test_id_text(authoring_test_id(f,"source.anim"))
    source:=authoring_test_id_text(authoring_test_id(f,"source.skeleton"))
    destination:=authoring_test_id_text(authoring_test_id(f,"destination.skeleton"))
    mapping:=authoring_test_id_text(authoring_test_id(f,"mapping.pose"))
    json:=fmt.tprintf(`{{"asset":"%s","clip":"walk","target":"root","property":"Position","keys":[{{"time":0,"value":[0,0,0,0]}},{{"time":1,"value":[1,0,0,0]}}]}}`,clip)
    if !testing.expect_value(t,authoring_test_execute(f,"track",json).code,0) {return}
    json=fmt.tprintf(`{{"asset":"%s","table":"Retarget","retarget":{{"source_bone":{{"path":""}},"target_bone":{{"path":""}},"mode":"Paths","translation":"Scaled","enabled":true}}}}`,mapping)
    if !testing.expect_value(t,authoring_test_execute(f,"mapping",json).code,0) {return}
    revision:=authoring_test_revision(f,"source.anim")
    json=fmt.tprintf(`{{"animation":"%s","source_skeleton":"%s","target_skeleton":"%s","profile":"%s","path":"baked.anim"}}`,clip,source,destination,mapping)
    if !testing.expect_value(t,authoring_test_execute(f,"bake",json).code,0) {return}
    testing.expect_value(t,authoring_test_revision(f,"source.anim"),revision)
    output_id:=authoring_test_id(f,"baked.anim");testing.expect(t,output_id!={} && output_id!=authoring_test_id(f,"source.anim"))
    file:asset.Asset;testing.expect_value(t,authoring_test_load(f,"baked.anim",&file),asset.Error.None);defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect_value(t,len(view.tracks),3);testing.expect_value(t,view.tracks[0].key_count,u32(31))
    testing.expect_value(t,view.keys[view.tracks[0].first_key+30].value.x,f32(1))
}

@(test)
timeline_key_pages_fit_api_scratch_and_refuse_oversized_arrays :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"capacity") {return};defer authoring_test_destroy(f)
    authoring_test_register(f,t,"create",Clip_Create_Params,authoring_clip_create)
    defaults:=Track_Set_Params{}
    inspect:=Track_Inspect_Params{limit=512}
    authoring_test_register(f,t,"track",Track_Set_Params,authoring_track_set,&defaults)
    authoring_test_register(f,t,"inspect",Track_Inspect_Params,authoring_track_inspect,&inspect)
    if !testing.expect_value(t,authoring_test_execute(f,"create",`{"path":"capacity.anim","name":"curve"}`).code,0) {return}
    id:=authoring_test_id_text(authoring_test_id(f,"capacity.anim"))
    request:serial.Writer;serial.writer_init(&request);defer serial.writer_destroy(&request)
    serial.text_write_raw(&request,fmt.tprintf(`{{"asset":"%s","clip":"curve","target":"pulse","property":"Float","keys":[`,id))
    for i in 0..<AUTHORING_KEYS {
        if i>0 {serial.text_write_raw(&request,",")}
        serial.text_write_raw(&request,fmt.tprintf(`{{"time":%d,"value":[%d,0,0,0]}}`,i,i))
    }
    end:=request.count
    serial.text_write_raw(&request,"]}")
    if !testing.expect_value(t,authoring_test_execute(f,"track",string(serial.writer_bytes(&request))).code,0) {return}
    revision:=authoring_test_revision(f,"capacity.anim")
    json:=fmt.tprintf(`{{"asset":"%s","clip":"curve","target":"pulse","property":"Float"}}`,id)
    testing.expect_value(t,authoring_test_execute(f,"inspect",json).code,0)
    testing.expect(t,api.json_valid(context.temp_allocator,string(serial.writer_bytes(&f.out))))
    testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"keys_total":512`))
    request.count=end
    serial.text_write_raw(&request,`,{"time":512,"value":[512,0,0,0]}]}`)
    testing.expect_value(t,authoring_test_execute(f,"track",string(serial.writer_bytes(&request))).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_revision(f,"capacity.anim"),revision)
}

@(test)
clip_authoring_appends_to_existing_assets_and_preserves_clips :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"append-clip") {return};defer authoring_test_destroy(f)
    authoring_test_register(f,t,"create",Clip_Create_Params,authoring_clip_create)
    if !testing.expect_value(t,authoring_test_execute(f,"create",`{"path":"library.anim","name":"idle"}`).code,0) {return}
    id:=authoring_test_id(f,"library.anim")
    revision:=authoring_test_revision(f,"library.anim")
    json:=`{"path":"library.anim","name":"walk"}`
    if !testing.expect_value(t,authoring_test_execute(f,"create",json).code,0) {return}
    changed:=authoring_test_revision(f,"library.anim")
    testing.expect(t,changed!=revision && authoring_test_id(f,"library.anim")==id)
    file:asset.Asset
    testing.expect_value(t,authoring_test_load(f,"library.anim",&file),asset.Error.None);defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&f.assets.types)
    testing.expect_value(t,error,asset.Error.None);testing.expect_value(t,len(view.clips),2)
    testing.expect(t,base.text_get(view.clips[0].name[:])=="idle" && base.text_get(view.clips[1].name[:])=="walk")
    testing.expect_value(t,authoring_test_execute(f,"create",json).code,api.INVALID_PARAMS)
    testing.expect_value(t,authoring_test_revision(f,"library.anim"),changed)
    testing.expect_value(t,authoring_test_execute(f,"create",`{"name":"run"}`).code,api.INVALID_PARAMS)
}
