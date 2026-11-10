package anim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

@(test)
morph_weights_compose_the_mesh_the_default_the_curve_and_the_overrides_without_allocations :: proc(t:^testing.T) {
    target:=asset.Morph_Target{weight=.4}
    base.text_set(target.name[:],"Smile")
    rig:=Skin_Rig{id={5,7},revision=1,morphs={target}}
    config:Morph_Weights
    testing.expect(t,morph_weight_set(&config,"Smile",.2,.Default))
    state:=Morph_Playing{entity=core.Entity(1),source=core.Entity(2),curve_count=-1}
    defer morph_playing_free(&state)
    testing.expect(t,morph_bind(&state,&rig,config,"Face",1) && state.error==.None)
    testing.expect_value(t,state.current[0],f32(.4))
    curves:=[2]Curve_Output{
        {target=base.name_hash("Other/@morph/Smile"),property=.Float,value={100,0,0,0},weight=1},
        {target=base.name_hash("Face/@morph/Smile"),property=.Float,value={.75,0,0,0},weight=.5},
    }
    source:=Playing{seen=4,curves_ready=true}
    append(&source.curves,..curves[:])
    defer delete(source.curves)
    // The curve, over the default by its weight.
    testing.expect(t,morph_compose(&state,&rig,config,&source))
    testing.expect(t,abs(state.current[0]-.85)<1e-6)
    copied:Morph_Playing
    core.value_copy(&copied,&state,type_info_of(Morph_Playing))
    defer morph_playing_free(&copied)
    testing.expect(t,raw_data(copied.current)!=raw_data(state.current))
    testing.expect(t,morph_weight_set(&config,"Smile",-1.5,.Override))
    rows:=state.curve_rows[0]
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    for tick in 0..<16 {
        testing.expect(t,morph_bind(&state,&rig,config,"Face",u64(tick+2)))
        testing.expect(t,morph_compose(&state,&rig,config,&source))
    }
    context=saved
    testing.expect(t,state.current[0]==-1.5 && state.curve_rows[0]==rows && abs(copied.current[0]-.85)<1e-6)
    testing.expect(t,morph_weight_set(&config,"Smile",.4,.Additive) && morph_bind(&state,&rig,config,"Face",20))
    testing.expect(t,morph_compose(&state,&rig,config,&source) && abs(state.current[0]-1.35)<1e-6)
    // Without its source the animated part goes: the mesh's weight and the entity's.
    testing.expect(t,morph_compose(&state,&rig,config,nil) && abs(state.current[0]-.8)<1e-6)
    morph_weight_clear(&config,"Smile")
    testing.expect(t,config.names[0]==0 && morph_bind(&state,&rig,config,"Face",21) && morph_compose(&state,&rig,config,nil) && state.current[0]==.4)
    testing.expect(t,!morph_weight_set(&config,"",1) && !morph_weight_set(&config,"Smile",transmute(f32)u32(0x7fc00000)))
    // Without a path (a rig that shows its own mesh) each target takes the curve that ends in its
    // name, whatever node path the importer gave it.
    tracks:[3]asset.Animation_Track
    for &track in tracks {track.property=.Float}
    base.text_set(tracks[0].target[:],"Armature/Body/@morph/Smile");base.text_set(tracks[1].target[:],"Armature/Body/@morph/Smile");base.text_set(tracks[2].target[:],"Armature/Body/Weight")
    morphs,listed:=host.content_animation_morphs({tracks=tracks[:]},context.allocator);defer delete(morphs)
    testing.expect(t,listed && len(morphs)==1 && morphs[0]==host.Content_Morph{base.name_hash("Armature/Body/@morph/Smile"),base.name_hash("Smile")})
    content:=host.Content_Animation{morphs=morphs}
    named:=Morph_Playing{curve_count=-1};defer morph_playing_free(&named)
    imported:=Playing{seen=4,curves_ready=true};defer delete(imported.curves)
    append(&imported.curves,Curve_Output{target=base.name_hash("Armature/Body/@morph/Smile"),property=.Float,value={.6,0,0,0},weight=1})
    testing.expect(t,morph_bind(&named,&rig,{},"",1) && named.by_name && morph_compose(&named,&rig,{},&imported,nil,&content) && abs(named.current[0]-.6)<1e-6)
    // A curve named as the target, as face captures and curve drives name them, and the
    // final curves of a rig with drives, which replace those of its animation.
    face:=Playing{seen=4,curves_ready=true,driven_ready=true,curve_layout=9};defer delete(face.curves);defer delete(face.driven)
    append(&face.curves,Curve_Output{target=base.name_hash("Smile"),property=.Float,value={.1,0,0,0},weight=1})
    append(&face.driven,Curve_Output{target=base.name_hash("Smile"),property=.Float,value={.3,0,0,0},weight=1})
    testing.expect(t,morph_compose(&named,&rig,{},&face) && abs(named.current[0]-.3)<1e-6)
    face.driven[0].value.x=.7
    testing.expect(t,morph_compose(&named,&rig,{},&face) && abs(named.current[0]-.7)<1e-6)
    pathed:=Morph_Playing{curve_count=-1};defer morph_playing_free(&pathed)
    testing.expect(t,morph_bind(&pathed,&rig,{},"Face",1) && !pathed.by_name && morph_compose(&pathed,&rig,{},&face) && abs(pathed.current[0]-.7)<1e-6,"a mesh bound by path takes the curve of the target's name too")
    full:Morph_Weights
    for i in 0..<asset.MORPH_WEIGHTS {testing.expect(t,morph_weight_set(&full,fmt.tprintf("Shape %d",i),1))}
    testing.expect(t,!morph_weight_set(&full,"One more",1) && morph_weight_set(&full,"Shape 3",2))
}

