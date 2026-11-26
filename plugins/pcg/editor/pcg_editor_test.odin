package pcg_editor

import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"

@(private)
@(test_world,editor="Pcg_Test_Editor",host="Pcg_Test_Shared")
Pcg_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    worlds:core.Table(core.World_Transform),
    graphs:core.Table(pcg.Pcg_Graph),
    zones:core.Table(pcg.Pcg_Zone),
    volumes:core.Table(volume.Volume),
    splines:core.Table(volume.Spline),
    references:core.Table(scene.Scene_Reference),
    highlights:core.Table(erender.Highlight),
    suppressed:core.Table(pcg.Pcg_Suppressed),
    renderers:core.Table(erender.Mesh_Renderer),
    pendings:core.Table(scene.Prefab_Pending),
    instances:core.Table(scene.Prefab_Instance),
    members:core.Table(scene.Prefab_Member),
    data:pcg.Pcg_Data,
    ground:pcg.Pcg_Ground,
    ground_requests:pcg.Pcg_Ground_Requests,
    suppressions:pcg.Pcg_Suppressions,
    suppress:pcg.Pcg_Suppress_Requests,
    promote:pcg.Pcg_Promote_Requests,
    streaming:scene.Streaming_Sources,
    queries:core.Ground_Queries,
    network:core.Network,
}
@(private) Pcg_Test_Editor :: struct {tool:Pcg_Tool}
// What the application keeps by world: the placements of the graphs.
@(private) Pcg_Test_Shared :: struct {generated:core.By_World(pcg.Pcg_Generated)}
@(private="file") TEST_WORLD_ID :: core.World_Id{index=0,generation=1}

// An editor of a project of assets over a world the runtime of pcg runs in
// by hand, without frames: what a handler would see after its frames.
@(private="file")
Fixture :: struct {
    root:string,
    assets:host.Assets,
    world:Pcg_Test_World,
    editor_world:Pcg_Test_Editor,
    shared:Pcg_Test_Shared,
    generated:^pcg.Pcg_Generated,
    app:host.App,
    selection:history.Selection,
    edits:history.Edits,
    document:editor.Document,
    viewport:editor.Viewport,
    gui:editor.Editor_Ui,
    s:editor.Session,
    problems:core.Problems,
    call:api.Call, // how the last call_run went
}

@(private="file")
fixture_open :: proc(t:^testing.T,f:^Fixture,name:string) -> bool {
    f.root=base.test_folder(t,name)
    if f.root=="" {return false}
    if !testing.expect(t,host.assets_init(&f.assets,{root=f.root,capacity=32})) {return false}
    if !test_world_init(t,&f.world) {host.assets_destroy(&f.assets);return false}
    ref:=test_world_ref(&f.world)
    f.world.network.role=.Server
    history.edits_reset(&f.edits,ref)
    f.app=host.App{allocator=context.allocator,assets=&f.assets,info=ref.info,shared=&f.shared}
    append(&f.app.worlds,host.World_Slot{data=&f.world,generation=TEST_WORLD_ID.generation})
    testing.expect(t,core.by_world_attach(&f.shared.generated,TEST_WORLD_ID,pcg.Pcg_Generated{},context.allocator))
    f.generated=core.by_world_get(&f.shared.generated,TEST_WORLD_ID)
    f.s=editor.Session{app=&f.app,info=ref.info,edit_world=&f.world,editor_world=&f.editor_world,assets_root=f.root,headless=true,selection=&f.selection,edits=&f.edits,document=&f.document,viewport=&f.viewport,gui=&f.gui}
    pcg.pcg_requests_serve(&f.world.suppress,&f.world.promote,&f.world.ground_requests,pcg.PCG_SETTINGS_DEFAULT,&f.problems)
    return true
}

@(private="file")
fixture_close :: proc(f:^Fixture) {
    pcg_tool_free(&f.editor_world.tool)
    if f.generated!=nil {pcg.pcg_generated_free(f.generated)}
    core.by_world_release(&f.shared.generated,core.by_world_detach(&f.shared.generated,TEST_WORLD_ID))
    delete(f.shared.generated.entries)
    delete(f.app.worlds)
    test_world_destroy(&f.world)
    delete(f.selection.entities)
    history.edits_free(&f.edits)
    host.assets_destroy(&f.assets)
}

// The places of the world of the entities, as their frames would make them.
@(private="file")
places_settle :: proc(f:^Fixture) {
    w:=&f.world
    test_world_settle(w)
    for row in 0..<core.count(&w.transforms) {
        e:=core.entity_at(&w.transforms,row)
        local:=core.to_math(core.at(&w.transforms,row))
        if place:=core.edit(&w.worlds,e);place!=nil {
            if place.transform!=local {place.transform=local}
        } else {core.add(&w.worlds,e,core.World_Transform{transform=local})}
    }
    test_world_settle(w)
}

// One frame of the runtime of pcg: its sources, what is taken out, the
// ground, then what the graphs place.
@(private="file")
runtime_step :: proc(f:^Fixture,frames:=3) {
    w:=&f.world
    for _ in 0..<frames {
        places_settle(f)
        at:=volume.Where{volumes=core.read(&w.volumes),worlds=core.read(&w.worlds),splines=core.read(&w.splines)}
        spawner:=scene.Spawner{core.commands(w,test_world_info(w)),&f.assets,&f.problems}
        pcg.pcg_load(&w.data,core.read(&w.graphs),&f.assets,context.allocator,&f.problems)
        pcg.pcg_suppress(&w.suppressions,&w.suppress,&w.promote,&w.suppressed,core.read(&w.graphs),core.read(&w.ids),core.read(&w.worlds),core.ref(f.generated),core.ref(&w.network),spawner,context.allocator)
        test_world_settle(w)
        pcg.pcg_ground(&w.ground,&w.ground_requests,core.ref(&w.data),core.read(&w.graphs),core.ref(&w.streaming),core.ref(&w.queries),core.read(&w.zones),at,test_world_ref(w),{phase=.Frame},nil,&f.problems)
        pcg.pcg_update(f.generated,core.ref(&w.data),core.ref(&w.ground),core.ref(&w.suppressions),core.read(&w.graphs),core.read(&w.zones),core.read(&w.ids),at,{phase=.Frame},nil,context.allocator,&f.problems)
        pcg.pcg_requests_serve(&w.suppress,&w.promote,&w.ground_requests,pcg.PCG_SETTINGS_DEFAULT,&f.problems)
    }
}

