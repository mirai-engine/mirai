package editor

import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/spatial"
import "mirai:ui"

// What a point or a rectangle of the window reaches in the scene: the discs
// of the entities without a body first, since they are drawn over it, then
// the nearest surface. A ray tests the box of each mesh, from what the assets
// know of it, before it reads anything; it goes into the space of each mesh
// whose box it crosses and through the BVH of its triangles. The triangles of
// a mesh are read the first time something needs them and its BVH is made the
// first time a ray reaches its box; both stay until the mesh changes: a
// generated one is released, the file of one changes.

PICK_REACH :: f32(1e5)

Pick :: struct {
    entity:core.Entity,
    distance:f32,
    position,normal:[3]f32, // in the world; normal faces the ray
    indicator:bool,         // the disc of an entity without a body
    batch:erender.Batch_Handle, // with batches: the batch of the instance met, whose object is entity
    instance:int,               // and that instance in it
}

@(private)
Pick_Mesh :: struct {
    id:base.Asset_Id,
    shape:erender.Shape,
    positions:[dynamic][3]f32,
    indices:[dynamic]u32,
    bvh:spatial.Bvh,
    low,high:[3]f32,
    generated:bool,
    built:bool,   // the BVH was made
    stamp:[2]i64, // size and time of the file it was read from
}

@(storage)
Picker :: struct {
    meshes:[dynamic]Pick_Mesh,
    revision:u64, // of the assets when the meshes were last compared with them
    structure:u64,
    loads:u64,    // meshes whose triangles were read
    builds:u64,   // BVHs made
}

picker_clear :: proc(p:^Picker) {
    for &mesh in p.meshes {pick_mesh_free(&mesh)}
    clear(&p.meshes)
}

@(private)
pick_mesh_free :: proc(mesh:^Pick_Mesh) {
    spatial.bvh_destroy(&mesh.bvh)
    delete(mesh.positions);delete(mesh.indices)
}

@(private)
picker_stamp :: proc(a:^host.Assets,id:base.Asset_Id) -> [2]i64 {
    file,found:=asset.registry_find(&a.registry,id)
    return found?{file.size,file.time}:{}
}

// Once the assets changed, the meshes whose geometry is no longer what was
// read go: a generated one that was released, one whose file changed. What
// else changed (textures, materials, other meshes) keeps the rest.
@(private)
picker_sync :: proc(p:^Picker,a:^host.Assets) {
    if a==nil || a.revision==p.revision && a.structure==p.structure {return}
    p.revision,p.structure=a.revision,a.structure
    for i:=len(p.meshes)-1;i>=0;i-=1 {
        mesh:=&p.meshes[i]
        if mesh.id=={} {continue}
        if mesh.generated?host.assets_mesh_generated(a,mesh.id):picker_stamp(a,mesh.id)==mesh.stamp {continue}
        pick_mesh_free(mesh)
        unordered_remove(&p.meshes,i)
    }
}

// The geometry the renderer draws for a Mesh_Renderer. A mesh that cannot be
// read counts as the cube drawn in its place.
@(private)
picker_mesh :: proc(p:^Picker,a:^host.Assets,mesh:erender.Mesh_Renderer) -> ^Pick_Mesh {
    picker_sync(p,a)
    for &m in p.meshes {
        if m.id==mesh.mesh && (mesh.mesh!={} || m.shape==mesh.shape) {return len(m.indices)>0?&m:(mesh.mesh!={}?picker_mesh(p,a,{shape=.Cube}):nil)}
    }
    append(&p.meshes,Pick_Mesh{id=mesh.mesh,shape=mesh.shape,generated=host.assets_mesh_generated(a,mesh.mesh)})
    m:=&p.meshes[len(p.meshes)-1]
    if a!=nil && mesh.mesh!={} && !m.generated {m.stamp=picker_stamp(a,mesh.mesh)}
    buffer:geom.Mesh_Buffer
    geom.mesh_buffer_init(&buffer,context.temp_allocator)
    if host.assets_geometry(a,mesh.mesh,mesh.shape,&buffer) && len(buffer.indices)>=3 {
        append(&m.positions,..buffer.positions[:])
        append(&m.indices,..buffer.indices[:])
        m.low,m.high=geom.mesh_bounds(m.positions[:])
        p.loads+=1
    }
    if len(m.indices)==0 {return mesh.mesh!={}?picker_mesh(p,a,{shape=.Cube}):nil}
    return m
}

