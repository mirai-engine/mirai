package foliage_editor

import "core:math"
import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import foliage "plugins:foliage/runtime"

// The methods of the foliage for agents and scripts: what the panel does,
// in the edited world, each a step of undo kept unsaved as a stroke of the
// tool is. foliage.paint does what one stroke of the brush does from at to
// to: Paint fills to the density of each type, under its rules, Erase leaves
// erase_density of it, Reapply gives the instances the values of their type
// again, and Generate turns on the generator of the cells.

@(storage)
Foliage_Api :: struct {provider:editor.Api_Provider}

FOLIAGE_API_DEFAULT :: Foliage_Api{provider={register=foliage_api_register}}

Create_Params :: struct {
    name:[128]u8 `mirai:"text,optional,label=The name of its entity and of its file; omitted: Foliage and a number"`,
    at:[3]f32 `mirai:"optional,label=Where its entity stands; omitted: under the target of the view"`,
}

Type_Add_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Foliage"`,
    mesh:base.Asset_Id `mirai:"label=The .mesh it shows"`,
    name:[32]u8 `mirai:"text,optional,label=What names it; omitted: that of its mesh"`,
    density:f32 `mirai:"optional,min=0,unit=1/m2,label=Instances per square metre the generator and Paint place"`,
    scale:[2]f32 `mirai:"optional,label=Across x and z: lowest and highest"`,
    height:[2]f32 `mirai:"optional,label=Along y times the scale across: lowest and highest"`,
    yaw:f32 `mirai:"optional,label=Degrees of a turn at random"`,
    tilt:f32 `mirai:"optional,label=Degrees of a lean at random"`,
    align:f32 `mirai:"optional,min=0,max=1,label=How much it leans with the ground"`,
    offset:[2]f32 `mirai:"optional,label=Metres it sinks (below 0) or rises: lowest and highest"`,
    rule:bool `mirai:"optional,label=It stands only where slope and ground_height and layers take it"`,
    slope:[2]f32 `mirai:"optional,label=Degrees from horizontal of its rule"`,
    ground_height:[2]f32 `mirai:"optional,label=Metres of the ground of its rule in the space of the Foliage"`,
    layers:[foliage.RULE_LAYERS][LAYER_NAME_BYTES]u8 `mirai:"optional,text,label=The layers of the terrain of its rule by their material (a path or its stem; default is one without a material); an empty list takes any"`,
    weight:f32 `mirai:"optional,min=0,max=1,label=Of those layers together at least"`,
    fade_distance:f32 `mirai:"optional,min=0,unit=m"`,
    cull_distance:f32 `mirai:"optional,min=0,unit=m"`,
    wind:f32 `mirai:"optional,min=0"`,
    casts_shadow:bool `mirai:"optional"`,
}

Type_Set_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Foliage"`,
    type:[32]u8 `mirai:"text,label=The type by its name as foliage.query lists them"`,
    name:[32]u8 `mirai:"text,optional,label=Another name; no other type may have it"`,
    mesh:base.Asset_Id `mirai:"optional,label=Another mesh: its instances stay"`,
    density:f32 `mirai:"optional,min=0,unit=1/m2,label=Instances per square metre the generator and Paint place"`,
    scale:[2]f32 `mirai:"optional,label=Across x and z: lowest and highest"`,
    height:[2]f32 `mirai:"optional,label=Along y times the scale across: lowest and highest"`,
    yaw:f32 `mirai:"optional,label=Degrees of a turn at random"`,
    tilt:f32 `mirai:"optional,label=Degrees of a lean at random"`,
    align:f32 `mirai:"optional,min=0,max=1,label=How much it leans with the ground"`,
    offset:[2]f32 `mirai:"optional,label=Metres it sinks (below 0) or rises: lowest and highest"`,
    rule:bool `mirai:"optional,label=It stands only where slope and ground_height and layers take it"`,
    slope:[2]f32 `mirai:"optional,label=Degrees from horizontal of its rule"`,
    ground_height:[2]f32 `mirai:"optional,label=Metres of the ground of its rule in the space of the Foliage"`,
    layers:[foliage.RULE_LAYERS][LAYER_NAME_BYTES]u8 `mirai:"optional,text,label=The layers of the terrain of its rule by their material (a path or its stem; default is one without a material); an empty list takes any"`,
    weight:f32 `mirai:"optional,min=0,max=1,label=Of those layers together at least"`,
    fade_distance:f32 `mirai:"optional,min=0,unit=m"`,
    cull_distance:f32 `mirai:"optional,min=0,unit=m"`,
    wind:f32 `mirai:"optional,min=0"`,
    casts_shadow:bool `mirai:"optional"`,
}

