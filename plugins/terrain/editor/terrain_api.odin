package terrain_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:ui"
import "mirai:editor/api"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"

// The methods of the terrain for agents and scripts: what the panel does, by
// what it does, in the edited world, each a step of undo as a stroke of the
// tool is. A stroke goes from at to to, touching every quarter
// of the radius, with what one pass of the tool does at each point. While a
// game of the caller plays, terrain.edit and terrain.layer are requests of
// that game instead (dig, request_layer), which it applies in its
// next tick as its own.

@(storage)
Terrain_Api :: struct {provider:editor.Api_Provider}

TERRAIN_API_DEFAULT :: Terrain_Api{provider={register=terrain_api_register}}

Create_Params :: struct {
    name:[128]u8 `mirai:"text,optional,label=The name of its entity and of its file; omitted: of its kind and a number"`,
    kind:[16]u8 `mirai:"text,optional,label=heightfield (open ground) or volume (caves, overhangs and digging); omitted: heightfield"`,
    samples:u32 `mirai:"optional,min=3,max=16385,label=Samples on a side over x and z"`,
    depth:u32 `mirai:"optional,min=3,max=16385,label=Samples along y of a volume"`,
    spacing:f32 `mirai:"optional,min=0.01,max=100,unit=m,label=Between two samples"`,
    chunk_cells:u32 `mirai:"optional,min=4,max=256,label=Cells on a side of a chunk"`,
    heightmap:[512]u8 `mirai:"text,optional,label=A PNG (16-bit too) or TGA or BMP of the project whose heights it takes in place of samples"`,
    height_scale:f32 `mirai:"optional,unit=m,label=How far the white of the heightmap stands over its black"`,
    height_offset:f32 `mirai:"optional,unit=m,label=The height of its black"`,
    at:[3]f32 `mirai:"optional,label=Where its entity stands, the center of the terrain; omitted: under the target of the view"`,
    ground:editor.Api_Entity_Text `mirai:"text,entity,optional,label=Of a volume: a Heightfield terrain it joins, standing on its samples and centered at at, its field its ground to dig into; it takes the spacing of the Heightfield"`,
}

Edit_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the terrain"`,
    brush:[16]u8 `mirai:"text,label=raise or lower or smooth or flatten or set_height or ramp or terrace or noise or erode or paint or erase or hole or fill or add or carve"`,
    at:[3]f32 `mirai:"label=Where it touches in the world; on a Heightfield the surface under its x and z"`,
    to:[3]f32 `mirai:"optional,label=Where the stroke goes on to; the other end of a ramp (at its height) or of a capsule"`,
    radius:f32 `mirai:"optional,min=0.1,max=500,unit=m"`,
    strength:f32 `mirai:"optional,min=0,max=1,label=What one pass does"`,
    passes:u32 `mirai:"optional,min=1,max=64,label=Passes over each point"`,
    falloff:[16]u8 `mirai:"text,optional,label=smooth or sphere or linear or sharp or flat"`,
    hardness:f32 `mirai:"optional,min=0,max=0.95,label=The part of the radius at full weight"`,
    height:f32 `mirai:"optional,unit=m,label=Of set_height in the world; omitted: the height under at"`,
    way:[8]u8 `mirai:"text,optional,label=both or raise or lower: what smooth and flatten and terrace and noise may do"`,
    capped:bool `mirai:"optional,label=raise and lower of a Heightfield stop at the height under at"`,
    interval:f32 `mirai:"optional,min=0.01,unit=m,label=Of terrace: between its steps"`,
    riser:f32 `mirai:"optional,min=0,max=1,label=Of terrace: the part of each step that rises"`,
    scale:f32 `mirai:"optional,min=0.1,unit=m,label=Of noise: across its features"`,
    sides:f32 `mirai:"optional,min=0,unit=m,label=Of ramp: how far its sides fall off past its radius"`,
    slope:[2]f32 `mirai:"optional,label=Degrees from horizontal of the Heightfield it touches: lowest and highest; omitted: any"`,
    slope_invert:bool `mirai:"optional,label=It touches outside slope instead"`,
    layer:[LAYER_NAME_BYTES]u8 `mirai:"text,optional,label=Of paint and erase, and of add on a Volume: the layer by its material (a path or its stem; default is one without a material); omitted: the first"`,
    weight:f32 `mirai:"optional,min=0,max=1,label=Of paint: the weight it takes the layer to in place of adding to it"`,
    shape:[16]u8 `mirai:"text,optional,label=Of add and carve: sphere or capsule or box; omitted: a sphere, or a capsule from at to to"`,
    alpha:[32]u8 `mirai:"text,optional,label=A shape of the brush by its name as the panel lists them"`,
    turn:f32 `mirai:"optional,label=Degrees the alpha turns"`,
    player:int `mirai:"optional,min=0,max=3,label=While a game plays: the run of that player of a game a turn plays on the network"`,
}

Layer_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the terrain"`,
    layer:[LAYER_NAME_BYTES]u8 `mirai:"text,optional,label=The layer to change or take out by its material (a path or its stem; default is one without a material); omitted adds one"`,
    remove:bool `mirai:"optional,label=Takes the layer out: what it covered goes to the others; the last one stays"`,
    material:base.Asset_Id `mirai:"optional,label=Its .mat; omitted: as it is"`,
    tiling:f32 `mirai:"optional,min=0.01,unit=m,label=Over which its textures repeat"`,
    height_blend:f32 `mirai:"optional,min=0,max=1"`,
    displacement:f32 `mirai:"optional,min=0,max=4,unit=m,label=Of a Heightfield near the view: how far its textures raise it"`,
    automatic:bool `mirai:"optional,label=It covers where the slope and the height are in its ranges"`,
    slope:[2]f32 `mirai:"optional,label=Degrees of its rule"`,
    height:[2]f32 `mirai:"optional,label=Metres of its rule in the terrain"`,
    softness:[2]f32 `mirai:"optional,label=Degrees and metres past the ranges over which it fades out"`,
    player:int `mirai:"optional,min=0,max=3,label=While a game plays: the run of that player of a game a turn plays on the network"`,
}

