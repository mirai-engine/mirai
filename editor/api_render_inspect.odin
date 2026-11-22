package editor

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"

// render.inspect_entity: what the renderer does with one entity in the image
// capture would take now, read from frames drawn for it as capture draws them
// while the cull of the GPU reports on its instance: never a test of its box
// again on the CPU.

Api_Render_Inspect_Params :: struct {
    entity:[API_ENTITY_TEXT]u8 `mirai:"text,entity,label=By its name or a path Parent/Child or its id or its handle"`,
    world:Api_Capture_Of `mirai:"optional,label=Game: the game of the caller as its camera shows it. Scene: what the viewport shows through its camera. Auto: Game while the caller has one playing, otherwise Scene; as capture with of"`,
}

// Why an entity is not in the image; None: it is.
Api_Render_Culled :: enum u8 {
    None,
    Disabled,     // it is turned off
    Hidden,       // Hidden on it or above it, or out of the layers of the camera, behind its clip plane or faded out
    No_Mesh,      // no Mesh_Renderer, or one with no mesh and no shape
    Frustum,      // its box is outside what the camera sees
    Occluded,     // its box is behind what is drawn in front of it
    Not_In_Scene, // the renderer holds no instance of it: its mesh has not arrived or failed
}

Api_Render_Inspect_Material :: struct {
    slot:int `mirai:"label=Of its mesh"`,
    path:string `mirai:"label=The material asset of the slot; empty: the default material"`,
    program:string `mirai:"label=The material program it is drawn with; empty: the standard surface"`,
    alpha_mode:asset.Alpha_Mode,
    base_color:[3]f32 `mirai:"label=As drawn, with the values the entity gives it"`,
    metallic:f32,
    roughness:f32,
}

Api_Render_Inspect_Result :: struct {
    entity:core.Entity `mirai:"label=Its handle in the world inspected"`,
    id:base.Entity_Id `mirai:"optional,label=Its id; absent for an entity of a game that has none"`,
    name:string,
    has_mesh:bool `mirai:"label=A Mesh_Renderer with a mesh or a shape"`,
    mesh:string `mirai:"label=The mesh asset, or the shape"`,
    visible:bool `mirai:"label=The cull of the last frame drew it"`,
    culled_reason:Api_Render_Culled,
    lod:int `mirai:"label=The finest level of its mesh the cut of clusters took, 0 the full detail; -1 when it was not drawn"`,
    levels:int `mirai:"label=Of its mesh in the renderer"`,
    aabb_min:[3]f32 `mirai:"unit=m,label=Of the box the renderer culls it by in the world; without an instance, that of its mesh where it is"`,
    aabb_max:[3]f32 `mirai:"unit=m"`,
    distance:f32 `mirai:"unit=m,label=From the camera to the middle of its box; 0 when no frame culled it"`,
    textures_pending:int `mirai:"label=Textures of its materials that do not hold yet the levels the frames sample"`,
    materials:[]Api_Render_Inspect_Material `mirai:"label=By slot of its mesh"`,
    skinned:bool `mirai:"label=Its vertices are posed on the GPU by a skeleton"`,
    skin_updated:bool `mirai:"label=Its library gave its skin a pose other than the rest it starts at"`,
}

@(private)
api_render_inspect_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="render.inspect_entity",summary="What the renderer does with an entity in the image capture would take now: whether it is drawn and if not why (turned off, hidden, no mesh, outside the view, behind something, no instance), the level of detail the cut took, its box, its distance to the camera, its materials as drawn, the textures still streaming and whether its skin is posed. It draws frames as capture does without changing the document or the viewport.",params=type_info_of(Api_Render_Inspect_Params),result=type_info_of(Api_Render_Inspect_Result),flags={.Read_Only,.As_User,.Draws},run=api_render_inspect})
}

