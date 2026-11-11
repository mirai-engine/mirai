package animation_editor

import "core:fmt"
import cmath "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Test_Locomotion_Mode :: distinct u16

// The modes of the physics plugin, as the World of a project with it names them.
test_locomotion_modes :: proc(info:^core.World_Info) {
    types:=make([]core.Named_Type_Info,1,context.temp_allocator);names:=make([]core.Name_Info,4,context.temp_allocator)
    types[0]={type=Test_Locomotion_Mode,name="Locomotion_Mode",path="plugins:physics/runtime",prefix="MODE_",limit=1<<16}
    for name,i in ([4]string{"FALLING","WALKING","FLYING","SWIMMING"}) {names[i]={type=Test_Locomotion_Mode,value=i64(i),name=name}}
    info.named_types,info.names=types,names
    core.test_info_index(info)
}

@(test)
setup_classifies_clips_by_the_words_of_their_name :: proc(t:^testing.T) {
    cases:=[?]struct {name:string,class:Setup_Class,loop:bool}{
        {"Idle",.Walking,true},{"MM_Walk_Fwd",.Walking,true},{"JogStart",.Walking,false},{"Sprint_Turn_180",.Walking,false},{"running",.Walking,true},
        {"Fall_Loop",.Falling,true},{"InAir",.Falling,true},{"Jump_Loop",.Falling,true},{"Jump_Start",.Jumping,false},{"TakeOff",.Jumping,false},
        {"Jump",.Jumping,false},{"Land",.Landing,false},{"Jump_Land",.Landing,false},{"Swim_Idle",.Swimming,true},{"Fly",.Flying,true},
        {"Crouch_Idle",.Crouching,true},{"Crouch_NE",.Crouching,true},{"CrouchWalk_Fwd",.Crouching,true},{"Slide_Start",.Sliding,false},
        {"KneeSliding",.Sliding,true},{"Slide_Loop",.Sliding,true},
        {"Chair_Sit",.None,false},{"Stairs_Up",.None,false},{"Wave",.None,false},
    }
    for c in cases {
        class,loop:=setup_class(c.name)
        testing.expectf(t,class==c.class && (class==.None || loop==c.loop),"%s: %v loop %v",c.name,class,loop)
    }
}

// The figure with a skinned mesh and a library: idle sways in place, walk
// travels at 1.2 m/s and loops, wave turns an arm without moving.
setup_test_character :: proc(f:^Pose_Bake_Test,t:^testing.T) -> base.Asset_Id {
    a:=&f.authoring
    source_id,skeleton_id,mesh_id:=base.Asset_Id{840,1},base.Asset_Id{840,2},base.Asset_Id{840,3}
    bones:=body_test_figure()
    map_,_:=asset.skeleton_body_detect(bones,lib.body_map_empty())
    body:asset.Skeleton_Body
    rows:[len(lib.Body_Part)]asset.Skeleton_Body_Part
    count,_:=asset.skeleton_body_rows(bones,map_,&body,&rows)
    baton:asset.Skeleton_Socket;base.text_set(baton.name[:],"baton");base.text_set(baton.bone[:],"root/pelvis/spine_01/clavicle_r/upperarm_r/lowerarm_r/hand_r");baton.offset=mm.TRANSFORM_IDENTITY;baton.offset.position={0,.1,0}
    testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/figure.skeleton",a.root),&a.assets.types,{id=skeleton_id,bones=bones,sockets={baton},body=&body,body_parts=rows[:count]}),asset.Error.None)
    vertices:=[3]asset.Vertex{{position={0,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}}
    skin:[3]asset.Skin_Vertex;for &vertex in skin {vertex.weights[0]=255}
    testing.expect_value(t,source_mesh_save(fmt.tprintf("%s/figure.mesh",a.root),&a.assets.types,{id=mesh_id,skeleton=skeleton_id,joints={{node=0,inverse_bind=1}}},{vertices=vertices[:],skin=skin[:]},{0,1,2}),asset.Error.None)
    frames:=31
    idle,walk_root,walk_pelvis,wave:=make([]lib.Keyframe,frames,context.temp_allocator),make([]lib.Keyframe,frames,context.temp_allocator),make([]lib.Keyframe,frames,context.temp_allocator),make([]lib.Keyframe,frames,context.temp_allocator)
    for i in 0..<frames {
        time:=f32(i)/30
        idle[i]={time=time,value={0,1+.01*cmath.sin(time*mm.TAU),0,0}}
        walk_root[i]={time=time,value={0,0,1.2*time,0}}
        walk_pelvis[i]={time=time,value={0,1+.03*cmath.sin(time*mm.TAU*2),0,0}}
        wave[i]={time=time,value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},.8*cmath.sin(time*mm.TAU)))}
    }
    root:asset.Animation_Root;base.text_set(root.bone[:],"root");root.translation=true
    clips:=[3]asset.Animation_Clip_Desc{
        {name="Idle",tracks={{target="root/pelvis",property=.Position,keys=idle}}},
        {name="Walk",root=root,tracks={{target="root",property=.Position,keys=walk_root},{target="root/pelvis",property=.Position,keys=walk_pelvis}}},
        {name="Wave",tracks={{target="root/pelvis/spine_01/clavicle_r/upperarm_r",property=.Rotation,keys=wave}}},
    }
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/moves.anim",a.root),&a.assets.types,{id=source_id,clips=clips[:]}),asset.Error.None)
    testing.expect(t,host.assets_scan(&a.assets))
    core.add(&f.world.meshes,f.rig,erender.Mesh_Renderer{mesh=mesh_id})
    core.settle(&f.info,&f.world,nil)
    return source_id
}