Interior_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of a Volume terrain"`,
    strata:[terrain.INTERIOR_STRATA]Stratum_Param `mirai:"optional,label=From the surface down; omitted: as they are, an empty list none"`,
    veins:[terrain.INTERIOR_VEINS]Vein_Param `mirai:"optional,label=Over the strata, each over those before it; omitted: as they are, an empty list none"`,
    wave:f32 `mirai:"optional,min=0,unit=m,label=How far the boundaries between strata rise and fall"`,
    wave_scale:f32 `mirai:"optional,min=0,unit=m,label=Across those waves"`,
    seed:u32 `mirai:"optional,label=Of the waves"`,
}

Stratum_Param :: struct {
    layer:[LAYER_NAME_BYTES]u8 `mirai:"text,label=Its layer by its material"`,
    depth:f32 `mirai:"optional,min=0,unit=m,label=Under the top of its column where it ends; the last reaches the bottom"`,
}

Vein_Param :: struct {
    layer:[LAYER_NAME_BYTES]u8 `mirai:"text,label=Its layer by its material"`,
    shape:[8]u8 `mirai:"text,optional,label=pocket (blobs) or vein (thin sheets)"`,
    scale:f32 `mirai:"optional,min=0.01,unit=m,label=Across its features"`,
    amount:f32 `mirai:"optional,min=0,max=1,label=How much of what is between its depths it takes"`,
    depth:[2]f32 `mirai:"optional,min=0,unit=m,label=Under the top of its column: from and to"`,
    seed:u32 `mirai:"optional"`,
}

Sample_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the terrain"`,
    at:[3]f32 `mirai:"label=A point of the world: what is under its x and z"`,
    player:int `mirai:"optional,min=0,max=3,label=While a game plays: the run of that player of a game a turn plays on the network"`,
}

Heightmap_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of a Heightfield Terrain"`,
    import_path:[512]u8 `mirai:"text,optional,label=An image whose heights it takes scaled and offset; another size gives it its size"`,
    export_path:[512]u8 `mirai:"text,optional,label=A 16-bit PNG it writes from its lowest height to its highest"`,
    height_scale:f32 `mirai:"optional,unit=m"`,
    height_offset:f32 `mirai:"optional,unit=m"`,
}

Resize_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of a Heightfield Terrain"`,
    samples:[2]u32 `mirai:"label=Samples over x and z: each an even number more or fewer than it has so that its center stays"`,
}

@(private) LAST_LAYER :: "A terrain keeps one layer at least: give this one another material with terrain.layer, or add another first"
@(private) LAYER_NAME_BYTES :: 256
Id_Result :: struct {
    id:base.Entity_Id,
}

Terrain_Edit_Result :: struct {
    changed:bool,
    touches:int `mirai:"optional"`,
}

Terrain_Layer_Result :: struct {
    layers:int,
    layer:string `mirai:"optional"`,
}

Terrain_Interior_Result :: struct {
    strata,veins:int,
}

Terrain_Sample_Result :: struct {
    found:bool,
    height:f32,
    normal:[3]f32 `mirai:"optional"`,
    slope:f32 `mirai:"unit=deg"`,
    weights:serial.Json `mirai:"optional"`,
    hole:bool `mirai:"optional"`,
    layers:int `mirai:"optional"`,
    check:string `mirai:"optional"`,
}

Terrain_Heightmap_Result :: struct {
    written:string `mirai:"optional"`,
    height_scale,height_offset:f32 `mirai:"optional"`,
}