Type_Remove_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Foliage"`,
    type:[32]u8 `mirai:"text,label=The type by its name: it goes with its instances"`,
}

Paint_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Foliage"`,
    mode:[16]u8 `mirai:"text,label=paint or erase or reapply or generate or ungenerate"`,
    at:[3]f32 `mirai:"label=Where the brush touches in the world: the surface under it"`,
    to:[3]f32 `mirai:"optional,label=Where the stroke goes on to touching every half radius"`,
    radius:f32 `mirai:"optional,min=0.1,max=500,unit=m"`,
    types:[8][32]u8 `mirai:"optional,text,label=The types it paints or erases or reapplies by their names; omitted: every type"`,
    density:f32 `mirai:"optional,min=0.01,max=1,label=Of paint: of the density of each type"`,
    erase_density:f32 `mirai:"optional,min=0,max=1,label=Of erase: of the density of each type it leaves"`,
    ground_only:bool `mirai:"optional,label=Of paint: only on the ground of the foliage (a terrain)"`,
}

Place_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Foliage"`,
    type:[32]u8 `mirai:"text,label=The type by its name"`,
    at:[3]f32 `mirai:"label=Where it stands in the world: on the surface under it"`,
}

Query_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Foliage"`,
    min:[3]f32 `mirai:"optional,label=A corner of the box of the world it lists; without min and max: only the types and their counts"`,
    max:[3]f32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=4096,clamp,label=Instances listed at most"`,
}

@(private) LAYER_NAME_BYTES :: 256
@(private) TYPE_OUT_OF_RANGE :: "The type is out of range: densities and distances at least 0, slopes from 0 to 90 degrees, align and weight from 0 to 1"
// What foliage.create answers.
Foliage_Create_Result :: struct {
    id:string,
}

// What foliage.type_add, foliage.type_set, foliage.type_remove, foliage.place answer.
Type_Result :: struct {
    type:string,
}

// What foliage.paint answers.
Foliage_Paint_Result :: struct {
    changed:bool,
}

// What foliage.query answers.
Foliage_Query_Result :: struct {
    types:[]serial.Json,
    instances:[]serial.Json `mirai:"optional"`,
    more:bool `mirai:"optional"`,
}

@(private)
foliage_api_register :: proc(s:^editor.Session) {
    paint_defaults:=Paint_Params{radius=3,density=1}
    query_defaults:=Query_Params{limit=256}
    editor.api_method_register(s,{name="foliage.create",summary="Makes a Foliage in the edited scene, with a .foliage of no types in memory until it is saved; one step of undo takes it away.",params=Create_Params,params_info=type_info_of(Create_Params),result=Foliage_Create_Result,result_info=type_info_of(Foliage_Create_Result),writes_result=true,run=api_create})
    editor.api_method_register(s,{name="foliage.type_add",summary="Adds a type of foliage that shows a mesh with the values it is given, as one step of undo; the name it answers names it in the other methods.",params=Type_Add_Params,params_info=type_info_of(Type_Add_Params),result=Type_Result,result_info=type_info_of(Type_Result),writes_result=true,run=api_type_add})
    editor.api_method_register(s,{name="foliage.type_set",summary="Changes the values of a type of foliage it is given, as one step of undo; the others stay: its mesh, how dense, large, turned and leaned it is, its offset, its rule of slope, height and terrain layers, its distances, wind and shadow.",params=Type_Set_Params,params_info=type_info_of(Type_Set_Params),result=Type_Result,result_info=type_info_of(Type_Result),writes_result=true,run=api_type_set})
    editor.api_method_register(s,{name="foliage.type_remove",summary="Takes a type of foliage out with its instances, as one step of undo.",params=Type_Remove_Params,params_info=type_info_of(Type_Remove_Params),flags={.Destructive},result=Type_Result,result_info=type_info_of(Type_Result),writes_result=true,run=api_type_remove})
    editor.api_method_register(s,{name="foliage.paint",summary="One stroke of the foliage brush from at to to (or at alone), as one step of undo: paint fills the ring to the density of each type under its rules, erase leaves erase_density of it, reapply gives the instances the scale, turn and offset of their type again, generate and ungenerate turn the generator of the cells under the ring on or off.",params=Paint_Params,params_info=type_info_of(Paint_Params),defaults=&paint_defaults,result=Foliage_Paint_Result,result_info=type_info_of(Foliage_Paint_Result),writes_result=true,run=api_paint})
    editor.api_method_register(s,{name="foliage.place",summary="Puts one instance of a type on the surface under a point, with the scale, turn and offset of its type at random, as one step of undo.",params=Place_Params,params_info=type_info_of(Place_Params),result=Type_Result,result_info=type_info_of(Type_Result),writes_result=true,run=api_place})
    editor.api_method_register(s,{name="foliage.query",summary="The types of a Foliage with how many instances each shows, and the instances inside a box of the world: type, where they are, their scale and whether they are manual or generated.",params=Query_Params,params_info=type_info_of(Query_Params),defaults=&query_defaults,flags={.Read_Only},result=Foliage_Query_Result,result_info=type_info_of(Foliage_Query_Result),writes_result=true,run=api_query})
}

