package animation_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import aa "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/serial"

// A standing figure with Unreal names, facing -Z with its left at -X.
body_test_figure :: proc() -> []aa.Skeleton_Bone {
    Row :: struct {name:string,parent:i32,at:[3]f32}
    rows:=[?]Row{
        {"root",-1,{}},{"pelvis",0,{0,1,0}},{"spine_01",1,{0,1.2,0}},{"neck_01",2,{0,1.5,0}},{"head",3,{0,1.6,0}},
        {"clavicle_l",2,{-.05,1.45,0}},{"upperarm_l",5,{-.2,1.45,0}},{"lowerarm_l",6,{-.45,1.45,.02}},{"hand_l",7,{-.7,1.45,0}},
        {"clavicle_r",2,{.05,1.45,0}},{"upperarm_r",9,{.2,1.45,0}},{"lowerarm_r",10,{.45,1.45,.02}},{"hand_r",11,{.7,1.45,0}},
        {"thigh_l",1,{-.1,.95,0}},{"calf_l",13,{-.1,.5,-.02}},{"foot_l",14,{-.1,.08,0}},{"ball_l",15,{-.1,.02,-.12}},
        {"thigh_r",1,{.1,.95,0}},{"calf_r",17,{.1,.5,-.02}},{"foot_r",18,{.1,.08,0}},{"ball_r",19,{.1,.02,-.12}},
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

body_test_skeleton :: proc(f:^Authoring_Test,t:^testing.T) -> base.Asset_Id {
    id:=base.Asset_Id{811,1}
    testing.expect_value(t,aa.skeleton_save(fmt.tprintf("%s/figure.skeleton",f.root),&f.assets.types,{id=id,bones=body_test_figure()}),aa.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    return id
}

body_test_view :: proc(f:^Authoring_Test,t:^testing.T) -> (map_:lib.Body_Map,bones:[]aa.Skeleton_Bone) {
    file:aa.Asset
    if !testing.expect_value(t,authoring_test_load(f,"figure.skeleton",&file),aa.Error.None) {return}
    defer aa.asset_close(&file)
    view,error:=aa.skeleton_view(&file,&f.assets.types)
    if !testing.expect_value(t,error,aa.Error.None) {return}
    bones=make([]aa.Skeleton_Bone,len(view.bones),context.temp_allocator);copy(bones,view.bones)
    return aa.skeleton_body_map(bones,view.body,view.body_parts),bones
}

@(test)
skeleton_body_detect_saves_the_parts_and_set_corrects_them_by_name :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"body") {return};defer authoring_test_destroy(f)
    identity:=authoring_test_id_text(body_test_skeleton(f,t))
    detect:=Body_Detect_Params{keep_manual=true}
    set:=Body_Set_Params{}
    authoring_test_register(f,t,"detect",Body_Detect_Params,body_detect,&detect)
    authoring_test_register(f,t,"set",Body_Set_Params,body_set,&set)

    before:=authoring_test_revision(f,"figure.skeleton")
    result:=authoring_test_execute(f,"detect",fmt.tprintf(`{{"asset":"%s","dry_run":true}}`,identity))
    if !testing.expect(t,result.code==0,result.message) {return}
    text:=string(serial.writer_bytes(&f.out))
    testing.expect(t,strings.contains(text,`"part":"Hand_L","bone":"root/pelvis/spine_01/clavicle_l/upperarm_l/lowerarm_l/hand_l"`))
    testing.expect(t,strings.contains(text,`"unassigned_total":1`) && strings.contains(text,`"root/ik_hand_root"`) && strings.contains(text,`"missing":[]`))
    testing.expect_value(t,authoring_test_revision(f,"figure.skeleton"),before)

    result=authoring_test_execute(f,"detect",fmt.tprintf(`{{"asset":"%s"}}`,identity))
    if !testing.expect(t,result.code==0,result.message) {return}
    testing.expect_value(t,result_shape_mismatch(Body_Result,string(serial.writer_bytes(&f.out))),"")
    map_,bones:=body_test_view(f,t)
    if bones==nil {return}
    testing.expect(t,map_.bones[.Pelvis]==1 && map_.bones[.Toe_R]==20 && map_.manual=={})

    // By unique name; another part on that bone gives it up.
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","parts":[{{"part":"Hand_L","bone":"lowerarm_l"}},{{"part":"Toe_R"}}]}}`,identity))
    if !testing.expect(t,result.code==0,result.message) {return}
    map_,bones=body_test_view(f,t)
    testing.expect(t,map_.bones[.Hand_L]==7 && map_.bones[.Elbow_L]==-1 && map_.bones[.Toe_R]==-1 && map_.manual=={.Hand_L,.Toe_R})
    testing.expect(t,strings.contains(string(serial.writer_bytes(&f.out)),`"missing":["Elbow_L","Toe_R"]`))

    // Detecting again keeps what a person set.
    result=authoring_test_execute(f,"detect",fmt.tprintf(`{{"asset":"%s"}}`,identity))
    map_,bones=body_test_view(f,t)
    testing.expect(t,map_.bones[.Hand_L]==7 && map_.bones[.Toe_R]==-1 && map_.bones[.Elbow_L]==-1)
    result=authoring_test_execute(f,"detect",fmt.tprintf(`{{"asset":"%s","keep_manual":false}}`,identity))
    map_,bones=body_test_view(f,t)
    testing.expect(t,map_.bones[.Hand_L]==8 && map_.bones[.Toe_R]==20 && map_.manual=={})

    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","parts":[{{"part":"Head","bone":"skull"}}]}}`,identity))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"parts[0].bone"`) && strings.contains(result.data,`"code":"Missing_Bone"`) && strings.contains(result.data,`root/pelvis/spine_01/neck_01/head`))
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","parts":[{{"part":"Tail","bone":"head"}}]}}`,identity))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.message,"Hand_L"))
    result=authoring_test_execute(f,"set",fmt.tprintf(`{{"asset":"%s","forward":[0,1,0],"up":[0,1,0]}}`,identity))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Invalid_Axes"`))
    f.session.mode=.Play
    result=authoring_test_execute(f,"detect",fmt.tprintf(`{{"asset":"%s"}}`,identity))
    testing.expect(t,result.code!=0 && strings.contains(result.data,`"fix":"Stop Play`))
    result=authoring_test_execute(f,"detect",fmt.tprintf(`{{"asset":"%s","dry_run":true}}`,identity))
    testing.expect_value(t,result.code,0)
    testing.expect(t,authoring_test_exists(f,"figure.skeleton"))
}