@(private)
terrain_api_register :: proc(s:^editor.Session) {
    editor.tool_entry(s,"terrain","Terrain",ui.icon_user(u8(editor.User_Icon.Terrain)),{key=.T,set=true})
    create_defaults:=Create_Params{samples=65,depth=17,spacing=1,chunk_cells=32,height_scale=32}
    edit_defaults:=Edit_Params{radius=4,strength=0.5,passes=1,interval=2,riser=0.25,scale=8,sides=2}
    layer_defaults:=Layer_Params{tiling=terrain.LAYER_DEFAULT.tiling}
    interior_defaults:=Interior_Params{wave_scale=16}
    for &stratum in interior_defaults.strata {stratum.depth=1}
    for &vein in interior_defaults.veins {vein.scale,vein.amount,vein.depth=4,0.3,{0,terrain.HEIGHT_LIMIT}}
    editor.api_method_register(s,{name="terrain.create",summary="Makes a terrain in the edited scene: a Heightfield (heights over x and z, for open ground) or a Volume (solid and air, for caves, overhangs and digging), flat or from a heightmap. One step of undo takes it and its .terrain away.",params=type_info_of(Create_Params),defaults=&create_defaults,result=type_info_of(Id_Result),run=api_create})
    editor.api_method_register(s,{name="terrain.edit",summary="One stroke of a brush of the terrain tool on a terrain, from at to to (or at alone), as one step of undo: sculpting (raise, lower, smooth, flatten, set_height, terrace, noise, erode, a ramp between at and to), painting a layer (paint, erase), holes (hole, fill) or a shape it joins or takes out (add, carve: a sphere at at, a capsule to to, or a box), on a Heightfield or a Volume alike. The error says what failed and what to use.",params=type_info_of(Edit_Params),defaults=&edit_defaults,result=type_info_of(Terrain_Edit_Result),run=api_edit})
    editor.api_method_register(s,{name="terrain.layer",summary="Adds, changes or takes out a material layer of a terrain, with its tiling, height blend and its automatic rule of slope and height, as one step of undo; what it is not given stays as it is. From one layer, which covers everything when the terrain is made, up to four.",params=type_info_of(Layer_Params),defaults=&layer_defaults,result=type_info_of(Terrain_Layer_Result),run=api_layer})
    editor.api_method_register(s,{name="terrain.interior",summary="Sets what a Volume holds under its surface, as its layers, and writes it into every sample as one step of undo: strata down from the top of each column (grass, dirt, rock) and pockets or veins of noise over them (ore). The walls and floor of what is dug show it, and what a game digs reports it by layer (terrain.Terrain_Digs). What it is not given stays as it is.",params=type_info_of(Interior_Params),defaults=&interior_defaults,result=type_info_of(Terrain_Interior_Result),run=api_interior})
    editor.api_method_register(s,{name="terrain.sample",summary="What a terrain has under a point: the height and normal of its surface in the world, its slope, the weight of each of its layers there by its name (rules included) and whether it is a hole; while a game of the caller plays, in that game, with check, a hash of every value of its source, equal in two games that hold the same.",params=type_info_of(Sample_Params),flags={.Read_Only},result=type_info_of(Terrain_Sample_Result),run=api_sample})
    editor.api_method_register(s,{name="terrain.heightmap",summary="Imports a heightmap into a Heightfield Terrain as one step of undo, or exports its heights as a 16-bit PNG (the scale and offset it answers import it back).",params=type_info_of(Heightmap_Params),result=type_info_of(Terrain_Heightmap_Result),run=api_heightmap})
    editor.api_method_register(s,{name="terrain.resize",summary="Gives a Heightfield Terrain other samples around its center as one step of undo: what it had stays where it was, and what grows takes the heights and layers of the nearest edge.",params=type_info_of(Resize_Params),result=type_info_of(Id_Result),run=api_resize})
}

// The tool, the edited world and the terrain of an id, ready to edit as
// the tool edits the selected one.
@(private)
api_terrain :: proc(s:^editor.Session,call:^api.Call,named:[]u8) -> (tool:^Terrain_Tool,world:core.World_Ref,ok:bool) {
    given:=base.text_get(named)
    tool=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Terrain_Tool)
    world=editor.edited_world(s)
    terrains:=core.world_table_of(world,terrain.Terrain);worlds:=core.world_table_of(world,core.World_Transform)
    if tool==nil || terrains==nil || worlds==nil {api.call_fail(call,api.INVALID_PARAMS,"The project has no terrain: activate the plugin terrain in project.mirai");return}
    tool_ready(tool)
    if tool.stroke.active {api.call_fail(call,api.INVALID_PARAMS,"A stroke of the terrain tool is held in the viewport: let it go first");return}
    e,named_found:=editor.api_call_entity(call,world,named)
    if !named_found {return}
    if !core.has(terrains,e) {api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a Terrain: scene.inspect lists them",given);return}
    if s.app==nil || s.app.assets==nil {api.call_fail(call,api.INTERNAL_ERROR,"The editor has no assets loaded");return}
    // Where it is now, also just made or moved by scene.write, with its ground and colliders.
    editor.api_place_settle(s,e)
    world=editor.edited_world(s)
    terrains,worlds=core.world_table_of(world,terrain.Terrain),core.world_table_of(world,core.World_Transform)
    if !core.has(worlds,e) {api.call_failf(call,api.INVALID_PARAMS,"Terrain %s has no place in the world: give its entity a place with scene.write",given);return}
    marker,_:=core.get(terrains,e)
    if !terrain.terrain_stamp(s.app.assets,marker.source).found {api.call_failf(call,api.INVALID_PARAMS,"The .terrain of terrain %s is not among the assets: asset.list shows them",given);return}
    if !stroke_prepare(tool,s.app.assets,s.app.allocator,terrains,worlds,editor.Pick{entity=e}) {api.call_failf(call,api.INVALID_PARAMS,"The .terrain of terrain %s could not be read: engine.diagnostics says why",given);return}
    if !stroke_baseline(tool) {api.call_fail(call,api.INTERNAL_ERROR,"The terrain history could not be stored: there is not enough memory");return}
    return tool,world,true
}

@(private)
api_changed_write :: proc(call:^api.Call,changed:bool,touches:int) {
    api.call_result(call,Terrain_Edit_Result)^={changed,touches}
}

@(private)
layer_materials :: proc(source:^terrain.Source) -> []base.Asset_Id {
    ids:=make([]base.Asset_Id,int(source.layer_count),context.temp_allocator)
    for &layer,i in source.layers[:source.layer_count] {ids[i]=layer.material}
    return ids
}

// The names of the layers of a source, as asset.slot_named takes them.
@(private)
layer_names :: proc(s:^editor.Session,source:^terrain.Source) -> []string {
    return asset.slot_names(&s.app.assets.registry,layer_materials(source))
}

// The layer of a source a name stands for.
@(private)
layer_named :: proc(s:^editor.Session,call:^api.Call,source:^terrain.Source,name:string) -> (index:int,ok:bool) {
    at,problem:=asset.slot_named(layer_names(s,source),layer_materials(source),name,"layers of the terrain")
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return -1,false}
    return at,true
}