// The tool and the edited world with the source of a Foliage ready to edit.
@(private)
api_foliage :: proc(s:^editor.Session,call:^api.Call,named:[]u8) -> (tool:^Foliage_Tool,world:core.World_Ref,e:core.Entity,owner:mm.Transform,ground:^foliage.Ground_Owner,ok:bool) {
    // A Foliage just made takes its place in the world with the next frame.
    given:=base.text_get(named)
    if api_foliage_unplaced(s,&given) {editor.api_settle(s,&given,api_foliage_unplaced)}
    tool=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Foliage_Tool)
    world=editor.edited_world(s)
    table:=core.world_table_of(world,foliage.Foliage);worlds:=core.world_table_of(world,core.World_Transform)
    if tool==nil || table==nil || worlds==nil {api.call_fail(call,api.INVALID_PARAMS,"The project has no foliage: activate the plugin foliage in project.mirai");return}
    tool_ready(tool)
    if tool.stroke.active || tool.gizmo.drag.active {api.call_fail(call,api.INVALID_PARAMS,"A stroke of the foliage tool is held in the viewport: let it go first");return}
    found:bool
    if e,found=editor.api_call_entity(call,world,named);!found {return}
    if !core.has(core.read(table),e) {api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a Foliage: scene.inspect lists them",given);return}
    if !edit_prepare(tool,s.app.assets,s.app.allocator,core.read(table),e) {api.call_failf(call,api.INVALID_PARAMS,"The source of foliage %s could not be read: engine.diagnostics says why",given);return}
    placed,has_place:=core.get(core.read(worlds),e)
    if !has_place {api.call_failf(call,api.INVALID_PARAMS,"Foliage %s has no place in the world: give its entity a Transform with scene.set",given);return}
    owner=placed.transform
    if grounds:=core.world_storage_of(world,foliage.Foliage_Ground);grounds!=nil {ground=foliage.ground_owner(grounds,e)}
    ok=true
    return
}

@(private)
type_write :: proc(call:^api.Call,name:string) {
    serial.text_write_raw(call.out,"{")
    api.write_text(call.out,"type",name,true)
    serial.text_write_raw(call.out,"}")
}

// Whether the entity named (^string) is a Foliage still without a place in the world.
@(private)
api_foliage_unplaced :: proc(s:^editor.Session,user:rawptr) -> bool {
    world:=editor.edited_world(s)
    table:=core.world_table_of(world,foliage.Foliage);worlds:=core.world_table_of(world,core.World_Transform)
    e,_:=editor.api_entity_find(world,(^string)(user)^)
    return table!=nil && worlds!=nil && e!=core.NONE && core.has(core.read(table),e) && !core.has(core.read(worlds),e)
}

@(private)
changed_write :: proc(call:^api.Call,changed:bool) {
    serial.text_write_raw(call.out,"{")
    api.write_bool(call.out,"changed",changed,true)
    serial.text_write_raw(call.out,"}")
}

