package foliage_editor

import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import foliage "plugins:foliage/runtime"
import pcg "plugins:pcg/runtime"

// The method of the foliage for agents and scripts: what a Foliage draws of
// its graph, read once the graph built the cells it keeps. Editing what it
// places is the graph's (its .pcg); taking an instance out or promoting it
// is pcg.pcg_suppress_request and foliage.foliage_promote.

@(storage)
Foliage_Api :: struct {provider:editor.Api_Provider}

FOLIAGE_API_DEFAULT :: Foliage_Api{provider={register=foliage_api_register}}

Query_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the Foliage"`,
    min:[3]f32 `mirai:"optional,label=A corner of the box of the world it lists; without min and max: only the layers and their counts"`,
    max:[3]f32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=4096,clamp,label=Instances listed at most"`,
}

Foliage_Query_Layer :: struct {
    layer:u32 `mirai:"label=The id of the layer in the source of the graph"`,
    asset:base.Asset_Id `mirai:"label=The mesh or prefab it places"`,
    instances:int `mirai:"label=Of the cells the graph keeps, without what was taken out"`,
    filler:bool `mirai:"label=A lower detail draws fewer of them"`,
    collides:bool,
}
Foliage_Query_Instance :: struct {
    layer:u32,
    coord:[2]i32 `mirai:"label=Its cell: with id, the instance pcg_suppress_request and foliage_promote take"`,
    id:u64,
    position:[3]f32,
    scale:[3]f32,
}
Foliage_Query_Result :: struct {
    cells:int `mirai:"label=The cells the graph keeps near the streaming sources"`,
    layers:[]Foliage_Query_Layer,
    instances:[]Foliage_Query_Instance `mirai:"optional"`,
    more:bool `mirai:"optional"`,
    physics_bytes:int `mirai:"label=Of the collision of every Foliage of the world (Foliage_Physics): what a copy of the world (Play, a rollback) copies of it"`,
}

@(private)
foliage_api_register :: proc(s:^editor.Session) {
    query_defaults:=Query_Params{limit=256}
    editor.api_method_register(s,{name="foliage.query",summary="The layers of the graph of a Foliage with how many instances each places in the cells it keeps, and the instances inside a box of the world: layer, cell and id, where they are and their scale.",params=type_info_of(Query_Params),defaults=&query_defaults,flags={.Read_Only},result=type_info_of(Foliage_Query_Result),run=api_query})
}

// What a Foliage draws of the cells of its graph, into r: the instances of
// each layer, and with listing, those in the box of the world from low to
// high, up to limit, from allocator.
query_fill :: proc(r:^Foliage_Query_Result,s:^pcg.Pcg_Source,gen:^pcg.Generated_Graph,frame:mm.Transform,listing:bool,low,high:[3]f32,limit:int,allocator:=context.allocator) {
    r.layers=make([]Foliage_Query_Layer,len(s.layers),allocator)
    for &l,i in s.layers {r.layers[i]={l.id,l.asset,0,l.filler,l.collides}}
    instances:=make([dynamic]Foliage_Query_Instance,allocator)
    for &cell in gen.cells {
        if !cell.built {continue}
        r.cells+=1
        for p in cell.placed {
            for &l in r.layers {if l.layer==p.layer {l.instances+=1}}
            if !listing {continue}
            at:=mm.transform_point(frame,p.position)
            if at.x<low.x || at.y<low.y || at.z<low.z || at.x>high.x || at.y>high.y || at.z>high.z {continue}
            if len(instances)>=limit {r.more=true;continue}
            append(&instances,Foliage_Query_Instance{p.layer,cell.coord,p.id,at,p.scale*frame.scale})
        }
    }
    if listing {r.instances=instances[:]}
}

@(private)
api_query :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Query_Params)
    given:=base.text_get(p.entity[:])
    world:=editor.edited_world(s)
    foliages,graphs:=core.world_table_of(world,foliage.Foliage),core.world_table_of(world,pcg.Pcg_Graph)
    if foliages==nil || graphs==nil {api.call_fail(call,api.INVALID_PARAMS,"The project has no foliage: activate the plugin foliage in project.mirai");return}
    e,found:=editor.api_call_entity(call,world,p.entity[:])
    if !found {return}
    if !core.has(foliages,e) {api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a Foliage: scene.inspect lists them",given);return}
    if !core.has(graphs,e) {api.call_failf(call,api.INVALID_PARAMS,"%s has no Pcg_Graph, which places what its Foliage draws: give it one with scene.write",given);return}
    editor.api_place_settle(s,e)
    // The frames that build the cells the graph keeps, from inside the handler.
    Settling :: struct {e:core.Entity}
    building :: proc(s:^editor.Session,user:rawptr) -> bool {
        e:=(^Settling)(user).e
        gen:=pcg.generated_graph(host.app_world_storage(s.app,s.edit_world,pcg.Pcg_Generated),e)
        return gen==nil || gen.pending
    }
    settling:=Settling{e}
    editor.api_settle(s,&settling,building)
    world=editor.edited_world(s)
    graph,_:=core.get(core.world_table_of(world,pcg.Pcg_Graph),e)
    placed,has_place:=core.get(core.world_table_of(world,core.World_Transform),e)
    if !has_place {api.call_failf(call,api.INVALID_PARAMS,"Foliage %s has no place in the world: give its entity a place with scene.write",given);return}
    entry:=pcg.data_find(core.world_storage_of(world,pcg.Pcg_Data),graph.source)
    gen:=pcg.generated_graph(host.app_world_storage(s.app,s.edit_world,pcg.Pcg_Generated),e)
    if entry==nil || gen==nil {api.call_failf(call,api.INVALID_PARAMS,"The graph of Foliage %s places nothing yet: its source is not read or not valid; engine.diagnostics says why",given);return}
    r:=api.call_result(call,Foliage_Query_Result)
    listing:=p.min!={} || p.max!={}
    query_fill(r,&entry.source,gen,pcg.graph_frame(graph,placed.transform),listing,linalg.min(p.min,p.max),linalg.max(p.min,p.max),int(p.limit),call.allocator)
    r.physics_bytes=foliage.physics_bytes(core.world_storage_of(world,foliage.Foliage_Physics))
}