// Whether a name can be that of a new terrain: its file takes it, and no other
// entity has it, so the calls that name it find it.
@(private)
api_name_free :: proc(s:^editor.Session,call:^api.Call,name:string) -> bool {
    if !editor.asset_stem_valid(name) {api.call_failf(call,api.INVALID_PARAMS,"name %q cannot name a file: leave out / \\ : * ? \" < > | and a leading dot",name);return false}
    if e,several:=editor.api_entity_find(editor.edited_world(s),name);e!=core.NONE || several!="" {api.call_failf(call,api.INVALID_PARAMS,"An entity is already named %q: give this one another name, or edit that one",name);return false}
    return true
}

@(private)
api_create :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Create_Params)
    tool:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Terrain_Tool)
    if tool==nil {api.call_fail(call,api.INVALID_PARAMS,"The project has no terrain: activate the plugin terrain in project.mirai");return}
    tool_ready(tool)
    named:=base.text_get(p.kind[:])
    kind,known:=terrain.Source_Kind{},named==""
    for k in terrain.Source_Kind {if strings.equal_fold(fmt.tprint(k),named) {kind,known=k,true}}
    if !known {api.call_fail(call,api.INVALID_PARAMS,"kind is heightfield or volume");return}
    name:=base.text_get(p.name[:])
    if name!="" && !api_name_free(s,call,name) {return}
    path:=base.text_get(p.heightmap[:])
    if path!="" {
        file,problem:=editor.api_file_path(s.project_root,path,context.temp_allocator)
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,fmt.tprintf("heightmap: %s",problem));return}
        path=file
    }
    if path!="" && kind==.Volume {api.call_fail(call,api.INVALID_PARAMS,"A volume starts as a solid block: a heightmap makes a heightfield");return}
    tool.create_kind,tool.create_source=kind,path!=""?.Heightmap:.Plane
    tool.samples,tool.depth,tool.cell,tool.chunk_cells=int(p.samples),int(p.depth),p.spacing,int(p.chunk_cells)
    tool.height_scale,tool.height_offset=p.height_scale,p.height_offset
    tool.heightmap_length=copy(tool.heightmap_path[:],path)
    s.toast_length=0
    placed:=editor.tool_call_given(call,"at")
    ground:=core.NONE
    if editor.tool_call_given(call,"ground") {
        if kind!=.Volume {api.call_fail(call,api.INVALID_PARAMS,"Only a volume joins a Heightfield: pass kind volume, or leave ground out");return}
        known:bool
        if ground,known=editor.api_call_entity(call,editor.edited_world(s),p.ground[:],"ground");!known {return}
    }
    e:=terrain_create(s,tool,editor.edited_world(s),s.app.assets,s.app.allocator,p.at,placed,ground,name)
    if e==core.NONE {editor.tool_call_fail(s,call,"The terrain could not be made");return}
    world:=editor.edited_world(s)
    core.world_settle(world)
    api.call_result(call,Id_Result).id=editor.api_entity_id(world,e)
}

// The brush of a name, and whether set_height (Flatten to a height).
@(private)
brush_named :: proc(name:string) -> (kind:terrain.Brush_Kind,level,ok:bool) {
    switch name {
    case "raise":      return .Raise,false,true
    case "lower":      return .Lower,false,true
    case "smooth":     return .Smooth,false,true
    case "flatten":    return .Flatten,false,true
    case "set_height": return .Flatten,true,true
    case "ramp":       return .Ramp,false,true
    case "terrace":    return .Terrace,false,true
    case "noise":      return .Noise,false,true
    case "erode":      return .Erode,false,true
    case "paint":      return .Paint,false,true
    case "erase":      return .Erase,false,true
    case "hole":       return .Hole,false,true
    case "fill":       return .Fill,false,true
    case "add":        return .Add,false,true
    case "carve":      return .Carve,false,true
    }
    return
}

