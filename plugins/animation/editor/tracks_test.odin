package animation_editor

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(private="file")
Tracks_Test_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    animations:core.Table(anim.Animation),
    targets:core.Table(anim.Animation_Target),
    requests:anim.Animation_Requests,
}
@(private="file")
Tracks_Test_Editor :: struct {api:editor.Api,tracks:Tracks,provider:Tracks_Api}

@(private="file")
tracks_test_types :: proc(types:^[dynamic]core.Test_Type) {
    anim.test_types(types)
    append(types,core.test_type(Tracks,default=proc(dst:^Tracks) {dst^=TRACKS_DEFAULT},free=tracks_free),core.test_type(Tracks_Api,default=proc(dst:^Tracks_Api) {dst^=TRACKS_API_DEFAULT}))
}

// A door whose clip moves its panel below it, a camera that names it as an actor, and an entity
// the clip does not reach, in an editor with its API: tracks of the panel, the actor and the
// weight of the door's Animation, each with a key at 0.
@(private="file")
Tracks_Fixture :: struct {
    authoring:Authoring_Test,
    info:core.World_Info,
    document:Tracks_Test_World,
    editor_world:Tracks_Test_Editor,
    edits:history.Edits,
    selection:history.Selection,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    out:serial.Writer,
    door,panel,actor,loose:core.Entity,
    clip:string, // the id of the .anim
}

@(private="file")
tracks_test_open :: proc(f:^Tracks_Fixture,t:^testing.T,name:string) -> bool {
    authoring_test_init(&f.authoring,t,name) or_return
    described:bool
    if f.info,described=core.test_info(t,Tracks_Test_World,core.Test_None,Tracks_Test_Editor,tracks_test_types);!described {return false}
    w:=&f.document
    if !testing.expect(t,core.world_init(&f.info,.World,w,context.allocator) && core.world_init(&f.info,.Editor,&f.editor_world,context.allocator)) {return false}
    entity :: proc(w:^Tracks_Test_World,id:u64,name:string,parent:core.Entity) -> core.Entity {
        e:=core.create(&w.entities)
        core.add(&w.ids,e,{base.Entity_Id(id)});core.add(&w.transforms,e,core.TRANSFORM_DEFAULT)
        label:core.Name;base.text_set(label.text[:],name);core.add(&w.names,e,label)
        if parent!=core.NONE {core.add(&w.parents,e,{entity=parent})}
        return e
    }
    f.door=entity(w,1,"Door",core.NONE)
    f.panel=entity(w,2,"Panel",f.door)
    f.actor=entity(w,3,"Camera",core.NONE)
    f.loose=entity(w,4,"Loose",core.NONE)
    target:=anim.Animation_Target{animation=f.door};base.text_set(target.path[:],"Shot")
    core.add(&w.targets,f.actor,target)
    s:=&f.authoring.session
    s.info,s.edit_world,s.editor_world,s.selection,s.edits,s.viewport,s.gui=&f.info,w,&f.editor_world,&f.selection,&f.edits,&f.viewport,&f.gui
    api_opened,api_problem:=editor.api_open(s,0,false,false)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return false}
    authoring_clip_register(s)
    serial.writer_init(&f.out,1<<16)
    animation:=anim.ANIMATION_DEFAULT;animation.playing=false
    core.add(&w.animations,f.door,animation)
    core.settle(&f.info,w,nil)
    history.edits_reset(&f.edits,core.world_ref(w,&f.info))
    if result:=tracks_test_call(f,"animation.clip.create",`{"path":"door.anim","name":"open"}`);!testing.expectf(t,result.code==0,"%v",result) {return false}
    id:=authoring_test_id(&f.authoring,"door.anim")
    f.clip=authoring_test_id_text(id)
    core.edit(&w.animations,f.door).asset=id
    core.settle(&f.info,w,nil)
    history.edits_reset(&f.edits,core.world_ref(w,&f.info))
    for track in ([?]string{`"target":"Panel","property":"Position"`,`"target":"Panel","property":"Rotation","keys":[{"time":0,"value":[0,0,0,1]}]`,`"target":"Shot","property":"Position"`,`"target":"@field/Animation.weight","property":"Float"`}) {
        keys:=`,"keys":[{"time":0,"value":[0,0,0,0]}]` if !strings.contains(track,"keys") else ""
        if !testing.expect_value(t,tracks_test_call(f,"animation.track.set",fmt.tprintf(`{{"asset":"%s","clip":"open",%s%s}}`,f.clip,track,keys)).code,0) {return false}
    }
    return true
}

