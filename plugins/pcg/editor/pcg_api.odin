package pcg_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg_lib "mirai:std/pcg"
import pcg "plugins:pcg/runtime"

// The methods of pcg for agents and scripts, in the edited world: what the
// rows and the brush do, each change one step of undo, and on an error
// nothing changed. The layers of a source change through the revisions of
// its file (pcg_history.odin); what is taken out of a graph and promoted are
// scene rows, undone by the journal of the scene.

@(storage)
Pcg_Api :: struct {provider:editor.Api_Provider}
PCG_API_DEFAULT :: Pcg_Api{provider={register=pcg_api_register}}

Create_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,optional,label=An entity without a Pcg_Graph that takes one; omitted: a new entity"`,
    name:[128]u8 `mirai:"text,optional,label=The name of the new entity and of the .pcg; omitted: PCG and a number"`,
    at:[3]f32 `mirai:"optional,label=Where the new entity stands; omitted: under the target of the view"`,
    bounds:[3]f32 `mirai:"optional,min=0,unit=m,label=Half the size of a box Volume the graph places within; omitted: no Volume, it places around the streaming sources"`,
    cell_size:f32 `mirai:"optional,min=4,max=256,clamp,unit=m,label=Across a cell of the source"`,
    seed:u32 `mirai:"optional,label=Of the source; omitted: one of its id"`,
    world_anchored:bool `mirai:"optional,label=Its cells are of the world: moving the entity does not move what it places"`,
}

Create_Result :: struct {
    entity:base.Entity_Id,
    source:base.Asset_Id,
    path:string `mirai:"label=Of the .pcg under the assets folder"`,
}

Entity_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Pcg_Graph"`,
}

Inspect_Layer :: struct {
    id:u32,
    kind:string,
    tier:string,
    asset:base.Asset_Id,
    density:f32,
    radius:f32,
    parent_layer:u32,
    channel:u32,
    field_expr:string,
    grammar_expr:string,
    symbols:[]string,
    field_ok:bool,
    field_hash:u64 `mirai:"label=Of its compiled field program: the same on every machine for the same program; 0 without a field"`,
    field_error:string `mirai:"optional"`,
    field_offset:int `mirai:"optional,label=The byte of field_expr where it fails"`,
    grammar_ok:bool,
    grammar_hash:u64 `mirai:"label=Of its compiled grammar; 0 for a layer of another kind"`,
    grammar_error:string `mirai:"optional"`,
    grammar_offset:int `mirai:"optional,label=The byte of grammar_expr where it fails"`,
}

Inspect_Result :: struct {
    source:base.Asset_Id,
    path:string,
    revision:u32,
    seed:u32,
    cell_size:f32,
    world_anchored:bool,
    valid:bool,
    issue:string `mirai:"optional,label=Why the source is not valid"`,
    layers:[]Inspect_Layer,
    painted_cells:int `mirai:"label=Cells a brush painted"`,
    wanted_cells:int `mirai:"label=Cells the graph places in now, near the streaming sources or the view"`,
    built_cells:int `mirai:"label=Of them, those whose placements are made"`,
    placed:int `mirai:"label=What the built cells place"`,
    suppressed:int `mirai:"label=Points taken out of the graph"`,
    suppressed_pages:int `mirai:"label=Pcg_Suppressed entities that hold them"`,
}

Symbol_Param :: struct {
    name:[32]u8 `mirai:"text"`,
    unit_size:f32 `mirai:"min=0,unit=m,label=Length of one module before stretching"`,
    scalable:bool `mirai:"optional,label=It stretches to fill what the others leave"`,
    asset:base.Asset_Id `mirai:"optional,label=What its module places; omitted: the asset of the layer"`,
}

Layer_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Pcg_Graph"`,
    op:[8]u8 `mirai:"text,label=add, set or remove"`,
    layer:u32 `mirai:"optional,label=The id of the layer set or remove change, as pcg.inspect lists them"`,
    index:int `mirai:"optional,min=0,label=Its place among the layers from 0; omitted: add puts it at the end and set leaves it"`,
    kind:[16]u8 `mirai:"text,optional,label=scatter, cascade or grammar; omitted on add: scatter"`,
    tier:[8]u8 `mirai:"text,optional,label=macro, meso or micro"`,
    asset:base.Asset_Id `mirai:"optional,label=What it places: a prefab, which promoting a point spawns, or a mesh"`,
    density:f32 `mirai:"optional,min=0,label=Scatter: points per m2; Cascade: children per parent"`,
    radius:f32 `mirai:"optional,min=0,unit=m,label=At scale 1: no point stands nearer to another of a layer with a radius than both radii"`,
    scale:[2]f32 `mirai:"optional,label=Across x and z: lowest and highest"`,
    height:[2]f32 `mirai:"optional,label=Along y times the scale across: lowest and highest"`,
    yaw:f32 `mirai:"optional,label=Degrees of a turn around y at random"`,
    tilt:f32 `mirai:"optional,label=Degrees of a lean at random"`,
    align:f32 `mirai:"optional,min=0,max=1,label=How much it leans with the ground"`,
    offset:[2]f32 `mirai:"optional,unit=m,label=Along its y at random: lowest and highest"`,
    parent_layer:u32 `mirai:"optional,label=Of a Cascade: the id of the Scatter layer before it it grows around"`,
    channel:u32 `mirai:"optional,max=7,label=Of a Grammar: the Pcg_Zone channel whose Splines it runs along"`,
    collides:bool `mirai:"optional"`,
    filler:bool `mirai:"optional,label=What a lower quality thins first"`,
    dither_group:u16 `mirai:"optional,label=Scatter layers of a tier with the same group above 0 share one set of points"`,
    cull_distance:f32 `mirai:"optional,min=0,unit=m"`,
    fade_distance:f32 `mirai:"optional,min=0,unit=m"`,
    impostor_distance:f32 `mirai:"optional,min=0,unit=m"`,
    rule:bool `mirai:"optional,label=It stands only where slope, ground_height and ground_layers take it"`,
    slope:[2]f32 `mirai:"optional,label=Degrees from horizontal of its rule: lowest and highest"`,
    ground_height:[2]f32 `mirai:"optional,unit=m,label=Of the ground in the frame of the graph for its rule"`,
    ground_layers:[pcg.GROUND_RULE_LAYERS]base.Asset_Id `mirai:"optional,label=The materials of the ground it stands on; none: any"`,
    weight:f32 `mirai:"optional,min=0,max=1,label=Of those ground layers together, at least"`,
    field_expr:string `mirai:"optional,label=Its viability from 0 to 1 (std/pcg field expression); empty: 1 everywhere"`,
    grammar_expr:string `mirai:"optional,label=Of a Grammar layer: how its symbols fill each span"`,
    symbols:[pcg.SYMBOLS_MAX]Symbol_Param `mirai:"optional,label=Of a Grammar layer: the symbols its grammar names"`,
}