// The brush of the params of terrain.edit in the space of a source, which
// to_local takes the world into, scaling its axes by scale, and the ends of
// its stroke there on its surface; across: the metres of the world in one of
// the source over x and z (terrain.brush_scale). The points it touches are
// the caller's.
@(private)
edit_brush :: proc(s:^editor.Session,call:^api.Call,p:^Edit_Params,source:^terrain.Source,to_local:matrix[4,4]f32,scale:[3]f32,kind:terrain.Brush_Kind,level:bool) -> (brush:terrain.Brush,from,to:[3]f32,across:f32,ok:bool) {
    up:f32
    scaled:terrain.Edit_Error
    if across,up,scaled=terrain.brush_scale(scale,source.kind,kind);scaled!=.None {api.call_failf(call,api.INVALID_PARAMS,"The terrain was not edited: %s",terrain.edit_error_fix(scaled,kind));return}
    layer:=0
    if name:=base.text_get(p.layer[:]);name!="" {
        found:bool
        if layer,found=layer_named(s,call,source,name);!found {return}
    }
    falloff:=geom.Falloff.Smooth
    if name:=base.text_get(p.falloff[:]);name!="" {
        found:=false
        for f,i in ([?]string{"smooth","sphere","linear","sharp","flat"}) {if strings.equal_fold(f,name) {falloff,found=geom.Falloff(i),true}}
        if !found {api.call_fail(call,api.INVALID_PARAMS,"falloff is smooth, sphere, linear, sharp or flat");return}
    }
    way:=terrain.Brush_Way.Both
    switch strings.to_lower(base.text_get(p.way[:]),context.temp_allocator) {
    case "","both":
    case "raise": way=.Up
    case "lower": way=.Down
    case: api.call_fail(call,api.INVALID_PARAMS,"way is both, raise or lower");return
    }
    local :: proc(to_local:matrix[4,4]f32,p:[3]f32) -> [3]f32 {return (to_local*[4]f32{p.x,p.y,p.z,1}).xyz}
    from,_=terrain.source_carry(source,local(to_local,p.at),{0,1,0},0)
    to=from
    if p.to!={} {to,_=terrain.source_carry(source,local(to_local,p.to),{0,1,0},0)}
    radius:=p.radius/across
    brush={kind=kind,radius=radius,amount=edit_amount(p,kind,p.radius/up),falloff=falloff,hardness=clamp(p.hardness,0,0.95),way=way,capped=p.capped && (kind==.Raise || kind==.Lower),interval=max(p.interval,0.01)/up,riser=clamp(p.riser,0,1),scale=max(p.scale,0.1)/across,layer=u32(layer),turn=math.to_radians(p.turn),rotation=1}
    if p.slope!={} {
        low,high:=math.to_radians(min(p.slope.x,p.slope.y)),math.to_radians(max(p.slope.x,p.slope.y))
        brush.slope,brush.slope_invert={clamp(low,0,math.PI/2),clamp(max(high,low+1e-4),0,math.PI/2)},p.slope_invert
    }
    // Flatten, set_height and a capped brush keep the height of at, or the one given.
    if kind==.Flatten || brush.capped || kind==.Terrace {brush.target=level && editor.tool_call_given(call,"height")?local(to_local,{p.at.x,p.height,p.at.z}).y:from.y}
    if kind==.Paint && editor.tool_call_given(call,"weight") {brush.toward,brush.target=true,clamp(p.weight,0,1)}
    if kind==.Add || kind==.Carve {
        // One shape: a sphere at at, a capsule to to, or a box.
        shape:=strings.to_lower(base.text_get(p.shape[:]),context.temp_allocator)
        if shape=="" {shape=p.to!={}?"capsule":"sphere"}
        found:=false
        for name,i in ([?]string{"sphere","capsule","box"}) {if name==shape {brush.shape,found=terrain.Brush_Shape(i),true}}
        if !found {api.call_fail(call,api.INVALID_PARAMS,"shape is sphere, capsule or box");return}
        brush.center,brush.amount=local(to_local,p.at),1
        if brush.shape==.Capsule {brush.delta=local(to_local,p.to)-brush.center}
        if brush.shape==.Box {brush.extent=radius}
    }
    return brush,from,to,across,true
}

// What one touch of a stroke of terrain.edit does at a point, by its params.
@(private)
edit_amount :: proc(p:^Edit_Params,kind:terrain.Brush_Kind,radius:f32) -> f32 {
    #partial switch kind {
    case .Raise,.Lower,.Noise: return clamp(p.strength,0,1)*radius*RAISE_PER_PASS
    }
    return clamp(p.strength,0,1)
}

@(private)
api_edit :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Edit_Params)
    kind,level,named:=brush_named(strings.to_lower(base.text_get(p.brush[:]),context.temp_allocator))
    if !named {api.call_fail(call,api.INVALID_PARAMS,"brush is raise, lower, smooth, flatten, set_height, ramp, terrace, noise, erode, paint, erase, hole, fill, add or carve");return}
    if r,own:=editor.api_play_run(s,call,p.player);r!=nil {
        if !own {editor.api_play_refused(call);return}
        api_edit_play(s,call,p,editor.run_ref(s,r),kind,level)
        return
    }
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    stroke:=&tool.stroke
    source:=&stroke.source
    axes:=[3]f32{linalg.length(stroke.to_world[0].xyz),linalg.length(stroke.to_world[1].xyz),linalg.length(stroke.to_world[2].xyz)}
    brush,from,to,across,made:=edit_brush(s,call,p,source,stroke.to_local,axes,kind,level)
    if !made {return}
    brush.seed=u32(stroke.id[0])
    if name:=base.text_get(p.alpha[:]);name!="" && kind!=.Add && kind!=.Carve {
        alphas_ready(&tool.alphas)
        for held,i in tool.alphas.names {if strings.equal_fold(held,name) {brush.alpha=&tool.alphas.list[i]}}
        if brush.alpha==nil {api.call_fail(call,api.INVALID_PARAMS,"No alpha by that name: the Shape of the panel lists them");return}
    }
    stroke.active=true
    defer if stroke.active {stroke_cancel(tool)}
    touches:=0
    s.toast_length=0
    path:=p.to!={}
    // A ramp and a shape are one touch from at to to; the others touch along the stroke.
    if kind==.Ramp || kind==.Add || kind==.Carve {
        if kind==.Ramp {
            if !path {api.call_fail(call,api.INVALID_PARAMS,"A ramp goes from at to to: give to");return}
            sides:=max(p.sides,0)/across
            at,end:=(stroke.to_local*[4]f32{p.at.x,p.at.y,p.at.z,1}).y,(stroke.to_local*[4]f32{p.to.x,p.to.y,p.to.z,1}).y
            brush.center,brush.delta,brush.amount={from.x,at,from.z},{to.x-from.x,end-at,to.z-from.z},1
            brush.radius,brush.hardness=brush.radius+sides,min(brush.radius/(brush.radius+sides),0.99)
        } else {brush.blend=max(tool.blend,0)/across}
        change:=terrain.source_edit(source,brush)
        if change.error!=.None {api.call_failf(call,api.INVALID_PARAMS,"The terrain was not edited: %s",terrain.edit_error_fix(change.error,brush.kind));return}
        stroke_changed(stroke,change)
        touches=1
    } else {
        step:=to-from
        count:=path?clamp(int(math.ceil(linalg.length(step)/(brush.radius*STROKE_SPACING))),1,4096):0
        for _ in 0..<max(p.passes,1) {
            for i in 0..=count {
                brush.center,_=terrain.source_carry(source,from+step*(f32(i)/f32(max(count,1))),{0,1,0},brush.radius*4)
                if kind==.Erode {brush.seed=u32(base.hash_u64(u64(touches)+u64(stroke.id[1])))}
                if !(brush.amount>0) {continue}
                change:=terrain.source_edit(source,brush)
                if change.error!=.None {api.call_failf(call,api.INVALID_PARAMS,"The terrain was not edited: %s",terrain.edit_error_fix(change.error,brush.kind));return}
                stroke_changed(stroke,change)
                touches+=1
            }
        }
    }
    if !stroke.changed {stroke_cancel(tool);api_changed_write(call,false,touches);return}
    stroke_end(s,tool,world,s.app.assets,label=fmt_label(kind,level))
    if stroke.active || stroke.changed {editor.tool_call_fail(s,call,"The stroke could not be kept");return}
    api_changed_write(call,true,touches)
}