// A call of a method by hand: raw is the JSON of the params given, which
// says which optional ones are.
@(private="file")
call_run :: proc(f:^Fixture,run:proc(s:^editor.Session,call:^api.Call),params:^$P,$R:typeid,raw:string) -> (result:^R) {
    method:=new(api.Method,context.temp_allocator)
    method^={params_id=P,result_id=R}
    result=new(R,context.temp_allocator)
    call:=api.Call{method=method,params=params,result=result,raw=raw,allocator=context.temp_allocator}
    run(&f.s,&call)
    f.call={failed=call.failed,error=call.error}
    return
}

@(private="file")
entity_named :: proc(params:^$P,name:string) {base.text_set(params.entity[:],name)}

// The source the registry holds for a graph now.
@(private="file")
held_source :: proc(t:^testing.T,f:^Fixture,id:base.Asset_Id,loc:=#caller_location) -> (s:pcg.Pcg_Source) {
    testing.expect_value(t,pcg.data_read(&s,&f.assets,id).kind,pcg.Pcg_Issue_Kind.None,loc=loc)
    return
}

// Undo or redo of the user, and what the editor does in the next frame.
@(private="file")
undo :: proc(t:^testing.T,f:^Fixture,redo:=false,loc:=#caller_location) {
    ref:=test_world_ref(&f.world)
    moved:=history.redo(&f.edits,ref,&f.selection) if redo else history.undo(&f.edits,ref,&f.selection)
    testing.expect(t,moved,loc=loc)
    pcg_sync(&f.s,&f.editor_world.tool,core.read(&f.world.graphs),&f.assets)
}

// Keeps what the last change of a source left as its step of the scene.
@(private="file")
commit :: proc(t:^testing.T,f:^Fixture,loc:=#caller_location) {
    history.edits_commit(&f.edits,test_world_ref(&f.world),&f.selection)
}

// A flat square mesh of 4 m, as a project imports one.
@(private="file")
mesh_write :: proc(t:^testing.T,f:^Fixture,id:base.Asset_Id) {
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for z in 0..=1 {for x in 0..=1 {append(&vertices,asset.Vertex{position={f32(x)*4,0,f32(z)*4},normal=mm.normal_pack({0,1,0}),color=0xffffffff,tangent=mm.tangent_pack({1,0,0},1)})}}
    append(&indices,0,2,1,1,2,3)
    g:asset.Mesh_Geometry
    testing.expect(t,asset.mesh_build_dag({vertices=vertices[:]},indices[:],&g,context.temp_allocator))
    testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/rock.mesh",f.root),&f.assets.types,{id=id,geometry=g}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
}

// A graph named Forest of a new source with one Scatter layer of the mesh,
// within a box of two cells by two, made through the API.
@(private="file")
forest_make :: proc(t:^testing.T,f:^Fixture,mesh:base.Asset_Id) -> (e:core.Entity,source:base.Asset_Id,layer:u32,ok:bool) {
    create:=Create_Params{at={0,0,0},bounds={30,20,30},cell_size=32,seed=7}
    base.text_set(create.name[:],"Forest")
    made:=call_run(f,api_create,&create,Create_Result,`{"name":"Forest","at":[0,0,0],"bounds":[30,20,30],"cell_size":32,"seed":7}`)
    if !testing.expectf(t,!f.call.failed,"%s",f.call.error.message) {return}
    e=core.entity_of(&f.world.entities,made.entity)
    testing.expect(t,core.has(&f.world.graphs,e) && core.has(&f.world.volumes,e))
    testing.expect(t,strings.has_suffix(made.path,"Forest.pcg"),made.path)
    add:=Layer_Params{density=0.02,radius=1,asset=mesh,field_expr="1"}
    entity_named(&add,"Forest");base.text_set(add.op[:],"add")
    added:=call_run(f,api_layer,&add,Layer_Result,`{"entity":"Forest","op":"add","density":0.02,"radius":1,"asset":"x","field_expr":"1"}`)
    if !testing.expectf(t,!f.call.failed,"%s",f.call.error.message) {return}
    commit(t,f)
    places_settle(f)
    return e,made.source,added.layer,true
}

