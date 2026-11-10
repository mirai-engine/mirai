package shapes

import "core:mem"
import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import physics "plugins:physics/runtime"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/geom"
import mm "mirai:std/math"

@(private="file")
World :: struct {
    entities:core.Entities,
    shapes:core.Table(Shape),
    brushes:core.Table(Shape_Brush),
    parts:core.Table(Shape_Part),
    rigids:core.Table(physics.Rigid_Body),
    colliders:core.Table(physics.Collider),
    meshes:core.Table(render.Mesh_Renderer),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    ids:core.Table(core.Id),
    hierarchy:core.Hierarchy,
    cache:Shapes_Cache,
    problems:core.Problems,
    info:core.World_Info,
    tables:[5]core.Table_Info,
    app:^host.App,
}

@(private="file")
App :: struct {
    app:host.App,
    assets:host.Assets,
}

@(private="file")
app_init :: proc(a:^App) -> bool {
    a.app.assets,a.app.allocator=&a.assets,context.allocator
    if !jobs.system_init(&a.app.jobs,{threads=0}) {return false}
    return host.assets_init(&a.assets,{root="assets",capacity=16})
}

@(private="file")
app_destroy :: proc(a:^App) {
    jobs.system_destroy(&a.app.jobs)
    host.assets_destroy(&a.assets)
}

@(private="file")
world_init :: proc(w:^World,app:^host.App) {
    core.entities_init(&w.entities)
    w.app=app
    w.tables={
        {type=Shape_Part,offset=offset_of(World,parts)},
        {type=core.Parent,offset=offset_of(World,parents)},
        {type=core.Transform,offset=offset_of(World,transforms)},
        {type=render.Mesh_Renderer,offset=offset_of(World,meshes)},
        {type=physics.Collider,offset=offset_of(World,colliders)},
    }
    w.info.tables=w.tables[:]
}

@(private="file")
world_destroy :: proc(w:^World) {
    shapes_release(&w.cache,w.app.assets)
    shapes_cache_free(&w.cache)
    core.table_destroy(&w.shapes);core.table_destroy(&w.brushes);core.table_destroy(&w.parts);core.table_destroy(&w.rigids);core.table_destroy(&w.colliders)
    core.table_destroy(&w.meshes);core.table_destroy(&w.parents);core.table_destroy(&w.transforms);core.table_destroy(&w.ids)
    delete(w.hierarchy.parent);delete(w.hierarchy.first_child);delete(w.hierarchy.last_child)
    delete(w.hierarchy.next_sibling);delete(w.hierarchy.previous_sibling);delete(w.hierarchy.cut)
    core.entities_destroy(&w.entities)
}

@(private="file")
world_settle :: proc(w:^World) {
    core.table_settle(&w.shapes,&w.entities);core.table_settle(&w.brushes,&w.entities);core.table_settle(&w.parts,&w.entities);core.table_settle(&w.rigids,&w.entities)
    core.table_settle(&w.colliders,&w.entities);core.table_settle(&w.meshes,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.ids,&w.entities)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    core.entities_settle(&w.entities)
}

@(private="file")
world_step :: proc(w:^World) {
    world_settle(w)
    shapes_update(&w.cache,w.app.assets,&w.app.jobs,w.app.allocator,core.commands(w,&w.info),core.read(&w.shapes),core.read(&w.brushes),core.read(&w.parts),core.read(&w.rigids),
        &w.colliders,&w.meshes,core.read(&w.transforms),core.read(&w.parents),core.ref(&w.hierarchy),&w.problems)
    world_settle(w)
}

// The children of a shape that draw it.
@(private="file")
parts_of :: proc(w:^World,e:core.Entity) -> (child:core.Entity,count:int) {
    for row in 0..<core.count(&w.parts) {
        c:=core.entity_at(&w.parts,row)
        if parent,has:=core.get(core.read(&w.parents),c);has && parent.entity==e {child,count=c,count+1}
    }
    return
}

@(private="file")
mesh_of :: proc(w:^World,child:core.Entity) -> base.Asset_Id {
    shown,_:=core.get(core.read(&w.meshes),child)
    return shown.mesh
}

