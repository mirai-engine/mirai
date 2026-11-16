package animation_editor

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// A game whose rig stands until W is held, and then walks: its matching jumps from Idle to Walk
// in the tick the body starts to move.
@(private)
@(test_world,host="Pose_Bake_Test_Shared",editor="History_Test_Editor")
History_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),transforms:core.Table(core.Transform),parents:core.Table(core.Parent),worlds:core.Table(core.World_Transform),
    names:core.Table(core.Name),targets:core.Table(anim.Animation_Target),animations:core.Table(anim.Animation),
    meshes:core.Table(erender.Mesh_Renderer),sources:core.Table(anim.Pose_Source),attachments:core.Table(anim.Bone_Attachment),
    playback:anim.Playback,requests:anim.Animation_Requests,events:anim.Animation_Events,constraints:anim.Animation_Constraints,
    modifier_runtime:anim.Modifier_Runtime,grounding:anim.Grounding_Runtime,actions:anim.Action_Runtime,motion:anim.Motion_Runtime,
    played:core.Table(anim.Animation_Played),remotes:core.Table(core.Remote),progress:core.Table(anim.Animation_Progress),
    hierarchy:core.Hierarchy,propagation:core.Propagation,jumps:core.Jumps,
    time:core.Time,frame:core.Frame_Time,input:core.Input,world_id:core.World_Id,
    gone_at:History_Test_Gone,
}
// The tick from which the game destroys its rig; 0: never.
@(private) History_Test_Gone :: struct {tick:u64}
@(private) History_Test_Editor :: struct {api:editor.Api,animation:Animation_Api}

@(private="file")
history_test_tick :: proc(data,shared,editor_data,app_data:rawptr) {
    w,s,app:=(^History_Test_World)(data),(^Pose_Bake_Test_Shared)(shared),(^host.App)(app_data)
    problems:=host.app_world_storage(app,data,core.Problems)
    velocity:=mm.Vec3{0,0,-1.2} if .W in w.input.keys_down else {}
    for e in w.animations.entities[:core.count(&w.animations)] {
        if w.gone_at.tick>0 && w.time.tick>=w.gone_at.tick {core.destroy(&w.entities,e);continue}
        anim.match_goal(&w.requests,{rig=e,mode=1,velocity=velocity,desired=velocity,facing={0,0,-1},acceleration=10,braking=10})
    }
    core.settle(app.info,data,editor_data)
    anim.animation_sample(core.read(&w.animations),&w.progress,&w.played,core.read(&w.attachments),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),core.read(&w.names),core.read(&w.targets),core.read(&w.meshes),core.read(&w.sources),core.read(&w.remotes),&w.requests,&w.events,&w.modifier_runtime,&w.playback,&s.characters,&s.skeletons,app,w.time,w.frame,problems,&w.actions,&w.motion,&s.sources,{},core.CLOCK_DEFAULT,anim.ANIMATION_BUDGET_CONFIG_DEFAULT)
    core.settle(app.info,data,editor_data)
    anim.animation_advance(&w.transforms,core.read(&w.parents),core.read(&w.worlds),&w.requests,&w.modifier_runtime,&w.playback,&w.constraints,&w.grounding,{},{},w.time,core.ref(&s.skeletons),problems,&w.motion,&s.characters,{},{},core.CLOCK_DEFAULT,nil)
    core.settle(app.info,data,editor_data)
}

// An editor without a window over the figure with its .character, whose Play keeps its past.
@(private="file")
History_Test :: struct {
    authoring:Authoring_Test,
    p:^platform.Platform,
    info:core.World_Info,
    shared:Pose_Bake_Test_Shared,
    data:rawptr,
    rig:core.Entity,
    tools:History_Test_Editor,
    edits:history.Edits,
    selection:history.Selection,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    document:editor.Document,
    build:editor.Build_State,
    settings:editor.Play_History,
}

@(private="file")
history_test_open :: proc(t:^testing.T,f:^History_Test,name:string) -> bool {
    if !authoring_test_init(&f.authoring,t,name) {return false}
    error:platform.Error
    f.p,error=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) || f.p==nil {return false}
    described:bool
    f.info,described=test_info(t,History_Test_World)
    if !described {return false}
    test_locomotion_modes(&f.info)
    f.info.loops[.Game][.Fixed]=history_test_tick
    if !testing.expect(t,core.world_init(&f.info,.Shared,&f.shared,context.allocator)) {return false}
    app:=&f.authoring.app
    app.info,app.shared,app.platform,app.tick_dt,app.max_ticks=&f.info,&f.shared,f.p,1.0/60,8
    f.data=host.app_world_create(app)
    w:=(^History_Test_World)(f.data)
    f.rig=core.create(&w.entities)
    core.add(&w.ids,f.rig,{value=17});core.add(&w.names,f.rig,core.name_make("Figure"))
    core.add(&w.transforms,f.rig,core.from_math(mm.TRANSFORM_IDENTITY))
    library,mesh:=setup_test_assets(&f.authoring,t)
    core.add(&w.meshes,f.rig,erender.Mesh_Renderer{mesh=mesh})
    core.settle(&f.info,f.data,nil)
    f.viewport={orbit=editor.ORBIT_DEFAULT}
    f.gui={layout={left_open=true,right_open=true,library_tab=.Content,bottom_open=true}}
    f.settings=editor.PLAY_HISTORY_DEFAULT
    s:=&f.authoring.session
    s.info,s.edit_world,s.editor_world=&f.info,f.data,&f.tools
    s.edits,s.selection,s.viewport,s.gui,s.document,s.build,s.play_history=&f.edits,&f.selection,&f.viewport,&f.gui,&f.document,&f.build,&f.settings
    history.edits_reset(&f.edits,editor.edited_world(s))
    opened,problem:=editor.api_open(s,0,true,listen=false)
    if !testing.expectf(t,opened==.None,"%v: %s",opened,problem) {return false}
    editor.api_state(s).poll_temp=context.temp_allocator
    editor.api_state(s).step_frame=history_test_frame
    _,failure:=history_test_call(f,"animation.character.setup",fmt.tprintf(`{{"entity":"Figure","library":"%s","folder":"c"}}`,authoring_test_id_text(library)))
    return testing.expectf(t,failure.code==0,"setup: %s %s",failure.message,failure.data)
}