Layer_Result :: struct {
    layer:u32,
    layers:int,
}

Density_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Pcg_Graph"`,
    value:f32 `mirai:"optional,min=0,max=1,clamp,label=The density the painted samples go toward: 1 all of that of the layers, 0 none"`,
    strength:f32 `mirai:"optional,min=0,max=1,clamp,label=Of the way to value they go"`,
    center:[3]f32 `mirai:"optional,label=A disc around this point of the world, in x and z; without it, the box of min and max"`,
    radius:f32 `mirai:"optional,min=0.1,max=4096,clamp,unit=m"`,
    falloff:f32 `mirai:"optional,min=0,max=1,clamp,label=Of the radius over which the disc fades out"`,
    min:[3]f32 `mirai:"optional,label=A corner of a box of the world, in x and z"`,
    max:[3]f32 `mirai:"optional"`,
}

Density_Result :: struct {
    changed:bool,
    painted_cells:int,
}

Point_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Pcg_Graph"`,
    coord:[2]i32 `mirai:"label=The cell of the point, as pcg.sample lists it"`,
    id:u64 `mirai:"label=Its stable id in the cell, as pcg.sample lists it"`,
    restore:bool `mirai:"optional,label=Puts a point taken out back"`,
}

Suppress_Result :: struct {
    suppressed:bool,
    in_cell:int `mirai:"label=Points taken out of the cell"`,
}

Promote_Result :: struct {
    entity:base.Entity_Id,
    position:[3]f32,
    rotation:[4]f32 `mirai:"label=x, y, z, w"`,
    scale:[3]f32,
}

Sample_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Pcg_Graph"`,
    min:[3]f32 `mirai:"label=A corner of the box of the world it samples"`,
    max:[3]f32,
    limit:u32 `mirai:"optional,min=1,max=4096,clamp,label=Placements listed at most"`,
    layer:u32 `mirai:"optional,label=A layer whose field it evaluates over a grid of the box, on the ground"`,
    samples:u32 `mirai:"optional,min=1,max=64,clamp,label=Per side of that grid"`,
}

Sample_Instance :: struct {
    coord:[2]i32,
    id:u64,
    layer:u32,
    asset:base.Asset_Id,
    position:[3]f32,
    rotation:[4]f32 `mirai:"label=x, y, z, w"`,
    scale:[3]f32,
}

Sample_Field :: struct {
    position:[3]f32,
    value:f32 `mirai:"label=The viability there, 0 to 1"`,
    ground:bool `mirai:"label=The ground there is known; without it the value is of height 0"`,
}

Sample_Result :: struct {
    instances:[]Sample_Instance,
    count:int `mirai:"label=Placements in the box, listed or not"`,
    more:bool,
    hash:u64 `mirai:"label=Of all the placements of the box: the same inputs give the same hash"`,
    cells:int `mirai:"label=Cells of the box whose placements are made"`,
    pending:int `mirai:"label=Cells of the box the graph wants but has not made yet"`,
    fields:[]Sample_Field `mirai:"optional"`,
}

@(private)
pcg_api_register :: proc(s:^editor.Session) {
    editor.tool_entry(s,TOOL,"PCG",.Sparkle)
    density_defaults:=Density_Params{value=1,strength=1,radius=8}
    sample_defaults:=Sample_Params{limit=256,samples=8}
    create_defaults:=Create_Params{cell_size=pcg.CELL_SIZE_DEFAULT}
    editor.api_method_register(s,{name="pcg.create",summary="Makes a .pcg of no layers and a Pcg_Graph that shows it, on an entity or a new one, as one step of undo.",params=type_info_of(Create_Params),defaults=&create_defaults,result=type_info_of(Create_Result),run=api_create})
    editor.api_method_register(s,{name="pcg.inspect",summary="The layers of the source of a Pcg_Graph with whether their field and grammar compile and the hashes of their programs, and what it paints, places and takes out.",params=type_info_of(Entity_Params),flags={.Read_Only},result=type_info_of(Inspect_Result),run=api_inspect})
    editor.api_method_register(s,{name="pcg.layer",summary="Adds, sets or removes a layer of the source of a Pcg_Graph as one step of undo, refusing a field or grammar that does not compile with the byte where it fails.",params=type_info_of(Layer_Params),result=type_info_of(Layer_Result),run=api_layer})
    editor.api_method_register(s,{name="pcg.density",summary="Moves the density the cells of a Pcg_Graph keep toward a value over a disc or a box of the world, as one stroke of the brush and one step of undo.",params=type_info_of(Density_Params),defaults=&density_defaults,result=type_info_of(Density_Result),run=api_density})
    editor.api_method_register(s,{name="pcg.suppress",summary="Takes a point out of a Pcg_Graph, or puts it back, as a Pcg_Suppressed row of the scene and one step of undo.",params=type_info_of(Point_Params),result=type_info_of(Suppress_Result),run=api_suppress})
    editor.api_method_register(s,{name="pcg.promote",summary="Takes a point out of a Pcg_Graph and places its prefab or mesh as a scene entity where it stood, both in one step of undo.",params=type_info_of(Point_Params),result=type_info_of(Promote_Result),run=api_promote})
    editor.api_method_register(s,{name="pcg.sample",summary="What a Pcg_Graph places in a box of the world, in a stable order with a hash, and the field of a layer over a grid of it.",params=type_info_of(Sample_Params),defaults=&sample_defaults,flags={.Read_Only},result=type_info_of(Sample_Result),run=api_sample})
}

// The tool, the edited world and the graph an entity param names, with its
// source ready to edit; false with the call failed.
@(private)
api_graph :: proc(s:^editor.Session,call:^api.Call,named:[]u8) -> (t:^Pcg_Tool,world:core.World_Ref,e:core.Entity,graph:pcg.Pcg_Graph,ok:bool) {
    t=tool_of(s)
    world=editor.edited_world(s)
    graphs:=core.world_table_of(world,pcg.Pcg_Graph)
    if t==nil || graphs==nil || s.app==nil || s.app.assets==nil {api.call_fail(call,api.INVALID_PARAMS,"The project has no pcg: activate the plugin pcg in project.mirai");return}
    if t.stroke.active {api.call_fail(call,api.INVALID_PARAMS,"A stroke of the PCG brush is held in the viewport: let it go first");return}
    found:bool
    if e,found=editor.api_call_entity(call,world,named);!found {return}
    given:=base.text_get(named)
    if !core.has(graphs,e) {api.call_failf(call,api.INVALID_PARAMS,"%s has no Pcg_Graph: pcg.create gives an entity one",given);return}
    editor.api_place_settle(s,e)
    world=editor.edited_world(s)
    graphs=core.world_table_of(world,pcg.Pcg_Graph)
    graph,_=core.get(graphs,e)
    if graph.source=={} {api.call_failf(call,api.INVALID_PARAMS,"The Pcg_Graph of %s has no source: give Pcg_Graph.source a .pcg, or make one with pcg.create",given);return}
    if !edit_prepare(t,s.app.assets,s.app.allocator,graphs,e) {api.call_failf(call,api.INVALID_PARAMS,"The source of %s cannot be edited: %s",given,issue_text(t.edit.issue));return}
    ok=true
    return
}