@(test)
a_shape_shows_and_collides_through_one_unsaved_child :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:World
    world_init(&w,&a.app)
    defer world_destroy(&w)
    // An L: concave, so a body needs several pieces.
    l:=SHAPE_DEFAULT
    l.point_count,l.loops[0]=6,6
    l.points[0],l.points[1],l.points[2],l.points[3],l.points[4],l.points[5]={0,0},{2,0},{2,1},{1,1},{1,2},{0,2}
    static:=core.create(&w.entities)
    core.add(&w.shapes,static,SHAPE_DEFAULT)
    sensor:=physics.COLLIDER_DEFAULT
    sensor.kind,sensor.sensor,sensor.friction,sensor.collides=.External,true,0.1,{}
    core.add(&w.colliders,static,sensor)
    body:=core.create(&w.entities)
    core.add(&w.shapes,body,l)
    core.add(&w.rigids,body,physics.RIGID_BODY_DYNAMIC)
    world_step(&w)
    testing.expect_value(t,w.problems.count,0)
    Case :: struct {name:string,shape:core.Entity,kind:physics.Collider_Kind}
    for c in ([]Case{{"static",static,.Mesh},{"body",body,.Hull}}) {
        child,count:=parts_of(&w,c.shape)
        if !testing.expectf(t,count==1,"%s: %d children",c.name,count) {continue}
        testing.expectf(t,!core.has(&w.ids,child),"%s: the child has no Id, so no scene saves it",c.name)
        collider,has:=core.get(core.read(&w.colliders),child)
        testing.expectf(t,has && collider.kind==c.kind && collider.size==0 && collider.center==0,"%s: %v",c.name,collider.kind)
        mesh:=mesh_of(&w,child)
        testing.expectf(t,host.assets_mesh_generated(&a.assets,mesh),"%s: generated mesh",c.name)
        generated:=host.assets_mesh(&a.assets,mesh)
        testing.expectf(t,generated!=nil && len(generated.collision.indices)>0,"%s: collision kept",c.name)
        if c.kind==.Mesh {
            testing.expectf(t,len(host.assets_mesh_disabled_edges(&a.assets,mesh))*3==len(generated.collision.indices),"%s: disabled edges",c.name)
            // The surface and filtering of the Collider of the shape, not its kind.
            testing.expectf(t,collider.sensor && collider.friction==0.1 && collider.collides=={},"%s: surface",c.name)
        } else {
            testing.expectf(t,len(generated.hull_sizes)>=2,"%s: %d hulls",c.name,len(generated.hull_sizes))
            testing.expectf(t,collider.friction==physics.COLLIDER_DEFAULT.friction,"%s: default surface",c.name)
        }
    }
    // A shape whose Collider physics would also make reports it.
    core.get(&w.colliders,static).kind=.Box
    world_step(&w)
    testing.expect_value(t,w.problems.count,1)
}