@(test)
morph_weights_report_unknown_targets_and_refuse_invalid_entries_keeping_their_weights :: proc(t:^testing.T) {
    target:=asset.Morph_Target{weight=.25}
    base.text_set(target.name[:],"Smile")
    rig:=Skin_Rig{id={5,7},revision=1,morphs={target}}
    state:=Morph_Playing{curve_count=-1}
    defer morph_playing_free(&state)
    config:Morph_Weights
    testing.expect(t,morph_weight_set(&config,"Smile",.5) && morph_weight_set(&config,"Future",2))
    testing.expect(t,morph_bind(&state,&rig,config,"Face",1) && state.error==.Unknown_Target && state.unknown==1)
    testing.expect(t,morph_compose(&state,&rig,config,nil) && state.current[0]==.5,"the entries that name a target apply")
    config.names[1]=config.names[0]
    testing.expect(t,morph_bind(&state,&rig,config,"Face",2) && state.error==.Invalid_Weights)
    testing.expect(t,morph_compose(&state,&rig,config,nil) && state.current[0]==.25,"invalid entries apply to no target")
    config={}
    config.names[0]=base.name_hash("Smile");config.values[0]=transmute(f32)u32(0x7fc00000)
    testing.expect(t,morph_bind(&state,&rig,config,"Face",3) && state.error==.Invalid_Weights)
    next:=Skin_Rig{id={5,7},revision=2,morphs={target,target}}
    base.text_set(next.morphs[1].name[:],"Blink")
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=100}
    saved:=context
    context.allocator=runtime.Allocator{runtime_failure_allocator,&failure}
    kept:=Morph_Playing{curve_count=-1}
    testing.expect(t,morph_bind(&kept,&rig,{},"Face",1))
    failure.remaining=0
    bound:=morph_bind(&kept,&next,{},"Face",2)
    context=saved
    testing.expect(t,!bound && kept.error==.Out_Of_Memory && kept.revision==1 && len(kept.current)==1 && len(kept.previous)==1 && kept.current[0]==.25,"a rebind without memory keeps the last weights")
    failure.remaining=100
    testing.expect(t,morph_bind(&kept,&next,{},"Face",2) && len(kept.current)==2 && kept.current[1]==.25)
    morph_playing_free(&kept)
}

@(private="file")
Morph_World :: struct {
    using world:core.Test_World,
    meshes:core.Table(erender.Mesh_Renderer),
    configs:core.Table(Morph_Weights),
    animations:core.Table(Animation),
    targets:core.Table(Animation_Target),
    sources:core.Table(Pose_Source),
    parents:core.Table(core.Parent),
}

@(private="file")
morph_test_step :: proc(w:^Morph_World,playback:^Playback,cache:^Skin_Runtime,state:^Morph_Playback,app:^host.App) {
    animation_morph(core.read(&w.meshes),core.read(&w.configs),core.read(&w.animations),core.read(&w.targets),core.read(&w.sources),core.read(&w.parents),{playback},{},cache,state,nil,app,{playing=true},nil)
}