@(private)
api_create :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Create_Params)
    t:=tool_of(s)
    world:=editor.edited_world(s)
    graphs:=core.world_table_of(world,pcg.Pcg_Graph)
    a:=s.app.assets if s.app!=nil else nil
    if t==nil || graphs==nil || a==nil {api.call_fail(call,api.INVALID_PARAMS,"The project has no pcg: activate the plugin pcg in project.mirai");return}
    name:=base.text_get(p.name[:])
    if name!="" && !editor.asset_stem_valid(name) {api.call_failf(call,api.INVALID_PARAMS,"name %q cannot name a file: leave out / \\ : * ? \" < > | and a leading dot",name);return}
    e:=core.NONE
    if editor.tool_call_given(call,"entity") {
        found:bool
        if e,found=editor.api_call_entity(call,world,p.entity[:]);!found {return}
        if core.has(graphs,e) {api.call_failf(call,api.INVALID_PARAMS,"%s already has a Pcg_Graph: pcg.layer edits its source",base.text_get(p.entity[:]));return}
    } else if name!="" {
        if found,several:=editor.api_entity_find(world,name);found!=core.NONE || several!="" {api.call_failf(call,api.INVALID_PARAMS,"An entity is already named %q: give this one another name, or name it with entity",name);return}
    }
    if bounds:=p.bounds;editor.tool_call_given(call,"bounds") && !(bounds.x>0 && bounds.y>0 && bounds.z>0) {api.call_fail(call,api.INVALID_PARAMS,"bounds are half the size of a box: each above 0");return}
    s.toast_length=0
    if !editor.api_edit_begin(s,call,"Add PCG graph") {return}
    id,made:=source_file_new(s,t,a,name,name!="",p.seed,clamp(p.cell_size,pcg.CELL_SIZE_MIN,pcg.CELL_SIZE_MAX))
    if !made {editor.tool_call_fail(s,call,"The .pcg could not be written");editor.api_edit_end(s,call,false);return}
    if e==core.NONE {
        at:=p.at if editor.tool_call_given(call,"at") else [3]f32{s.viewport.orbit.target.x,0,s.viewport.orbit.target.z} if s.viewport!=nil else {}
        e=editor.entity_create(s,{name=name!=""?name:"PCG",named=name!="",transform={position=at,rotation=1,scale={1,1,1}}})
        if e==core.NONE {editor.tool_call_fail(s,call,"The entity could not be made");editor.api_edit_end(s,call,false);return}
    }
    value:=pcg.Pcg_Graph{source=id,revision=1,world_anchored=p.world_anchored}
    editor.component_add(s,e,editor.component_table(s,"Pcg_Graph"),&value)
    if editor.tool_call_given(call,"bounds") {
        shape:=volume.box(p.bounds)
        editor.component_add(s,e,editor.component_table(s,"Volume"),&shape)
    }
    core.world_settle(world)
    if !core.has(graphs,e) {api.call_fail(call,api.SERVER_ERROR,"The Pcg_Graph could not be added");editor.api_edit_end(s,call,false);return}
    if !editor.api_edit_end(s,call,true) {return}
    r:=api.call_result(call,Create_Result)
    r.entity,r.source=editor.api_entity_id(world,e),id
    if file,found:=asset.registry_find(&a.registry,id);found {r.path=strings.clone(file.path,call.allocator)}
}

@(private)
api_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Entity_Params)
    t,world,e,graph,ok:=api_graph(s,call,p.entity[:])
    if !ok {return}
    // What the runtime holds is read once it caught up with the source.
    runtime_settle(s,e,{},{},false)
    world=editor.edited_world(s)
    source:=&t.edit.source
    r:=api.call_result(call,Inspect_Result)
    r.source,r.revision,r.seed,r.cell_size,r.world_anchored=graph.source,graph.revision,source.info.seed,source.info.cell_size,graph.world_anchored
    if file,found:=asset.registry_find(&s.app.assets.registry,graph.source);found {r.path=strings.clone(file.path,call.allocator)}
    issue:=pcg.source_issue(source)
    r.valid=issue.kind==.None
    if !r.valid {r.issue=strings.clone(issue_text(issue),call.allocator)}
    r.layers=make([]Inspect_Layer,len(source.layers),call.allocator)
    for &l,i in source.layers {
        o:=&r.layers[i]
        o.id,o.asset,o.density,o.radius,o.parent_layer,o.channel=l.id,l.asset,l.density,l.radius,l.parent_layer,l.channel
        o.kind,o.tier=strings.to_lower(KIND_NAMES[l.kind],call.allocator),strings.to_lower(TIER_NAMES[l.tier],call.allocator)
        o.field_expr=strings.clone(l.field_expr,call.allocator)
        o.grammar_expr=strings.clone(l.grammar_expr,call.allocator)
        o.symbols=make([]string,len(l.grammar_symbols),call.allocator)
        for &def,k in l.grammar_symbols {o.symbols[k]=strings.clone(base.text_get(def.name[:]),call.allocator)}
        o.field_ok,o.grammar_ok=true,true
        if l.field_expr!="" {
            program,err:=pcg_lib.field_compile(l.field_expr,context.temp_allocator)
            o.field_hash,o.field_ok=program.hash,err.kind==.None
            if !o.field_ok {o.field_error,o.field_offset=strings.clone(err.message!=""?err.message:fmt.tprint(err.kind),call.allocator),err.offset}
            pcg_lib.field_program_destroy(&program)
        }
        if l.kind==.Grammar {
            d:=text_compile(&l,true,l.grammar_expr)
            o.grammar_ok=d.ok
            if !d.ok {o.grammar_error,o.grammar_offset=strings.clone(base.text_get(d.message[:]),call.allocator),d.offset} else {
                symbols:=make([]pcg_lib.Grammar_Symbol,len(l.grammar_symbols),context.temp_allocator)
                for &def,k in l.grammar_symbols {symbols[k]={name=base.text_get(def.name[:]),unit_size=def.unit_size,scalable=def.scalable}}
                program,_:=pcg_lib.grammar_compile(l.grammar_expr,symbols,context.temp_allocator)
                o.grammar_hash=program.hash
                pcg_lib.grammar_destroy(&program)
            }
        }
    }
    for cell in source.cells {if len(cell.density)>0 {r.painted_cells+=1}}
    if owner:=pcg.ground_owner(core.world_storage_of(world,pcg.Pcg_Ground),e);owner!=nil {r.wanted_cells=len(owner.cells)}
    if generated:=pcg.generated_graph(generated_of(s,world),e);generated!=nil {
        for &cell in generated.cells {if cell.built {r.built_cells+=1;r.placed+=len(cell.placed)}}
    }
    if pages:=core.world_table_of(world,pcg.Pcg_Suppressed);pages!=nil {
        id:=core.id_of(core.world_table_of(world,core.Id),e)
        for page in pages.values[:core.count(pages)] {
            if id==0 || page.graph!=id {continue}
            r.suppressed_pages+=1
            r.suppressed+=int(min(page.count,pcg.SUPPRESSED_PAGE))
        }
    }
}