@(test)
a_change_builds_again_and_releases_only_what_the_world_made :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:World
    world_init(&w,&a.app)
    defer world_destroy(&w)
    e:=core.create(&w.entities)
    core.add(&w.shapes,e,SHAPE_DEFAULT)
    world_step(&w)
    child,_:=parts_of(&w,e)
    first:=mesh_of(&w,child)

    // Nothing changed since the step saw its own writes: no pass, the same mesh.
    world_step(&w)
    pass:=w.cache.pass
    world_step(&w)
    testing.expect(t,w.cache.pass==pass && mesh_of(&w,child)==first)

    // A new source: a new mesh on the same child, and the old one released.
    core.get(&w.shapes,e).depth=2
    world_step(&w)
    again,count:=parts_of(&w,e)
    second:=mesh_of(&w,again)
    testing.expect(t,count==1 && again==child && second!=first)
    testing.expect(t,host.assets_mesh_generated(&a.assets,second) && !host.assets_mesh_generated(&a.assets,first))

    // A source that cannot be built keeps the mesh it had and says why.
    core.get(&w.shapes,e).depth=-1
    world_step(&w)
    testing.expect(t,mesh_of(&w,child)==second && host.assets_mesh_generated(&a.assets,second))
    testing.expect_value(t,w.problems.count,1)
    core.get(&w.shapes,e).depth=1

    // Becoming a body changes the collider.
    core.add(&w.rigids,e,physics.RIGID_BODY_DYNAMIC)
    world_step(&w)
    collider,_:=core.get(core.read(&w.colliders),child)
    testing.expect_value(t,collider.kind,physics.Collider_Kind.Hull)
    third:=mesh_of(&w,child)

    // A copy of the world finds the child, makes its own mesh and leaves the original's.
    copy:World
    world_init(&copy,&a.app)
    testing.expect(t,core.entities_copy(&copy.entities,&w.entities))
    testing.expect(t,core.table_copy(&copy.shapes,&w.shapes) && core.table_copy(&copy.parts,&w.parts) && core.table_copy(&copy.rigids,&w.rigids))
    testing.expect(t,core.table_copy(&copy.colliders,&w.colliders) && core.table_copy(&copy.meshes,&w.meshes) && core.table_copy(&copy.parents,&w.parents))
    testing.expect(t,core.table_copy(&copy.transforms,&w.transforms))
    world_step(&copy)
    copied,copies:=parts_of(&copy,e)
    own:=mesh_of(&copy,copied)
    testing.expect(t,copies==1 && copied==child && own!=third && host.assets_mesh_generated(&a.assets,own))
    core.remove(&copy.shapes,e)
    world_step(&copy)
    world_destroy(&copy)
    testing.expect(t,!host.assets_mesh_generated(&a.assets,own) && host.assets_mesh_generated(&a.assets,third))
    testing.expect(t,mesh_of(&w,child)==third)

    // The shape goes: its child and its mesh go with it.
    core.remove(&w.shapes,e)
    world_step(&w)
    _,count=parts_of(&w,e)
    testing.expect(t,count==0 && !core.alive(&w.entities,child) && !host.assets_mesh_generated(&a.assets,third))
}

// A brush entity under a solid, as a scene saves it: Id, Parent, Transform and Shape_Brush.
@(private="file")
brush_add :: proc(w:^World,solid:core.Entity,order:i32,brush:Shape_Brush,position,size:[3]f32) -> core.Entity {
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{value=base.Entity_Id(100+order)})
    core.add(&w.parents,e,core.Parent{entity=solid,order=order})
    core.add(&w.transforms,e,core.Transform{position,mm.QUAT_IDENTITY,size})
    core.add(&w.brushes,e,brush)
    return e
}

// The volume the static collision of a mesh encloses.
@(private="file")
volume_of :: proc(a:^App,mesh:base.Asset_Id) -> f64 {
    m:=host.assets_mesh(&a.assets,mesh)
    if m==nil {return 0}
    c:=m.collision
    v:f64
    for i:=0;i+2<len(c.indices);i+=3 {
        p,q,r:=c.positions[c.indices[i]],c.positions[c.indices[i+1]],c.positions[c.indices[i+2]]
        v+=f64(p.x*(q.y*r.z-q.z*r.y)-p.y*(q.x*r.z-q.z*r.x)+p.z*(q.x*r.y-q.y*r.x))
    }
    return v/6
}

@(private="file")
reported :: proc(w:^World,e:core.Entity,code:string) -> bool {
    for &p in core.problems_list(&w.problems) {
        if p.entity==e && base.text_equal(p.code[:],code) {return true}
    }
    return false
}

