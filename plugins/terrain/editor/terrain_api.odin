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
// what it does, in the edited world, each a step of undo kept unsaved as a
// stroke of the tool is. A stroke goes from at to to, touching every quarter
// of the radius, with what one pass of the tool does at each point. While a
// game of the caller plays, terrain.edit and terrain.layer are requests of
// that game instead (dig, request_layer), which it applies in its
// next tick as its own.

@(storage)
Terrain_Api :: struct {provider:editor.Api_Provider}

TERRAIN_API_DEFAULT :: Terrain_Api{provider={register=terrain_api_register}}

Create_Params :: struct {
    name:[128]u8 `mirai:"text,optional,label=The name of its entity and of its file; omitted: of its kind and a number"`,
    kind:[16]u8 `mirai:"text,optional,label=heightfield or mesh (a 3D Terrain that may have caves) or volume; omitted: heightfield"`,
    samples:u32 `mirai:"optional,min=3,max=16385,label=Samples on a side over x and z"`,
    depth:u32 `mirai:"optional,min=3,max=129,label=Samples along y of a volume"`,
    spacing:f32 `mirai:"optional,min=0.01,max=100,unit=m,label=Between two samples"`,
    chunk_cells:u32 `mirai:"optional,min=4,max=256,label=Cells on a side of a chunk"`,
    heightmap:[512]u8 `mirai:"text,optional,label=A PNG (16-bit too) or TGA or BMP of the project whose heights it takes in place of samples"`,
    height_scale:f32 `mirai:"optional,unit=m,label=How far the white of the heightmap stands over its black"`,
    height_offset:f32 `mirai:"optional,unit=m,label=The height of its black"`,
    base_depth:f32 `mirai:"optional,min=0,unit=m,label=Of a 3D Terrain: how deep its solid goes under its lowest point; 0 an open surface"`,
    at:[3]f32 `mirai:"optional,label=Where its entity stands; omitted: under the target of the view"`,
    ground:editor.Api_Entity_Text `mirai:"text,entity,optional,label=Of a volume: a Heightfield terrain it joins, standing on its samples and centered at at, its field its ground to dig into; it takes the spacing of the Heightfield"`,
}

Edit_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of the terrain"`,
    brush:[16]u8 `mirai:"text,label=raise or lower or smooth or flatten or set_height or ramp or terrace or noise or erode or paint or erase or hole or fill or add or remove or union or subtract"`,
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
    layer:[LAYER_NAME_BYTES]u8 `mirai:"text,optional,label=Of paint and erase, and of add and union on a Volume: the layer by its material (a path or its stem; default is one without a material); omitted: the first"`,
    weight:f32 `mirai:"optional,min=0,max=1,label=Of paint: the weight it takes the layer to in place of adding to it"`,
    shape:[16]u8 `mirai:"text,optional,label=Of union and subtract: sphere or capsule or box"`,
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
@(private) ID_RESULT :: `{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}`