// The names that tell the types of a source apart: their own, and "#2" on for
// the second that has the same.
@(private)
type_names :: proc(source:^foliage.Source) -> []string {
    names:=make([]string,len(source.types),context.temp_allocator)
    for &t,i in source.types {
        repeated:=1
        for &other in source.types[:i] {if type_name(&other)==type_name(&t) {repeated+=1}}
        names[i]=repeated>1?fmt.tprintf("%s#%d",type_name(&t),repeated):type_name(&t)
    }
    return names
}

// The type of a source a name stands for; nil, with the failure of the call, when none.
@(private)
type_named :: proc(call:^api.Call,source:^foliage.Source,name:string) -> ^foliage.Foliage_Type {
    if len(source.types)==0 {api.call_fail(call,api.INVALID_PARAMS,"The foliage has no type: foliage.type_add adds one");return nil}
    at,problem:=asset.slot_named(type_names(source),nil,name,"types of the foliage")
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return nil}
    return &source.types[at]
}

// The ground of a Foliage as the next frames find it: a terrain just made
// reaches it with them.
@(private)
ground_settled :: proc(s:^editor.Session,e:core.Entity) -> ^foliage.Ground_Owner {
    Waited :: struct {e:core.Entity}
    held :: proc(s:^editor.Session,user:rawptr) -> ^foliage.Ground_Owner {
        grounds:=core.world_storage_of(editor.edited_world(s),foliage.Foliage_Ground)
        return grounds!=nil?foliage.ground_owner(grounds,(^Waited)(user).e):nil
    }
    waited:=Waited{e}
    missing :: proc(s:^editor.Session,user:rawptr) -> bool {
        owner:=held(s,user)
        return owner==nil || owner.layer_count==0
    }
    editor.api_settle(s,&waited,missing)
    return held(s,&waited)
}

// The bits of the layers of its rule that the names of a type stand for.
@(private)
rule_layers :: proc(s:^editor.Session,call:^api.Call,ground:^foliage.Ground_Owner,names:[][LAYER_NAME_BYTES]u8,count:int) -> (bits:u32,ok:bool) {
    for &name in names[:clamp(count,0,len(names))] {
        if ground==nil || ground.layer_count==0 {api.call_fail(call,api.INVALID_PARAMS,"The foliage stands on no terrain, so its rule has no layers to name: make the terrain first");return}
        at,problem:=asset.slot_named(asset.slot_names(&s.app.assets.registry,ground.layers[:ground.layer_count]),ground.layers[:ground.layer_count],base.text_get(name[:]),"layers of the terrain under the foliage")
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
        bits|=1<<u32(at)
    }
    return bits,true
}

// Puts the values the params of a type give on it; they are of its rule and
// of how it shows, what is not given stays.
@(private)
type_values :: proc(call:^api.Call,t:^foliage.Foliage_Type,p:^$T,layers:u32) {
    if editor.tool_call_given(call,"density") {t.density=p.density}
    if editor.tool_call_given(call,"scale") {t.scale={min(p.scale.x,p.scale.y),max(p.scale.x,p.scale.y)}}
    if editor.tool_call_given(call,"height") {t.height={min(p.height.x,p.height.y),max(p.height.x,p.height.y)}}
    if editor.tool_call_given(call,"yaw") {t.yaw=math.to_radians(p.yaw)}
    if editor.tool_call_given(call,"tilt") {t.tilt=math.to_radians(p.tilt)}
    if editor.tool_call_given(call,"align") {t.align=p.align}
    if editor.tool_call_given(call,"offset") {t.offset={min(p.offset.x,p.offset.y),max(p.offset.x,p.offset.y)}}
    if editor.tool_call_given(call,"rule") {t.rule.enabled=p.rule}
    if editor.tool_call_given(call,"slope") {t.rule.slope={math.to_radians(min(p.slope.x,p.slope.y)),math.to_radians(max(p.slope.x,p.slope.y))}}
    if editor.tool_call_given(call,"ground_height") {t.rule.height={min(p.ground_height.x,p.ground_height.y),max(p.ground_height.x,p.ground_height.y)}}
    if editor.tool_call_given(call,"layers") {t.rule.layers=layers}
    if editor.tool_call_given(call,"weight") {t.rule.weight=p.weight}
    if editor.tool_call_given(call,"fade_distance") {t.fade_distance=p.fade_distance}
    if editor.tool_call_given(call,"cull_distance") {t.cull_distance=p.cull_distance}
    if editor.tool_call_given(call,"wind") {t.wind=p.wind}
    if editor.tool_call_given(call,"casts_shadow") {t.casts_shadow=p.casts_shadow}
}