// The kind or the tier a text names, as pcg.layer takes them.
@(private)
kind_named :: proc(text:string) -> (kind:pcg.Pcg_Layer_Kind,ok:bool) {
    for name,k in KIND_NAMES {if strings.equal_fold(name,text) {return k,true}}
    return
}
@(private)
tier_named :: proc(text:string) -> (tier:pcg.Pcg_Tier,ok:bool) {
    for name,k in TIER_NAMES {if strings.equal_fold(name,text) {return k,true}}
    return
}

@(private)
api_layer :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Layer_Params)
    // What is made of the frame's memory before api_graph is gone after it: the frames it runs reset it.
    Op :: enum u8 {Add,Set,Remove}
    op:Op
    switch named:=base.text_get(p.op[:]);{
    case strings.equal_fold(named,"add"):    op=.Add
    case strings.equal_fold(named,"set"):    op=.Set
    case strings.equal_fold(named,"remove"): op=.Remove
    case: api.call_fail(call,api.INVALID_PARAMS,"op is add, set or remove");return
    }
    kind,has_kind:=pcg.Pcg_Layer_Kind.Scatter,editor.tool_call_given(call,"kind")
    if has_kind {
        named:bool
        if kind,named=kind_named(base.text_get(p.kind[:]));!named {api.call_fail(call,api.INVALID_PARAMS,"kind is scatter, cascade or grammar");return}
    }
    tier,has_tier:=pcg.Pcg_Tier.Macro,editor.tool_call_given(call,"tier")
    if has_tier {
        named:bool
        if tier,named=tier_named(base.text_get(p.tier[:]));!named {api.call_fail(call,api.INVALID_PARAMS,"tier is macro, meso or micro");return}
    }
    if op!=.Add && p.layer==0 {api.call_failf(call,api.INVALID_PARAMS,"%s names the layer by its id in layer: pcg.inspect lists them","set" if op==.Set else "remove");return}
    t,world,_,_,ok:=api_graph(s,call,p.entity[:])
    if !ok {return}
    a:=s.app.assets
    source:=&t.edit.source
    if !edit_baseline(t) {api.call_fail(call,api.SERVER_ERROR,"There is no memory to keep the PCG history: free memory and call again");return}
    // From here on what fails puts the source back as its head holds it.
    fail :: proc(s:^editor.Session,t:^Pcg_Tool,call:^api.Call,message:string,data:="") {
        edit_cancel(s,t,s.app.assets)
        api.call_fail(call,api.INVALID_PARAMS,message,data)
    }
    id:=p.layer
    label:="Set PCG layer"
    switch op {
    case .Remove:
        if !pcg.source_layer_remove(source,id) {fail(s,t,call,fmt.tprintf("The source has no layer %d: pcg.inspect lists them",id));return}
        label="Remove PCG layer"
    case .Add:
        l:=pcg.source_layer_add(source,kind,tier)
        if l==nil {fail(s,t,call,fmt.tprintf("The source holds %d layers, as many as it can: remove one first",pcg.LAYERS_MAX));return}
        id,label=l.id,"Add PCG layer"
        if kind==.Cascade && !editor.tool_call_given(call,"parent_layer") {
            #reverse for other in source.layers {if other.kind==.Scatter {l.parent_layer=other.id;break}}
        }
    case .Set:
        l,_:=pcg.source_layer(source,id)
        if l==nil {fail(s,t,call,fmt.tprintf("The source has no layer %d: pcg.inspect lists them",id));return}
        if has_kind {l.kind=kind}
        if has_tier {l.tier=tier}
    }
    if op!=.Remove {
        l,at:=pcg.source_layer(source,id)
        layer_values(call,l,p)
        field:=l.field_expr
        grammar:=l.grammar_expr
        symbols:=l.grammar_symbols
        if editor.tool_call_given(call,"field_expr") {field=p.field_expr}
        if editor.tool_call_given(call,"grammar_expr") {grammar=p.grammar_expr}
        if count,given:=api.params_array_count(call,"symbols");given {
            defs:=make([]pcg.Grammar_Symbol_Def,clamp(count,0,len(p.symbols)),context.temp_allocator)
            for &def,k in defs {def=pcg.grammar_symbol(base.text_get(p.symbols[k].name[:]),p.symbols[k].unit_size,p.symbols[k].scalable,p.symbols[k].asset)}
            symbols=defs
        }
        if len(field)>pcg.TEXT_MAX || len(grammar)>pcg.TEXT_MAX {fail(s,t,call,fmt.tprintf("an expression holds %d bytes at most",pcg.TEXT_MAX));return}
        if !pcg.source_layer_texts(source,id,field,grammar,symbols) {api.call_fail(call,api.SERVER_ERROR,"There is no memory for the texts of the layer: free memory and call again");edit_cancel(s,t,a);return}
        l,at=pcg.source_layer(source,id)
        // What a text says fails, at the byte where it does, before the rest of the layer.
        if d:=text_compile(l,false,l.field_expr);!d.ok {
            fail(s,t,call,fmt.tprintf("field_expr of layer %d does not compile at byte %d: %s; fix the expression",id,d.offset,base.text_get(d.message[:])),fmt.tprintf(`{"field":"field_expr","offset":%d,"length":%d}`,d.offset,d.length))
            return
        }
        if l.kind==.Grammar {
            if d:=text_compile(l,true,l.grammar_expr);!d.ok {
                fail(s,t,call,fmt.tprintf("grammar_expr of layer %d does not compile at byte %d: %s; fix the grammar or its symbols",id,d.offset,base.text_get(d.message[:])),fmt.tprintf(`{"field":"grammar_expr","offset":%d}`,d.offset))
                return
            }
        }
        if editor.tool_call_given(call,"index") {
            to:=clamp(p.index,0,len(source.layers)-1)
            held:=source.layers[at]
            ordered_remove(&source.layers,at)
            inject_at(&source.layers,to,held)
            pcg.source_compiled_free(source)
        }
    }
    if issue:=pcg.source_issue(source);issue.kind!=.None {fail(s,t,call,fmt.tprintf("The layer is not kept: %s",issue_text(issue)));return}
    s.toast_length=0
    if !edit_commit(s,t,world,a,label) {editor.tool_call_fail(s,call,"The layer could not be kept");return}
    r:=api.call_result(call,Layer_Result)
    r.layer,r.layers=id if op!=.Remove else 0,len(t.edit.source.layers)
}