@(test)
character_setup_builds_locomotion_look_feet_hands_and_gestures_from_the_body :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"setup") {return};defer pose_bake_test_destroy(f)
    library:=setup_test_character(f,t)
    a:=&f.authoring
    // What it played before: a clip and its rate.
    stale:=anim.ANIMATION_DEFAULT;stale.speed=.65;base.text_set(stale.clip[:],"Walk")
    core.add(&f.world.animations,f.rig,stale);core.settle(&f.info,&f.world,nil)
    defaults:=Setup_Params{want=SETUP_ALL}
    authoring_test_register(a,t,"setup",Setup_Params,setup,&defaults)
    request:=fmt.tprintf(`{{"entity":"0000000000000011","library":"%s","folder":"characters"}}`,authoring_test_id_text(library))
    // Matching follows the modes of the Character: a project without physics has none.
    result:=authoring_test_execute(a,"setup",request)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Missing_Plugin") && strings.contains(result.data,"physics") && !authoring_test_exists(a,"characters/figure.character"))
    test_locomotion_modes(&f.info)
    result=authoring_test_execute(a,"setup",strings.concatenate({request[:len(request)-1],`,"dry_run":true}`},context.temp_allocator))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    testing.expect(t,!authoring_test_exists(a,"characters/figure.character"))
    text:=string(serial_bytes(a))
    testing.expectf(t,strings.contains(text,`"clip":"Idle","mode":"WALKING","entry":false,"loop":true`) && strings.contains(text,`"clip":"Walk","mode":"WALKING"`) && strings.contains(text,`"gestures":["Wave"]`),"clips in %s",text)

    result=authoring_test_execute(a,"setup",request)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text=string(serial_bytes(a))
    for want in ([]string{"Locomotion","Look","Foot_Ik","Hand_Ik","Gestures"}) {testing.expectf(t,strings.contains(text,fmt.tprintf(`"want":"%s","status":"Ready"`,want)),"%s in %s",want,text)}
    testing.expectf(t,strings.contains(text,`"detail":"walking: Idle, Walk"`),"detail in %s",text)
    // One .character holds the locomotion, the gestures, the warping and the modifiers.
    animation,found:=core.get(core.read(&f.world.animations),f.rig)
    if !testing.expect(t,found) {return}
    testing.expect(t,animation.asset==authoring_test_id(a,"characters/figure.character") && animation.root_motion==.In_Place)
    testing.expect(t,base.text_get(animation.clip[:])=="" && animation.speed==1)
    file:asset.Asset
    if testing.expect_value(t,authoring_test_load(a,"characters/figure.character",&file),asset.Error.None) {
        set,error:=anim.character_view(&file,&a.assets.types)
        profile:=set.pose
        testing.expect(t,error==.None && set.info.animation==library && len(profile.look)==1 && len(profile.ik)==2 && profile.grounding.count==2)
        // The skeleton keeps its body: the set names its parts, not its bones, and its legs are
        // those of the body.
        testing.expect(t,base.text_get(profile.look[0].bone.path[:])=="@head" && !profile.look[0].enabled)
        testing.expect(t,base.text_get(profile.ik[0].end.path[:])=="@hand_l" && profile.grounding.legs[1].foot=={} && profile.grounding.body=={})
        actions:=set.actions
        testing.expect(t,len(actions.actions)==3 && len(actions.layers)==3)
        if len(actions.actions)==3 && len(actions.layers)==3 {
            testing.expect(t,base.text_get(actions.layers[0].over.path[:])=="@upper_body" && base.text_get(actions.layers[1].over.path[:])=="@arm_l" && base.text_get(actions.layers[2].over.path[:])=="@arm_r")
            for action,i in actions.actions {testing.expect(t,action.layer==actions.layers[i].name,"each gesture plays in the layer of its part of the body")}
        }
        // Idle and walk alone make a valid locomotion: rates cover the speeds between them.
        match:=set.match
        testing.expect(t,len(match.clips)==2)
        if len(match.clips)==2 {
            testing.expect(t,base.text_get(match.clips[0].clip[:])=="Idle" && match.clips[0].modes==1<<1 && match.clips[0].loop && !match.clips[0].entry)
            testing.expect(t,base.text_get(match.clips[1].clip[:])=="Walk" && match.clips[1].modes==1<<1)
        }
        asset.asset_close(&file)
    }

    result=authoring_test_execute(a,"setup",request)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Already_Exists") && strings.contains(result.data,"replace"))
    result=authoring_test_execute(a,"setup",strings.concatenate({request[:len(request)-1],`,"replace":true,"want":["Look"]}`},context.temp_allocator))
    testing.expectf(t,result.code==0,"%s %s",result.message,result.data)
    // What it plays already names its clips; a plain entity has no skeleton.
    result=authoring_test_execute(a,"setup",`{"entity":"0000000000000011","folder":"characters"}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Already_Exists"))
    plain:=core.create(&f.world.entities);core.add(&f.world.ids,plain,{value=19});core.settle(&f.info,&f.world,nil)
    result=authoring_test_execute(a,"setup",`{"entity":"0000000000000013"}`)
    testing.expect(t,result.code!=0 && strings.contains(result.data,"Missing_Skeleton"))
}

@(test)
character_setup_classifies_the_clips_it_is_given_at_their_speeds_and_fails_past_its_capacities :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"setup-clips") {return};defer pose_bake_test_destroy(f)
    library:=setup_test_character(f,t)
    a:=&f.authoring
    test_locomotion_modes(&f.info)
    defaults:=Setup_Params{want=SETUP_ALL}
    authoring_test_register(a,t,"setup",Setup_Params,setup,&defaults)
    ids:=fmt.tprintf(`"entity":"0000000000000011","library":"%s","folder":"characters"`,authoring_test_id_text(library))

    // Only the clips named are classified, at the speed told for them.
    result:=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"clips":["Idle","Walk"],"speeds":[{{"clip":"Walk","speed":2.5}}],"dry_run":true}}`,ids))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text:=string(serial_bytes(a))
    testing.expectf(t,strings.contains(text,`"clip":"Walk","mode":"WALKING","entry":false,"loop":true,"speed":2.5,"told":true`) && strings.contains(text,`"gestures":[]`),"clips in %s",text)
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"clips":["Idle","Run"]}}`,ids))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"clips[1]"`) && strings.contains(result.data,"Missing_Clip"))
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"speeds":[{{"clip":"Wave","speed":1}}]}}`,ids))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"speeds[0].clip"`) && strings.contains(result.data,"Not_Locomotion"))
    // A clip with rates of its own plays between them instead of those of the locomotion.
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"want":["Locomotion"],"speeds":[{{"clip":"Walk","speed":3}}],"rates":[{{"clip":"Walk","min_rate":0.5,"max_rate":1.5}}]}}`,ids))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text=string(serial_bytes(a))
    testing.expectf(t,strings.contains(text,`"speed":3,"told":true,"rates":[0.5,1.5]`),"rates in %s",text)
    match:asset.Asset
    if testing.expect_value(t,authoring_test_load(a,"characters/figure.character",&match),asset.Error.None) {
        set,error:=anim.character_view(&match,&a.assets.types);profile:=set.match
        testing.expect(t,error==.None && len(profile.clips)==2 && profile.clips[0].speed==0 && profile.clips[1].speed==3)
        if len(profile.clips)==2 {testing.expect(t,profile.clips[0].min_rate==0 && profile.clips[0].max_rate==0 && profile.clips[1].min_rate==.5 && profile.clips[1].max_rate==1.5)}
        asset.asset_close(&match)
    }

    // A blend of Idle and Walk takes their place in the locomotion, with its samples, and the rates
    // and the weight of the direction of the trajectory are written as given.
    blends:=`"blends":[{"clips":["Idle","Walk"],"samples":[{"weights":[1,0,0,0,0,0,0,0]},{"weights":[0.5,0.5,0,0,0,0,0,0],"speed":0.6},{"weights":[0,1,0,0,0,0,0,0]}],"min_rate":0.5,"max_rate":2}]`
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"want":["Locomotion"],"replace":true,%s,"min_rate":0.3,"max_rate":1.5,"trajectory_direction":0}}`,ids,blends))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text=string(serial_bytes(a))
    testing.expectf(t,strings.contains(text,`"locomotion":[],"blends":[{"clips":["Idle","Walk"],"mode":"WALKING","samples":3,"rates":[0.5,2]}]`),"blends in %s",text)
    if testing.expect_value(t,authoring_test_load(a,"characters/figure.character",&match),asset.Error.None) {
        set,error:=anim.character_view(&match,&a.assets.types);profile:=set.match
        ok:=error==.None && len(profile.clips)==1 && len(profile.samples)==3
        if testing.expectf(t,ok,"%v: %d clips, %d samples",error,len(profile.clips),len(profile.samples)) {
            source:=profile.clips[0]
            testing.expect(t,base.text_get(source.clip[:])=="Idle" && base.text_get(source.blend[0][:])=="Walk" && source.blend[1][0]==0 && source.loop && source.modes==1<<1 && source.min_rate==.5 && source.max_rate==2)
            testing.expect(t,profile.samples[1]==anim.Match_Sample{source=0,weights={0=.5,1=.5},speed=.6} && profile.samples[2].weights=={1=1})
            testing.expect(t,profile.info.min_rate==.3 && profile.info.max_rate==1.5 && profile.info.trajectory_direction==0)
        }
        asset.asset_close(&match)
    }
    // What a blend or the rates cannot be says what failed and how to fix it.
    Refused :: struct {params,path,code:string}
    for refused in ([?]Refused{
        {`"blends":[{"clips":["Idle","Wave"],"samples":[{"weights":[1,0,0,0,0,0,0,0]}]}]`,"blends[0].clips[1]","Not_Locomotion"},
        {`"blends":[{"clips":["Idle"],"samples":[{"weights":[1,0,0,0,0,0,0,0]}]}]`,"blends[0].clips","Blend_Size"},
        {`"blends":[{"clips":["Idle","Walk"],"samples":[{"weights":[0,0,0,0,0,0,0,0]}]}]`,"blends[0].samples[0].weights","Zero_Weights"},
        {`"blends":[{"clips":["Idle","Walk"],"samples":[{"weights":[1,0,1,0,0,0,0,0]}]}]`,"blends[0].samples[0].weights[2]","Extra_Weight"},
        {`"blends":[{"clips":["Idle","Walk"]}]`,"blends[0].samples","Required"},
        {`"min_rate":2,"max_rate":1`,"min_rate","Invalid_Rate"},
        {`"blends":[{"clips":["Idle","Walk"],"samples":[{"weights":[1,0,0,0,0,0,0,0]}],"min_rate":0.5}]`,"blends[0].min_rate","Invalid_Rate"},
        {`"rates":[{"clip":"Wave","min_rate":0.5,"max_rate":1}]`,"rates[0].clip","Not_Locomotion"},
        {`"rates":[{"clip":"Walk","min_rate":2,"max_rate":1}]`,"rates[0].min_rate","Invalid_Rate"},
        {`"rates":[{"clip":"Walk","min_rate":0.5,"max_rate":1},{"clip":"Walk","min_rate":0.5,"max_rate":1}]`,"rates[1].clip","Duplicate"},
        {`"blends":[{"clips":["Idle","Walk"],"samples":[{"weights":[1,0,0,0,0,0,0,0]}]}],"rates":[{"clip":"Walk","min_rate":0.5,"max_rate":1}]`,"rates[0].clip","Blended"},
    }) {
        result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"want":["Locomotion"],"replace":true,%s}}`,ids,refused.params))
        testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,fmt.tprintf(`"path":"%s"`,refused.path)) && strings.contains(result.data,refused.code) && strings.contains(result.data,`"fix"`),"%s: %s",refused.code,result.data)
    }
    jog:=[2]lib.Keyframe{{time=0,value={0,1,0,0}},{time=.5,value={0,1.02,0,0}}}
    still:=[2]lib.Keyframe{{time=0,value={0,1,0,0}},{time=1,value={0,1.01,0,0}}}
    paced:=[2]asset.Animation_Clip_Desc{{name="Idle",tracks={{target="root/pelvis",property=.Position,keys=still[:]}}},{name="Jog",tracks={{target="root/pelvis",property=.Position,keys=jog[:]}}}}
    pace:=base.Asset_Id{840,11}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/pace.anim",a.root),&a.assets.types,{id=pace,clips=paced[:]}),asset.Error.None)
    testing.expect(t,host.assets_scan(&a.assets))
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{"entity":"0000000000000011","library":"%s","folder":"paced","want":["Locomotion"],"blends":[{{"clips":["Idle","Jog"],"samples":[{{"weights":[1,1,0,0,0,0,0,0]}}]}}]}}`,authoring_test_id_text(pace)))
    testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"blends[0].clips[1]"`) && strings.contains(result.data,"Unequal_Duration") && strings.contains(result.data,"retime"),"%s",result.data)

    // A library larger than a .character takes fails and says how many there are.
    frames:=[2]lib.Keyframe{{time=0,value={0,1,0,0}},{time=1,value={0,1.01,0,0}}}
    turn:=[2]lib.Keyframe{{time=0,value=lib.quat_vec4(1)},{time=1,value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},.5))}}
    many:=make([dynamic]asset.Animation_Clip_Desc,context.temp_allocator)
    for i in 0..<anim.MATCH_CLIPS+1 {append(&many,asset.Animation_Clip_Desc{name=fmt.tprintf("Idle_%d",i),tracks={{target="root/pelvis",property=.Position,keys=frames[:]}}})}
    for i in 0..<SETUP_GESTURES+1 {append(&many,asset.Animation_Clip_Desc{name=fmt.tprintf("Wave_%d",i),tracks={{target="root/pelvis/spine_01/clavicle_r/upperarm_r",property=.Rotation,keys=turn[:]}}})}
    large:=base.Asset_Id{840,9}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/many.anim",a.root),&a.assets.types,{id=large,clips=many[:]}),asset.Error.None)
    testing.expect(t,host.assets_scan(&a.assets))
    crowded:=fmt.tprintf(`"entity":"0000000000000011","library":"%s","folder":"crowded"`,authoring_test_id_text(large))
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"want":["Locomotion"]}}`,crowded))
    testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Capacity"`) && strings.contains(result.data,"65: walking") && strings.contains(result.data,"Pass clips"),"%s",result.data)
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"want":["Gestures"]}}`,crowded))
    testing.expectf(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"code":"Capacity"`) && strings.contains(result.data,"Wave_0"),"%s",result.data)
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"want":["Locomotion","Gestures"],"clips":["Idle_0","Wave_3"],"dry_run":true}}`,crowded))
    testing.expectf(t,result.code==0 && strings.contains(string(serial_bytes(a)),`"gestures":["Wave_3"]`),"%s %s",result.message,result.data)

    // With the skeleton alone it writes the assets and changes no entity.
    before,_:=core.get(&f.world.animations,f.rig)
    solo:=fmt.tprintf(`"skeleton":"%s","library":"%s","folder":"solo"`,authoring_test_id_text(base.Asset_Id{840,2}),authoring_test_id_text(library))
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s}}`,solo))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text=string(serial_bytes(a))
    testing.expectf(t,strings.has_prefix(text,`{"skeleton":`) && authoring_test_exists(a,"solo/figure.character"),"%s",text)
    after,_:=core.get(&f.world.animations,f.rig)
    testing.expect(t,after==before && after.asset!=authoring_test_id(a,"solo/figure.character"))
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{%s,"entity":"0000000000000011"}}`,solo))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Exclusive_Reference"))
    result=authoring_test_execute(a,"setup",fmt.tprintf(`{{"skeleton":"%s"}}`,authoring_test_id_text(base.Asset_Id{840,2})))
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"library"`))
}