// The box of what a Mesh_Renderer shows, in the space of its mesh: the one
// the assets keep for a mesh they loaded from a file, without reading its
// triangles, or that of its geometry.
@(private)
picker_bounds :: proc(p:^Picker,a:^host.Assets,mesh:erender.Mesh_Renderer) -> (low,high:[3]f32,ok:bool) {
    picker_sync(p,a)
    if mesh.mesh!={} && a!=nil {
        held:=false
        for &m in p.meshes {if m.id==mesh.mesh {held=true;break}}
        if !held {
            if low,high,known:=host.assets_mesh_bounds(a,mesh.mesh);known {return low,high,true}
        }
    }
    m:=picker_mesh(p,a,mesh)
    if m==nil {return}
    return m.low,m.high,true
}

// The BVH of a mesh, made the first time a ray reaches its box.
@(private)
picker_bvh :: proc(p:^Picker,mesh:^Pick_Mesh) -> bool {
    if !mesh.built {
        mesh.built=true
        if spatial.bvh_build_triangles(&mesh.bvh,mesh.positions[:],mesh.indices[:],{allocator=context.allocator}) {p.builds+=1}
    }
    return len(mesh.bvh.nodes)>0
}

// Nearest triangle the ray crosses, in the space of the mesh.
@(private)
pick_mesh_ray :: proc(p:^Picker,mesh:^Pick_Mesh,ray:mm.Ray) -> (t:f32,normal:[3]f32,hit:bool) {
    if _,_,inside:=mm.ray_aabb(ray,{mesh.low-1e-4,mesh.high+1e-4});!inside {return}
    if !picker_bvh(p,mesh) {return}
    t=PICK_REACH
    walk:=spatial.bvh_ray(&mesh.bvh,ray.origin,ray.direction*PICK_REACH,1)
    for {
        primitives,more:=spatial.bvh_ray_next(&walk)
        if !more {break}
        for primitive in primitives {
            triangle:=mm.Triangle{mesh.positions[mesh.indices[3*primitive]],mesh.positions[mesh.indices[3*primitive+1]],mesh.positions[mesh.indices[3*primitive+2]]}
            if distance,_,crossed:=mm.ray_triangle(ray,triangle);crossed && distance<t {
                t,hit=distance,true
                normal=linalg.cross(triangle.b-triangle.a,triangle.c-triangle.a)
                walk.max_fraction=distance/PICK_REACH
            }
        }
    }
    return
}

// One entity with a Transform as the viewport sees it.
Scene_Item :: struct {
    entity:core.Entity,
    world:mm.Transform,
    mesh:erender.Mesh_Renderer,
    hidden:bool,               // itself or an ancestor, hidden or turned off
    body:bool,                 // the renderer draws something for it, or its ghost does
    indicator:bool,
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
    row:int,
}

