package editor

import "core:math/linalg"
import "mirai:core"
import "mirai:editor/api"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// Spatial queries on the document in Edit, over the meshes the viewport
// picks: rays, boxes and resting entities on what is under them. Places come
// from the locals, so they see the edits of this frame.

API_SPATIAL_LIMIT :: 64
GROUND_RISE :: f32(0.5) // m: how far above its bottom a ground ray starts at least; an entity rises at most that or its height

Api_Raycast_Params :: struct {
    origin:[3]f32 `mirai:"optional,label=Where the ray starts in the world; with direction"`,
    direction:[3]f32 `mirai:"optional,label=Where the ray goes in the world; not zero; it is normalized"`,
    point:[2]f32 `mirai:"optional,label=Instead of origin and direction: window points over the viewport the ray goes through from the camera of the editor"`,
    reach:f32 `mirai:"optional,unit=m,label=How far the ray looks"`,
    ignore:[API_SPATIAL_LIMIT][API_ENTITY_TEXT]u8 `mirai:"optional,text,label=Entities the ray goes through with what hangs from them by name or path Parent/Child or id"`,
}
Api_Raycast_Result :: struct {
    hit:bool `mirai:"label=Whether the ray met a mesh; without a hit the rest is empty"`,
    id:base.Entity_Id `mirai:"label=The entity met: the nearest one with an id that holds the mesh"`,
    name:[64]u8 `mirai:"text"`,
    point:[3]f32 `mirai:"label=Where it met it in the world"`,
    normal:[3]f32 `mirai:"label=Of the surface met in the world facing the ray"`,
    distance:f32 `mirai:"unit=m"`,
}

Api_Spatial_Entities_Params :: struct {
    entities:[API_SPATIAL_LIMIT][API_ENTITY_TEXT]u8 `mirai:"text,label=Entities of the scene by name or path Parent/Child or id"`,
}
Api_Bounds_Entity :: struct {
    id:base.Entity_Id,
    min,max,center,size:[3]f32 `mirai:"label=Of the box in the world of the entity with what hangs from it"`,
    meshes:bool `mirai:"label=Whether meshes make the box; without them it is the point of the entity"`,
}
Api_Bounds_Result :: struct {
    entities:[API_SPATIAL_LIMIT]Api_Bounds_Entity `mirai:"trim,label=One per entity in their order"`,
    min,max,center,size:[3]f32 `mirai:"label=Of the box around all of them"`,
    meshes:bool `mirai:"label=Whether any of them has meshes"`,
}

Api_Ground_Params :: struct {
    entities:[API_SPATIAL_LIMIT][API_ENTITY_TEXT]u8 `mirai:"text,label=Entities of the scene by name or path Parent/Child or id to rest on what is under them; none hanging from another"`,
    offset:f32 `mirai:"optional,unit=m,label=Height of the bottom of each over the surface"`,
    align:bool `mirai:"optional,label=Also turn each so that its up axis follows the normal of the surface"`,
}
Api_Ground_Entity :: struct {
    id:base.Entity_Id,
    position:[3]f32 `mirai:"label=Local to the parent"`,
    rotation_deg:[3]f32 `mirai:"label=Local to the parent in degrees"`,
    world_position:[3]f32,
    moved:f32 `mirai:"unit=m,label=How far it went up; negative is down"`,
}
Api_Ground_Result :: struct {
    entities:[API_SPATIAL_LIMIT]Api_Ground_Entity `mirai:"trim,label=One per entity in their order"`,
}

@(private)
spatial_api_register :: proc(s:^Session,st:^Api_State) {
    raycast:=Api_Raycast_Params{reach=PICK_REACH}
    api_register(s,st,{name="scene.raycast",summary="The first mesh of the document a ray meets: the one picking in the viewport would select.",params=Api_Raycast_Params,result=Api_Raycast_Result,defaults=&raycast,flags={.Read_Only},run=api_scene_raycast})
    api_register(s,st,{name="scene.bounds",summary="The boxes in the world of entities of the document with what hangs from them and the box around them all.",params=Api_Spatial_Entities_Params,result=Api_Bounds_Result,flags={.Read_Only},run=api_scene_bounds})
    api_register(s,st,{name="scene.ground",summary="Moves entities of the document up or down until the bottom of their box rests on the first surface under them as one step of undo.",params=Api_Ground_Params,result=Api_Ground_Result,run=api_scene_ground})
}