// Puts the values the params of a layer give on it; what is not given stays.
@(private)
layer_values :: proc(call:^api.Call,l:^pcg.Pcg_Layer,p:^Layer_Params) {
    given :: editor.tool_call_given
    if given(call,"asset") {l.asset=p.asset}
    if given(call,"density") {l.density=p.density}
    if given(call,"radius") {l.radius=p.radius}
    if given(call,"scale") {l.scale={min(p.scale.x,p.scale.y),max(p.scale.x,p.scale.y)}}
    if given(call,"height") {l.height={min(p.height.x,p.height.y),max(p.height.x,p.height.y)}}
    if given(call,"yaw") {l.yaw=math.to_radians(p.yaw)}
    if given(call,"tilt") {l.tilt=math.to_radians(p.tilt)}
    if given(call,"align") {l.align=p.align}
    if given(call,"offset") {l.offset={min(p.offset.x,p.offset.y),max(p.offset.x,p.offset.y)}}
    if given(call,"parent_layer") {l.parent_layer=p.parent_layer}
    if given(call,"channel") {l.channel=p.channel}
    if given(call,"collides") {l.collides=p.collides}
    if given(call,"filler") {l.filler=p.filler}
    if given(call,"dither_group") {l.dither_group=p.dither_group}
    if given(call,"cull_distance") {l.cull_distance=p.cull_distance}
    if given(call,"fade_distance") {l.fade_distance=p.fade_distance}
    if given(call,"impostor_distance") {l.impostor_distance=p.impostor_distance}
    if given(call,"rule") {l.ground_rule.enabled=p.rule}
    if given(call,"slope") {l.ground_rule.slope={math.to_radians(min(p.slope.x,p.slope.y)),math.to_radians(max(p.slope.x,p.slope.y))}}
    if given(call,"ground_height") {l.ground_rule.height={min(p.ground_height.x,p.ground_height.y),max(p.ground_height.x,p.ground_height.y)}}
    if given(call,"ground_layers") {l.ground_rule.layers=p.ground_layers}
    if given(call,"weight") {l.ground_rule.weight=p.weight}
}

@(private)
api_density :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Density_Params)
    disc:=editor.tool_call_given(call,"center")
    boxed:=editor.tool_call_given(call,"min") && editor.tool_call_given(call,"max")
    if disc==boxed {api.call_fail(call,api.INVALID_PARAMS,"Give center (with radius) for a disc, or min and max for a box");return}
    t,world,e,graph,ok:=api_graph(s,call,p.entity[:])
    if !ok {return}
    place,placed:=core.get(core.world_table_of(world,core.World_Transform),e)
    if !placed {api.call_fail(call,api.INVALID_PARAMS,"The Pcg_Graph has no place in the world: give its entity a Transform");return}
    frame,to_frame,inverted:=graph_frames(graph,place.transform)
    if !inverted {api.call_fail(call,api.INVALID_PARAMS,"The frame of the cells of the Pcg_Graph cannot be inverted: give its entity a scale above 0");return}
    area:Paint_Area
    if disc {
        c:=mm.mat4_point(to_frame,p.center)
        area={disc=true,center=c.xz,radius=clamp(p.radius,0.1,4096)/max(abs(frame.scale.x),1e-6),falloff=clamp(p.falloff,0,1)}
    } else {
        box:=mm.aabb_transform(mm.Aabb{linalg.min(p.min,p.max),linalg.max(p.min,p.max)},to_frame)
        area={low=box.min.xz,high=box.max.xz}
    }
    held:=[2]f32{pcg.POSITION_MAX,pcg.POSITION_MAX}
    low,high:=area.low,area.high
    if disc {low,high=area.center-area.radius,area.center+area.radius}
    if !(abs(low.x)<=held.x && abs(low.y)<=held.y && abs(high.x)<=held.x && abs(high.y)<=held.y) {api.call_failf(call,api.INVALID_PARAMS,"The area reaches past the %.0f m from the origin of the frame of the cells that a source holds: give a nearer one",pcg.POSITION_MAX);return}
    cells_low,cells_high:=area_cells(t.edit.source.info.cell_size,area)
    if i64(cells_high.x-cells_low.x+1)*i64(cells_high.y-cells_low.y+1)>pcg.CELLS_MAX {api.call_failf(call,api.INVALID_PARAMS,"The area covers more than %d cells, what a source paints at most: give a smaller one",pcg.CELLS_MAX);return}
    if !edit_baseline(t) {api.call_fail(call,api.SERVER_ERROR,"There is no memory to keep the PCG history: free memory and call again");return}
    changed:=density_paint(&t.edit.source,area,clamp(p.value,0,1),clamp(p.strength,0,1))
    r:=api.call_result(call,Density_Result)
    if !changed {
        for cell in t.edit.source.cells {if len(cell.density)>0 {r.painted_cells+=1}}
        return
    }
    s.toast_length=0
    if !edit_commit(s,t,world,s.app.assets,"Paint PCG density") {editor.tool_call_fail(s,call,"The density could not be kept");return}
    if requests:=core.world_storage_of(world,pcg.Pcg_Ground_Requests);requests!=nil {ground_ask(core.world_storage_of(world,pcg.Pcg_Ground),requests,e,&t.edit.source,area)}
    r.changed=true
    for cell in t.edit.source.cells {if len(cell.density)>0 {r.painted_cells+=1}}
}

// The rows of the scene that take points out of the cell of a graph.
@(private)
pages_of :: proc(w:core.World_Ref,graph:base.Entity_Id,coord:[2]i32) -> []core.Entity {
    pages:=core.world_table_of(w,pcg.Pcg_Suppressed)
    out:=make([dynamic]core.Entity,context.temp_allocator)
    if pages==nil {return nil}
    for page,row in pages.values[:core.count(pages)] {if page.graph==graph && page.coord==coord {append(&out,core.entity_at(pages,row))}}
    return out[:]
}