@(private="file")
tracks_test_close :: proc(f:^Tracks_Fixture) {
    s:=&f.authoring.session
    editor.api_close(s)
    serial.writer_destroy(&f.out)
    history.edits_free(&f.edits);delete(f.selection.entities);delete(f.viewport.gizmo.items)
    core.world_destroy(&f.info,.World,&f.document);core.world_destroy(&f.info,.Editor,&f.editor_world)
    core.test_info_destroy(&f.info)
    authoring_test_destroy(&f.authoring)
}

@(private="file")
tracks_test_call :: proc(f:^Tracks_Fixture,method,params:string) -> api.Error {
    st:=editor.api_state(&f.authoring.session)
    base.arena_reset(&st.server.scratch);serial.writer_reset(&f.out)
    st.poll_temp=context.temp_allocator
    found:=api.method_find(&st.server,method)
    if found==nil {return {api.METHOD_NOT_FOUND,method,""}}
    error,_:=api.method_execute(&st.server,found,params,&f.out)
    return error
}

// Undoes or redoes the last step as its author: those of the API are the API's.
@(private="file")
tracks_test_undo :: proc(f:^Tracks_Fixture,redo:=false) -> bool {
    w:=core.world_ref(&f.document,&f.info)
    at:=f.edits.cursor if redo else f.edits.cursor-1
    if at<0 || at>=len(f.edits.steps) {return false}
    f.edits.author=f.edits.steps[at].author
    return history.redo(&f.edits,w,&f.selection) if redo else history.undo(&f.edits,w,&f.selection)
}

// What the test writes in the world by hand, as a step of the person.
@(private="file")
tracks_test_edit :: proc(f:^Tracks_Fixture) {
    core.settle(&f.info,&f.document,nil)
    f.edits.author=history.EDIT_AUTHOR_USER
    history.edits_begin(&f.edits,&f.selection,"Move")
    history.edits_end(&f.edits)
    history.edits_commit(&f.edits,core.world_ref(&f.document,&f.info),&f.selection)
}

@(private="file")
tracks_test_keys :: proc(f:^Tracks_Fixture,target:string,property:lib.Property) -> []lib.Keyframe {
    file:asset.Asset
    if authoring_test_load(&f.authoring,"door.anim",&file)!=.None {return nil}
    defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&f.authoring.assets.types)
    if error!=.None {return nil}
    for &track in view.tracks {
        if base.text_get(track.target[:])==target && track.property==property {return slice.clone(view.keys[track.first_key:][:track.key_count],context.temp_allocator)}
    }
    return nil
}

@(private="file")
tracks_test_times :: proc(keys:[]lib.Keyframe) -> []f32 {
    times:=make([]f32,len(keys),context.temp_allocator)
    for key,i in keys {times[i]=key.time}
    return times
}