@(private)
fmt_label :: proc(kind:terrain.Brush_Kind,level:bool) -> string {
    #partial switch kind {
    case .Paint,.Erase: return "Paint terrain"
    case .Hole,.Fill:   return "Terrain holes"
    case .Ramp:         return "Ramp"
    case .Add,.Carve:   return "Shape"
    }
    return "Sculpt"
}

@(private)
api_layer :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Layer_Params)
    if r,own:=editor.api_play_run(s,call,p.player);r!=nil {
        if !own {editor.api_play_refused(call);return}
        api_layer_play(s,call,p,editor.run_ref(s,r))
        return
    }
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    source:=&tool.stroke.source
    count:=int(source.layer_count)
    index:=-1
    if name:=base.text_get(p.layer[:]);name!="" {
        found:bool
        if index,found=layer_named(s,call,source,name);!found {return}
    }
    s.toast_length=0
    if p.remove {
        if index<0 {api.call_fail(call,api.INVALID_PARAMS,"Give layer, the one to take out");return}
        if count==1 {api.call_fail(call,api.INVALID_PARAMS,LAST_LAYER);return}
        if !terrain_layer_commit(s,tool,world,s.app.assets,index,{},true) {editor.tool_call_fail(s,call,"The layer could not be taken out");return}
    } else {
        if index<0 {index=count}
        if index>=terrain.LAYERS_MAX {api.call_failf(call,api.INVALID_PARAMS,"A terrain has up to %d layers and it has %d: name one with layer to change it",terrain.LAYERS_MAX,count);return}
        layer:=index<count?source.layers[index]:terrain.LAYER_DEFAULT
        if !layer_values(call,p,&layer) {return}
        if !terrain_layer_commit(s,tool,world,s.app.assets,index,layer,false) {editor.tool_call_fail(s,call,"The layer could not be set");return}
    }
    r:=api.call_result(call,Terrain_Layer_Result)
    r.layers=int(tool.stroke.source.layer_count)
    if !p.remove {r.layer=layer_names(s,&tool.stroke.source)[index]}
}

// What of a layer the params of terrain.layer give.
@(private)
layer_values :: proc(call:^api.Call,p:^Layer_Params,layer:^terrain.Terrain_Layer) -> bool {
    if p.material!={} {layer.material=p.material}
    if editor.tool_call_given(call,"tiling") {layer.tiling=p.tiling}
    if editor.tool_call_given(call,"height_blend") {layer.height_blend=p.height_blend}
    if editor.tool_call_given(call,"displacement") {layer.displacement=p.displacement}
    if editor.tool_call_given(call,"automatic") {layer.auto.enabled=p.automatic}
    if editor.tool_call_given(call,"slope") {layer.auto.slope={math.to_radians(min(p.slope.x,p.slope.y)),math.to_radians(max(p.slope.x,p.slope.y))}}
    if editor.tool_call_given(call,"height") {layer.auto.height={min(p.height.x,p.height.y),max(p.height.x,p.height.y)}}
    if editor.tool_call_given(call,"softness") {layer.auto.softness={math.to_radians(max(p.softness.x,0)),max(p.softness.y,0)}}
    if !terrain.layer_valid(layer^) {api.call_fail(call,api.INVALID_PARAMS,"The layer is out of range: tiling above 0, height_blend from 0 to 1, displacement from 0 to 4 m, slope from 0 to 90 degrees");return false}
    return true
}