// Takes a point out of a graph, or puts it back, in the step that is open:
// into a Pcg_Suppressed of its cell with room, or a new one hanging from the
// graph; a row left empty goes. Why it cannot, or "".
suppress_write :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity,coord:[2]i32,id:u64,restore:bool) -> (in_cell:int,problem:string) {
    pages:=core.world_table_of(w,pcg.Pcg_Suppressed)
    graph:=core.id_of(core.world_table_of(w,core.Id),e)
    if pages==nil {return 0,"The world has no Pcg_Suppressed: activate the plugin pcg in project.mirai"}
    if graph==0 {return 0,"The entity of the Pcg_Graph has no Id, which names it in a saved game and on the network: give it one, as the entities of a scene have"}
    held:=pages_of(w,graph,coord)
    at_page,at_item:=core.NONE,-1
    room:=core.NONE
    for page_e in held {
        page,_:=core.get(pages,page_e)
        count:=int(min(page.count,pcg.SUPPRESSED_PAGE))
        in_cell+=count
        for item,k in page.items[:count] {if item.id==id {at_page,at_item=page_e,k}}
        if count<pcg.SUPPRESSED_PAGE && room==core.NONE {room=page_e}
    }
    if restore {
        if at_page==core.NONE {return in_cell,fmt.tprintf("Point %d of cell %v is not taken out: pcg.inspect counts those that are",id,coord)}
        page:=core.edit(pages,at_page)
        count:=int(min(page.count,pcg.SUPPRESSED_PAGE))
        copy(page.items[at_item:count-1],page.items[at_item+1:count])
        page.items[count-1]={}
        page.count=u32(count-1)
        if page.count==0 {editor.entities_delete(s,{at_page})}
        return in_cell-1,""
    }
    if at_page!=core.NONE {return in_cell,fmt.tprintf("Point %d of cell %v is already taken out: restore puts it back",id,coord)}
    if room!=core.NONE {
        page:=core.edit(pages,room)
        page.items[page.count]={id}
        page.count+=1
        return in_cell+1,""
    }
    made:=editor.entity_create(s,{name="Suppressed",parent=e})
    if made==core.NONE {return in_cell,"The row of what is taken out could not be made"}
    value:=pcg.Pcg_Suppressed{graph=graph,coord=coord,count=1}
    value.items[0]={id}
    editor.component_add(s,made,editor.component_table(s,"Pcg_Suppressed"),&value)
    core.world_settle(w)
    if !core.has(pages,made) {return in_cell,"The row of what is taken out could not be made"}
    return in_cell+1,""
}

// Runs the frames that bring what the runtime holds of a graph up to its
// source as the registry holds it now, from inside a handler (a manual
// editor runs them only on demand): its source read again, its ground read
// and its cells, those from low to high with boxed, placed. False when the
// frames ran out first.
runtime_settle :: proc(s:^editor.Session,e:core.Entity,low,high:[2]i32,boxed:bool) -> bool {
    Waited :: struct {e:core.Entity,low,high:[2]i32,boxed:bool}
    pending :: proc(s:^editor.Session,user:rawptr) -> bool {
        w:=(^Waited)(user)
        world:=editor.edited_world(s)
        graph,shown:=core.get(core.world_table_of(world,pcg.Pcg_Graph),w.e)
        entry:=pcg.data_find(core.world_storage_of(world,pcg.Pcg_Data),graph.source)
        grounds:=core.world_storage_of(world,pcg.Pcg_Ground)
        requests:=core.world_storage_of(world,pcg.Pcg_Ground_Requests)
        if !shown || grounds==nil || requests==nil || s.app==nil {return false}
        if entry==nil || entry.stamp!=pcg.data_stamp(s.app.assets,graph.source) {return true}
        // A source that cannot be read keeps the last one: no frame changes that.
        if len(entry.source.compiled)!=len(entry.source.layers) {return false}
        owner:=pcg.ground_owner(grounds,w.e)
        if owner==nil || owner.epoch!=entry.epoch || owner.loads!=entry.loads {return true}
        for task in grounds.queue {if task.entity==w.e {return true}}
        for asked in requests.cells.items {if asked.entity==w.e {return true}}
        made:=pcg.generated_graph(generated_of(s,world),w.e)
        if made==nil || made.pending || made.ground!=owner.revision || made.wants!=owner.cells_revision {return true}
        // What the rows of the scene take out, indexed and then out of the cells.
        taken:=0
        if pages:=core.world_table_of(world,pcg.Pcg_Suppressed);pages!=nil {
            id:=core.id_of(core.world_table_of(world,core.Id),w.e)
            for page in pages.values[:core.count(pages)] {if id!=0 && page.graph==id {taken+=int(min(page.count,pcg.SUPPRESSED_PAGE))}}
        }
        gone:=pcg.suppressed_owner(core.world_storage_of(world,pcg.Pcg_Suppressions),w.e)
        if (gone==nil?0:len(gone.items))!=taken || made.suppressed!=(gone==nil?0:gone.hash) {return true}
        if !w.boxed {return false}
        for want in owner.cells {
            if want.coord.x<w.low.x || want.coord.y<w.low.y || want.coord.x>w.high.x || want.coord.y>w.high.y {continue}
            if pcg.generated_cell(made,want.coord)==nil {return true}
        }
        return false
    }
    waited:=Waited{e,low,high,boxed}
    return editor.api_settle(s,&waited,pending)
}

// The cell of a graph the runtime placed, made in the next frames if it
// waits for them; nil when it is not placed.
@(private)
cell_settled :: proc(s:^editor.Session,e:core.Entity,coord:[2]i32) -> ^pcg.Generated_Cell {
    runtime_settle(s,e,coord,coord,true)
    return pcg.generated_cell(pcg.generated_graph(generated_of(s,editor.edited_world(s)),e),coord)
}

@(private)
api_suppress :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Point_Params)
    _,world,e,_,ok:=api_graph(s,call,p.entity[:])
    if !ok {return}
    if !p.restore {
        cell:=cell_settled(s,e,p.coord)
        world=editor.edited_world(s)
        if cell!=nil {
            if _,placed:=pcg.placed_find(cell.placed[:],p.id);!placed && !point_taken(world,e,p.coord,p.id) {
                api.call_failf(call,api.INVALID_PARAMS,"Cell %v places no point %d: pcg.sample lists what it places",p.coord,p.id)
                return
            }
        }
    }
    if !editor.api_edit_begin(s,call,"Restore PCG point" if p.restore else "Suppress PCG point") {return}
    in_cell,problem:=suppress_write(s,world,e,p.coord,p.id,p.restore)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);editor.api_edit_end(s,call,false);return}
    if !editor.api_edit_end(s,call,true) {return}
    r:=api.call_result(call,Suppress_Result)
    r.suppressed,r.in_cell=!p.restore,in_cell
}

// Whether a point of a cell of a graph is taken out by a row of the scene.
@(private)
point_taken :: proc(w:core.World_Ref,e:core.Entity,coord:[2]i32,id:u64) -> bool {
    pages:=core.world_table_of(w,pcg.Pcg_Suppressed)
    graph:=core.id_of(core.world_table_of(w,core.Id),e)
    if pages==nil || graph==0 {return false}
    for page_e in pages_of(w,graph,coord) {
        page,_:=core.get(pages,page_e)
        for item in page.items[:min(page.count,pcg.SUPPRESSED_PAGE)] {if item.id==id {return true}}
    }
    return false
}