@(private="file")
history_test_close :: proc(f:^History_Test) {
    s:=&f.authoring.session
    if f.data!=nil {
        editor.runs_stop(s)
        editor.api_close(s)
        history.edits_free(&f.edits)
        delete(f.selection.entities)
        delete(s.edit_selection.entities)
        host.app_world_scratch_free(&f.authoring.app)
        host.app_world_free(&f.authoring.app,f.data)
        core.world_destroy(&f.info,.Shared,&f.shared)
    }
    delete(f.authoring.app.worlds)
    authoring_test_destroy(&f.authoring)
    if f.info.sizes[.World]>0 {test_info_destroy(&f.info)}
    if f.p!=nil {platform.destroy(f.p)}
}

@(private="file")
history_test_call :: proc(f:^History_Test,name,params:string) -> (text:string,error:api.Error) {
    st:=editor.api_state(&f.authoring.session)
    base.arena_reset(&st.server.scratch);serial.writer_reset(&f.authoring.out)
    method:=api.method_find(&st.server,name)
    if method==nil {return "",{api.METHOD_NOT_FOUND,"Missing test method",name}}
    error,_=api.method_execute(&st.server,method,params,&f.authoring.out)
    return strings.clone(string(serial.writer_bytes(&f.authoring.out)),context.temp_allocator),error
}

// A frame of the editor as a step runs it, without the window.
@(private="file")
history_test_frame :: proc(s:^editor.Session) -> bool {
    platform.frame_begin(s.app.platform)
    editor.play_input_update(s)
    editor.game_frame(s)
    return true
}

// The rows of an answer of animation.history.
@(private="file")
history_test_rows :: proc(t:^testing.T,text:string,loc:=#caller_location) -> (rows:json.Array) {
    value,error:=json.parse(transmute([]u8)text,allocator=context.temp_allocator)
    if !testing.expectf(t,error==nil,"%v in %s",error,text,loc=loc) {return}
    result:=value.(json.Object)
    if inner,wrapped:=result["result"].(json.Object);wrapped {result=inner}
    rows,_=result["rows"].(json.Array)
    return
}

@(private="file")
history_test_step :: proc(t:^testing.T,f:^History_Test,params:string,loc:=#caller_location) -> u64 {
    text,error:=history_test_call(f,"play.step",params)
    if !testing.expectf(t,error.code==0,"play.step %s: %s %s",params,error.message,error.data,loc=loc) {return 0}
    value,_:=json.parse(transmute([]u8)text,allocator=context.temp_allocator)
    result,_:=value.(json.Object)
    if inner,wrapped:=result["result"].(json.Object);wrapped {result=inner}
    tick,_:=result["tick"].(json.Float)
    return u64(tick)
}