@(private)
api_create :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Create_Params)
    tool:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Foliage_Tool)
    if tool==nil {api.call_fail(call,api.INVALID_PARAMS,"The project has no foliage: activate the plugin foliage in project.mirai");return}
    tool_ready(tool)
    s.toast_length=0
    world:=editor.edited_world(s)
    name:=base.text_get(p.name[:])
    if name!="" {
        if !editor.asset_stem_valid(name) {api.call_failf(call,api.INVALID_PARAMS,"name %q cannot name a file: leave out / \\ : * ? \" < > | and a leading dot",name);return}
        if found,several:=editor.api_entity_find(world,name);found!=core.NONE || several!="" {api.call_failf(call,api.INVALID_PARAMS,"An entity is already named %q: give this one another name, or edit that one",name);return}
    }
    e:=foliage_create(s,tool,world,s.app.assets,s.app.allocator,p.at,editor.tool_call_given(call,"at"),name)
    if e==core.NONE {editor.tool_call_fail(s,call,"The foliage could not be made");return}
    core.world_settle(world)
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_key(w,"id",true);api.write_id(w,editor.api_entity_id(world,e))
    serial.text_write_raw(w,"}")
}

@(private)
api_type_add :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Type_Add_Params)
    tool,world,e,_,ground,ok:=api_foliage(s,call,p.entity[:])
    if !ok {return}
    count,_:=api.params_array_count(call,"layers")
    if count>0 {ground=ground_settled(s,e)}
    layers,named:=rule_layers(s,call,ground,p.layers[:],count)
    if !named {return}
    s.toast_length=0
    t:=type_make(s,tool,s.app.assets,p.mesh,base.text_get(p.name[:]))
    if t==nil {editor.tool_call_fail(s,call,"The type could not be added");return}
    id:=t.id
    type_values(call,t,p,layers)
    source:=&tool.edit.source
    if !foliage.source_valid(source) {foliage.source_type_remove(source,id);api.call_fail(call,api.INVALID_PARAMS,TYPE_OUT_OF_RANGE);return}
    name:=strings.clone(type_name(t),context.temp_allocator)
    if !edit_commit(s,tool,world,s.app.assets,"Add foliage type") {editor.tool_call_fail(s,call,"The type could not be added");return}
    type_write(call,name)
}

@(private)
api_type_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Type_Set_Params)
    tool,world,e,_,ground,ok:=api_foliage(s,call,p.entity[:])
    if !ok {return}
    source:=&tool.edit.source
    t:=type_named(call,source,base.text_get(p.type[:]))
    if t==nil {return}
    count,_:=api.params_array_count(call,"layers")
    if count>0 {ground=ground_settled(s,e)}
    layers,named:=rule_layers(s,call,ground,p.layers[:],count)
    if !named {return}
    if name:=base.text_get(p.name[:]);name!="" && name!=type_name(t) {
        for &other in source.types {
            if other.id!=t.id && type_name(&other)==name {api.call_failf(call,api.INVALID_PARAMS,"Another type is named %q: give this one another name",name);return}
        }
    }
    edit_baseline(tool)
    before:=t^
    if name:=base.text_get(p.name[:]);name!="" {base.text_set(t.name[:],name)}
    if p.mesh!={} {t.mesh,t.prefab,t.materials=p.mesh,{},{}}
    type_values(call,t,p,layers)
    if !foliage.source_valid(source) {t^=before;api.call_fail(call,api.INVALID_PARAMS,TYPE_OUT_OF_RANGE);return}
    final:=strings.clone(type_name(t),context.temp_allocator)
    if t^==before {type_write(call,final);return}
    tool.held_dirty=false
    s.toast_length=0
    if !edit_commit(s,tool,world,s.app.assets,"Foliage type") {editor.tool_call_fail(s,call,"The type could not be kept");return}
    type_write(call,final)
}

