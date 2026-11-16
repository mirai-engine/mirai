package animation_editor

import "core:fmt"
import cmath "core:math"
import "core:strings"
import "core:testing"
import aa "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// The figure with its body, and a clip that sways the pelvis with noise
// while the root travels forward, with a marker at half its second.
clip_test_assets :: proc(f:^Authoring_Test,t:^testing.T) -> (animation,skeleton:base.Asset_Id) {
    animation,skeleton=base.Asset_Id{812,1},base.Asset_Id{812,2}
    bones:=body_test_figure()
    map_,_:=aa.skeleton_body_detect(bones,lib.body_map_empty())
    body:aa.Skeleton_Body
    rows:[len(lib.Body_Part)]aa.Skeleton_Body_Part
    count,_:=aa.skeleton_body_rows(bones,map_,&body,&rows)
    testing.expect_value(t,aa.skeleton_save(fmt.tprintf("%s/figure.skeleton",f.root),&f.assets.types,{id=skeleton,bones=bones,body=&body,body_parts=rows[:count]}),aa.Error.None)
    frames:=61
    root,pelvis,hand:=make([]lib.Keyframe,frames,context.temp_allocator),make([]lib.Keyframe,frames,context.temp_allocator),make([]lib.Keyframe,frames,context.temp_allocator)
    state:=u64(7)
    for i in 0..<frames {
        time:=f32(i)/60
        state=state*6364136223846793005+1442695040888963407
        noise:=f32(state>>40)/f32(1<<24)*.02-.01
        root[i]={time=time,value={0,0,time,0}}
        pelvis[i]={time=time,value={noise,1+.02*cmath.sin(time*mm.TAU*2),0,0}}
        turn:=mm.quat_axis_angle({0,0,1},.4*cmath.sin(time*mm.TAU))
        hand[i]={time=time,value=lib.quat_vec4(turn)}
    }
    clip:=aa.Animation_Clip_Desc{name="sway",tracks={
        {target="root",property=.Position,keys=root},
        {target="root/pelvis",property=.Position,keys=pelvis},
        {target="root/pelvis/spine_01/clavicle_r/upperarm_r",property=.Rotation,keys=hand},
    },markers={{time=.5,name="step"}},root={translation=true}}
    base.text_set(clip.root.bone[:],"root")
    testing.expect_value(t,aa.animation_save(fmt.tprintf("%s/sway.anim",f.root),&f.assets.types,{id=animation,clips={clip}}),aa.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    return
}

clip_test_number :: proc(text,object,field:string) -> f32 {
    value:=api.json_member(text,object)
    if field!="" {value=api.json_member(value,field)}
    number,_:=strconv_f32(value)
    return number
}
strconv_f32 :: proc(text:string) -> (f32,bool) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    bits,ok:=serial.text_read_float(&r,4)
    return transmute(f32)u32(bits),ok
}