// The terrain of an id in a game that plays, its source there, its
// requests and the transform of the world into it.
@(private)
api_play_terrain :: proc(call:^api.Call,w:core.World_Ref,named:[]u8) -> (e:core.Entity,source:^terrain.Source,requests:^terrain.Terrain_Requests,to_local:matrix[4,4]f32,place:mm.Transform,ok:bool) {
    terrains,worlds:=core.world_table_of(w,terrain.Terrain),core.world_table_of(w,core.World_Transform)
    data,queued:=core.world_storage_of(w,terrain.Terrain_Data),core.world_storage_of(w,terrain.Terrain_Requests)
    if terrains==nil || worlds==nil || data==nil || queued==nil {api.call_fail(call,api.INVALID_PARAMS,"The game has no terrain: activate the plugin terrain in project.mirai");return}
    named_found:bool
    if e,named_found=editor.api_call_entity(call,w,named,game=true);!named_found {return}
    given:=base.text_get(named)
    marker,found:=core.get(terrains,e)
    if !found {api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a Terrain in the game: scene.inspect with world Game lists them",given);return}
    placed,has:=core.get(worlds,e)
    source=terrain.terrain_source(core.ref(data),marker.source)
    if !has || source==nil {api.call_failf(call,api.INVALID_PARAMS,"The source of terrain %s is not loaded in the game yet: step it and call again",given);return}
    to_local=linalg.inverse(mm.transform_matrix(placed.transform))
    return e,source,queued,to_local,placed.transform,true
}

// terrain.edit in a game that plays: its touches as requests of the game.
@(private)
api_edit_play :: proc(s:^editor.Session,call:^api.Call,p:^Edit_Params,w:core.World_Ref,kind:terrain.Brush_Kind,level:bool) {
    e,source,requests,to_local,place,ok:=api_play_terrain(call,w,p.entity[:])
    if !ok {return}
    if base.text_get(p.alpha[:])!="" {api.call_fail(call,api.INVALID_PARAMS,"A game asks for brushes without an alpha: leave alpha out");return}
    if kind==.Ramp {api.call_fail(call,api.INVALID_PARAMS,"While a game plays terrain.edit asks for the brushes that touch along a stroke and for add and carve; a ramp goes in a request of play.push");return}
    brush,from,to,_,made:=edit_brush(s,call,p,source,to_local,linalg.abs(place.scale),kind,level)
    if !made {return}
    brush.seed=u32(editor.api_entity_id(w,e))
    if kind==.Add || kind==.Carve {
        world,_:=terrain.brush_world(brush,place,source.kind)
        if error:=terrain.dig(requests,world,e);error!=.None {api.call_failf(call,api.INVALID_PARAMS,"The terrain was not edited: %s",terrain.edit_error_fix(error,kind));return}
        api_changed_write(call,true,1)
        return
    }
    step:=to-from
    count:=p.to!={}?clamp(int(math.ceil(linalg.length(step)/(brush.radius*STROKE_SPACING))),1,4096):0
    touches:=(count+1)*int(max(p.passes,1))
    room:=cap(requests.edits.items)-len(requests.edits.items)
    if touches>room {api.call_failf(call,api.INVALID_PARAMS,"The stroke would ask for %d touches and the game has room for %d in this tick: make it shorter or the radius larger, go on after a tick, or raise Terrain_Settings.requests",touches,room);return}
    pushed:=0
    for _ in 0..<max(p.passes,1) {
        for i in 0..=count {
            brush.center,_=terrain.source_carry(source,from+step*(f32(i)/f32(max(count,1))),{0,1,0},brush.radius*4)
            world,_:=terrain.brush_world(brush,place,source.kind)
            if brush.amount>0 && terrain.dig(requests,world,e)==.None {pushed+=1}
        }
    }
    api_changed_write(call,pushed>0,pushed)
}

// terrain.layer in a game that plays: a request of the game.
@(private)
api_layer_play :: proc(s:^editor.Session,call:^api.Call,p:^Layer_Params,w:core.World_Ref) {
    e,source,requests,_,_,ok:=api_play_terrain(call,w,p.entity[:])
    if !ok {return}
    count:=int(source.layer_count)
    index:=-1
    if name:=base.text_get(p.layer[:]);name!="" {
        found:bool
        if index,found=layer_named(s,call,source,name);!found {return}
    }
    if len(requests.layers.items)>=cap(requests.layers.items) {api.call_fail(call,api.INVALID_PARAMS,"The game has no room for more layer changes in this tick: step it first, or raise Terrain_Settings.requests");return}
    if p.remove {
        if index<0 {api.call_fail(call,api.INVALID_PARAMS,"Give layer, the one to take out");return}
        if count==1 {api.call_fail(call,api.INVALID_PARAMS,LAST_LAYER);return}
        terrain.request_layer_remove(requests,e,index)
    } else {
        if index<0 {index=count}
        if index>=terrain.LAYERS_MAX {api.call_failf(call,api.INVALID_PARAMS,"A terrain has up to %d layers and it has %d in the game: name one with layer to change it",terrain.LAYERS_MAX,count);return}
        layer:=index<count?source.layers[index]:terrain.LAYER_DEFAULT
        if !layer_values(call,p,&layer) {return}
        terrain.request_layer(requests,e,index,layer)
    }
    api.call_result(call,Terrain_Layer_Result).layers=int(p.remove?count-1:max(count,index+1))
}

@(private)
api_interior :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Interior_Params)
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    source:=&tool.stroke.source
    if source.kind!=.Volume {api.call_failf(call,api.INVALID_PARAMS,"A %s has no interior: only a Volume holds what is under its surface",terrain_kind_name(source.kind));return}
    interior:=source.interior
    if editor.tool_call_given(call,"strata") {
        count,_:=api.params_array_count(call,"strata")
        interior.strata,interior.strata_count={},u32(count)
        for &stratum,i in p.strata[:count] {
            layer,found:=layer_named(s,call,source,base.text_get(stratum.layer[:]))
            if !found {return}
            interior.strata[i]={u32(layer),stratum.depth}
        }
    }
    if editor.tool_call_given(call,"veins") {
        count,_:=api.params_array_count(call,"veins")
        interior.veins,interior.vein_count={},u32(count)
        for &vein,i in p.veins[:count] {
            shape:=terrain.Vein_Shape.Pocket
            switch strings.to_lower(base.text_get(vein.shape[:]),context.temp_allocator) {
            case "","pocket":
            case "vein": shape=.Vein
            case: api.call_failf(call,api.INVALID_PARAMS,"veins[%d].shape is pocket or vein",i);return
            }
            layer,found:=layer_named(s,call,source,base.text_get(vein.layer[:]))
            if !found {return}
            interior.veins[i]={layer=u32(layer),shape=shape,scale=vein.scale,amount=vein.amount,depth={min(vein.depth.x,vein.depth.y),max(vein.depth.x,vein.depth.y)},seed=vein.seed}
        }
    }
    if editor.tool_call_given(call,"wave") {interior.wave=p.wave}
    if editor.tool_call_given(call,"wave_scale") || interior.wave>0 && interior.wave_scale==0 {interior.wave_scale=p.wave_scale}
    if editor.tool_call_given(call,"seed") {interior.seed=p.seed}
    if !terrain.interior_valid(interior,source.layer_count) {
        api.call_failf(call,api.INVALID_PARAMS,"The interior is out of range: the depths of the strata from the top down, each vein with a scale above 0 and an amount from 0 to 1, and a wave_scale above 0 with a wave")
        return
    }
    s.toast_length=0
    if !terrain_interior_commit(s,tool,world,s.app.assets,interior) {editor.tool_call_fail(s,call,"The interior could not be set");return}
    api.call_result(call,Terrain_Interior_Result)^={int(source.interior.strata_count),int(source.interior.vein_count)}
}