@(private)
terrain_api_register :: proc(s:^editor.Session) {
    editor.tool_entry(s,"terrain","Terrain",ui.icon_user(u8(editor.User_Icon.Terrain)),{key=.T,set=true})
    create_defaults:=Create_Params{samples=65,depth=17,spacing=1,chunk_cells=32,height_scale=32,base_depth=8}
    edit_defaults:=Edit_Params{radius=4,strength=0.5,passes=1,interval=2,riser=0.25,scale=8,sides=2}
    layer_defaults:=Layer_Params{tiling=terrain.LAYER_DEFAULT.tiling}
    interior_defaults:=Interior_Params{wave_scale=16}
    for &stratum in interior_defaults.strata {stratum.depth=1}
    for &vein in interior_defaults.veins {vein.scale,vein.amount,vein.depth=4,0.3,{0,terrain.HEIGHT_LIMIT}}
    editor.api_method_register(s,Create_Params,{name="terrain.create",summary="Makes a terrain in the edited scene: a Heightfield (heights over x and z), a 3D Terrain (a mesh, for caves and overhangs) or a Volume (solid and air), flat or from a heightmap. Its .terrain stays in memory until it is saved; one step of undo takes it away.",defaults=&create_defaults,result_schema=ID_RESULT,run=api_create})
    editor.api_method_register(s,Edit_Params,{name="terrain.edit",summary="One stroke of a brush of the terrain tool on a terrain, from at to to (or at alone), as one step of undo: sculpting (raise, lower, smooth, flatten, set_height, terrace, noise, erode, a ramp between at and to), painting a layer (paint, erase), holes (hole, fill) or shapes of a 3D Terrain or a Volume (union, subtract). The error says what the terrain takes.",defaults=&edit_defaults,result_schema=`{"type":"object","properties":{"changed":{"type":"boolean"},"touches":{"type":"integer"}},"required":["changed"]}`,run=api_edit})
    editor.api_method_register(s,Layer_Params,{name="terrain.layer",summary="Adds, changes or takes out a material layer of a terrain, with its tiling, height blend and its automatic rule of slope and height, as one step of undo; what it is not given stays as it is. From one layer, which covers everything when the terrain is made, up to four.",defaults=&layer_defaults,result_schema=`{"type":"object","properties":{"layers":{"type":"integer"},"layer":{"type":"string"}},"required":["layers"]}`,run=api_layer})
    editor.api_method_register(s,Interior_Params,{name="terrain.interior",summary="Sets what a Volume holds under its surface, as its layers, and writes it into every sample as one step of undo: strata down from the top of each column (grass, dirt, rock) and pockets or veins of noise over them (ore). The walls and floor of what is dug show it, and what a game digs reports it by layer (terrain.Terrain_Digs). What it is not given stays as it is.",defaults=&interior_defaults,result_schema=`{"type":"object","properties":{"strata":{"type":"integer"},"veins":{"type":"integer"}},"required":["strata","veins"]}`,run=api_interior})
    editor.api_method_register(s,Sample_Params,{name="terrain.sample",summary="What a terrain has under a point: the height and normal of its surface in the world, its slope, the weight of each of its layers there by its name (rules included) and whether it is a hole; while a game of the caller plays, in that game, with check, a hash of every value of its source, equal in two games that hold the same.",flags={.Read_Only},result_schema=`{"type":"object","properties":{"found":{"type":"boolean"},"height":{"type":"number"},"normal":{"type":"array"},"slope":{"type":"number"},"weights":{"type":"object"},"hole":{"type":"boolean"},"layers":{"type":"integer"},"check":{"type":"string"}},"required":["found"]}`,run=api_sample})
    editor.api_method_register(s,Heightmap_Params,{name="terrain.heightmap",summary="Imports a heightmap into a Heightfield Terrain as one step of undo, or exports its heights as a 16-bit PNG (the scale and offset it answers import it back).",result_schema=`{"type":"object","properties":{"written":{"type":"string"},"height_scale":{"type":"number"},"height_offset":{"type":"number"}}}`,run=api_heightmap})
    editor.api_method_register(s,Resize_Params,{name="terrain.resize",summary="Gives a Heightfield Terrain other samples around its center as one step of undo: what it had stays where it was, and what grows takes the heights and layers of the nearest edge.",result_schema=ID_RESULT,run=api_resize})
}

// The tool, the edited world and the terrain of an id, ready to edit as
// the tool edits the selected one.
@(private)
api_terrain :: proc(s:^editor.Session,call:^api.Call,named:[]u8) -> (tool:^Terrain_Tool,world:core.World_Ref,ok:bool) {
    // A terrain just made takes its place in the world with the next frame.
    given:=base.text_get(named)
    if api_terrain_unplaced(s,&given) {editor.api_settle(s,&given,api_terrain_unplaced)}
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
    if !core.has(worlds,e) {api.call_failf(call,api.INVALID_PARAMS,"Terrain %s has no place in the world: give its entity a place with scene.write",given);return}
    marker,_:=core.get(terrains,e)
    if !terrain.terrain_stamp(s.app.assets,marker.source).found {api.call_failf(call,api.INVALID_PARAMS,"The .terrain of terrain %s is not among the assets: asset.list shows them",given);return}
    if !stroke_prepare(tool,s.app.assets,s.app.allocator,core.read(terrains),core.read(worlds),editor.Pick{entity=e}) {api.call_failf(call,api.INVALID_PARAMS,"The .terrain of terrain %s could not be read: engine.diagnostics says why",given);return}
    if !stroke_baseline(tool) {api.call_fail(call,api.INTERNAL_ERROR,"The terrain history could not be stored: there is not enough memory");return}
    return tool,world,true
}