@(test)
a_solid_is_made_of_its_brush_children_and_follows_their_changes :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:World
    world_init(&w,&a.app)
    defer world_destroy(&w)
    solid:=core.create(&w.entities)
    core.add(&w.ids,solid,core.Id{value=1})
    core.add(&w.transforms,solid,core.TRANSFORM_IDENTITY)
    core.add(&w.shapes,solid,Shape{kind=.Solid,uv_scale=1})
    box:=brush_add(&w,solid,0,{kind=.Box},{0,0,0},{2,2,2})
    cut:=brush_add(&w,solid,1,{kind=.Sphere,subtract=true},{1,1,1},{1.6,1.6,1.6})
    world_step(&w)
    testing.expect_value(t,w.problems.count,0)
    child,count:=parts_of(&w,solid)
    if !testing.expect_value(t,count,1) {return}
    // The brushes are source: no mesh or collider of their own.
    for b in ([2]core.Entity{box,cut}) {
        testing.expect(t,!core.has(&w.meshes,b) && !core.has(&w.colliders,b) && core.has(&w.ids,b))
    }
    first:=mesh_of(&w,child)
    // The box of 8 m3 without the eighth of the sphere at its corner.
    testing.expectf(t,abs(volume_of(&a,first)-7.73)<0.05,"volume %v",volume_of(&a,first))

    // Moving a brush builds once, on the tick that sees it.
    core.get(&w.transforms,cut).position={1,1,0.9}
    world_step(&w)
    moved:=mesh_of(&w,child)
    testing.expect(t,moved!=first && !host.assets_mesh_generated(&a.assets,first))
    world_step(&w)
    world_step(&w)
    testing.expect(t,mesh_of(&w,child)==moved && len(w.cache.dirty)==0)

    // Reordered, the cut comes first and has nothing to cut: the whole box, and a problem.
    core.get(&w.parents,box).order=2
    world_step(&w)
    reordered:=mesh_of(&w,child)
    testing.expect(t,reordered!=moved)
    testing.expectf(t,abs(volume_of(&a,reordered)-8)<1e-3,"volume %v",volume_of(&a,reordered))
    testing.expect(t,reported(&w,solid,"shapes.first_brush"))
    core.get(&w.parents,box).order=0
    world_step(&w)
    back:=mesh_of(&w,child)
    testing.expect(t,back!=reordered && volume_of(&a,back)<7.9)

    // Removing the cut builds the whole box again.
    core.remove(&w.brushes,cut)
    world_step(&w)
    removed:=mesh_of(&w,child)
    testing.expect(t,removed!=back)
    testing.expectf(t,abs(volume_of(&a,removed)-8)<1e-3,"volume %v",volume_of(&a,removed))
}

@(test)
a_body_of_brushes_that_only_add_has_a_piece_per_brush :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:World
    world_init(&w,&a.app)
    defer world_destroy(&w)
    solid:=core.create(&w.entities)
    core.add(&w.transforms,solid,core.TRANSFORM_IDENTITY)
    core.add(&w.shapes,solid,Shape{kind=.Solid,uv_scale=1})
    core.add(&w.rigids,solid,physics.RIGID_BODY_DYNAMIC)
    brush_add(&w,solid,0,{kind=.Box},{0,0,0},{1,1,1})
    brush_add(&w,solid,1,{kind=.Cylinder},{0,0,1},{0.5,1,0.5})
    brush_add(&w,solid,2,{kind=.Sphere},{0.8,0,0},{0.5,0.5,2})
    world_step(&w)
    testing.expect_value(t,w.problems.count,0)
    child,_:=parts_of(&w,solid)
    mesh:=host.assets_mesh(&a.assets,mesh_of(&w,child))
    if !testing.expect(t,mesh!=nil) {return}
    testing.expect_value(t,len(mesh.hull_sizes),3)
    // Each piece is its brush placed: the last one is 2 m tall along Z.
    at:=0
    for size,i in mesh.hull_sizes {
        if i==2 {
            lo,hi:=geom.mesh_bounds(mesh.hull_points[at:][:size])
            testing.expectf(t,abs(hi.z-lo.z-2)<1e-3 && abs(hi.x-lo.x-0.5)<1e-3,"%v %v",lo,hi)
        }
        at+=int(size)
    }
}

@(test)
outlines_without_brushes_do_no_work_and_allocate_nothing_while_nothing_changes :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:World
    world_init(&w,&a.app)
    defer world_destroy(&w)
    for i in 0..<4 {
        e:=core.create(&w.entities)
        core.add(&w.transforms,e,core.Transform{{f32(2*i),0,0},mm.QUAT_IDENTITY,{1,1,1}})
        core.add(&w.shapes,e,SHAPE_DEFAULT)
    }
    world_step(&w)
    world_step(&w)
    pass:=w.cache.pass
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    allocator:=a.app.allocator
    a.app.allocator=mem.tracking_allocator(&track)
    // The entities move: what moves an outline is not its source.
    for i in 0..<3 {
        for row in 0..<core.count(&w.transforms) {core.at(&w.transforms,row).position.y=f32(i)}
        world_step(&w)
    }
    a.app.allocator=allocator
    testing.expect_value(t,w.cache.pass,pass)
    testing.expect_value(t,track.total_allocation_count,0)
    testing.expect_value(t,len(w.cache.brushes.values),0)
}