@(test)
animation_morph_follows_its_mesh_and_its_weights_and_reads_the_curves_of_its_rig :: proc(t:^testing.T) {
    problems:core.Problems
    w:Morph_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    rig_entity,entity,plain:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    id,other:=base.Asset_Id{71,73},base.Asset_Id{79,83}
    target:=asset.Morph_Target{weight=.25}
    base.text_set(target.name[:],"Smile")
    core.add(&w.meshes,entity,erender.Mesh_Renderer{mesh=id});core.add(&w.meshes,plain,erender.Mesh_Renderer{mesh=other})
    core.add(&w.parents,entity,core.Parent{entity=rig_entity});core.add(&w.animations,rig_entity,ANIMATION_DEFAULT)
    face:Animation_Target;base.text_set(face.path[:],"Face");core.add(&w.targets,entity,face)
    core.test_world_settle(&w)
    cache:Skin_Runtime
    cache.rig_rows=make(map[base.Asset_Id]u32)
    append(&cache.rigs,Skin_Rig{id=id,checked=1,revision=1,morphs={target}},Skin_Rig{id=other,checked=1,revision=1})
    cache.rig_rows[id],cache.rig_rows[other]=0,1
    defer {delete(cache.rig_rows);delete(cache.rigs)}
    assets:host.Assets
    app:=host.App{assets=&assets,allocator=context.allocator}
    playback:Playback;defer playback_free(&playback)
    state:Morph_Playback;defer morph_playback_free(&state)
    morph_test_step(&w,&playback,&cache,&state,&app)
    if !testing.expect(t,len(state.states)==1 && state.states[0].entity==entity && state.states[0].source==rig_entity) {return}
    testing.expect_value(t,state.states[0].current[0],f32(.25))
    // The curves of the animated ancestor drive it.
    pose:=state_get(&playback,rig_entity)
    pose.seen,pose.curves_ready=playback.frame,true
    append(&pose.curves,Curve_Output{target=base.name_hash("Face/@morph/Smile"),property=.Float,value={.9,0,0,0},weight=1})
    morph_test_step(&w,&playback,&cache,&state,&app)
    testing.expect_value(t,state.states[0].current[0],f32(.9))
    testing.expect_value(t,state.states[0].previous[0],f32(.25))
    config:Morph_Weights
    testing.expect(t,morph_weight_set(&config,"Smile",-.75))
    core.add(&w.configs,entity,config);core.test_world_settle(&w)
    morph_test_step(&w,&playback,&cache,&state,&app)
    testing.expect_value(t,state.states[0].current[0],f32(-.75))
    // A changed weight binds again without memory and without asking for the mesh.
    cache.rigs[0].checked=0
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator();app.allocator=context.allocator
    morph_weight_set(core.edit(&w.configs,entity),"Smile",-.5)
    morph_test_step(&w,&playback,&cache,&state,&app)
    morph_test_step(&w,&playback,&cache,&state,&app)
    context=saved;app.allocator=context.allocator
    testing.expect(t,cache.rigs[0].checked==0 && state.states[0].current[0]==-.5 && problems.count==0)
    cache.rigs[0].checked=1
    composed,found:=animation_morph_state(&state,entity)
    testing.expect(t,found && composed.error==.None && composed.weights[0]==-.5 && composed.mesh==cache.rigs[0].id)
    // A mesh that changes keeps the weights of its entity on the targets it still has.
    next:=[2]asset.Morph_Target{target,{weight=.1}}
    base.text_set(next[1].name[:],"Blink")
    cache.rigs[0].morphs=next[:];cache.rigs[0].revision+=1;cache.rigs[0].checked=1
    morph_test_step(&w,&playback,&cache,&state,&app)
    testing.expect(t,len(state.states[0].current)==2 && state.states[0].current[0]==-.5 && state.states[0].current[1]==.1)
    core.remove(&w.meshes,entity);core.test_world_settle(&w)
    morph_test_step(&w,&playback,&cache,&state,&app)
    testing.expect(t,len(state.states)==0 && morph_playing(&state,entity)==nil)
}