// pcg.create makes the graph and its source as one step; pcg.layer adds,
// sets and removes layers as steps, each a revision of the file, and refuses
// a field or a grammar that does not compile at the byte where it fails,
// changing nothing; pcg.inspect lists the layers with their programs.
@(test)
the_layers_of_a_source_change_through_the_api_one_step_each :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_open(t,f,"pcg-layers") {return}
    defer fixture_close(f)
    e,id,tree,made:=forest_make(t,f,{})
    if !made {return}
    held:=held_source(t,f,id)
    testing.expect(t,len(held.layers)==1 && held.layers[0].id==tree && held.layers[0].field_expr=="1")
    testing.expect_value(t,held.info.revision,u32(2))
    pcg.source_destroy(&held)
    testing.expect_value(t,core.at(&f.world.graphs,0).revision,u32(2))

    // A field that does not compile is refused at its byte, and the source stays.
    Bad :: struct {field,grammar:string,kind:string,offset:int}
    bads:=[]Bad{{field="fbm2(x, z",offset=9},{field="1 + * 2",offset=4},{field="nope(x)",offset=0},{kind="grammar",grammar="[bay, Q]",offset=6},{kind="grammar",grammar="[bay]**",offset=6}}
    for bad in bads {
        p:=Layer_Params{field_expr=bad.field,grammar_expr=bad.grammar}
        entity_named(&p,"Forest");base.text_set(p.op[:],"add")
        raw:=`{"entity":"Forest","op":"add","field_expr":"x"}`
        if bad.kind!="" {
            base.text_set(p.kind[:],bad.kind)
            p.symbols[0]={unit_size=4,scalable=true};base.text_set(p.symbols[0].name[:],"bay")
            raw=`{"entity":"Forest","op":"add","kind":"grammar","grammar_expr":"x","symbols":[{"name":"bay","unit_size":4,"scalable":true}]}`
        }
        call_run(f,api_layer,&p,Layer_Result,raw)
        testing.expectf(t,f.call.failed && f.call.error.code==api.INVALID_PARAMS,"%v is refused",bad)
        testing.expectf(t,strings.contains(f.call.error.message,fmt.tprintf("at byte %d",bad.offset)),"%v: %s",bad,f.call.error.message)
        testing.expectf(t,strings.contains(f.call.error.data,fmt.tprintf(`"offset":%d`,bad.offset)),"%v: %s",bad,f.call.error.data)
        held=held_source(t,f,id)
        testing.expectf(t,len(held.layers)==1 && held.info.revision==2,"%v leaves the source as it was",bad)
        pcg.source_destroy(&held)
        testing.expect_value(t,len(f.editor_world.tool.edit.source.layers),1)
    }

    // A Grammar layer of a fence and a set of the tree, two steps.
    fence:=Layer_Params{grammar_expr="[post, [rail, post]*]"}
    entity_named(&fence,"Forest");base.text_set(fence.op[:],"add");base.text_set(fence.kind[:],"grammar")
    fence.symbols[0]={unit_size=0.2};base.text_set(fence.symbols[0].name[:],"post")
    fence.symbols[1]={unit_size=2,scalable=true};base.text_set(fence.symbols[1].name[:],"rail")
    added:=call_run(f,api_layer,&fence,Layer_Result,`{"entity":"Forest","op":"add","kind":"grammar","grammar_expr":"x","symbols":[{"name":"post","unit_size":0.2},{"name":"rail","unit_size":2,"scalable":true}]}`)
    testing.expectf(t,!f.call.failed && added.layers==2,"%s",f.call.error.message)
    commit(t,f)
    set:=Layer_Params{layer=tree,density=0.04,field_expr="clamp(perlin2(x*0.05, z*0.05) + 0.5, 0, 1)",index=1}
    entity_named(&set,"Forest");base.text_set(set.op[:],"set")
    call_run(f,api_layer,&set,Layer_Result,`{"entity":"Forest","op":"set","layer":1,"density":0.04,"field_expr":"x","index":1}`)
    testing.expectf(t,!f.call.failed,"%s",f.call.error.message)
    commit(t,f)
    held=held_source(t,f,id)
    testing.expect(t,held.info.revision==4 && len(held.layers)==2 && held.layers[1].id==tree && held.layers[1].density==0.04,"the tree moved after the fence and changed")
    pcg.source_destroy(&held)

    // inspect: the programs of each layer and their hashes.
    who:=Entity_Params{};entity_named(&who,"Forest")
    seen:=call_run(f,api_inspect,&who,Inspect_Result,`{"entity":"Forest"}`)
    if testing.expectf(t,!f.call.failed && len(seen.layers)==2,"%s",f.call.error.message) {
        testing.expect(t,seen.valid && seen.revision==4 && seen.cell_size==32 && seen.seed==7)
        testing.expect(t,seen.layers[0].kind=="grammar" && seen.layers[0].grammar_ok && seen.layers[0].grammar_hash!=0 && len(seen.layers[0].symbols)==2)
        testing.expect(t,seen.layers[1].kind=="scatter" && seen.layers[1].field_ok && seen.layers[1].field_hash!=0)
    }

    // Remove, then undo back to the first revision and redo forward.
    remove:=Layer_Params{layer=added.layer}
    entity_named(&remove,"Forest");base.text_set(remove.op[:],"remove")
    call_run(f,api_layer,&remove,Layer_Result,`{"entity":"Forest","op":"remove","layer":2}`)
    testing.expectf(t,!f.call.failed,"%s",f.call.error.message)
    commit(t,f)
    for revision:=u32(4);revision>=2;revision-=1 {
        undo(t,f)
        testing.expect_value(t,core.at(&f.world.graphs,0).revision,revision)
        held=held_source(t,f,id)
        testing.expectf(t,held.info.revision==revision,"the file is at revision %d, not %d",held.info.revision,revision)
        testing.expect(t,revision!=3 || len(held.layers)==2 && held.layers[0].id==tree,"revision 3 holds the tree first and the fence")
        pcg.source_destroy(&held)
    }
    undo(t,f,redo=true);undo(t,f,redo=true);undo(t,f,redo=true)
    held=held_source(t,f,id)
    testing.expect(t,held.info.revision==5 && len(held.layers)==1 && held.layers[0].density==0.04,"redo comes back to the removal")
    pcg.source_destroy(&held)
    testing.expect(t,core.alive(&f.world.entities,e))
}

// A text of a layer compiles as the rows show it: where it fails, by byte.
@(test)
a_text_that_does_not_compile_says_the_byte_where_it_fails :: proc(t:^testing.T) {
    Case :: struct {grammar:bool,text:string,ok:bool,offset:int}
    cases:=[]Case{
        {false,"",true,0},{false,"perlin2(x*0.1, z*0.1)",true,0},{false,"1 +",false,3},{false,"x ** 2",false,3},
        {true,"[bay]*",true,0},{true,"[bay,]",false,5},{true,"",false,0},{true,"[gate]",false,1},
    }
    l:pcg.Pcg_Layer
    l.id=3
    symbols:=[1]pcg.Grammar_Symbol_Def{pcg.grammar_symbol("bay",4,true)}
    l.grammar_symbols=symbols[:]
    for c in cases {
        d:=text_compile(&l,c.grammar,c.text)
        testing.expectf(t,d.ok==c.ok && (c.ok || d.offset==c.offset),"%v: %v at %d (%s)",c,d.ok,d.offset,base.text_get(d.message[:]))
        if !c.ok {testing.expectf(t,base.text_get(d.message[:])!="","%v says why",c)}
    }
}