@(private="file")
spatial_in_edit :: proc(s:^Session,call:^api.Call,method:string) -> bool {
    if !playing(s) {return true}
    api.call_failf(call,api.SERVER_ERROR,"%s works on the document in Edit; play.stop first, or read the world of the game with play.inspect",method)
    return false
}

// Whether the params name a key, whatever its value.
@(private="file")
spatial_given :: proc(call:^api.Call,key:string) -> bool {
    a:Rpc_Args
    rpc_init(&a,call,call.raw)
    if !serial.text_accept(&a.r,'{') {return false}
    object:Rpc_Object
    for name in rpc_next(&a,&object) {
        if name==key {return true}
        if _,ok:=rpc_raw(&a);!ok {break}
    }
    return false
}

// The bodies of the scene with their places from the locals; with ghosts,
// also what is hidden or turned off.
@(private="file")
spatial_items :: proc(s:^Session,w:core.World_Ref,ghosts:bool) -> []Scene_Item {
    out:=make([dynamic]Scene_Item,context.temp_allocator)
    it:=scene_items(s,w,ghosts,locals=true)
    for item in scene_item_next(&it) {
        if item.body {append(&out,item)}
    }
    return out[:]
}

@(private="file")
spatial_ignored :: proc(w:core.World_Ref,e:core.Entity,ignore:[]core.Entity) -> bool {
    for ignored in ignore {
        if entity_under(w,e,ignored) {return true}
    }
    return false
}

@(private="file")
spatial_ray :: proc(s:^Session,w:core.World_Ref,items:[]Scene_Item,ray:mm.Ray,reach:f32,ignore:[]core.Entity) -> (hit:Pick) {
    nearest:=reach
    for item in items {
        met,found:=pick_item(s,w,item,ray,nearest)
        if !found || spatial_ignored(w,item.entity,ignore) {continue}
        hit,nearest=met,met.distance
    }
    return
}

// The world box of the meshes of an entity and of what hangs from it, moved
// by `by`. Without meshes, the point of the entity.
@(private="file")
spatial_box :: proc(s:^Session,w:core.World_Ref,items:[]Scene_Item,e:core.Entity,by:mm.Mat4=1) -> (box:mm.Aabb,meshes:bool) {
    box={{1e30,1e30,1e30},{-1e30,-1e30,-1e30}}
    for item in items {
        if !entity_under(w,item.entity,e) {continue}
        low,high,known:=picker_bounds(s.picker,s.app.assets,item.mesh)
        if !known {continue}
        placed:=mm.aabb_transform({low,high},by*mm.transform_matrix(item.world))
        box={linalg.min(box.min,placed.min),linalg.max(box.max,placed.max)}
        meshes=true
    }
    if !meshes {
        point:=mm.mat4_point(by,entity_world(w,e).position)
        box={point,point}
    }
    return
}

@(private="file")
spatial_finite :: proc "contextless" (values:[]f32) -> bool {
    for v in values {
        if v-v!=0 {return false}
    }
    return true
}