@(private)
api_promote :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Point_Params)
    if p.restore {api.call_fail(call,api.INVALID_PARAMS,"restore belongs to pcg.suppress: a promoted point comes back by undo, or by deleting its entity and pcg.suppress with restore");return}
    _,world,e,graph,ok:=api_graph(s,call,p.entity[:])
    if !ok {return}
    if point_taken(world,e,p.coord,p.id) {api.call_failf(call,api.INVALID_PARAMS,"Point %d of cell %v is already taken out: pcg.suppress with restore puts it back first",p.id,p.coord);return}
    cell:=cell_settled(s,e,p.coord)
    world=editor.edited_world(s)
    if cell==nil {api.call_failf(call,api.INVALID_PARAMS,"Cell %v of the Pcg_Graph is not placed: only the cells near the streaming sources and the view are; pcg.sample says which are",p.coord);return}
    placed,found:=pcg.placed_find(cell.placed[:],p.id)
    if !found {api.call_failf(call,api.INVALID_PARAMS,"Cell %v places no point %d: pcg.sample lists what it places",p.coord,p.id);return}
    if placed.asset=={} {api.call_failf(call,api.INVALID_PARAMS,"Layer %d places no asset, so point %d has nothing to promote: give the layer a prefab or a mesh with pcg.layer",placed.layer,p.id);return}
    a:=s.app.assets
    file,known:=asset.registry_find(&a.registry,placed.asset)
    prefab:=known && asset.registry_prefab(file)
    if !known || !prefab && file.kind!=asset.KIND_MESH {api.call_failf(call,api.INVALID_PARAMS,"The asset of layer %d is neither a prefab nor a mesh of the project: give the layer one with pcg.layer",placed.layer);return}
    world_place:=core.get(core.world_table_of(world,core.World_Transform),e) or_else core.World_Transform{transform=mm.TRANSFORM_IDENTITY}
    at:=mm.transform_compose(pcg.graph_frame(graph,world_place.transform),mm.Transform{position=placed.position,rotation=placed.rotation,scale=placed.scale})
    if !editor.api_edit_begin(s,call,"Promote PCG point") {return}
    if _,problem:=suppress_write(s,world,e,p.coord,p.id,false);problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);editor.api_edit_end(s,call,false);return}
    spawned:=core.NONE
    if prefab {
        rotation:=[4]f32{at.rotation.x,at.rotation.y,at.rotation.z,at.rotation.w}
        root,error:=editor.prefab_instantiate(s,placed.asset,{position=at.position,rotation=rotation,scale_multiplier=at.scale},true)
        if error!=.None {api.call_failf(call,api.INVALID_PARAMS,"The prefab of layer %d could not be placed: %s",placed.layer,editor.prefab_error_text(error));editor.api_edit_end(s,call,false);return}
        spawned=core.entity_of(core.world_entities(world),root)
    } else {
        spawned=editor.entity_create(s,{name=editor.asset_name_of(a,placed.asset,"Promoted"),transform={position=at.position,rotation=at.rotation,scale=at.scale}})
        if spawned!=core.NONE {
            shown:=erender.Mesh_Renderer{mesh=placed.asset,shape=.None,shadows=true}
            editor.component_add(s,spawned,editor.component_table(s,"Mesh_Renderer"),&shown)
        }
    }
    if spawned==core.NONE {api.call_fail(call,api.SERVER_ERROR,"The promoted entity could not be made");editor.api_edit_end(s,call,false);return}
    if !editor.api_edit_end(s,call,true) {return}
    r:=api.call_result(call,Promote_Result)
    r.entity=editor.api_entity_id(world,spawned)
    r.position,r.rotation,r.scale=at.position,{at.rotation.x,at.rotation.y,at.rotation.z,at.rotation.w},at.scale
}

@(private)
api_sample :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Sample_Params)
    _,world,e,graph,ok:=api_graph(s,call,p.entity[:])
    if !ok {return}
    place,placed:=core.get(core.world_table_of(world,core.World_Transform),e)
    if !placed {api.call_fail(call,api.INVALID_PARAMS,"The Pcg_Graph has no place in the world: give its entity a Transform");return}
    frame,to_frame,inverted:=graph_frames(graph,place.transform)
    if !inverted {api.call_fail(call,api.INVALID_PARAMS,"The frame of the cells of the Pcg_Graph cannot be inverted: give its entity a scale above 0");return}
    data:=core.world_storage_of(world,pcg.Pcg_Data)
    entry:=pcg.data_find(data,graph.source)
    if entry==nil || len(entry.source.compiled)!=len(entry.source.layers) {api.call_fail(call,api.INVALID_PARAMS,"The runtime shows no source for the Pcg_Graph yet: engine.diagnostics says why");return}
    source:=&entry.source
    low_world,high_world:=linalg.min(p.min,p.max),linalg.max(p.min,p.max)
    box:=mm.aabb_transform(mm.Aabb{low_world,high_world},to_frame)
    if !(abs(box.min.x)<=pcg.POSITION_MAX && abs(box.min.z)<=pcg.POSITION_MAX && abs(box.max.x)<=pcg.POSITION_MAX && abs(box.max.z)<=pcg.POSITION_MAX) {api.call_failf(call,api.INVALID_PARAMS,"The box reaches past the %.0f m from the origin of the frame of the cells: give a nearer one",pcg.POSITION_MAX);return}
    low,_:=pcg.cell_of(source.info.cell_size,box.min.xz)
    high,_:=pcg.cell_of(source.info.cell_size,box.max.xz)
    if i64(high.x-low.x+1)*i64(high.y-low.y+1)>4096 {api.call_fail(call,api.INVALID_PARAMS,"The box covers more than 4096 cells: give a smaller one");return}
    // The cells of the box the graph wants are made first.
    runtime_settle(s,e,low,high,true)
    // The frames moved what the world holds: read it again.
    world=editor.edited_world(s)
    entry=pcg.data_find(core.world_storage_of(world,pcg.Pcg_Data),graph.source)
    if entry==nil || len(entry.source.compiled)!=len(entry.source.layers) {api.call_fail(call,api.INVALID_PARAMS,"The runtime shows no source for the Pcg_Graph now: engine.diagnostics says why");return}
    source=&entry.source
    generated:=pcg.generated_graph(generated_of(s,world),e)
    owner:=pcg.ground_owner(core.world_storage_of(world,pcg.Pcg_Ground),e)
    r:=api.call_result(call,Sample_Result)
    if owner!=nil {
        for want in owner.cells {
            if want.coord.x<low.x || want.coord.y<low.y || want.coord.x>high.x || want.coord.y>high.y {continue}
            if pcg.generated_cell(generated,want.coord)==nil {r.pending+=1}
        }
    }
    found:=make([dynamic]Sample_Instance,context.temp_allocator)
    for z in low.y..=high.y {for x in low.x..=high.x {
        cell:=pcg.generated_cell(generated,{x,z})
        if cell==nil {continue}
        r.cells+=1
        for q in cell.placed {
            at:=mm.transform_compose(frame,mm.Transform{position=q.position,rotation=q.rotation,scale=q.scale})
            if at.position.x<low_world.x || at.position.y<low_world.y || at.position.z<low_world.z || at.position.x>high_world.x || at.position.y>high_world.y || at.position.z>high_world.z {continue}
            append(&found,Sample_Instance{coord={x,z},id=q.id,layer=q.layer,asset=q.asset,position=at.position,rotation={at.rotation.x,at.rotation.y,at.rotation.z,at.rotation.w},scale=at.scale})
        }
    }}
    slice.sort_by(found[:],proc(a,b:Sample_Instance) -> bool {
        if a.coord!=b.coord {return a.coord.y<b.coord.y || a.coord.y==b.coord.y && a.coord.x<b.coord.x}
        return a.id<b.id
    })
    h:=base.HASH_SEED
    for &q in found {h=base.hash64(([^]byte)(&q)[:size_of(q)],h)}
    r.count,r.hash=len(found),h
    n:=min(len(found),int(clamp(p.limit,1,4096)))
    r.instances=make([]Sample_Instance,n,call.allocator)
    copy(r.instances,found[:n])
    r.more=n<len(found)
    if !editor.tool_call_given(call,"layer") {return}
    fields,problem:=field_grid(world,e,graph,frame,to_frame,source,owner,p.layer,low_world,high_world,int(clamp(p.samples,1,64)),call)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    r.fields=fields
}

