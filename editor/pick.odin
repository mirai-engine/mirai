package editor

import "core:math/linalg"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import mm "mirai:std/math"
import "mirai:ui"

// What a point or a rectangle of the window reaches in the scene: the discs
// of the entities without a body first, where the scene in front does not
// cover them, then the nearest surface. A ray tests the box of each mesh, from what the assets
// know of it, before the renderer meets the mesh as it draws it
// (render.mesh_ray): through its software tree, or one it makes the first
// time a ray reaches the box while rays are traced by hardware, kept until
// the mesh goes.

PICK_REACH :: f32(1e5)

Pick :: struct {
    entity:core.Entity,
    distance:f32,
    position,normal:[3]f32, // in the world; normal faces the ray
    indicator:bool,         // the disc of an entity without a body
    batch:erender.Batch_Handle, // with batches: the batch of the instance met, whose object is entity
    instance:int,               // and that instance in it
}

// The mesh the renderer draws for a Mesh_Renderer: one that cannot be loaded
// is the stand-in drawn in its place.
@(private)
pick_mesh :: proc(a:^host.Assets,mesh:erender.Mesh_Renderer) -> ^host.Assets_Mesh {
    if a==nil {return nil}
    return mesh.mesh!={}?host.assets_mesh(a,mesh.mesh):host.assets_shape(a,mesh.shape)
}

// The box of what a Mesh_Renderer shows, in the space of its mesh.
mesh_bounds :: proc(a:^host.Assets,mesh:erender.Mesh_Renderer) -> (low,high:[3]f32,ok:bool) {
    m:=pick_mesh(a,mesh)
    if m==nil {return}
    return m.bounds_min,m.bounds_max,true
}

// One entity with a Transform as the viewport sees it.
Scene_Item :: struct {
    entity:core.Entity,
    world:mm.Transform,
    mesh:erender.Mesh_Renderer,
    hidden:bool,               // itself or an ancestor, hidden or turned off
    body:bool,                 // the renderer draws something for it, or its ghost does
    indicator:bool,            // it shows a disc, within the reach of the discs and drawn unless the iteration is far
}

Scene_Iter :: struct {
    s:^Session,
    w:core.World_Ref,
    transforms:^core.Table(core.Transform),
    worlds:^core.Table(core.World_Transform),
    meshes:^core.Table(erender.Mesh_Renderer),
    any_hidden:bool,
    ghosts:bool,               // what is hidden or turned off counts as shown (ghosts_shown)
    locals:bool,               // the places come from the locals, as an edit of this frame left them
    far:bool,                  // a disc counts at any distance from the camera
    zoom:f32,                  // of the camera, for the reach of the discs (indicator_zoom)
    row:int,
}

scene_items :: proc(s:^Session,w:core.World_Ref,ghosts:=false,locals:=false,far:=false) -> Scene_Iter {
    hidden:=core.world_table_of(w,erender.Hidden)
    return {
        s=s,w=w,transforms=core.world_table_of(w,core.Transform),worlds=core.world_table_of(w,core.World_Transform),
        meshes=core.world_table_of(w,erender.Mesh_Renderer),any_hidden=hidden!=nil && core.count(hidden)>0,ghosts=ghosts,locals=locals,
        far=far || s.viewport==nil,zoom=s.viewport!=nil?indicator_zoom(s.viewport):1,row=-1,
    }
}