// Whether the entity named (^string) is a terrain still without a place in the world.
@(private)
api_terrain_unplaced :: proc(s:^editor.Session,user:rawptr) -> bool {
    world:=editor.edited_world(s)
    terrains:=core.world_table_of(world,terrain.Terrain);worlds:=core.world_table_of(world,core.World_Transform)
    e,_:=editor.api_entity_find(world,(^string)(user)^)
    return terrains!=nil && worlds!=nil && e!=core.NONE && core.has(terrains,e) && !core.has(worlds,e)
}

@(private)
api_changed_write :: proc(call:^api.Call,changed:bool,touches:int) {
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_bool(w,"changed",changed,true)
    if touches>0 {api.write_int(w,"touches",i64(touches))}
    serial.text_write_raw(w,"}")
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
    kind:terrain.Source_Kind
    switch strings.to_lower(base.text_get(p.kind[:]),context.temp_allocator) {
    case "","heightfield": kind=.Heightfield
    case "mesh":        kind=.Mesh
    case "volume":      kind=.Volume
    case: api.call_fail(call,api.INVALID_PARAMS,"kind is heightfield, mesh or volume");return
    }
    name:=base.text_get(p.name[:])
    if name!="" && !api_name_free(s,call,name) {return}
    path:=base.text_get(p.heightmap[:])
    if path!="" {
        file,problem:=editor.api_file_path(s.project_root,path,context.temp_allocator)
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,fmt.tprintf("heightmap: %s",problem));return}
        path=file
    }
    if path!="" && kind==.Volume {api.call_fail(call,api.INVALID_PARAMS,"A volume starts as a solid block: a heightmap makes a heightfield or a mesh");return}
    tool.create_kind,tool.create_source=kind,path!=""?.Heightmap:.Plane
    tool.samples,tool.depth,tool.cell,tool.chunk_cells=int(p.samples),int(p.depth),p.spacing,int(p.chunk_cells)
    tool.height_scale,tool.height_offset,tool.solid_depth=p.height_scale,p.height_offset,p.base_depth
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_key(w,"id",true);api.write_id(w,editor.api_entity_id(world,e))
    serial.text_write_raw(w,"}")
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
    case "remove":     return .Remove,false,true
    case "union":      return .Union,false,true
    case "subtract":   return .Subtract,false,true
    }
    return
}