@(test)
clip_edit_retimes_smooths_and_loops_into_a_new_clip_with_metrics_before_and_after :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"clip-edit") {return};defer authoring_test_destroy(f)
    animation,skeleton:=clip_test_assets(f,t)
    defaults:=Clip_Edit_Params{rate=60}
    analyze:=Analyze_Params{rate=60,contacts=16}
    authoring_test_register(f,t,"edit",Clip_Edit_Params,clip_edit,&defaults)
    authoring_test_register(f,t,"analyze",Analyze_Params,clip_analyze,&analyze)
    ids:=fmt.tprintf(`"asset":"%s","skeleton":"%s"`,authoring_test_id_text(animation),authoring_test_id_text(skeleton))

    result:=authoring_test_execute(f,"analyze",fmt.tprintf(`{{%s,"clip":"sway"}}`,ids))
    if !testing.expect(t,result.code==0,result.message) {return}
    text:=strings.clone(api.json_compact(string(serial.writer_bytes(&f.out))),context.temp_allocator)
    testing.expect_value(t,result_shape_mismatch(Metrics_Result,text),"")
    testing.expect(t,strings.contains(text,`"root":"root"`) && strings.contains(text,`"in_place":false`))
    testing.expectf(t,abs(clip_test_number(text,"speed","")-1)<.01,"speed in %s",text)
    jerk:=clip_test_number(text,"jerk","mean")

    before:=authoring_test_revision(f,"sway.anim")
    request:=fmt.tprintf(`{{%s,"clip":"sway","name":"slow sway","edits":[{{"verb":"Retime","duration":2}},{{"verb":"Smooth","amount":0.4}},{{"verb":"Make_Loop"}}]}}`,ids)
    result=authoring_test_execute(f,"edit",strings.concatenate({request[:len(request)-1],`,"dry_run":true}`},context.temp_allocator))
    if !testing.expect(t,result.code==0,result.message) {return}
    testing.expect_value(t,authoring_test_revision(f,"sway.anim"),before)
    result=authoring_test_execute(f,"edit",request)
    if !testing.expect(t,result.code==0,result.message) {return}
    text=strings.clone(api.json_compact(string(serial.writer_bytes(&f.out))),context.temp_allocator)
    testing.expect_value(t,result_shape_mismatch(Clip_Edit_Result,text),"")
    after:=api.json_member(text,"after")
    testing.expectf(t,abs(clip_test_number(after,"duration","")-2)<1e-3,"after %s",after)
    testing.expectf(t,abs(clip_test_number(after,"speed","")-.5)<.02,"after %s",after)
    testing.expectf(t,clip_test_number(after,"jerk","mean")<jerk/4,"jerk %v to %s",jerk,after)
    testing.expect(t,strings.contains(after,`"loop":true`))

    file:aa.Asset
    if !testing.expect_value(t,authoring_test_load(f,"sway.anim",&file),aa.Error.None) {return}
    defer aa.asset_close(&file)
    view,error:=aa.animation_view(&file,&f.assets.types)
    if !testing.expect(t,error==.None && len(view.clips)==2) {return}
    edited:=view.clips[1]
    testing.expect_value(t,base.text_get(edited.name[:]),"slow sway")
    testing.expect(t,edited.marker_count==1 && abs(view.markers[edited.first_marker].time-1)<.02)
    testing.expect(t,edited.root.translation && base.text_get(edited.root.bone[:])=="root")

    // A skeleton that stores no body has one found for the call: an Offset of a part works.
    plain:=base.Asset_Id{812,3}
    testing.expect_value(t,aa.skeleton_save(fmt.tprintf("%s/plain.skeleton",f.root),&f.assets.types,{id=plain,bones=body_test_figure()}),aa.Error.None)
    result=authoring_test_execute(f,"edit",fmt.tprintf(`{{"asset":"%s","skeleton":"%s","path":"found.anim","edits":[{{"verb":"Offset","part":"Head","direction":"Forward","strength":"Medium"}}]}}`,authoring_test_id_text(animation),authoring_test_id_text(plain)))
    testing.expectf(t,result.code==0,"%s %s",result.message,result.data)

    // What a step needs, and what is not there, says so.
    result=authoring_test_execute(f,"edit",fmt.tprintf(`{{%s,"edits":[{{"verb":"Offset","part":"Head"}}]}}`,ids))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"edits[0].direction"`) && strings.contains(result.data,`"fix":`))
    result=authoring_test_execute(f,"edit",fmt.tprintf(`{{%s,"edits":[{{"verb":"Wiggle"}}]}}`,ids))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.message,"is not one of its names"))
    result=authoring_test_execute(f,"edit",fmt.tprintf(`{{%s,"edits":[{{"verb":"Retime","factor":2,"duration":1}}]}}`,ids))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"edits[0]"`))
    result=authoring_test_execute(f,"edit",request)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Already_Exists"`))
    result=authoring_test_execute(f,"edit",fmt.tprintf(`{{%s,"path":"mirror.anim","edits":[{{"verb":"Mirror"}},{{"verb":"Offset","part":"Spine","direction":"Forward","strength":"Medium","range":[0.2,0.8]}}]}}`,ids))
    testing.expect(t,result.code==0,result.data)
    testing.expect(t,authoring_test_exists(f,"mirror.anim"))

    // Without edits the clip is copied with its keys, here into the .anim just made (whose clip
    // kept its name), which moves the same skeleton: a library of clips picked from another.
    copy_request:=fmt.tprintf(`{{%s,"clip":"sway","path":"mirror.anim","name":"plain","edits":[]}}`,ids)
    result=authoring_test_execute(f,"edit",copy_request)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    picked:aa.Asset
    if testing.expect_value(t,authoring_test_load(f,"mirror.anim",&picked),aa.Error.None) {
        library,library_error:=aa.animation_view(&picked,&f.assets.types)
        source:=view.clips[0]
        if testing.expect(t,library_error==.None && len(library.clips)==2) {
            copied:=library.clips[1]
            testing.expect(t,base.text_get(library.clips[0].name[:])=="sway" && base.text_get(copied.name[:])=="plain")
            testing.expect(t,copied.track_count==source.track_count && copied.marker_count==source.marker_count && copied.root==source.root)
            for track,i in library.tracks[copied.first_track:][:copied.track_count] {
                original:=view.tracks[source.first_track+u32(i)]
                testing.expect(t,track.target==original.target && track.key_count==original.key_count && view.keys[original.first_key]==library.keys[track.first_key])
            }
        }
        aa.asset_close(&picked)
    }
    result=authoring_test_execute(f,"edit",copy_request)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Already_Exists"`))
    result=authoring_test_execute(f,"edit",strings.concatenate({copy_request[:len(copy_request)-1],`,"replace":true,"edits":[{"verb":"Face_Rest"}]}`},context.temp_allocator))
    testing.expectf(t,result.code==0,"%s %s",result.message,result.data)
    // Another skeleton's library, or another kind of asset, does not take it.
    turn:=[2]lib.Keyframe{{time=0,value=lib.quat_vec4(1)},{time=1,value=lib.quat_vec4(1)}}
    testing.expect_value(t,aa.animation_save(fmt.tprintf("%s/other.anim",f.root),&f.assets.types,{id={812,3},clips={{name="nod",tracks={{target="neck",property=.Rotation,keys=turn[:]}}}}}),aa.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    result=authoring_test_execute(f,"edit",fmt.tprintf(`{{%s,"clip":"sway","path":"other.anim"}}`,ids))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Other_Skeleton"`) && strings.contains(result.data,`"actual":"neck"`))
    result=authoring_test_execute(f,"edit",fmt.tprintf(`{{%s,"clip":"sway","path":"figure.skeleton"}}`,ids))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Invalid_Asset"`))
}