@(test)
skin_rigs_pack_the_influences_and_morph_deltas_of_every_level_in_the_order_the_renderer_stores_them :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"animation-skin-levels")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    vertices:[10]asset.Vertex
    influences:[10]asset.Skin_Vertex
    for &vertex,i in vertices {vertex.position={f32(i),0,0};influences[i].joints[0]=1 if i<4 else 0;influences[i].weights[0]=255}
    target:=asset.Morph_Target{count=3,weight=.7}
    base.text_set(target.name[:],"Stretch")
    id:=base.Asset_Id{613,617}
    // Level 0 names vertices 6 to 9 and level 1 vertices 1 to 3: the mesh holds them in that order.
    indices:=[9]u32{6,7,8,6,8,9,1,2,3}
    levels:=[2]asset.Level_Source{{index_count=6},{first_index=6,index_count=3,error=.1}}
    deltas:=[3]asset.Morph_Delta{{vertex=1,position={0,.1,0}},{vertex=6,position={0,.6,0},tangent={0,0,.5}},{vertex=9,position={0,.9,0}}}
    description:=asset.Mesh_Desc{id=id,skeleton={619,631},joints={{node=0,inverse_bind=1},{node=1,inverse_bind=1}}}
    source:=asset.Mesh_Source{vertices=vertices[:],skin=influences[:],morphs={target},morph_deltas=deltas[:]}
    if !testing.expect(t,asset.mesh_build(source,indices[:],levels[:],&description.geometry,context.temp_allocator)) {return}
    if !testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/rig.mesh",directory),&types,description),asset.Error.None) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    state:Skin_Runtime
    defer skin_runtime_free(&state)
    row:=skin_rig_load(&state,app.assets,app.allocator,id,nil,core.NONE)
    if !testing.expect(t,row!=max(u32)) {return}
    rig:=&state.rigs[row]
    testing.expect(t,len(rig.influences)==7 && len(rig.morph.ranges)==7 && len(rig.morph.deltas)==3 && rig.morph.count==1)
    for influence,i in rig.influences {testing.expect_value(t,influence.joints[0],u16(0 if i<4 else 1))}
    expected:=[3]f32{.6,.9,.1}
    for vertex,i in ([3]int{0,3,4}) {
        range:=rig.morph.ranges[vertex]
        testing.expect_value(t,range.count,u32(1))
        testing.expect(t,abs(asset.morph_position(rig.morph.deltas[range.first].position,rig.morph.step).y-expected[i])<=rig.morph.step/2)
    }
    tangent:=asset.morph_tangent(rig.morph.deltas[rig.morph.ranges[0].first].tangent)
    testing.expect(t,abs(tangent.z-.5)<=asset.MORPH_TANGENT_STEP/2 && tangent.x==0 && tangent.y==0)
    testing.expect_value(t,rig.morphs[0].weight,f32(.7))
}

// The assets know a mesh they loaded without a skin or morphs: its rig is
// none without reading its file again, which for a large mesh would hold
// the frame that first shows it.
@(test)
a_rigid_mesh_the_assets_loaded_is_not_read_again_for_its_rig :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"animation-rigid")
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    id:=base.Asset_Id{641,643}
    path:=fmt.tprintf("%s/rigid.mesh",directory)
    vertices:=[3]asset.Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    if !testing.expect_value(t,rig_mesh_save(path,&types,{id=id},vertices[:],{0,1,2},nil),asset.Error.None) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    if mesh:=host.assets_mesh(&assets,id);!testing.expect(t,mesh!=nil && !mesh.failed) {return}
    // Read again, the file would be a problem.
    if !testing.expect(t,os.write_entire_file(path,{1,2,3})==nil) {return}
    app:=host.App{assets=&assets,allocator=context.allocator}
    state:Skin_Runtime
    defer skin_runtime_free(&state)
    problems:core.Problems
    row:=skin_rig_load(&state,app.assets,app.allocator,id,&problems,core.NONE)
    testing.expect(t,row!=max(u32) && len(state.rigs[row].morphs)==0 && len(state.rigs[row].influences)==0)
    testing.expect_value(t,problems.count,0)
}

// The rooms of the morph targets of a rig, with the memory ending at each
// request in turn: the bind is refused whole with Out_Of_Memory, and with
// memory enough it goes through.
@(test)
morph_bind_without_memory_is_refused_whole :: proc(t:^testing.T) {
    targets:[3]asset.Morph_Target
    names:=[3]string{"Smile","Blink","Frown"}
    for &target,i in targets {
        target.weight=f32(i)*.25
        base.text_set(target.name[:],names[i])
    }
    saved:=context.allocator
    failure:=Runtime_Allocation_Failure{owner=saved}
    for count in 1..=len(targets) {
        rig:=Skin_Rig{id={5,7},revision=1,morphs=targets[:count]}
        state:=Morph_Playing{entity=core.Entity(1),source=core.Entity(2),curve_count=-1}
        bound,refused:=false,false
        for budget in 0..<16 {
            failure.remaining=budget
            context.allocator={runtime_failure_allocator,&failure}
            bound=morph_bind(&state,&rig,{},"Face",1)
            context.allocator=saved
            failure.remaining=1000
            if bound {break}
            refused=true
            testing.expectf(t,state.error==.Out_Of_Memory && len(state.current)==0 && len(state.names)==0 && state.mesh=={},"%d targets with %d requests served: %v, %d bound",count,budget,state.error,len(state.current))
        }
        testing.expectf(t,bound && refused && state.error==.None && len(state.current)==count && len(state.curve_rows)==count,"%d targets: refused without memory, and bound with it",count)
        morph_playing_free(&state)
    }
}