scene_item_next :: proc(it:^Scene_Iter) -> (item:Scene_Item,ok:bool) {
    if it.transforms==nil {return}
    it.row+=1
    if it.row>=len(it.transforms.entities) {return}
    e:=it.transforms.entities[it.row]
    item.entity=e
    if row:=it.worlds!=nil && !it.locals?core.row_of(it.worlds,e):-1;row>=0 {item.world=it.worlds.values[row].transform} else {item.world=entity_world(it.w,e)}
    // A mesh off with its entity is still its own; one turned off by itself is not there.
    has_mesh:=false
    if row:=it.meshes!=nil?core.raw_row(core.raw(it.meshes),e):-1;row>=0 && !it.meshes.off[row] {item.mesh,has_mesh=it.meshes.values[row],true}
    if it.any_hidden {item.hidden=entity_hidden(it.w,e)}
    item.hidden||=core.entity_off(core.world_entities(it.w),e)
    shown:=!item.hidden || it.ghosts
    item.body=shown && has_mesh && (item.mesh.mesh!={} || item.mesh.shape!=.None)
    item.indicator=shown && !has_mesh && entity_author(it.w,e)==e && (it.far || indicator_shade(it.s,e,item.world.position,it.zoom)>0 && indicator_drawn(it.s,e,item.world.position)) && entity_marked(it.s,it.w,e)
    return item,true
}

// Whether an entity without a body shows a disc: one whose icon says what it
// is (a light, a camera, a card of a plugin). A group, or an entity whose
// components show themselves (a terrain, a foliage), has none, as other
// editors show no icon for an empty object.
entity_marked :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> bool {
    icon,_:=entity_icon(s,w,e)
    return icon!=.Group
}

entity_author :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    ids:=core.world_table_of(w,core.Id)
    parents:=core.world_table_of(w,core.Parent)
    if ids==nil || parents==nil {return e}
    if author:=core.ancestor_with(parents,ids,e);author!=core.NONE {return author}
    return e
}

// What is under a point of the window; with ghosts, also what is hidden or
// turned off; with batches, also the instances of the batches of the world
// (foliage), as their batch and instance. A disc the surface under the point
// covers there is not under it, as it is not drawn there.
pick_point :: proc(s:^Session,w:core.World_Ref,point:[2]f32,ghosts:=false,batches:=false) -> (hit:Pick) {
    v:=s.viewport
    ray:=viewport_ray(v,point)
    surface:Pick
    traced:=false
    if v.show_indicators {
        best_distance,best_depth:=max(f32),max(f32)
        items:=scene_items(s,w,ghosts)
        for item in scene_item_next(&items) {
            if !item.indicator {continue}
            screen,front:=viewport_screen(v,item.world.position)
            radius,_,seen:=indicator_size(v,item.world.position)
            if !front || !seen {continue}
            distance,depth:=linalg.distance(screen,point),linalg.distance(item.world.position,ray.origin)
            if distance>radius+INDICATOR_HIT || !(distance<best_distance || distance==best_distance && depth<best_depth) {continue}
            // What covers the scene covers the discs too: the instances of the batches as well.
            if !traced {surface,traced=pick_ray(s,w,ray,PICK_REACH,ghosts,true),true}
            if surface.entity!=core.NONE && indicator_covered(v,item.world.position,ray,surface.distance) {continue}
            best_distance,best_depth=distance,depth
            hit={entity=item.entity,distance=depth,position=item.world.position,normal=-ray.direction,indicator=true}
        }
        if hit.entity!=core.NONE {return}
    }
    if traced && (batches || surface.batch==0) {return surface}
    return pick_ray(s,w,ray,PICK_REACH,ghosts,batches)
}

// The nearest surface a ray of the world meets within reach, without the
// discs: the bodies of the scene and, with batches, the instances of its batches.
pick_ray :: proc(s:^Session,w:core.World_Ref,ray:mm.Ray,reach:f32=PICK_REACH,ghosts:=false,batches:=false) -> (hit:Pick) {
    nearest:=reach
    items:=scene_items(s,w,ghosts)
    for item in scene_item_next(&items) {
        if met,found:=pick_item(s,w,item,ray,nearest);found {hit,nearest=met,met.distance}
    }
    if batches {
        if id:=core.world_storage_of(w,core.World_Id);id!=nil {
            if met,found:=erender.batch_ray(s.app.renderer,id^,ray.origin,ray.direction,nearest);found && met.distance<nearest {
                e:=core.Entity(met.object_id)
                if entity_alive(w,e) {
                    hit={entity=entity_author(w,e),distance=met.distance,position=ray.origin+ray.direction*met.distance,normal=met.normal,batch=met.handle,instance=met.instance}
                }
            }
        }
    }
    return
}