@(private)
api_scene_raycast :: proc(s:^Session,call:^api.Call) {
    if !spatial_in_edit(s,call,"scene.raycast") {return}
    params:=api.call_params(call,Api_Raycast_Params)
    w:=edited_world(s)
    ignore,known:=api_call_entities(call,w,params.ignore[:],"ignore")
    if !known {return}
    if !spatial_finite({params.reach}) || params.reach<=0 {
        api.call_fail(call,api.INVALID_PARAMS,"reach must be a finite number of meters above 0")
        return
    }
    by_point:=spatial_given(call,"point")
    has_origin,has_direction:=spatial_given(call,"origin"),spatial_given(call,"direction")
    ray:mm.Ray
    switch {
    case by_point && (has_origin || has_direction):
        api.call_fail(call,api.INVALID_PARAMS,"point makes the ray from the camera of the editor; give point alone or origin and direction")
        return
    case by_point:
        v:=s.viewport
        if v==nil || v.size.x<=0 || v.size.y<=0 {
            api.call_fail(call,api.SERVER_ERROR,"The editor shows no viewport to cast from; give origin and direction")
            return
        }
        point:=params.point
        if !spatial_finite(point[:]) || point.x<v.origin.x || point.y<v.origin.y || point.x>v.origin.x+v.size.x || point.y>v.origin.y+v.size.y {
            api.call_failf(call,api.INVALID_PARAMS,"point [%g,%g] is not over the viewport: it spans window points [%g,%g] to [%g,%g]",point.x,point.y,v.origin.x,v.origin.y,v.origin.x+v.size.x,v.origin.y+v.size.y)
            return
        }
        ray=viewport_ray(v,point)
    case:
        if !has_origin || !has_direction {
            api.call_fail(call,api.INVALID_PARAMS,"give origin and direction of the ray in the world, or point over the viewport")
            return
        }
        if !spatial_finite(params.origin[:]) || !spatial_finite(params.direction[:]) {
            api.call_fail(call,api.INVALID_PARAMS,"origin and direction must be finite numbers")
            return
        }
        length:=linalg.length(params.direction)
        if length<1e-6 {
            api.call_fail(call,api.INVALID_PARAMS,"direction is zero; give where the ray goes, as [0,-1,0] for down")
            return
        }
        ray={params.origin,params.direction/length}
    }
    hit:=spatial_ray(s,w,spatial_items(s,w,false),ray,params.reach,ignore)
    if hit.entity==core.NONE {return}
    result:=api.call_result(call,Api_Raycast_Result)
    result^={hit=true,id=api_entity_id(w,hit.entity),point=hit.position,normal=hit.normal,distance=hit.distance}
    api_text_put(result.name[:],entity_name(w,hit.entity))
}

@(private)
api_scene_bounds :: proc(s:^Session,call:^api.Call) {
    if !spatial_in_edit(s,call,"scene.bounds") {return}
    params:=api.call_params(call,Api_Spatial_Entities_Params)
    w:=edited_world(s)
    entities,known:=api_call_entities(call,w,params.entities[:],"entities")
    if !known {return}
    if len(entities)==0 {
        api.call_failf(call,api.INVALID_PARAMS,"entities must name 1 to %d entities of the scene",API_SPATIAL_LIMIT)
        return
    }
    items:=spatial_items(s,w,true)
    result:=api.call_result(call,Api_Bounds_Result)
    all:=mm.Aabb{{1e30,1e30,1e30},{-1e30,-1e30,-1e30}}
    for e,i in entities {
        box,meshes:=spatial_box(s,w,items,e)
        result.entities[i]={id=api_entity_id(w,e),min=box.min,max=box.max,center=(box.min+box.max)*0.5,size=box.max-box.min,meshes=meshes}
        all={linalg.min(all.min,box.min),linalg.max(all.max,box.max)}
        result.meshes||=meshes
    }
    result.min,result.max,result.center,result.size=all.min,all.max,(all.min+all.max)*0.5,all.max-all.min
}

// The box around some entities of a world, with what hangs from them.
api_entities_box :: proc(s:^Session,w:core.World_Ref,entities:[]core.Entity) -> mm.Aabb {
    items:=spatial_items(s,w,true)
    all:=mm.Aabb{{1e30,1e30,1e30},{-1e30,-1e30,-1e30}}
    for e in entities {
        box,_:=spatial_box(s,w,items,e)
        all={linalg.min(all.min,box.min),linalg.max(all.max,box.max)}
    }
    return all
}

// The highest surface the rays down from the footprint of a box meet: the
// first one its bottom touches going down. The normal is that of the middle
// ray when it meets one.
@(private="file")
spatial_ground_surface :: proc(s:^Session,w:core.World_Ref,items:[]Scene_Item,e:core.Entity,box:mm.Aabb) -> (height:f32,normal:[3]f32,found:bool) {
    start:=max(box.max.y,box.min.y+GROUND_RISE)+1e-3
    height=-1e30
    middle:[3]f32
    for row in 0..<3 {
        for column in 0..<3 {
            x:=box.min.x+(box.max.x-box.min.x)*f32(column)*0.5
            z:=box.min.z+(box.max.z-box.min.z)*f32(row)*0.5
            hit:=spatial_ray(s,w,items,{{x,start,z},{0,-1,0}},PICK_REACH,{e})
            if hit.entity==core.NONE {continue}
            if hit.position.y>height {height,normal=hit.position.y,hit.normal}
            if row==1 && column==1 {middle=hit.normal}
            found=true
        }
    }
    if middle!={} {normal=middle}
    return
}