// pcg.density moves the density of the cells under a disc or a box as one
// step of undo; undo and redo put back what the file held.
@(test)
painting_density_is_one_step_that_undo_takes_back :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_open(t,f,"pcg-density") {return}
    defer fixture_close(f)
    _,id,_,made:=forest_make(t,f,{})
    if !made {return}
    erase:=Density_Params{value=0,strength=1,center={10,0,10},radius=6,falloff=0}
    entity_named(&erase,"Forest")
    painted:=call_run(f,api_density,&erase,Density_Result,`{"entity":"Forest","value":0,"strength":1,"center":[10,0,10],"radius":6,"falloff":0}`)
    if !testing.expectf(t,!f.call.failed && painted.changed && painted.painted_cells==1,"%s %v",f.call.error.message,painted^) {return}
    commit(t,f)
    held:=held_source(t,f,id)
    cell:=pcg.source_cell(&held,{0,0})
    if testing.expect(t,cell!=nil && len(cell.density)==pcg.PAINT_SAMPLES*pcg.PAINT_SAMPLES) {
        testing.expect_value(t,pcg.paint_at(cell,0,32,10,10,false),f32(0))
        testing.expect_value(t,pcg.paint_at(cell,0,32,30,30,false),f32(1))
    }
    pcg.source_destroy(&held)
    // A box over the four cells gives it all back: no painted cell is left.
    fill:=Density_Params{value=1,strength=1,min={-40,0,-40},max={40,0,40}}
    entity_named(&fill,"Forest")
    painted=call_run(f,api_density,&fill,Density_Result,`{"entity":"Forest","value":1,"strength":1,"min":[-40,0,-40],"max":[40,0,40]}`)
    testing.expectf(t,!f.call.failed && painted.changed && painted.painted_cells==0,"%s %v",f.call.error.message,painted^)
    commit(t,f)
    // A disc and a box together, or neither, are refused.
    both:=Density_Params{center={1,0,1},min={0,0,0},max={1,0,1}}
    entity_named(&both,"Forest")
    call_run(f,api_density,&both,Density_Result,`{"entity":"Forest","center":[1,0,1],"min":[0,0,0],"max":[1,0,1]}`)
    testing.expect(t,f.call.failed && strings.contains(f.call.error.message,"disc"))
    undo(t,f)
    held=held_source(t,f,id)
    testing.expect(t,pcg.source_cell(&held,{0,0})!=nil,"undo puts the erased disc back")
    pcg.source_destroy(&held)
    undo(t,f)
    held=held_source(t,f,id)
    testing.expect(t,len(held.cells)==0 && held.info.revision==2,"and then nothing painted")
    pcg.source_destroy(&held)
    undo(t,f,redo=true)
    held=held_source(t,f,id)
    testing.expect(t,len(held.cells)==1,"redo paints it again")
    pcg.source_destroy(&held)
}

// The brush paints toward a value by strength, fading over its falloff, and
// a cell that keeps all of its density goes.
@(test)
the_density_brush_fades_and_drops_cells_left_whole :: proc(t:^testing.T) {
    s:pcg.Pcg_Source
    pcg.source_init(&s)
    defer pcg.source_destroy(&s)
    disc:=Paint_Area{disc=true,center={16,16},radius=8,falloff=0.5}
    Case :: struct {p:[2]f32,w:f32}
    for c in ([]Case{{{16,16},1},{{20,16},1},{{24.5,16},0},{{22,16},0.5}}) {
        testing.expectf(t,abs(area_weight(disc,c.p)-c.w)<1e-3,"%v: %v",c,area_weight(disc,c.p))
    }
    testing.expect(t,density_paint(&s,disc,0,0.5))
    cell:=pcg.source_cell(&s,{0,0})
    if !testing.expect(t,cell!=nil) {return}
    middle:=pcg.paint_at(cell,0,s.info.cell_size,16,16,false)
    testing.expectf(t,abs(middle-0.5)<0.01,"half way at the middle: %v",middle)
    testing.expect_value(t,pcg.paint_at(cell,0,s.info.cell_size,0,0,false),f32(1))
    // Within its falloff a touch moves a sample only part of the way.
    testing.expect(t,density_paint(&s,disc,1,1))
    testing.expect_value(t,len(s.cells),1)
    hard:=disc
    hard.falloff=0
    testing.expect(t,density_paint(&s,hard,1,1))
    testing.expect_value(t,len(s.cells),0)
    testing.expect(t,!density_paint(&s,hard,1,1),"all of it again changes nothing")
    testing.expect(t,!density_paint(&s,Paint_Area{disc=true,center={1e8,0},radius=8},0,1),"past the cells a source holds")
}