// What the ray under a point of the window goes through within reach,
// nearest first and each entity once: the bodies it crosses and the discs
// under the point that the scene does not cover there. Returns how many it wrote; the farthest are left out.
pick_through :: proc(s:^Session,w:core.World_Ref,point:[2]f32,out:[]Pick,ghosts:=false) -> int {
    v:=s.viewport
    ray:=viewport_ray(v,point)
    count:=0
    surface:Pick
    traced:=false
    items:=scene_items(s,w,ghosts)
    for item in scene_item_next(&items) {
        hit:Pick
        if item.indicator && v.show_indicators {
            screen,front:=viewport_screen(v,item.world.position)
            radius,_,seen:=indicator_size(v,item.world.position)
            if !front || !seen || linalg.distance(screen,point)>radius+INDICATOR_HIT {continue}
            if !traced {surface,traced=pick_ray(s,w,ray,PICK_REACH,ghosts,true),true}
            if surface.entity!=core.NONE && indicator_covered(v,item.world.position,ray,surface.distance) {continue}
            hit={entity=item.entity,distance=linalg.distance(item.world.position,ray.origin),position=item.world.position,normal=-ray.direction,indicator=true}
        } else {
            hit=pick_item(s,w,item,ray,PICK_REACH) or_continue
        }
        count=picks_insert(out,count,hit)
    }
    return count
}

// Puts a pick among the first count of out by distance, keeping the nearest of each entity.
@(private)
picks_insert :: proc(out:[]Pick,count:int,hit:Pick) -> int {
    count:=count
    for i in 0..<count {
        if out[i].entity!=hit.entity {continue}
        if out[i].distance<=hit.distance {return count}
        copy(out[i:count-1],out[i+1:count])
        count-=1
        break
    }
    at:=count
    for at>0 && out[at-1].distance>hit.distance {at-=1}
    if at>=len(out) {return count}
    if count<len(out) {count+=1}
    copy(out[at+1:count],out[at:count-1])
    out[at]=hit
    return count
}

// Where a ray meets the body of an item before nearest.
@(private)
pick_item :: proc(s:^Session,w:core.World_Ref,item:Scene_Item,ray:mm.Ray,nearest:f32) -> (hit:Pick,found:bool) {
    if !item.body {return}
    mesh:=pick_mesh(s.app.assets,item.mesh)
    if mesh==nil || mesh.handle==host.ASSETS_MESH_NONE {return}
    // Most entities are far from the ray: the sphere around the box says so without inverting.
    low,high:=mesh.bounds_min,mesh.bounds_max
    middle,half:=(low+high)*0.5,(high-low)*0.5
    center:=mm.transform_point(item.world,middle)
    radius:=linalg.length(half*linalg.abs(item.world.scale))+1e-3
    to:=center-ray.origin
    along:=linalg.dot(to,ray.direction)
    if along< -radius || along-radius>nearest || linalg.dot(to,to)-along*along>radius*radius {return}
    renderer:=s.app.renderer
    // A tree of the mesh while rays are traced by hardware: the renderer keeps none of its own.
    erender.mesh_ray_prepare(renderer,mesh.handle)
    t,_,normal,crossed:=erender.mesh_ray(renderer,mesh.handle,mm.transform_matrix(item.world),ray.origin,ray.direction,nearest)
    if !crossed || t>=nearest {return}
    return {entity=entity_author(w,item.entity),distance=t,position=ray.origin+ray.direction*t,normal=normal},true
}