@(test)
a_key_is_added_moved_eased_and_deleted_each_in_one_step_of_undo :: proc(t:^testing.T) {
    f:=new(Tracks_Fixture);defer free(f)
    if !tracks_test_open(f,t,"tracks-keys") {return}
    defer tracks_test_close(f)
    w:=core.world_ref(&f.document,&f.info)
    track:=fmt.tprintf(`"asset":"%s","clip":"open","target":"Panel","property":"Position"`,f.clip)
    cases:=[?]struct{edit:string,times:[]f32}{
        {`"time":0.5,"key":{"value":[5,0,0,0]}`,{0,0.5}},
        {`"time":0.5,"to":2`,{0,2}},
        {`"time":2,"key":{"interpolation":"Step","ease":"Quad_In"}`,{0,2}},
        {`"time":0,"to":2`,{2}},
        {`"time":2,"remove":true`,{}},
    }
    for c in cases {
        before:=tracks_test_keys(f,"Panel",.Position)
        cursor:=f.edits.cursor
        result:=tracks_test_call(f,"animation.key.set",fmt.tprintf(`{{%s,%s}}`,track,c.edit))
        if !testing.expectf(t,result.code==0,"%s: %v",c.edit,result) {return}
        after:=tracks_test_keys(f,"Panel",.Position)
        testing.expectf(t,slice.equal(tracks_test_times(after),c.times),"%s leaves the keys at %v",c.edit,tracks_test_times(after))
        testing.expectf(t,f.edits.cursor==cursor+1,"%s is one step",c.edit)
        testing.expect(t,tracks_test_undo(f))
        testing.expectf(t,slice.equal(tracks_test_keys(f,"Panel",.Position),before),"undo of %s gives the keys back",c.edit)
        testing.expect(t,tracks_test_undo(f,true))
        if strings.contains(c.edit,"interpolation") {
            // A field left out keeps what the key holds.
            key:=after[len(after)-1]
            testing.expect(t,key.value==mm.Vec4{5,0,0,0} && key.interpolation==.Step && key.ease==.Quad_In)
        }
    }
    // What the key set refuses writes nothing.
    for edit in ([?]string{`"time":0,"to":1,"remove":true`,`"time":3,"to":1`,`"time":3,"key":{"ease":"Quad_In"}`,`"time":3`}) {
        cursor:=f.edits.cursor
        testing.expectf(t,tracks_test_call(f,"animation.key.set",fmt.tprintf(`{{%s,%s}}`,track,edit)).code==api.INVALID_PARAMS,"%s is refused",edit)
        testing.expect_value(t,f.edits.cursor,cursor)
    }
}

@(test)
capture_keys_the_tracks_of_an_entity_with_what_it_has_now :: proc(t:^testing.T) {
    f:=new(Tracks_Fixture);defer free(f)
    if !tracks_test_open(f,t,"tracks-capture") {return}
    defer tracks_test_close(f)
    w:=core.world_ref(&f.document,&f.info)
    names:=[?]struct{e:core.Entity,name:string,reached:bool}{{f.door,"",true},{f.panel,"Panel",true},{f.actor,"Shot",true},{f.loose,"",false}}
    for c in names {
        name,reached:=track_name(w,f.door,c.e)
        testing.expectf(t,name==c.name && reached==c.reached,"%s is %q, reached %v",editor.entity_name(w,c.e),name,reached)
    }
    turn:=mm.quat_axis_angle({0,1,0},1)
    core.edit(&f.document.transforms,f.panel)^={position={1,2,3},rotation=turn,scale={1,1,1}}
    core.edit(&f.document.animations,f.door).weight=0.25
    tracks_test_edit(f)
    cursor:=f.edits.cursor
    result:=tracks_test_call(f,"animation.key.capture",`{"animation":"0000000000000001","entity":"0000000000000002","time":1}`)
    if !testing.expectf(t,result.code==0,"%v",result) {return}
    testing.expect(t,strings.contains(api.json_compact(string(serial.writer_bytes(&f.out))),`"keys":2`),api.json_compact(string(serial.writer_bytes(&f.out))))
    testing.expect_value(t,f.edits.cursor,cursor+1)
    position:=tracks_test_keys(f,"Panel",.Position)
    rotation:=tracks_test_keys(f,"Panel",.Rotation)
    testing.expect(t,len(position)==2 && position[1].time==1 && position[1].value==mm.Vec4{1,2,3,0})
    testing.expect(t,len(rotation)==2 && rotation[1].value==lib.quat_vec4(turn))
    testing.expect_value(t,len(tracks_test_keys(f,"Shot",.Position)),1)
    testing.expect(t,tracks_test_undo(f))
    testing.expect_value(t,len(tracks_test_keys(f,"Panel",.Position)),1)
    // A field track of the entity that plays the clip keys its field.
    testing.expect_value(t,tracks_test_call(f,"animation.key.capture",`{"animation":"0000000000000001","entity":"0000000000000001","time":1}`).code,0)
    weight:=tracks_test_keys(f,"@field/Animation.weight",.Float)
    testing.expect(t,len(weight)==2 && weight[1].value.x==0.25)
    testing.expect_value(t,len(tracks_test_keys(f,"Panel",.Position)),1)
    for refused in ([?]string{`{"animation":"0000000000000001","entity":"0000000000000004","time":1}`,`{"animation":"0000000000000002","entity":"0000000000000002","time":1}`}) {
        cursor=f.edits.cursor
        testing.expectf(t,tracks_test_call(f,"animation.key.capture",refused).code==api.INVALID_PARAMS,"%s is refused",refused)
        testing.expect_value(t,f.edits.cursor,cursor)
    }
}