@(test)
history_reads_the_jump_of_matching_at_its_tick_with_its_candidates_and_says_what_is_wrong :: proc(t:^testing.T) {
    f:=new(History_Test);defer free(f)
    defer history_test_close(f)
    if !history_test_open(t,f,"history") {return}
    s:=&f.authoring.session
    // The game destroys its rig from tick 40 on: what plays again plays the same.
    core.world_storage_of(core.world_ref(f.data,&f.info),History_Test_Gone).tick=40
    if !testing.expect(t,editor.play_start(s)) {return}
    // A run that has played no tick has no past to read.
    _,error:=history_test_call(f,"animation.history",`{"entity":"Figure"}`)
    testing.expectf(t,error.code!=0 && strings.contains(error.message,"play.step"),"before a tick: %s",error.message)
    history_test_step(t,f,`{"for":20}`)
    jumped_at:=history_test_step(t,f,`{"for":1,"keys":["W"]}`)
    history_test_step(t,f,`{"for":10,"keys":["W"]}`)
    text:string
    text,error=history_test_call(f,"animation.history",`{"entity":"Figure","candidates":4}`)
    if !testing.expectf(t,error.code==0,"%s %s",error.message,error.data) {return}
    rows:=history_test_rows(t,text)
    if !testing.expectf(t,len(rows)>20,"rows in %s",text) {return}
    found:=false
    played_on:=0
    for value in rows {
        row:=value.(json.Object)
        tick:=u64(row["tick"].(json.Float))
        clip,_:=row["clip"].(json.String)
        jumped,_:=row["jumped"].(json.Boolean)
        searched,_:=row["searched"].(json.Boolean)
        if tick<jumped_at && tick>1 {testing.expectf(t,clip=="Idle","tick %d stands in Idle, not %s",tick,clip)}
        // Each search keeps what it asked, also one no change forced that played on (interval).
        listed,_:=row["candidates"].(json.Array)
        if searched {testing.expectf(t,len(listed)>0,"a search at tick %d lists its candidates: %v",tick,row)}
        if searched && !jumped && len(listed)>0 {played_on+=1}
        if tick!=jumped_at {continue}
        found=true
        testing.expectf(t,jumped && searched && clip=="Walk","the jump is at tick %d: %v",tick,row)
        candidates,_:=row["candidates"].(json.Array)
        if !testing.expectf(t,len(candidates)>0 && len(candidates)<=4,"candidates at the jump: %v",row) {continue}
        best:=candidates[0].(json.Object)
        reason,_:=best["reason"].(json.String)
        name,_:=best["clip"].(json.String)
        testing.expectf(t,reason=="None" && name==clip,"the first candidate is the row it chose: %v",best)
        sum:f64
        for _,cost in best["costs"].(json.Object) {sum+=cost.(json.Float)}
        cost:=best["cost"].(json.Float)
        testing.expectf(t,abs(sum-cost)<=1e-3*max(1,abs(cost)),"its feature costs %f sum its cost %f",sum,cost)
    }
    testing.expectf(t,found,"no row at tick %d in %s",jumped_at,text)
    testing.expectf(t,played_on>0,"a search that played on lists its candidates: %s",text)
    // Every five ticks, searched and jumped tell what happened since the row before.
    text,error=history_test_call(f,"animation.history",`{"entity":"Figure","from":2,"every":5}`)
    if !testing.expectf(t,error.code==0,"%s %s",error.message,error.data) {return}
    rows=history_test_rows(t,text)
    for i in 1..<len(rows) {
        before,row:=rows[i-1].(json.Object),rows[i].(json.Object)
        searched,_:=row["searched"].(json.Boolean)
        jumped,_:=row["jumped"].(json.Boolean)
        testing.expectf(t,searched==(row["searches"].(json.Float)>before["searches"].(json.Float)) && jumped==(row["jumps"].(json.Float)>before["jumps"].(json.Float)),"since the row before: %v after %v",row,before)
    }
    // Hostile input: a pose no tick keeps, a name of no entity, a rig gone at some ticks.
    _,error=history_test_call(f,"animation.history",`{"entity":"Figure","names":["@hand_r"],"stage":"Rigs"}`)
    testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,"stage"),"unknown stage: %s %s",error.message,error.data)
    _,error=history_test_call(f,"animation.history",`{"entity":"Nobody"}`)
    testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.data,"Missing_Entity"),"no such entity: %s %s",error.message,error.data)
    testing.expect(t,history_test_step(t,f,`{"for":12}`)>40)
    text,error=history_test_call(f,"animation.history",fmt.tprintf(`{{"entity":"0x%016x","from":37}}`,u64(f.rig)))
    if !testing.expectf(t,error.code==0,"%s %s",error.message,error.data) {return}
    rows=history_test_rows(t,text)
    if !testing.expect(t,len(rows)>=4) {return}
    first,last:=rows[0].(json.Object),rows[len(rows)-1].(json.Object)
    _,lacked:=first["code"].(json.String)
    code,_:=last["code"].(json.String)
    testing.expectf(t,!lacked && code=="Missing_Entity","the rig plays, then is gone: %v ... %v",first,last)
}

@(test)
history_places_bones_in_the_pose_asked_at_each_row :: proc(t:^testing.T) {
    f:=new(History_Test);defer free(f)
    defer history_test_close(f)
    if !history_test_open(t,f,"history-pose") {return}
    if !testing.expect(t,editor.play_start(&f.authoring.session)) {return}
    history_test_step(t,f,`{"for":12,"keys":["W"]}`)
    text,error:=history_test_call(f,"animation.history",`{"entity":"Figure","from":4,"names":["@hand_r"],"stage":"Sampled"}`)
    if !testing.expectf(t,error.code==0,"%s %s",error.message,error.data) {return}
    rows:=history_test_rows(t,text)
    if !testing.expect(t,len(rows)>4) {return}
    for value in rows {
        row:=value.(json.Object)
        pose,_:=row["pose"].(json.Object)
        transforms,_:=pose["transforms"].(json.Array)
        testing.expectf(t,len(transforms)==1,"each row places the hand: %v",row)
    }
    _,error=history_test_call(f,"animation.history",`{"entity":"Figure","names":["@nose_tip"]}`)
    testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.data,"Missing_Name"),"a bone the skeleton lacks: %s %s",error.message,error.data)
}