@(private)
api_type_remove :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Type_Remove_Params)
    tool,world,_,_,_,ok:=api_foliage(s,call,p.entity[:])
    if !ok {return}
    t:=type_named(call,&tool.edit.source,base.text_get(p.type[:]))
    if t==nil {return}
    id,name:=t.id,strings.clone(type_name(t),context.temp_allocator)
    s.toast_length=0
    if !types_remove(s,tool,world,s.app.assets,{id}) {editor.tool_call_fail(s,call,"The type could not be taken out");return}
    type_write(call,name)
}

@(private)
api_paint :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Paint_Params)
    mode:Foliage_Mode
    generate:=true
    switch strings.to_lower(base.text_get(p.mode[:]),context.temp_allocator) {
    case "paint":      mode=.Paint
    case "erase":      mode=.Erase
    case "reapply":    mode=.Reapply
    case "generate":   mode=.Generate
    case "ungenerate": mode,generate=.Generate,false
    case: api.call_fail(call,api.INVALID_PARAMS,"mode is paint, erase, reapply, generate or ungenerate");return
    }
    tool,world,_,owner,ground,ok:=api_foliage(s,call,p.entity[:])
    if !ok {return}
    source:=&tool.edit.source
    // What the brush of the tool holds goes back to it after the stroke.
    held_prefs,held_painted,held_stroke:=tool.prefs,make([dynamic]u32,0,len(tool.painted),context.temp_allocator),tool.stroke
    append(&held_painted,..tool.painted[:])
    defer {
        tool.prefs=held_prefs
        clear(&tool.painted);append(&tool.painted,..held_painted[:])
        tool.stroke=held_stroke
        clear(&tool.reapplied)
    }
    clear(&tool.painted)
    listed,_:=api.params_array_count(call,"types")
    for &name in p.types[:clamp(listed,0,len(p.types))] {
        t:=type_named(call,source,base.text_get(name[:]))
        if t==nil {return}
        append(&tool.painted,t.id)
    }
    if len(tool.painted)==0 {for t in source.types {append(&tool.painted,t.id)}}
    if len(tool.painted)==0 && mode!=.Generate {api.call_fail(call,api.INVALID_PARAMS,"The foliage has no type: foliage.type_add adds one");return}
    tool.radius,tool.paint_density,tool.erase_density,tool.ground_only=clamp(p.radius,RADIUS_MIN,RADIUS_MAX),clamp(p.density,0.01,1),clamp(p.erase_density,0,1),p.ground_only
    tool.stroke={active=true,mode=mode,generate=generate}
    to_local,inverted:=mm.transform_inverse_matrix(owner)
    if !inverted {api.call_fail(call,api.INVALID_PARAMS,"The transform of the Foliage cannot be inverted");return}
    edit_baseline(tool)
    from,to:=p.at,p.to!={}?p.to:p.at
    step:=to-from
    count:=clamp(int(math.ceil(linalg.length(step)/(tool.radius*STROKE_SPACING))),1,4096)
    changed:=false
    for i in 0..=count {
        point:=from+step*(f32(i)/f32(count))
        if p.to=={} && i>0 {break}
        // The surface under the point, from above it.
        hit:=editor.pick_ray(s,world,mm.Ray{point+{0,tool.radius*4+1000,0},{0,-1,0}},tool.radius*8+2000)
        at,normal:=point,[3]f32{0,1,0}
        if hit.entity!=core.NONE {at,normal=hit.position,hit.normal} else if mode==.Paint {continue}
        changed|=brush_touch(s,tool,world,owner,to_local,ground,at,normal)
    }
    if !changed {changed_write(call,false);return}
    labels:=[Foliage_Mode]string{.Paint="Paint foliage",.Erase="Erase foliage",.Select="",.Place="",.Reapply="Reapply foliage",.Generate="Generate foliage"}
    s.toast_length=0
    if !edit_commit(s,tool,world,s.app.assets,labels[mode]) {editor.tool_call_fail(s,call,"The stroke could not be kept");return}
    changed_write(call,true)
}