@(private)
api_render_inspect :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Render_Inspect_Params)
    r,_:=api_play_run(s,call)
    game:=p.world==.Game || p.world==.Auto && r!=nil
    if game && r==nil {api_no_game(call);return}
    if s.app==nil || s.app.assets==nil {api.call_fail(call,api.SERVER_ERROR,"The editor has no assets to inspect with");return}
    w:=game?run_ref(s,r):shown_world(s)
    e,known:=api_call_entity(call,w,p.entity[:],"entity",game=game)
    if !known {return}
    result:=api.call_result(call,Api_Render_Inspect_Result)
    result^={entity=e,id=api_entity_id(w,e),name=api.clone_text(call.allocator,entity_name(w,e)),lod=-1}
    meshes:=core.world_table_of(w,erender.Mesh_Renderer)
    shown:erender.Mesh_Renderer
    if meshes!=nil {
        if row:=core.raw_row(core.raw(meshes),e);row>=0 && !core.row_off(meshes,row) {shown=meshes.values[row];result.has_mesh=shown.mesh!={} || shown.shape!=.None}
    }
    switch {
    case shown.mesh!={}: result.mesh=api.clone_text(call.allocator,asset_path(s,shown.mesh))
    case result.has_mesh: result.mesh=fmt.aprintf("%v",shown.shape,allocator=call.allocator)
    }
    placed:=entity_world(w,e)
    mesh:=result.has_mesh?pick_mesh(s.app.assets,shown):nil
    if mesh!=nil {
        box:=mm.aabb_transform({mesh.bounds_min,mesh.bounds_max},mm.transform_matrix(placed))
        result.aabb_min,result.aabb_max=box.min,box.max
        result.skinned=mesh.skeleton!={}
    } else {
        result.aabb_min,result.aabb_max=placed.position,placed.position
    }
    switch {
    case core.entity_off(core.world_entities(w),e): result.culled_reason=.Disabled
    case entity_hidden(w,e):                         result.culled_reason=.Hidden
    case !result.has_mesh:                           result.culled_reason=.No_Mesh
    }
    if result.culled_reason!=.None {
        api_render_inspect_materials(s,call,result,shown,mesh,-1)
        return
    }
    // Frames draw the world into the renderer; then frames more with the cull
    // reporting on the instance it holds of e.
    renderer:=s.app.renderer
    if renderer==nil {api.call_fail(call,api.SERVER_ERROR,"render.inspect_entity draws frames of an entity that is on with a mesh: start without --no-gpu");return}
    if !api_render_inspect_draw(s,call,r,game) {return}
    instance:=-1
    sync:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),erender.Render_Sync)
    if id:=core.world_storage_of(w,core.World_Id);sync!=nil && id!=nil && sync.world==id^ {instance=erender.instance_of(sync,e)}
    found,held:=gpu.renderer_instance_inspect(renderer,instance)
    if !held {
        result.culled_reason=.Not_In_Scene
        api_render_inspect_materials(s,call,result,shown,mesh,-1)
        return
    }
    gpu.renderer_probe_set(renderer,instance)
    defer gpu.renderer_probe_set(renderer,-1)
    if !api_render_inspect_draw(s,call,r,game) {return}
    gpu.renderer_stats_of_last_frame(renderer)
    found,held=gpu.renderer_instance_inspect(renderer,instance)
    if !held {
        result.culled_reason=.Not_In_Scene
        api_render_inspect_materials(s,call,result,shown,mesh,-1)
        return
    }
    result.aabb_min,result.aabb_max=found.low,found.high
    result.distance=found.distance
    result.levels=found.levels
    result.lod=found.level
    result.skinned,result.skin_updated=found.skinned,found.posed
    switch found.cull {
    case .None:     result.culled_reason=.None
    case .Hidden:   result.culled_reason=.Hidden
    case .Frustum:  result.culled_reason=.Frustum
    case .Occluded: result.culled_reason=.Occluded
    case .Untested: result.culled_reason=.Not_In_Scene
    }
    result.visible=result.culled_reason==.None
    api_render_inspect_materials(s,call,result,shown,mesh,instance)
}

// The frames capture would draw of the world inspected, whose pixels go;
// false after failing the call.
@(private)
api_render_inspect_draw :: proc(s:^Session,call:^api.Call,r:^Run,game:bool) -> bool {
    pixels:[]u8
    drawn:bool
    if game {
        pixels,_,_,drawn=api_play_pixels(s,r,API_CAPTURE_SETTLE)
    } else {
        // As capture of the scene: a frame of the editor first settles what the document changed.
        api_frames(s,1,HEADLESS_DT)
        pixels,_,_,drawn=api_capture_image(s,false,api_capture_size(api_capture_viewport(s.app),0,0))
    }
    delete(pixels,s.app.allocator)
    if !drawn {api.call_failf(call,api.SERVER_ERROR,"The renderer could not draw the frame: %s",host.app_draw_problem(s.app))}
    return drawn
}

// The material of each slot of the mesh of an entity: as the renderer draws
// its instance, or without one as its assets say, with the textures of them
// still streaming.
@(private)
api_render_inspect_materials :: proc(s:^Session,call:^api.Call,result:^Api_Render_Inspect_Result,shown:erender.Mesh_Renderer,mesh:^host.Assets_Mesh,instance:int) {
    instance:=instance
    if mesh==nil {return}
    renderer:=s.app.renderer
    if renderer==nil {instance=-1}
    count:=clamp(int(mesh.slot_count),1,min(len(mesh.slot_materials),erender.MATERIAL_SLOTS))
    result.materials=make([]Api_Render_Inspect_Material,count,call.allocator)
    material:gpu.Material_Handle
    slots:[32]u32
    held:=false
    if instance>=0 {material,slots,_,held=gpu.scene_instance_materials(renderer,u32(instance))}
    pending:[8]gpu.Texture_Handle
    pending_count:=0
    for &out,slot in result.materials {
        id:=shown.materials[slot]
        if id=={} {id=mesh.slot_materials[slot]}
        desc:=gpu.DEFAULT_MATERIAL
        switch {
        case held:
            row:=u32(material)
            if slot<len(slots) && slots[slot]>0 {row=slots[slot]-1}
            desc=host.assets_material_values(s.app.assets,row)
        case id!={}:
            if ref,loaded:=s.app.assets.index[id];loaded && ref.kind==.Material {desc.info=s.app.assets.materials[ref.index].info}
        }
        out={slot=slot,path=api.clone_text(call.allocator,asset_path(s,id)),program=api.clone_text(call.allocator,base.text_get(desc.program[:])),alpha_mode=desc.alpha_mode,base_color=desc.base_color,metallic=desc.metallic,roughness=desc.roughness}
        if !held {continue}
        textures: for texture in desc.textures {
            if texture==0 || !gpu.renderer_texture_pending(renderer,texture) {continue}
            for seen in pending[:pending_count] {if seen==texture {continue textures}}
            result.textures_pending+=1
            if pending_count<len(pending) {pending[pending_count]=texture;pending_count+=1}
        }
    }
}