@(test)
the_tracks_tool_is_turned_on_by_its_entry_and_keys_what_the_gizmo_moves :: proc(t:^testing.T) {
    f:=new(Tracks_Fixture);defer free(f)
    if !tracks_test_open(f,t,"tracks-tool") {return}
    defer tracks_test_close(f)
    s:=&f.authoring.session
    w:=core.world_ref(&f.document,&f.info)
    // The entry of the Tools menu and the methods come from one registration of the plugin.
    entry:=editor.command_binding(s,TRACKS_TOOL)
    if !testing.expect(t,entry!=nil && entry.method=="editor.tool" && entry.menu==.Tools) {return}
    st:=editor.api_state(s)
    testing.expect(t,api.method_find(&st.server,"animation.tracks.show")!=nil && api.method_find(&st.server,"animation.key.capture")!=nil)
    testing.expect(t,editor.command_run(s,TRACKS_TOOL))
    editor.commands_run(s)
    testing.expect(t,editor.tool_on(s,TRACKS_TOOL))
    testing.expect_value(t,tracks_test_call(f,"animation.tracks.show",`{"entity":"0000000000000001","time":0.5}`).code,0)
    tracker:=&f.editor_world.tracks
    testing.expect(t,tracker.entity==f.door && tracker.head==0.5)
    view,clip,ok:=tracks_clip(s,tracker,w)
    if !testing.expect(t,ok) {return}
    // The gizmo let go of the panel where it moved it, and of the loose entity: the panel is keyed at
    // the head in the step of the move, which one undo takes back whole.
    cursor:=f.edits.cursor
    f.edits.author=history.EDIT_AUTHOR_USER
    testing.expect(t,history.edits_begin(&f.edits,&f.selection,"Move"))
    moved:=mm.TRANSFORM_IDENTITY;moved.position={0,4,0}
    for e in ([2]core.Entity{f.panel,f.loose}) {
        append(&f.viewport.gizmo.items,editor.Gizmo_Item{entity=e,local=editor.entity_local(w,e)})
        core.edit(&f.document.transforms,e)^=core.from_math(moved)
    }
    core.settle(&f.info,&f.document,nil)
    history.edits_end(&f.edits)
    tracks_key_moved(s,tracker,w,view,clip)
    history.edits_flush(&f.edits,w,&f.selection)
    testing.expect_value(t,f.edits.cursor,cursor+1)
    position:=tracks_test_keys(f,"Panel",.Position)
    testing.expect(t,len(position)==2 && position[1].time==0.5 && position[1].value==mm.Vec4{0,4,0,0},fmt.tprint(position))
    testing.expect(t,tracks_test_undo(f))
    panel,_:=core.get(&f.document.transforms,f.panel)
    testing.expect(t,len(tracks_test_keys(f,"Panel",.Position))==1 && panel.position==[3]f32{})
}