@(private)
api_place :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Place_Params)
    tool,world,_,owner,ground,ok:=api_foliage(s,call,p.entity[:])
    if !ok {return}
    source:=&tool.edit.source
    t:=type_named(call,source,base.text_get(p.type[:]))
    if t==nil {return}
    to_local,inverted:=mm.transform_inverse_matrix(owner)
    if !inverted {api.call_fail(call,api.INVALID_PARAMS,"The transform of the Foliage cannot be inverted");return}
    hit:=editor.pick_ray(s,world,mm.Ray{p.at+{0,1000,0},{0,-1,0}},4000)
    at,normal:=p.at,[3]f32{0,1,0}
    if hit.entity!=core.NONE {at,normal=hit.position,hit.normal}
    edit_baseline(tool)
    tool.random+=1
    random:=mm.rng_make(base.hash_u64(tool.random),u64(t.id)+1)
    up:=linalg.normalize0(mm.quat_rotate(conj(owner.rotation),normal))
    paint_instance(source,t,mm.mat4_point(to_local,at),up,&random,ground)
    s.toast_length=0
    placed_name:=strings.clone(type_name(t),context.temp_allocator)
    if !edit_commit(s,tool,world,s.app.assets,"Place foliage instance") {editor.tool_call_fail(s,call,"The instance could not be kept");return}
    type_write(call,placed_name)
}

@(private)
api_query :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Query_Params)
    tool,_,_,owner,ground,ok:=api_foliage(s,call,p.entity[:])
    if !ok {return}
    source:=&tool.edit.source
    w:=call.out
    serial.text_write_raw(w,"{")
    // The counts by type of every cell: each built once.
    counts:=make([]u32,len(source.types),context.temp_allocator)
    listing:=p.min!={} || p.max!={}
    low,high:=linalg.min(p.min,p.max),linalg.max(p.min,p.max)
    listed:=0
    more:=false
    instances:=make([dynamic]foliage.Placed,context.temp_allocator)
    manual:=make([dynamic]bool,context.temp_allocator)
    for &cell in source.cells {
        if !foliage.cell_build(source,&cell,ground_of(ground,cell.coord),&tool.work) {api.call_fail(call,api.SERVER_ERROR,"no memory to place the instances of a cell: free memory and ask again");return}
        for placed in tool.work.placed {
            for t,i in source.types {if t.id==placed.type {counts[i]+=1}}
            if !listing {continue}
            at:=mm.transform_point(owner,placed.position)
            if at.x<low.x || at.y<low.y || at.z<low.z || at.x>high.x || at.y>high.y || at.z>high.z {continue}
            if listed>=int(p.limit) {more=true;continue}
            moved:=placed
            moved.position=at
            append(&instances,moved);append(&manual,placed.id&foliage.MANUAL!=0)
            listed+=1
        }
    }
    names:=type_names(source)
    api.write_key(w,"types",true);serial.text_write_raw(w,"[")
    for &t,i in source.types {
        if i>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        api.write_text(w,"name",names[i],true)
        buffer:[40]u8
        api.write_key(w,"mesh");serial.text_write_string(w,base.asset_id_format(t.mesh,buffer[:]))
        api.write_uint(w,"instances",u64(counts[i]))
        api.write_key(w,"density");api.write_number(w,t.density)
        api.write_bool(w,"rule",t.rule.enabled)
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]")
    if listing {
        api.write_key(w,"instances");serial.text_write_raw(w,"[")
        for placed,i in instances {
            if i>0 {serial.text_write_raw(w,",")}
            serial.text_write_raw(w,"{")
            _,type_at:=foliage.source_type(source,placed.type)
            api.write_text(w,"type",type_at>=0?names[type_at]:"",true)
            api.write_key(w,"position");serial.text_write_raw(w,"[");api.write_number(w,placed.position.x);serial.text_write_raw(w,",");api.write_number(w,placed.position.y);serial.text_write_raw(w,",");api.write_number(w,placed.position.z);serial.text_write_raw(w,"]")
            api.write_key(w,"scale");serial.text_write_raw(w,"[");api.write_number(w,placed.scale[0]);serial.text_write_raw(w,",");api.write_number(w,placed.scale[1]);serial.text_write_raw(w,"]")
            api.write_bool(w,"manual",manual[i])
            serial.text_write_raw(w,"}")
        }
        serial.text_write_raw(w,"]")
        api.write_bool(w,"more",more)
    }
    serial.text_write_raw(w,"}")
}