@(private)
api_edit :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Edit_Params)
    kind,level,named:=brush_named(strings.to_lower(base.text_get(p.brush[:]),context.temp_allocator))
    if !named {api.call_fail(call,api.INVALID_PARAMS,"brush is raise, lower, smooth, flatten, set_height, ramp, terrace, noise, erode, paint, erase, hole, fill, add, remove, union or subtract");return}
    if r,own:=editor.api_play_run(s,call,p.player);r!=nil {
        if !own {editor.api_play_refused(call);return}
        api_edit_play(s,call,p,editor.run_ref(s,r),kind,level)
        return
    }
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    stroke:=&tool.stroke
    source:=&stroke.source
    // What each representation takes, as the panel offers it.
    taken:bool
    switch source.kind {
    case .Heightfield: taken=kind!=.Add && kind!=.Remove && kind!=.Union && kind!=.Subtract
    case .Mesh:        taken=kind==.Raise || kind==.Lower || kind==.Smooth || kind==.Flatten || kind==.Paint || kind==.Erase || kind==.Union || kind==.Subtract
    case .Volume:      taken=kind==.Add || kind==.Remove || kind==.Smooth || kind==.Flatten || kind==.Noise || kind==.Paint || kind==.Erase || kind==.Union || kind==.Subtract
    }
    if !taken {
        offers:=[terrain.Source_Kind]string{.Heightfield="raise, lower, smooth, flatten, set_height, ramp, terrace, noise, erode, paint, erase, hole and fill",.Mesh="raise, lower, smooth, flatten, set_height, paint, erase, union and subtract",.Volume="add, remove, smooth, flatten, set_height, noise, paint, erase, union and subtract"}
        api.call_failf(call,api.INVALID_PARAMS,"A %s takes %s",terrain_kind_name(source.kind),offers[source.kind])
        return
    }
    layer:=0
    if name:=base.text_get(p.layer[:]);name!="" {
        found:bool
        if layer,found=layer_named(s,call,source,name);!found {return}
    }
    falloffs:=[?]string{"smooth","sphere","linear","sharp","flat"}
    falloff:=geom.Falloff.Smooth
    if name:=strings.to_lower(base.text_get(p.falloff[:]),context.temp_allocator);name!="" {
        found:=false
        for f,i in falloffs {if f==name {falloff,found=geom.Falloff(i),true}}
        if !found {api.call_fail(call,api.INVALID_PARAMS,"falloff is smooth, sphere, linear, sharp or flat");return}
    }
    way:=terrain.Brush_Way.Both
    switch strings.to_lower(base.text_get(p.way[:]),context.temp_allocator) {
    case "","both":
    case "raise": way=.Up
    case "lower": way=.Down
    case: api.call_fail(call,api.INVALID_PARAMS,"way is both, raise or lower");return
    }
    alpha:^terrain.Brush_Alpha
    if name:=base.text_get(p.alpha[:]);name!="" {
        alphas_ready(&tool.alphas)
        for held,i in tool.alphas.names {if strings.equal_fold(held,name) {alpha=&tool.alphas.list[i]}}
        if alpha==nil {api.call_fail(call,api.INVALID_PARAMS,"No alpha by that name: the Shape of the panel lists them");return}
    }
    // Points of the world into the terrain; on a Heightfield on its surface.
    local :: proc(stroke:^Stroke,p:[3]f32) -> [3]f32 {
        q:=(stroke.to_local*[4]f32{p.x,p.y,p.z,1}).xyz
        if stroke.source.kind==.Heightfield {q.y=terrain.source_height(&stroke.source,q.x,q.z)}
        return q
    }
    from:=local(stroke,p.at)
    to:=from
    path:=p.to!={}
    if path {to=local(stroke,p.to)}
    radius:=p.radius/stroke.scale
    brush:=terrain.Brush{kind=kind,radius=radius,falloff=falloff,hardness=clamp(p.hardness,0,0.95),way=way,capped=p.capped && source.kind==.Heightfield,interval=max(p.interval,0.01)/stroke.scale,riser=clamp(p.riser,0,1),scale=max(p.scale,0.1)/stroke.scale,layer=u32(layer),alpha=alpha,turn=math.to_radians(p.turn),seed=u32(stroke.id[0]),normal={0,1,0},max_edge=tool.edge_length/stroke.scale}
    if p.slope!={} && source.kind==.Heightfield {
        low,high:=math.to_radians(min(p.slope.x,p.slope.y)),math.to_radians(max(p.slope.x,p.slope.y))
        brush.slope,brush.slope_invert={clamp(low,0,math.PI/2),clamp(max(high,low+1e-4),0,math.PI/2)},p.slope_invert
    }
    if kind==.Paint && editor.tool_call_given(call,"weight") {brush.toward,brush.target=true,clamp(p.weight,0,1)}
    // Flatten, set_height and a capped brush keep the height of at, or the one given.
    target:=from.y
    if level && editor.tool_call_given(call,"height") {target=(stroke.to_local*[4]f32{p.at.x,p.height,p.at.z,1}).y}
    stroke.target=target
    if kind==.Flatten || brush.capped || kind==.Terrace {brush.target=target}
    strength:=clamp(p.strength,0,1)
    stroke.active=true
    defer if stroke.active {stroke_cancel(tool)}
    touches:=0
    s.toast_length=0
    // A ramp and a shape are one touch from at to to; the others touch along the stroke.
    if kind==.Ramp || kind==.Union || kind==.Subtract {
        brush.center,brush.amount=from,1
        if kind==.Ramp {
            if !path {api.call_fail(call,api.INVALID_PARAMS,"A ramp goes from at to to: give to");return}
            sides:=max(p.sides,0)/stroke.scale
            brush.center,brush.delta=from,to-from
            brush.center.y,brush.delta.y=(stroke.to_local*[4]f32{p.at.x,p.at.y,p.at.z,1}).y,(stroke.to_local*[4]f32{p.to.x,p.to.y,p.to.z,1}).y-(stroke.to_local*[4]f32{p.at.x,p.at.y,p.at.z,1}).y
            brush.radius,brush.hardness=radius+sides,min(radius/(radius+sides),0.99)
        } else {
            names:=[?]string{"sphere","capsule","box"}
            shape:=strings.to_lower(base.text_get(p.shape[:]),context.temp_allocator)
            if shape=="" {shape="sphere"}
            found:=false
            for name,i in names {if name==shape {brush.shape,found=terrain.Brush_Shape(i),true}}
            if !found {api.call_fail(call,api.INVALID_PARAMS,"shape is sphere, capsule or box");return}
            brush.rotation=1
            if brush.shape==.Capsule {brush.delta=to-from}
            if brush.shape==.Box {brush.extent=radius}
            if source.kind==.Volume {brush.blend=max(tool.blend,0)/stroke.scale}
        }
        change:=terrain.source_edit(source,brush,terrain_vertex_budget(world,stroke.id))
        if change.error!=.None {edit_error(s,change.error);editor.tool_call_fail(s,call,"The terrain operation is invalid");return}
        stroke_changed(stroke,change)
        touches=1
    } else {
        step:=to-from
        count:=path?clamp(int(math.ceil(linalg.length(step)/(radius*STROKE_SPACING))),1,4096):1
        for _ in 0..<max(p.passes,1) {
            for i in 0..=count {
                if !path && i>0 {break}
                point:=from+step*(f32(i)/f32(max(count,1)))
                if source.kind==.Heightfield {point.y=terrain.source_height(source,point.x,point.z)} else if hit,normal,found:=terrain.source_ray(source,point+[3]f32{0,radius*4,0},{0,-1,0});found {point,brush.normal=hit,normal}
                brush.center=point
                #partial switch kind {
                case .Raise,.Lower,.Noise: brush.amount=strength*radius*RAISE_PER_PASS
                case:                      brush.amount=strength
                }
                if kind==.Erode {brush.seed=u32(base.hash_u64(u64(touches)+u64(stroke.id[1])))}
                if !(brush.amount>0) {continue}
                change:=terrain.source_edit(source,brush,terrain_vertex_budget(world,stroke.id))
                if change.error!=.None {edit_error(s,change.error);editor.tool_call_fail(s,call,"The terrain operation is invalid");return}
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
    case .Union,.Subtract: return "Shape"
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_uint(w,"layers",u64(tool.stroke.source.layer_count),true)
    if !p.remove {api.write_text(w,"layer",layer_names(s,&tool.stroke.source)[index])}
    serial.text_write_raw(w,"}")
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
api_play_terrain :: proc(call:^api.Call,w:core.World_Ref,named:[]u8) -> (e:core.Entity,source:^terrain.Source,requests:^terrain.Terrain_Requests,to_local:matrix[4,4]f32,scale:f32,ok:bool) {
    terrains,worlds:=core.world_table_of(w,terrain.Terrain),core.world_table_of(w,core.World_Transform)
    data,queued:=core.world_storage_of(w,terrain.Terrain_Data),core.world_storage_of(w,terrain.Terrain_Requests)
    if terrains==nil || worlds==nil || data==nil || queued==nil {api.call_fail(call,api.INVALID_PARAMS,"The game has no terrain: activate the plugin terrain in project.mirai");return}
    named_found:bool
    if e,named_found=editor.api_call_entity(call,w,named,game=true);!named_found {return}
    given:=base.text_get(named)
    marker,found:=core.get(terrains,e)
    if !found {api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a Terrain in the game: play.inspect lists them",given);return}
    placed,has:=core.get(worlds,e)
    source=terrain.terrain_source(core.ref(data),marker.source)
    if !has || source==nil {api.call_failf(call,api.INVALID_PARAMS,"The source of terrain %s is not loaded in the game yet: step it and call again",given);return}
    to_local=linalg.inverse(mm.transform_matrix(placed.transform))
    scale=max(abs(placed.scale.x),1e-6)
    return e,source,queued,to_local,scale,true
}

// terrain.edit in a game that plays: its touches as requests of the game.
@(private)
api_edit_play :: proc(s:^editor.Session,call:^api.Call,p:^Edit_Params,w:core.World_Ref,kind:terrain.Brush_Kind,level:bool) {
    e,source,requests,to_local,scale,ok:=api_play_terrain(call,w,p.entity[:])
    if !ok {return}
    if base.text_get(p.alpha[:])!="" {api.call_fail(call,api.INVALID_PARAMS,"A game asks for brushes without an alpha: leave alpha out");return}
    if kind==.Ramp || kind==.Union || kind==.Subtract {api.call_fail(call,api.INVALID_PARAMS,"While a game plays terrain.edit asks for the brushes that touch along a stroke; a ramp or a shape goes in a request of play.push");return}
    layer:=0
    if name:=base.text_get(p.layer[:]);name!="" {
        found:bool
        if layer,found=layer_named(s,call,source,name);!found {return}
    }
    local :: proc(source:^terrain.Source,to_local:matrix[4,4]f32,p:[3]f32) -> [3]f32 {
        q:=(to_local*[4]f32{p.x,p.y,p.z,1}).xyz
        if source.kind==.Heightfield {q.y=terrain.source_height(source,q.x,q.z)}
        return q
    }
    from:=local(source,to_local,p.at)
    to:=p.to!={}?local(source,to_local,p.to):from
    radius:=p.radius/scale
    falloff:=geom.Falloff.Smooth
    if name:=base.text_get(p.falloff[:]);name!="" {
        names:=[?]string{"smooth","sphere","linear","sharp","flat"}
        found:=false
        for f,i in names {if strings.equal_fold(f,name) {falloff,found=geom.Falloff(i),true}}
        if !found {api.call_fail(call,api.INVALID_PARAMS,"falloff is smooth, sphere, linear, sharp or flat");return}
    }
    brush:=terrain.Brush{kind=kind,radius=radius,falloff=falloff,hardness=clamp(p.hardness,0,0.95),capped=p.capped && source.kind==.Heightfield,interval=max(p.interval,0.01)/scale,riser=clamp(p.riser,0,1),scale=max(p.scale,0.1)/scale,layer=u32(layer),normal={0,1,0},rotation=1,seed=u32(editor.api_entity_id(w,e))}
    if kind==.Paint && editor.tool_call_given(call,"weight") {brush.toward,brush.target=true,clamp(p.weight,0,1)}
    if kind==.Flatten || brush.capped || kind==.Terrace {brush.target=level && editor.tool_call_given(call,"height")?(to_local*[4]f32{p.at.x,p.height,p.at.z,1}).y:from.y}
    step:=to-from
    count:=p.to!={}?clamp(int(math.ceil(linalg.length(step)/(radius*STROKE_SPACING))),1,4096):0
    touches:=(count+1)*int(max(p.passes,1))
    room:=cap(requests.edits.items)-len(requests.edits.items)
    if touches>room {api.call_failf(call,api.INVALID_PARAMS,"The stroke would ask for %d touches and the game has room for %d in this tick: make it shorter or the radius larger, go on after a tick, or raise Terrain_Settings.requests",touches,room);return}
    place,_:=core.get(core.read(core.world_table_of(w,core.World_Transform)),e)
    pushed:=0
    for _ in 0..<max(p.passes,1) {
        for i in 0..=count {
            brush.center=from+step*(f32(i)/f32(max(count,1)))
            if source.kind==.Heightfield {brush.center.y=terrain.source_height(source,brush.center.x,brush.center.z)}
            #partial switch kind {
            case .Raise,.Lower,.Noise: brush.amount=clamp(p.strength,0,1)*radius*RAISE_PER_PASS
            case:                      brush.amount=clamp(p.strength,0,1)
            }
            if brush.amount>0 {terrain.dig(requests,terrain.brush_world(brush,place.transform),e);pushed+=1}
        }
    }
    serial.text_write_raw(call.out,"{")
    api.write_bool(call.out,"changed",pushed>0,true)
    api.write_int(call.out,"touches",i64(pushed))
    serial.text_write_raw(call.out,"}")
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
    serial.text_write_raw(call.out,"{")
    api.write_uint(call.out,"layers",u64(p.remove?count-1:max(count,index+1)),true)
    serial.text_write_raw(call.out,"}")
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_uint(w,"strata",u64(source.interior.strata_count),true)
    api.write_uint(w,"veins",u64(source.interior.vein_count))
    serial.text_write_raw(w,"}")
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_bool(w,"found",found,true)
    if played {
        api.write_uint(w,"layers",u64(source.layer_count))
        api.write_key(w,"check");buffer:[16]u8;serial.text_write_string(w,fmt.bprintf(buffer[:],"%016x",check))
    }
    if found {
        world_point:=(to_world*[4]f32{point.x,point.y,point.z,1}).xyz
        up:=linalg.normalize0((to_world*[4]f32{normal.x,normal.y,normal.z,0}).xyz)
        api.write_key(w,"height");api.write_number(w,world_point.y)
        api.write_key(w,"normal");serial.text_write_raw(w,"[");api.write_number(w,up.x);serial.text_write_raw(w,",");api.write_number(w,up.y);serial.text_write_raw(w,",");api.write_number(w,up.z);serial.text_write_raw(w,"]")
        api.write_key(w,"slope");api.write_number(w,math.to_degrees(math.acos(clamp(normal.y,-1,1))))
        weights:=terrain.layers_vertex(source,terrain.source_weights_at(source,point),normal,point.y)
        api.write_key(w,"weights");serial.text_write_raw(w,"{")
        for name,i in layer_names(s,source) {
            api.write_key(w,name,i==0)
            api.write_number(w,weights[i])
        }
        serial.text_write_raw(w,"}")
    }
    if source.kind==.Heightfield {
        origin:=terrain.source_origin(source)
        c,r:=int((q.x-origin.x)/source.cell),int((q.z-origin.z)/source.cell)
        api.write_bool(w,"hole",c>=0 && r>=0 && c<int(source.samples.x)-1 && r<int(source.samples.z)-1 && terrain.source_hole(source,c,r))
    }
    serial.text_write_raw(w,"}")
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_key(w,"height_scale",true);api.write_number(w,tool.height_scale)
    api.write_key(w,"height_offset");api.write_number(w,tool.height_offset)
    if exported!="" {api.write_text(w,"written",exported)}
    serial.text_write_raw(w,"}")
}

@(private)
api_resize :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Resize_Params)
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    s.toast_length=0
    if !terrain_resize(s,tool,world,s.app.assets,{int(p.samples.x),int(p.samples.y)}) {editor.tool_call_fail(s,call,"The terrain could not be resized");return}
    w:=call.out
    serial.text_write_raw(w,"{")
    resized,_:=editor.api_entity_find(world,base.text_get(p.entity[:]))
    api.write_key(w,"id",true);api.write_id(w,editor.api_entity_id(world,resized))
    serial.text_write_raw(w,"}")
}