// Whether the scene covers the disc of a place at its center, as the draw
// tests it against the depth: what a ray from the camera toward it meets
// first is in front of it. Behind the camera it is hidden.
indicator_hidden :: proc(s:^Session,w:core.World_Ref,position:[3]f32,ghosts:bool) -> bool {
    v:=s.viewport
    screen,front:=viewport_screen(v,position)
    if !front {return true}
    ray:=viewport_ray(v,screen)
    surface:=pick_ray(s,w,ray,linalg.distance(ray.origin,position)*1.01+1,ghosts,true)
    return surface.entity!=core.NONE && indicator_covered(v,position,ray,surface.distance)
}

// Whether a rectangle of the window takes an item: its origin inside, or
// the whole box of its body. ok is false when it shows nothing of it: a
// disc the scene covers.
@(private)
item_in_rect :: proc(s:^Session,w:core.World_Ref,item:Scene_Item,rect:ui.Rect) -> (inside,ok:bool) {
    v:=s.viewport
    if !item.body && (!v.show_indicators || !item.indicator) {return}
    pivot,front:=viewport_screen(v,item.world.position)
    if !item.body && front && indicator_hidden(s,w,item.world.position,ghosts_shown(s)) {return}
    if front && ui.rect_contains(rect,pivot) {return true,true}
    if !item.body {return false,front}
    low,high,known:=mesh_bounds(s.app.assets,item.mesh)
    if !known {return}
    bounds,projected:=project_box(v,mm.transform_matrix(item.world),low,high)
    if !projected {return}
    return bounds.x>=rect.x && bounds.y>=rect.y && bounds.x+bounds.w<=rect.x+rect.w && bounds.y+bounds.h<=rect.y+rect.h,true
}

// The rectangle of the window that holds a box placed by m. ok is false when a corner is behind the camera.
@(private)
project_box :: proc(v:^Viewport,m:mm.Mat4,low,high:[3]f32) -> (rect:ui.Rect,ok:bool) {
    smin,smax:=[2]f32{1e30,1e30},[2]f32{-1e30,-1e30}
    for corner in 0..<8 {
        p:=mm.mat4_point(m,{corner&1==0?low.x:high.x,corner&2==0?low.y:high.y,corner&4==0?low.z:high.z})
        screen,front:=viewport_screen(v,p)
        if !front {return}
        smin=linalg.min(smin,screen);smax=linalg.max(smax,screen)
    }
    return {smin.x,smin.y,smax.x-smin.x,smax.y-smin.y},true
}

// The world box of the selected entities and of what hangs from them. An
// entity without a body counts as a small box.
selection_bounds :: proc(s:^Session,w:core.World_Ref) -> (low,high:[3]f32,found:bool) {
    return entities_bounds(s,w,s.selection.entities[:])
}

@(private)
entities_bounds :: proc(s:^Session,w:core.World_Ref,entities:[]core.Entity) -> (low,high:[3]f32,found:bool) {
    low,high={1e30,1e30,1e30},{-1e30,-1e30,-1e30}
    items:=scene_items(s,w,ghosts_shown(s))
    for item in scene_item_next(&items) {
        selected:=false
        for e in entities {
            if entity_under(w,item.entity,e) {selected=true;break}
        }
        if !selected {continue}
        box:mm.Aabb
        if item.body {
            if mesh_low,mesh_high,known:=mesh_bounds(s.app.assets,item.mesh);known {
                box=mm.aabb_transform({mesh_low,mesh_high},mm.transform_matrix(item.world))
            } else {
                box={item.world.position-INDICATOR_EXTENT,item.world.position+INDICATOR_EXTENT}
            }
        } else {
            box={item.world.position-INDICATOR_EXTENT,item.world.position+INDICATOR_EXTENT}
        }
        low=linalg.min(low,box.min);high=linalg.max(high,box.max);found=true
    }
    return
}

@(private)
finite3 :: proc "contextless" (v:[3]f32) -> bool {return v.x-v.x==0 && v.y-v.y==0 && v.z-v.z==0}