// The viability of a layer at a grid of samples by samples points of a box
// of the world, on the ground of the graph, as its field reads it there: the
// height and slope of the ground, the masks of the zones, the ecotopes of the
// paint, and an occupancy of 0.
@(private)
field_grid :: proc(world:core.World_Ref,e:core.Entity,graph:pcg.Pcg_Graph,frame:mm.Transform,to_frame:mm.Mat4,source:^pcg.Pcg_Source,owner:^pcg.Pcg_Ground_Owner,layer:u32,low,high:[3]f32,samples:int,call:^api.Call) -> (fields:[]Sample_Field,problem:string) {
    l,at:=pcg.source_layer(source,layer)
    if l==nil {return nil,fmt.tprintf("The source has no layer %d: pcg.inspect lists them",layer)}
    c:=&source.compiled[at]
    fields=make([]Sample_Field,samples*samples,call.allocator)
    zones:=zones_placed(world)
    cell_size:=source.info.cell_size
    ecotopes:=int(source.info.ecotopes)
    xs,ys,zs,heights,slopes,occupancy,out:[pcg_lib.TILE]f32
    masks:[pcg.MASKS_MAX][pcg_lib.TILE]f32
    eco:[pcg.ECOTOPES_MAX][pcg_lib.TILE]f32
    scratch:=new(pcg_lib.Field_Scratch,context.temp_allocator)
    if scratch==nil {return nil,"There is no memory to evaluate the field: free memory and call again"}
    for start:=0;start<len(fields);start+=pcg_lib.TILE {
        n:=min(pcg_lib.TILE,len(fields)-start)
        for k in 0..<n {
            i,j:=(start+k)%samples,(start+k)/samples
            u:=f32(i)+0.5
            v:=f32(j)+0.5
            point:=[3]f32{low.x+(high.x-low.x)*u/f32(samples),0,low.z+(high.z-low.z)*v/f32(samples)}
            local:=mm.mat4_point(to_frame,point)
            coord,in_cell:=pcg.cell_of(cell_size,local.xz)
            ground,_:=pcg.ground_cell(owner,coord)
            height,normal,known:=pcg.ground_at(ground,in_cell.x,in_cell.y)
            if !known {height,normal=0,{0,1,0}}
            local.y=height
            xs[k],ys[k],zs[k],heights[k]=local.x,height,local.z,height
            slopes[k]=math.acos(clamp(normal.y,-1,1))
            occupancy[k]=0
            world_point:=mm.transform_point(frame,local)
            for ch in 0..<pcg.MASKS_MAX {masks[ch][k]=pcg.zone_mask(zones,u32(ch),world_point)}
            paint:=pcg.source_cell(source,coord)
            for ec in 0..<ecotopes {eco[ec][k]=pcg.paint_at(paint,ec,cell_size,in_cell.x,in_cell.y,true)}
            fields[start+k]={position=world_point,ground=known}
        }
        if !c.has_field {
            for k in 0..<n {fields[start+k].value=1}
            continue
        }
        mask_slices:[pcg.MASKS_MAX][]f32
        eco_slices:[pcg.ECOTOPES_MAX][]f32
        for ch in 0..<pcg.MASKS_MAX {mask_slices[ch]=masks[ch][:n]}
        for ec in 0..<ecotopes {eco_slices[ec]=eco[ec][:n]}
        inputs:=pcg_lib.Field_Inputs{x=xs[:n],y=ys[:n],z=zs[:n],height=heights[:n],slope=slopes[:n],occupancy=occupancy[:n],masks=mask_slices[:],ecotopes=eco_slices[:]}
        if pcg_lib.field_eval_tile(&c.field,inputs,out[:n],scratch)!=.None {return nil,"The field program of the layer does not run: pcg.inspect says how it compiled"}
        for k in 0..<n {
            value:=out[k]
            fields[start+k].value=value>0?min(value,1):0
        }
    }
    return fields,""
}

// The zones that give masks in a world, in the order they apply: by
// priority, then the bigger first.
@(private)
zones_placed :: proc(w:core.World_Ref) -> []pcg.Pcg_Zone_Placed {
    out:=make([dynamic]pcg.Pcg_Zone_Placed,context.temp_allocator)
    zones:=core.world_table_of(w,pcg.Pcg_Zone)
    if zones==nil {return nil}
    at:=where_of(w)
    for row in 0..<core.count(zones) {
        zone:=core.at(zones,row)
        if zone.exclude {continue}
        if v,pose,outline,ok:=volume.placed(at,core.entity_at(zones,row));ok {
            append(&out,pcg.Pcg_Zone_Placed{region={v,pose,outline},zone=zone.zone,channel=zone.channel,weight=clamp(zone.weight,0,1),box=volume.bounds(v,pose,outline)})
        }
    }
    slice.sort_by(out[:],proc(a,b:pcg.Pcg_Zone_Placed) -> bool {
        if a.zone.priority!=b.zone.priority {return a.zone.priority<b.zone.priority}
        return volume.size(a.region.volume,a.region.pose,a.region.outline)>volume.size(b.region.volume,b.region.pose,b.region.outline)
    })
    return out[:]
}