// pcg.suppress takes a point out as a row of the scene and puts it back,
// each a step of undo; pcg.sample lists what is placed in a stable order
// with a hash, the same for the same inputs.
@(test)
suppressing_a_point_is_a_scene_step_and_sampling_is_deterministic :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_open(t,f,"pcg-suppress") {return}
    defer fixture_close(f)
    e,_,tree,made:=forest_make(t,f,{})
    if !made {return}
    runtime_step(f)
    box:=Sample_Params{min={-40,-10,-40},max={40,10,40},limit=4096,layer=tree,samples=4}
    entity_named(&box,"Forest")
    raw:=`{"entity":"Forest","min":[-40,-10,-40],"max":[40,10,40],"limit":4096,"layer":1,"samples":4}`
    first:=call_run(f,api_sample,&box,Sample_Result,raw)
    if !testing.expectf(t,!f.call.failed && first.count>0 && first.cells==4 && first.pending==0,"%s %v %v %v",f.call.error.message,first.count,first.cells,first.pending) {return}
    testing.expect(t,len(first.fields)==16)
    for field in first.fields {testing.expectf(t,field.value==1 && field.ground,"%v",field)}
    for i in 1..<len(first.instances) {
        a,b:=first.instances[i-1],first.instances[i]
        testing.expect(t,a.coord!=b.coord || a.id<b.id,"in the order of their cells and ids")
    }
    // Made again from nothing, the graph places the same.
    pcg.pcg_generated_free(f.generated)
    runtime_step(f)
    again:=call_run(f,api_sample,&box,Sample_Result,raw)
    testing.expect(t,!f.call.failed && again.hash==first.hash && again.count==first.count,"the same inputs give the same placements")

    chosen:=first.instances[0]
    point:=Point_Params{coord=chosen.coord,id=chosen.id}
    entity_named(&point,"Forest")
    taken:=call_run(f,api_suppress,&point,Suppress_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    if !testing.expectf(t,!f.call.failed && taken.suppressed && taken.in_cell==1,"%s",f.call.error.message) {return}
    testing.expect_value(t,core.count(&f.world.suppressed),1)
    page:=core.at(&f.world.suppressed,0)
    testing.expect(t,page.coord==chosen.coord && page.count==1 && page.items[0].id==chosen.id)
    parent,_:=core.get(&f.world.parents,core.entity_at(&f.world.suppressed,0))
    testing.expect(t,parent.entity==e,"the row hangs from the graph")
    call_run(f,api_suppress,&point,Suppress_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    testing.expect(t,f.call.failed && strings.contains(f.call.error.message,"already"),"twice is refused")
    runtime_step(f)
    after:=call_run(f,api_sample,&box,Sample_Result,raw)
    testing.expect(t,!f.call.failed && after.count==first.count-1 && after.hash!=first.hash,"the point is gone")
    // Undo puts it back; redo takes it out again; restore puts it back as a step.
    undo(t,f)
    testing.expect_value(t,core.count(&f.world.suppressed),0)
    undo(t,f,redo=true)
    testing.expect_value(t,core.count(&f.world.suppressed),1)
    point.restore=true
    back:=call_run(f,api_suppress,&point,Suppress_Result,`{"entity":"Forest","coord":[0,0],"id":1,"restore":true}`)
    testing.expectf(t,!f.call.failed && !back.suppressed && back.in_cell==0,"%s",f.call.error.message)
    test_world_settle(&f.world)
    testing.expect_value(t,core.count(&f.world.suppressed),0)
    runtime_step(f)
    restored:=call_run(f,api_sample,&box,Sample_Result,raw)
    testing.expect(t,!f.call.failed && restored.hash==first.hash,"put back, it is where it was")
    // A point the cell does not place is refused.
    point.restore,point.id=false,0xdead_beef_0000
    call_run(f,api_suppress,&point,Suppress_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    testing.expect(t,f.call.failed && strings.contains(f.call.error.message,"pcg.sample"))
}

// pcg.promote takes a point out and places its mesh where it stood, one
// step that undo takes back whole.
@(test)
promoting_a_point_places_its_mesh_and_takes_it_out_in_one_step :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_open(t,f,"pcg-promote") {return}
    defer fixture_close(f)
    ROCK :: base.Asset_Id{0x70c6,0x11}
    mesh_write(t,f,ROCK)
    _,_,_,made:=forest_make(t,f,ROCK)
    if !made {return}
    runtime_step(f)
    box:=Sample_Params{min={-40,-10,-40},max={40,10,40},limit=1}
    entity_named(&box,"Forest")
    sampled:=call_run(f,api_sample,&box,Sample_Result,`{"entity":"Forest","min":[-40,-10,-40],"max":[40,10,40],"limit":1}`)
    if !testing.expectf(t,!f.call.failed && len(sampled.instances)==1,"%s",f.call.error.message) {return}
    chosen:=sampled.instances[0]
    testing.expect_value(t,chosen.asset,ROCK)
    entities:=core.count(&f.world.transforms)
    point:=Point_Params{coord=chosen.coord,id=chosen.id}
    entity_named(&point,"Forest")
    promoted:=call_run(f,api_promote,&point,Promote_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    if !testing.expectf(t,!f.call.failed,"%s",f.call.error.message) {return}
    test_world_settle(&f.world)
    spawned:=core.entity_of(&f.world.entities,promoted.entity)
    renderer,shown:=core.get(&f.world.renderers,spawned)
    testing.expect(t,shown && renderer.mesh==ROCK,"the entity shows the mesh of the layer")
    local,_:=core.get(&f.world.transforms,spawned)
    testing.expectf(t,linalg.length(local.position-chosen.position)<1e-4 && abs(linalg.dot(local.rotation,quaternion(x=chosen.rotation.x,y=chosen.rotation.y,z=chosen.rotation.z,w=chosen.rotation.w)))>0.9999,"where it stood: %v %v",local.position,chosen.position)
    testing.expect(t,linalg.length(local.scale-chosen.scale)<1e-4)
    testing.expect_value(t,core.count(&f.world.suppressed),1)
    testing.expect_value(t,core.count(&f.world.transforms),entities+2)
    call_run(f,api_promote,&point,Promote_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    testing.expect(t,f.call.failed && strings.contains(f.call.error.message,"already"),"a point is promoted once")
    // One undo takes both away; redo brings both.
    undo(t,f)
    testing.expect(t,!core.alive(&f.world.entities,spawned) || !core.has(&f.world.renderers,spawned),"the entity goes")
    testing.expect_value(t,core.count(&f.world.suppressed),0)
    testing.expect_value(t,core.count(&f.world.transforms),entities)
    undo(t,f,redo=true)
    testing.expect_value(t,core.count(&f.world.suppressed),1)
    testing.expect_value(t,core.count(&f.world.renderers),1)
}

// The id of a grammar module is a hash, which has AUTHORED_POINT_BIT as
// often as not: such a module is still a generated point, which pcg.suppress
// takes out and puts back by a Pcg_Suppressed row and pcg.promote places,
// the .pcg as it was.
@(test)
a_grammar_module_with_the_authored_bit_in_its_id_is_a_generated_point :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_open(t,f,"pcg-grammar-bit") {return}
    defer fixture_close(f)
    ROCK :: base.Asset_Id{0x70c6,0x33}
    mesh_write(t,f,ROCK)
    _,source_id,_,made:=forest_make(t,f,ROCK)
    if !made {return}
    fence:=Layer_Params{grammar_expr="[post, [rail, post]*]",asset=ROCK}
    entity_named(&fence,"Forest");base.text_set(fence.op[:],"add");base.text_set(fence.kind[:],"grammar")
    fence.symbols[0]={unit_size=0.2};base.text_set(fence.symbols[0].name[:],"post")
    fence.symbols[1]={unit_size=2,scalable=true};base.text_set(fence.symbols[1].name[:],"rail")
    added:=call_run(f,api_layer,&fence,Layer_Result,`{"entity":"Forest","op":"add","kind":"grammar","grammar_expr":"x","asset":"x","symbols":[{"name":"post","unit_size":0.2},{"name":"rail","unit_size":2,"scalable":true}]}`)
    if !testing.expectf(t,!f.call.failed,"%s",f.call.error.message) {return}
    commit(t,f)
    line:=editor.entity_create(&f.s,{name="Fence",transform={position={0,0,5},rotation=1,scale={1,1,1}}})
    core.add(&f.world.zones,line,pcg.PCG_ZONE_DEFAULT)
    core.add(&f.world.splines,line,volume.Spline{count=2,points={0={position={-12,0,0},width=1},1={position={12,0,0},width=1}}})
    places_settle(f)
    commit(t,f)
    runtime_step(f)
    box:=Sample_Params{min={-40,-10,-40},max={40,10,40},limit=4096}
    entity_named(&box,"Forest")
    sampled:=call_run(f,api_sample,&box,Sample_Result,`{"entity":"Forest","min":[-40,-10,-40],"max":[40,10,40],"limit":4096}`)
    if !testing.expectf(t,!f.call.failed,"%s",f.call.error.message) {return}
    chosen:Sample_Instance
    modules:=0
    for inst in sampled.instances {
        if inst.layer!=added.layer {continue}
        modules+=1
        if pcg.point_authored(inst.id) {chosen=inst}
    }
    if !testing.expectf(t,chosen.id!=0,"none of the %d modules of the fence has the bit in its id",modules) {return}
    revision:=f.editor_world.tool.edit.revision

    point:=Point_Params{coord=chosen.coord,id=chosen.id}
    entity_named(&point,"Forest")
    taken:=call_run(f,api_suppress,&point,Suppress_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    if !testing.expectf(t,!f.call.failed && taken.suppressed && taken.in_cell==1,"%s",f.call.error.message) {return}
    test_world_settle(&f.world)
    testing.expect_value(t,core.count(&f.world.suppressed),1)
    point.restore=true
    back:=call_run(f,api_suppress,&point,Suppress_Result,`{"entity":"Forest","coord":[0,0],"id":1,"restore":true}`)
    testing.expectf(t,!f.call.failed && !back.suppressed && back.in_cell==0,"%s",f.call.error.message)
    test_world_settle(&f.world)
    testing.expect_value(t,core.count(&f.world.suppressed),0)

    runtime_step(f)
    point.restore=false
    promoted:=call_run(f,api_promote,&point,Promote_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    if !testing.expectf(t,!f.call.failed,"%s",f.call.error.message) {return}
    test_world_settle(&f.world)
    renderer,shown:=core.get(&f.world.renderers,core.entity_of(&f.world.entities,promoted.entity))
    testing.expect(t,shown && renderer.mesh==ROCK,"the module is placed as an entity")
    testing.expect_value(t,core.count(&f.world.suppressed),1)
    held:=held_source(t,f,source_id)
    testing.expect(t,held.info.revision==revision && pcg.source_point_count(&held)==0,"the .pcg is as it was")
    pcg.source_destroy(&held)
}

// An edit that moves a Pcg_Zone asks the ground of the cells it left and
// reached again, those of the graph under it alone; one far from the graph
// asks nothing, and the first follow only learns where the zones are.
@(test)
moving_a_zone_asks_the_cells_under_it_again :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_open(t,f,"pcg-follow") {return}
    defer fixture_close(f)
    _,_,_,made:=forest_make(t,f,{})
    if !made {return}
    runtime_step(f)
    w:=&f.world
    zone:=core.create(&w.entities)
    core.add(&w.ids,zone,core.Id{value=900})
    core.add(&w.transforms,zone,core.Transform{position={10,0,10},rotation=1,scale={1,1,1}})
    core.add(&w.zones,zone,pcg.PCG_ZONE_DEFAULT)
    core.add(&w.volumes,zone,volume.box({2,2,2}))
    places_settle(f)
    asked :: proc(w:^Pcg_Test_World) -> (cells:[dynamic][2]i32) {
        cells=make([dynamic][2]i32,context.temp_allocator)
        for request in w.ground_requests.cells.items {append(&cells,request.coord)}
        return
    }
    pcg_follow(&f.s)
    testing.expect_value(t,len(asked(w)),0)
    // Into the cell at -1, -1: it and the one it left.
    core.edit(&w.transforms,zone).position={-10,0,-10}
    places_settle(f)
    pcg_follow(&f.s)
    cells:=asked(w)
    testing.expectf(t,len(cells)==2,"%v",cells)
    for c in cells {testing.expectf(t,c=={0,0} || c=={-1,-1},"%v",c)}
    pcg.pcg_requests_serve(&w.suppress,&w.promote,&w.ground_requests,pcg.PCG_SETTINGS_DEFAULT,&f.problems)
    clear(&w.ground_requests.cells.items)
    // Far from the graph, and staying: nothing.
    core.edit(&w.transforms,zone).position={500,0,500}
    places_settle(f)
    pcg_follow(&f.s)
    testing.expectf(t,len(asked(w))==1,"only the cell it left: %v",asked(w))
    clear(&w.ground_requests.cells.items)
    pcg_follow(&f.s)
    testing.expect_value(t,len(asked(w)),0)
}

// pcg.points bulk adds/removes/clears authored points; pcg.absorb converts
// plain entities into authored points and deletes them in one undo step;
// pcg.promote and pcg.suppress on authored points edit the .pcg directly with
// zero Pcg_Suppressed residue; painting full density preserves authored points.
@(test)
authored_points_absorb_promote_suppress_and_undo_leave_zero_residue :: proc(t:^testing.T) {
    f:=new(Fixture);defer free(f)
    if !fixture_open(t,f,"pcg-points-absorb") {return}
    defer fixture_close(f)
    ROCK :: base.Asset_Id{0x70c6,0x22}
    mesh_write(t,f,ROCK)
    create:=Create_Params{at={0,0,0},bounds={30,20,30},cell_size=32,seed=11}
    base.text_set(create.name[:],"Forest")
    made:=call_run(f,api_create,&create,Create_Result,`{"name":"Forest","at":[0,0,0],"bounds":[30,20,30],"cell_size":32,"seed":11}`)
    if !testing.expectf(t,!f.call.failed,"%s",f.call.error.message) {return}
    places_settle(f)
    source_id:=made.source

    // 1. Bulk add via pcg.points auto-creates a density-0 Scatter layer for ROCK.
    pts:Points_Params
    entity_named(&pts,"Forest")
    base.text_set(pts.op[:],"add")
    pts.asset=ROCK
    pts.points[0]={position={4,1,6}}
    pts.points[1]={position={-5,2,-3},scale={2,3,2}}
    add_res:=call_run(f,api_points,&pts,Points_Result,`{"entity":"Forest","op":"add","points":[{"position":[4,1,6]},{"position":[-5,2,-3],"scale":[2,3,2]}]}`)
    if !testing.expectf(t,!f.call.failed && add_res.added==2 && add_res.points==2,"%s",f.call.error.message) {return}
    commit(t,f)
    layer_id:=add_res.layer
    src:=held_source(t,f,source_id)
    testing.expect(t,len(src.layers)==1 && src.layers[0].density==0 && src.layers[0].asset==ROCK)
    pcg.source_destroy(&src)

    // 2. Painting full density back over the cell does NOT delete authored points.
    paint:=Density_Params{value=0,strength=1,center={4,0,6},radius=4}
    entity_named(&paint,"Forest")
    call_run(f,api_density,&paint,Density_Result,`{"entity":"Forest","value":0,"strength":1,"center":[4,0,6],"radius":4}`)
    testing.expect(t,!f.call.failed)
    commit(t,f)
    paint.value=1
    call_run(f,api_density,&paint,Density_Result,`{"entity":"Forest","value":1,"strength":1,"center":[4,0,6],"radius":4}`)
    testing.expect(t,!f.call.failed)
    commit(t,f)
    src=held_source(t,f,source_id)
    testing.expect_value(t,pcg.source_point_count(&src),2)
    pcg.source_destroy(&src)

    // 3. Promoting an authored point spawns an entity and removes it from .pcg with ZERO Pcg_Suppressed!
    runtime_step(f)
    first:=add_res.placed[0]
    prom:=Point_Params{coord=first.coord,id=first.id}
    entity_named(&prom,"Forest")
    prom_res:=call_run(f,api_promote,&prom,Promote_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    if !testing.expectf(t,!f.call.failed,"%s",f.call.error.message) {return}
    test_world_settle(&f.world)
    testing.expect_value(t,core.count(&f.world.suppressed),0)
    src=held_source(t,f,source_id)
    testing.expect_value(t,pcg.source_point_count(&src),1)
    pcg.source_destroy(&src)
    spawned:=core.entity_of(&f.world.entities,prom_res.entity)
    testing.expect(t,core.has(&f.world.renderers,spawned))

    // Single undo deletes the spawned entity and puts the authored point back.
    undo(t,f)
    testing.expect(t,!core.has(&f.world.renderers,spawned))
    src=held_source(t,f,source_id)
    testing.expect_value(t,pcg.source_point_count(&src),2)
    pcg.source_destroy(&src)
    undo(t,f,redo=true)
    test_world_settle(&f.world)
    spawned=core.entity_of(&f.world.entities,prom_res.entity)
    testing.expect(t,core.has(&f.world.renderers,spawned))

    // 4. Move the promoted entity (without settling World_Transform!) and absorb it back:
    // zero Pcg_Suppressed, entity gone, moved point in .pcg at [10, 3, 12].
    // The outline of the selection it has, a derived component, does not keep it out.
    core.edit(&f.world.transforms,spawned).position={10,3,12}
    core.add(&f.world.highlights,spawned,erender.Highlight{level=1})
    test_world_settle(&f.world)
    abs:Absorb_Params
    entity_named(&abs,"Forest")
    base.text_set(abs.entities[0][:],fmt.tprintf("0x%x",u64(prom_res.entity)))
    abs_res:=call_run(f,api_absorb,&abs,Absorb_Result,`{"entity":"Forest","entities":["moved"]}`)
    if !testing.expectf(t,!f.call.failed && abs_res.absorbed==1 && abs_res.layers_added==0,"%s",f.call.error.message) {return}
    test_world_settle(&f.world)
    testing.expect(t,!core.alive(&f.world.entities,spawned))
    testing.expect_value(t,core.count(&f.world.suppressed),0)
    testing.expect_value(t,abs_res.placed[0].layer,layer_id)
    src=held_source(t,f,source_id)
    testing.expect_value(t,pcg.source_point_count(&src),2)
    moved_pt,found_moved:=pcg.source_point_find(&src,abs_res.placed[0].coord,abs_res.placed[0].id)
    testing.expect(t,found_moved && linalg.length(moved_pt.position-[3]f32{10,3,12})<1e-4)
    pcg.source_destroy(&src)

    // Undo of absorb restores the moved entity and removes the absorbed point.
    undo(t,f)
    test_world_settle(&f.world)
    testing.expect_value(t,core.count(&f.world.renderers),1)
    src=held_source(t,f,source_id)
    testing.expect_value(t,pcg.source_point_count(&src),1)
    pcg.source_destroy(&src)
    undo(t,f,redo=true)

    // 5. pcg.suppress on an authored point removes it from .pcg (no Pcg_Suppressed), restore is refused.
    sup:=Point_Params{coord=abs_res.placed[0].coord,id=abs_res.placed[0].id,restore=true}
    entity_named(&sup,"Forest")
    call_run(f,api_suppress,&sup,Suppress_Result,`{"entity":"Forest","coord":[0,0],"id":1,"restore":true}`)
    testing.expect(t,f.call.failed)
    sup.restore=false
    call_run(f,api_suppress,&sup,Suppress_Result,`{"entity":"Forest","coord":[0,0],"id":1}`)
    testing.expect(t,!f.call.failed && core.count(&f.world.suppressed)==0)
    src=held_source(t,f,source_id)
    testing.expect_value(t,pcg.source_point_count(&src),1)
    pcg.source_destroy(&src)

    // 6. pcg.absorb refuses entities with extra components, negative scale, material overrides, or outside Volume.
    bad_e:=editor.entity_create(&f.s,{name="BadProp",transform={position={2,0,2},rotation=1,scale={-1,1,1}}})
    bad_mr:=erender.Mesh_Renderer{mesh=ROCK,shape=.None,shadows=true}
    editor.component_add(&f.s,bad_e,editor.component_table(&f.s,"Mesh_Renderer"),&bad_mr)
    places_settle(f)
    bad_abs:Absorb_Params
    entity_named(&bad_abs,"Forest")
    base.text_set(bad_abs.entities[0][:],"BadProp")
    call_run(f,api_absorb,&bad_abs,Absorb_Result,`{"entity":"Forest","entities":["BadProp"]}`)
    testing.expect(t,f.call.failed && strings.contains(f.call.error.message,"scale"))
    core.edit(&f.world.transforms,bad_e).scale={1,1,1}
    core.edit(&f.world.transforms,bad_e).position={100,0,100} // outside bounds {30,20,30}
    places_settle(f)
    call_run(f,api_absorb,&bad_abs,Absorb_Result,`{"entity":"Forest","entities":["BadProp"]}`)
    testing.expect(t,f.call.failed && strings.contains(f.call.error.message,"Volume"))
    core.edit(&f.world.transforms,bad_e).position={2,0,2}
    core.edit(&f.world.renderers,bad_e).materials[0]={9,9}
    places_settle(f)
    call_run(f,api_absorb,&bad_abs,Absorb_Result,`{"entity":"Forest","entities":["BadProp"]}`)
    testing.expect(t,f.call.failed && strings.contains(f.call.error.message,"material"))
    core.edit(&f.world.renderers,bad_e).materials={}
    core.add(&f.world.zones,bad_e,pcg.PCG_ZONE_DEFAULT)
    places_settle(f)
    call_run(f,api_absorb,&bad_abs,Absorb_Result,`{"entity":"Forest","entities":["BadProp"]}`)
    testing.expect(t,f.call.failed && strings.contains(f.call.error.message,"component"))

    // What the delete would leave in place is refused before the source takes a point: an entity
    // the graph hangs from, and one of a section that is not the one edited.
    core.remove(&f.world.zones,bad_e)
    forest:=core.entity_of(&f.world.entities,made.entity)
    core.add(&f.world.parents,forest,core.Parent{entity=bad_e})
    places_settle(f)
    before:=held_source(t,f,source_id)
    call_run(f,api_absorb,&bad_abs,Absorb_Result,`{"entity":"Forest","entities":["BadProp"]}`)
    testing.expectf(t,f.call.failed && strings.contains(f.call.error.message,"under it"),"%s",f.call.error.message)
    core.remove(&f.world.parents,forest)
    section:=editor.entity_create(&f.s,{name="Section",transform={position={0,0,0},rotation=1,scale={1,1,1}}})
    core.add(&f.world.references,section,scene.Scene_Reference{})
    core.add(&f.world.parents,bad_e,core.Parent{entity=section})
    places_settle(f)
    call_run(f,api_absorb,&bad_abs,Absorb_Result,`{"entity":"Forest","entities":["BadProp"]}`)
    testing.expectf(t,f.call.failed && strings.contains(f.call.error.message,"section"),"%s",f.call.error.message)
    testing.expect(t,core.alive(&f.world.entities,bad_e) && core.has(&f.world.renderers,bad_e),"the entity stays")
    after:=held_source(t,f,source_id)
    testing.expect(t,after.info.revision==before.info.revision && pcg.source_point_count(&after)==pcg.source_point_count(&before),"the .pcg is as it was")
    pcg.source_destroy(&before);pcg.source_destroy(&after)

    // A layer that holds authored points stays a Macro or Meso Scatter layer, and the call says why.
    micro:=Layer_Params{layer=layer_id}
    entity_named(&micro,"Forest");base.text_set(micro.op[:],"set");base.text_set(micro.tier[:],"micro")
    call_run(f,api_layer,&micro,Layer_Result,`{"entity":"Forest","op":"set","layer":1,"tier":"micro"}`)
    testing.expectf(t,f.call.failed && strings.contains(f.call.error.message,"authored points"),"%s",f.call.error.message)

    // 7. pcg.points clear removes remaining authored points.
    clr:Points_Params
    entity_named(&clr,"Forest")
    base.text_set(clr.op[:],"clear")
    clr_res:=call_run(f,api_points,&clr,Points_Result,`{"entity":"Forest","op":"clear"}`)
    testing.expect(t,!f.call.failed && clr_res.removed==1 && clr_res.points==0)
}