scene_items :: proc(s:^Session,w:core.World_Ref,ghosts:=false,locals:=false) -> Scene_Iter {
    hidden:=core.world_table_of(w,erender.Hidden)
    return {
        s=s,w=w,transforms=core.world_table_of(w,core.Transform),worlds=core.world_table_of(w,core.World_Transform),
        meshes=core.world_table_of(w,erender.Mesh_Renderer),any_hidden=hidden!=nil && core.count(hidden)>0,ghosts=ghosts,locals=locals,row=-1,
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
    item.indicator=shown && !has_mesh && entity_author(it.w,e)==e && entity_marked(it.s,it.w,e)
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
    if author:=core.ancestor_with(core.read(parents),core.read(ids),e);author!=core.NONE {return author}
    return e
}

// What is under a point of the window; with ghosts, also what is hidden or
// turned off; with batches, also the instances of the batches of the world
// (foliage), as their batch and instance.
pick_point :: proc(s:^Session,w:core.World_Ref,point:[2]f32,ghosts:=false,batches:=false) -> (hit:Pick) {
    v:=s.viewport
    ray:=viewport_ray(v,point)
    if v.show_indicators {
        best_distance,best_depth:=INDICATOR_HIT,f32(1e30)
        items:=scene_items(s,w,ghosts)
        for item in scene_item_next(&items) {
            if !item.indicator {continue}
            screen,front:=viewport_screen(v,item.world.position)
            if !front {continue}
            distance,depth:=linalg.distance(screen,point),linalg.distance(item.world.position,ray.origin)
            if distance<best_distance || distance==best_distance && depth<best_depth {
                best_distance,best_depth=distance,depth
                hit={entity=item.entity,distance=depth,position=item.world.position,normal=-ray.direction,indicator=true}
            }
        }
        if hit.entity!=core.NONE {return}
    }
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
// under the point. Returns how many it wrote; the farthest are left out.
pick_through :: proc(s:^Session,w:core.World_Ref,point:[2]f32,out:[]Pick,ghosts:=false) -> int {
    v:=s.viewport
    ray:=viewport_ray(v,point)
    count:=0
    items:=scene_items(s,w,ghosts)
    for item in scene_item_next(&items) {
        hit:Pick
        if item.indicator && v.show_indicators {
            screen,front:=viewport_screen(v,item.world.position)
            if !front || linalg.distance(screen,point)>INDICATOR_HIT {continue}
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
    low,high,known:=picker_bounds(s.picker,s.app.assets,item.mesh)
    if !known {return}
    // Most entities are far from the ray: the sphere around the box says so without inverting.
    middle,half:=(low+high)*0.5,(high-low)*0.5
    center:=mm.transform_point(item.world,middle)
    radius:=linalg.length(half*linalg.abs(item.world.scale))+1e-3
    to:=center-ray.origin
    along:=linalg.dot(to,ray.direction)
    if along< -radius || along-radius>nearest || linalg.dot(to,to)-along*along>radius*radius {return}
    matrix_world:=mm.transform_matrix(item.world)
    inverse:=linalg.inverse(matrix_world)
    origin:=inverse*[4]f32{ray.origin.x,ray.origin.y,ray.origin.z,1}
    direction:=inverse*[4]f32{ray.direction.x,ray.direction.y,ray.direction.z,0}
    local:=mm.Ray{origin.xyz,direction.xyz}
    if !finite3(local.origin) || !finite3(local.direction) {return}
    if _,_,inside:=mm.ray_aabb(local,{low-1e-4,high+1e-4});!inside {return}
    mesh:=picker_mesh(s.picker,s.app.assets,item.mesh)
    if mesh==nil {return}
    t,local_normal,crossed:=pick_mesh_ray(s.picker,mesh,local)
    if !crossed || t>=nearest {return}
    normal:=linalg.normalize0((linalg.transpose(inverse)*[4]f32{local_normal.x,local_normal.y,local_normal.z,0}).xyz)
    if linalg.dot(normal,ray.direction)>0 {normal=-normal}
    return {entity=entity_author(w,item.entity),distance=t,position=ray.origin+ray.direction*t,normal=normal},true
}

// Whether a rectangle of the window takes an item: its origin inside, or
// the whole box of its body. ok is false when it shows nothing of it.
@(private)
item_in_rect :: proc(s:^Session,w:core.World_Ref,item:Scene_Item,rect:ui.Rect) -> (inside,ok:bool) {
    v:=s.viewport
    if !item.body && (!v.show_indicators || !item.indicator) {return}
    pivot,front:=viewport_screen(v,item.world.position)
    if front && ui.rect_contains(rect,pivot) {return true,true}
    if !item.body {return false,front}
    low,high,known:=picker_bounds(s.picker,s.app.assets,item.mesh)
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
            if mesh_low,mesh_high,known:=picker_bounds(s.picker,s.app.assets,item.mesh);known {
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