@(private)
api_scene_ground :: proc(s:^Session,call:^api.Call) {
    if !spatial_in_edit(s,call,"scene.ground") {return}
    params:=api.call_params(call,Api_Ground_Params)
    if !spatial_finite({params.offset}) {
        api.call_fail(call,api.INVALID_PARAMS,"offset must be a finite number of meters")
        return
    }
    if !api_edit_begin(s,call,"Ground") {return}
    w:=edited_world(s)
    entities,known:=api_call_entities(call,w,params.entities[:],"entities")
    if !known {api_edit_end(s,call,false);return}
    if len(entities)==0 {
        api.call_failf(call,api.INVALID_PARAMS,"entities must name 1 to %d entities of the scene",API_SPATIAL_LIMIT)
        api_edit_end(s,call,false)
        return
    }
    places:=make([]mm.Transform,len(entities),context.temp_allocator)
    result:=api.call_result(call,Api_Ground_Result)
    boxes,surfaces:=spatial_items(s,w,true),spatial_items(s,w,false)
    for e,i in entities {
        id:=api_entity_id(w,e)
        for other in entities {
            if other!=e && entity_under(w,e,other) {
                api.call_failf(call,api.INVALID_PARAMS,"entities[%d]: 0x%016x hangs from 0x%016x which is listed too and moves it; list only the one above",i,u64(id),u64(api_entity_id(w,other)))
                api_edit_end(s,call,false)
                return
            }
        }
        if !entity_has(w,e,core.Transform) {
            api.call_failf(call,api.INVALID_PARAMS,"entities[%d]: 0x%016x has no Transform to move",i,u64(id))
            api_edit_end(s,call,false)
            return
        }
        world:=entity_world(w,e)
        box,_:=spatial_box(s,w,boxes,e)
        height,normal,found:=spatial_ground_surface(s,w,surfaces,e,box)
        if !found {
            api.call_failf(call,api.INVALID_PARAMS,"entities[%d]: nothing shown is under 0x%016x %q; move it over a surface first or leave it out",i,u64(id),entity_label(w,e))
            api_edit_end(s,call,false)
            return
        }
        placed:=world
        if params.align && linalg.length(normal)>0.5 {
            up:=linalg.normalize0(mm.transform_direction(world,{0,1,0}))
            placed.rotation=linalg.normalize(mm.quat_between(up,linalg.normalize(normal))*world.rotation)
            inverse,invertible:=mm.transform_inverse_matrix(world)
            if !invertible {
                api.call_failf(call,api.INVALID_PARAMS,"entities[%d]: 0x%016x has no size on some axis and cannot turn; give it a scale or leave align out",i,u64(id))
                api_edit_end(s,call,false)
                return
            }
            box,_=spatial_box(s,w,boxes,e,mm.transform_matrix(placed)*inverse)
            if turned,_,met:=spatial_ground_surface(s,w,surfaces,e,box);met {height=turned}
        }
        moved:=height+params.offset-box.min.y
        placed.position.y+=moved
        local,related:=mm.transform_relative(placed,entity_parent_world(w,e))
        if !related {
            api.call_failf(call,api.INVALID_PARAMS,"entities[%d]: the parent of 0x%016x has no size on some axis",i,u64(id))
            api_edit_end(s,call,false)
            return
        }
        before:=entity_local(w,e)
        local.scale=before.scale
        if !params.align {local.rotation=before.rotation}
        places[i]=local
        result.entities[i]={id=id,position=local.position,rotation_deg=mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD,world_position=placed.position,moved=moved}
    }
    for e,i in entities {
        if !transform_set(s,e,places[i]) {
            api.call_failf(call,api.SERVER_ERROR,"entities[%d]: the transform of 0x%016x cannot be written now; another user holds it",i,u64(api_entity_id(w,e)))
            break
        }
    }
    api_edit_end(s,call,!call.failed)
}