@(private)
api_sample :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Sample_Params)
    source:^terrain.Source
    to_local,to_world:matrix[4,4]f32
    check:u64
    played:=false
    if r,_:=editor.api_play_run(s,call,p.player);r!=nil {
        w:=editor.run_ref(s,r)
        _,source,_,to_local,_,played=api_play_terrain(call,w,p.entity[:])
        if !played {return}
        to_world=linalg.inverse(to_local)
        data:=core.world_storage_of(w,terrain.Terrain_Data)
        terrains:=core.world_table_of(w,terrain.Terrain)
        found_e,_:=editor.api_entity_find(w,base.text_get(p.entity[:]))
        marker,_:=core.get(terrains,found_e)
        check,_=terrain.terrain_source_check(core.ref(data),marker.source)
    } else {
        tool,_,ok:=api_terrain(s,call,p.entity[:])
        if !ok {return}
        source,to_local,to_world=&tool.stroke.source,tool.stroke.to_local,tool.stroke.to_world
    }
    q:=(to_local*[4]f32{p.at.x,p.at.y,p.at.z,1}).xyz
    point,normal,found:=terrain.source_ray(source,{q.x,terrain.HEIGHT_LIMIT*0.5,q.z},{0,-1,0})
    r:=api.call_result(call,Terrain_Sample_Result)
    r.found=found
    if played {r.layers,r.check=int(source.layer_count),fmt.aprintf("%016x",check,allocator=call.allocator)}
    if found {
        world_point:=(to_world*[4]f32{point.x,point.y,point.z,1}).xyz
        r.height,r.normal=world_point.y,linalg.normalize0((to_world*[4]f32{normal.x,normal.y,normal.z,0}).xyz)
        r.slope=math.to_degrees(math.acos(clamp(normal.y,-1,1)))
        weights:=terrain.layers_vertex(source,terrain.source_weights_at(source,point),normal,point.y)
        by_layer:=strings.builder_make(call.allocator)
        for name,i in layer_names(s,source) {fmt.sbprintf(&by_layer,"%s%q:%v",i==0?"{":",",name,weights[i])}
        strings.write_byte(&by_layer,'}')
        r.weights=serial.Json(strings.builder_len(by_layer)>1?strings.to_string(by_layer):"{}")
    }
    origin:=terrain.source_origin(source)
    c,r_:=int((q.x-origin.x)/source.cell),int((q.z-origin.z)/source.cell)
    r.hole=c>=0 && r_>=0 && c<int(source.samples.x)-1 && r_<int(source.samples.z)-1 && terrain.source_hole(source,c,r_)
}

@(private)
api_heightmap :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Heightmap_Params)
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    if tool.stroke.source.kind!=.Heightfield {api.call_fail(call,api.INVALID_PARAMS,"A heightmap is of a Heightfield Terrain");return}
    if editor.tool_call_given(call,"height_scale") {tool.height_scale=p.height_scale}
    if editor.tool_call_given(call,"height_offset") {tool.height_offset=p.height_offset}
    imported,exported:=base.text_get(p.import_path[:]),base.text_get(p.export_path[:])
    if imported=="" && exported=="" {api.call_fail(call,api.INVALID_PARAMS,"Give import_path or export_path");return}
    s.toast_length=0
    if imported!="" {
        file,problem:=editor.api_file_path(s.project_root,imported,context.temp_allocator)
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
        if !heightmap_import(s,tool,world,s.app.assets,file) {editor.tool_call_fail(s,call,"The heightmap could not be imported");return}
    }
    if exported!="" {
        file,problem:=editor.api_file_path(s.project_root,exported,context.temp_allocator)
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
        exported=file
    }
    if exported!="" && !heightmap_export(s,tool,exported) {editor.tool_call_fail(s,call,"The heightmap could not be written");return}
    api.call_result(call,Terrain_Heightmap_Result)^={exported,tool.height_scale,tool.height_offset}
}

@(private)
api_resize :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Resize_Params)
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    s.toast_length=0
    if !terrain_resize(s,tool,world,s.app.assets,{int(p.samples.x),int(p.samples.y)}) {editor.tool_call_fail(s,call,"The terrain could not be resized");return}
    resized,_:=editor.api_entity_find(world,base.text_get(p.entity[:]))
    api.call_result(call,Id_Result).id=editor.api_entity_id(world,resized)
}
