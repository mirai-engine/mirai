package shapes

import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import "mirai:host"
import physics "plugins:physics/runtime"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/geom"
import mm "mirai:std/math"

@(private)
@(test_world)
Step_World :: struct {
    using world:Test_World,
    shapes:core.Table(Shape),
    brushes:core.Table(Shape_Brush),
    parts:core.Table(Shape_Part),
    rigids:core.Table(physics.Rigid_Body),
    colliders:core.Table(physics.Collider),
    meshes:core.Table(render.Mesh_Renderer),
    tints:core.Table(render.Material_Values),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    ids:core.Table(core.Id),
    splines:core.Table(volume.Spline),
    bends:core.Table(Bend),
    elsewhere:core.Table(render.Drawn_Elsewhere),
    hierarchy:core.Hierarchy,
    ground:core.Ground_Queries,
}

// A world of shapes with what its application holds for it.
@(private="file")
Step_Test :: struct {
    using rows:Step_World,
    cache:Shapes_Cache,
    problems:core.Problems,
    app:^host.App,
    ground_seen:u64, // the cursor the generated call keeps in ground.changed
    pit:Pit,
}

@(private="file")
Pit :: struct {
    box:mm.Aabb,
    depth:f32,
    probes:int,
}

@(private="file")
App :: struct {
    app:host.App,
    assets:host.Assets,
}

@(private="file")
app_init :: proc(a:^App,root:="assets") -> bool {
    a.app.assets,a.app.allocator=&a.assets,context.allocator
    if !jobs.system_init(&a.app.jobs,{threads=0}) {return false}
    return host.assets_init(&a.assets,{root=root,capacity=16})
}

@(private="file")
app_destroy :: proc(a:^App) {
    jobs.system_destroy(&a.app.jobs)
    host.assets_destroy(&a.assets)
}

@(private="file")
world_init :: proc(t:^testing.T,w:^Step_Test,app:^host.App) -> bool {
    w.app=app
    return test_world_init(t,&w.rows)
}

@(private="file")
world_destroy :: proc(w:^Step_Test) {
    shapes_release(&w.cache,w.app.assets)
    shapes_cache_free(&w.cache)
    test_world_destroy(&w.rows)
}

@(private="file")
world_settle :: proc(w:^Step_Test) {
    test_world_settle(&w.rows)
    core.hierarchy_settle(&w.hierarchy,&w.parents,&w.entities)
}

@(private="file")
world_step :: proc(w:^Step_Test) {
    world_settle(w)
    ground:=w.ground
    core.events_read(&ground.changed,&w.ground_seen)
    shapes_update(&w.cache,w.app.assets,&w.app.jobs,w.app.allocator,core.commands(&w.rows,test_world_info(&w.rows)),core.read(&w.shapes),core.read(&w.brushes),core.read(&w.parts),core.read(&w.rigids),
        &w.colliders,&w.meshes,&w.tints,core.read(&w.transforms),core.read(&w.parents),core.ref(&w.hierarchy),&w.problems,
        core.read(&w.splines),core.ref(&ground),test_world_ref(&w.rows),core.read(&w.bends),core.read(&w.elsewhere))
    world_settle(w)
}

// The children of a shape that draw it.
@(private="file")
parts_of :: proc(w:^Step_Test,e:core.Entity) -> (child:core.Entity,count:int) {
    for row in 0..<core.count(&w.parts) {
        c:=core.entity_at(&w.parts,row)
        if parent,has:=core.get(&w.parents,c);has && parent.entity==e {child,count=c,count+1}
    }
    return
}

@(private="file")
mesh_of :: proc(w:^Step_Test,child:core.Entity) -> base.Asset_Id {
    shown,_:=core.get(&w.meshes,child)
    return shown.mesh
}

@(test)
a_shape_shows_and_collides_through_one_unsaved_child :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
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
        collider,has:=core.get(&w.colliders,child)
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
    // A Collider of its own kind collides in place of the shape, and its child only draws it with
    // the Material_Values of the shape.
    core.edit(&w.colliders,static)^={kind=.Box,size={0.5,0.5,0.5}}
    core.add(&w.tints,static,render.Material_Values{color={0.4,0.38,0.36,1}})
    world_step(&w)
    child,_:=parts_of(&w,static)
    tint,tinted:=core.get(&w.tints,child)
    testing.expect(t,w.problems.count==0 && !core.has(&w.colliders,child) && mesh_of(&w,child)!={},"the child draws and does not collide")
    testing.expect(t,tinted && tint.color=={0.4,0.38,0.36,1},"the child takes the Material_Values of the shape")
    core.remove(&w.tints,static)
    world_step(&w)
    testing.expect(t,!core.has(&w.tints,child),"and loses them with it")
}

@(test)
a_change_builds_again_and_releases_only_what_the_world_made :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
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
    core.edit(&w.shapes,e).depth=2
    world_step(&w)
    again,count:=parts_of(&w,e)
    second:=mesh_of(&w,again)
    testing.expect(t,count==1 && again==child && second!=first)
    testing.expect(t,host.assets_mesh_generated(&a.assets,second) && !host.assets_mesh_generated(&a.assets,first))

    // A source that cannot be built keeps the mesh it had and says why.
    core.edit(&w.shapes,e).depth=-1
    world_step(&w)
    testing.expect(t,mesh_of(&w,child)==second && host.assets_mesh_generated(&a.assets,second))
    testing.expect_value(t,w.problems.count,1)
    core.edit(&w.shapes,e).depth=1

    // Becoming a body changes the collider.
    core.add(&w.rigids,e,physics.RIGID_BODY_DYNAMIC)
    world_step(&w)
    collider,_:=core.get(&w.colliders,child)
    testing.expect_value(t,collider.kind,physics.Collider_Kind.Hull)
    third:=mesh_of(&w,child)

    // A copy of the world finds the child, makes its own mesh and leaves the original's.
    copy:Step_Test
    if !world_init(t,&copy,&a.app) {return}
    testing.expect(t,test_world_copy(&copy.rows,&w.rows))
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
brush_add :: proc(w:^Step_Test,solid:core.Entity,order:i32,brush:Shape_Brush,position,size:[3]f32) -> core.Entity {
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
reported :: proc(w:^Step_Test,e:core.Entity,code:string) -> bool {
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
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
    defer world_destroy(&w)
    solid:=core.create(&w.entities)
    core.add(&w.ids,solid,core.Id{value=1})
    core.add(&w.transforms,solid,core.TRANSFORM_IDENTITY)
    core.add(&w.shapes,solid,Shape{uv_scale={1,1}})
    box:=brush_add(&w,solid,0,{kind=.Box},{0,0,0},{2,2,2})
    cut:=brush_add(&w,solid,1,{kind=.Sphere,op=.Subtract},{1,1,1},{1.6,1.6,1.6})
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
    core.edit(&w.transforms,cut).position={1,1,0.9}
    world_step(&w)
    moved:=mesh_of(&w,child)
    testing.expect(t,moved!=first && !host.assets_mesh_generated(&a.assets,first))
    world_step(&w)
    world_step(&w)
    testing.expect(t,mesh_of(&w,child)==moved && len(w.cache.dirty)==0)

    // Reordered, the cut comes first and has nothing to cut: the whole box, and a problem.
    core.edit(&w.parents,box).order=2
    world_step(&w)
    reordered:=mesh_of(&w,child)
    testing.expect(t,reordered!=moved)
    testing.expectf(t,abs(volume_of(&a,reordered)-8)<1e-3,"volume %v",volume_of(&a,reordered))
    testing.expect(t,reported(&w,solid,"shapes.first_brush"))
    core.edit(&w.parents,box).order=0
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
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
    defer world_destroy(&w)
    solid:=core.create(&w.entities)
    core.add(&w.transforms,solid,core.TRANSFORM_IDENTITY)
    core.add(&w.shapes,solid,Shape{uv_scale={1,1}})
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
polygons_without_brushes_do_no_work_and_allocate_nothing_while_nothing_changes :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
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
    // The entities move: what moves a polygon is not its source.
    for i in 0..<3 {
        for row in 0..<core.count(&w.transforms) {core.edit_at(&w.transforms,row).position.y=f32(i)}
        world_step(&w)
    }
    a.app.allocator=allocator
    testing.expect_value(t,w.cache.pass,pass)
    testing.expect_value(t,track.total_allocation_count,0)
    testing.expect_value(t,len(w.cache.brushes.values),0)
}

// Ground of a test that rises toward +x.
@(private="file")
slope_open :: proc(w:core.World_Ref) -> (core.Ground_Query,bool) {
    probe :: proc(user:rawptr,origin,down:[3]f32) -> (core.Ground_Hit,core.Ground_Found) {
        return {point={origin.x,origin.x/10,origin.z},normal={0,1,0}},.Ground
    }
    return {probe=probe,spacing=0.5},true
}

// Flat ground at 0 with a pit dug in it, which counts what it was probed.
@(private="file")
pit_open :: proc(w:core.World_Ref) -> (core.Ground_Query,bool) {
    probe :: proc(user:rawptr,origin,down:[3]f32) -> (core.Ground_Hit,core.Ground_Found) {
        pit:=cast(^Pit)user
        pit.probes+=1
        b:=pit.box
        inside:=origin.x>=b.min.x && origin.x<=b.max.x && origin.z>=b.min.z && origin.z<=b.max.z
        return {point={origin.x,inside?-pit.depth:0,origin.z},normal={0,1,0}},.Ground
    }
    return {user=&(cast(^Step_Test)w.data).pit,probe=probe,spacing=0.5},true
}

// A spline with a material is a ribbon that lies on the ground, follows it
// across, moves with its entity and collides with nothing; without a material
// nothing draws it.
@(test)
a_spline_with_a_material_lies_on_the_ground_as_a_ribbon :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
    defer world_destroy(&w)
    w.ground.open=slope_open
    road:=core.create(&w.entities)
    core.add(&w.transforms,road,core.Transform{{0,5,0},mm.QUAT_IDENTITY,{1,1,1}})
    spline:=volume.SPLINE_DEFAULT
    spline.material={1,1}
    core.add(&w.splines,road,spline)
    world_step(&w)
    testing.expect_value(t,w.problems.count,0)
    child,count:=parts_of(&w,road)
    if !testing.expect_value(t,count,1) {return}
    testing.expect(t,!core.has(&w.colliders,child),"a ribbon collides with nothing")
    ribbon:=host.assets_mesh(&a.assets,mesh_of(&w,child))
    if !testing.expect(t,ribbon!=nil) {return}
    // 12 m along -z and 3 wide in the frame of the entity, 5 m over the ground, which rises 0.3 m across it.
    lo,hi:=ribbon.bounds_min,ribbon.bounds_max
    testing.expectf(t,abs(lo.x+1.5)<1e-3 && abs(hi.x-1.5)<1e-3 && abs(lo.z+12)<1e-3 && abs(hi.z)<1e-3,"%v %v",lo,hi)
    testing.expectf(t,abs(lo.y-(-5-0.15+0.05))<1e-3 && abs(hi.y-(-5+0.15+0.05))<1e-3,"it follows the ground across: %v %v",lo,hi)
    testing.expect(t,ribbon.vertex_count>=2*7,"points across as the ground has samples")

    // It moves with its entity, and lies on the ground there.
    core.edit(&w.transforms,road).position.y=9
    world_step(&w)
    moved:=host.assets_mesh(&a.assets,mesh_of(&w,child))
    testing.expect(t,moved!=nil && abs(moved.bounds_min.y-(lo.y-4))<1e-3)

    // A point without width is refused, and the ribbon it had stays.
    core.edit(&w.splines,road).points[1].width=0
    world_step(&w)
    testing.expect(t,reported(&w,road,"shapes.invalid") && mesh_of(&w,child)!=0)

    // Without a material nothing draws it.
    core.edit(&w.splines,road)^=volume.SPLINE_DEFAULT
    world_step(&w)
    _,count=parts_of(&w,road)
    testing.expect_value(t,count,0)
}

// A ribbon lies again only where the ground announces a change under it: a
// pit dug away from the road probes nothing, one dug under it lays the road
// on its bottom, and a tick without changes does no work.
@(test)
a_ribbon_lies_again_only_where_the_ground_changed_under_it :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
    defer world_destroy(&w)
    w.ground.open=pit_open
    road:=core.create(&w.entities)
    core.add(&w.transforms,road,core.Transform{{0,0,0},mm.QUAT_IDENTITY,{1,1,1}})
    spline:=volume.SPLINE_DEFAULT
    spline.material={1,1}
    core.add(&w.splines,road,spline)
    world_step(&w)
    world_step(&w)
    child,count:=parts_of(&w,road)
    if !testing.expect_value(t,count,1) {return}
    first:=mesh_of(&w,child)

    Case :: struct {what:string,pit:mm.Aabb,laid:bool}
    cases:=[?]Case{
        {"a tick without changes",{},false},
        {"a pit away from the road",{{20,-10,-4},{24,10,0}},false},
        {"a pit under the road",{{-1,-10,-7},{1,10,-5}},true},
        {"a tick without changes after the dig",{},false},
    }
    for c in cases {
        if c.pit!={} {
            w.pit.box,w.pit.depth=c.pit,2
            core.push(&w.ground.changed,c.pit)
        }
        w.pit.probes=0
        before:=mesh_of(&w,child)
        world_step(&w)
        after:=mesh_of(&w,child)
        testing.expectf(t,(w.pit.probes>0)==c.laid && (after!=before)==c.laid,"%s: %d probes, mesh %v to %v",c.what,w.pit.probes,before,after)
    }
    dug:=host.assets_mesh(&a.assets,mesh_of(&w,child))
    testing.expect(t,mesh_of(&w,child)!=first && dug!=nil && abs(dug.bounds_min.y-(-2+0.05))<1e-3,"the road lies on the bottom of the pit")
}

@(test)
a_bend_draws_and_collides_the_mesh_of_its_entity_bent_through_one_child :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    a:App
    if !testing.expect(t,app_init(&a)) {return}
    defer app_destroy(&a)
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
    defer world_destroy(&w)
    // A cube of one metre laid along a quarter of a circle of radius 2 in XZ.
    bend:=BEND_DEFAULT
    bend.end,bend.start_tangent,bend.end_tangent={2,0,-2},{0,0,-3.3137},{3.3137,0,0}
    e:=core.create(&w.entities)
    core.add(&w.meshes,e,render.Mesh_Renderer{shape=.Cube,materials={0=base.Asset_Id{1,2}}})
    core.add(&w.bends,e,bend)
    surface:=physics.COLLIDER_DEFAULT
    surface.kind,surface.friction=.External,0.1
    core.add(&w.colliders,e,surface)
    world_step(&w)
    testing.expect_value(t,w.problems.count,0)
    child,count:=parts_of(&w,e)
    if !testing.expect_value(t,count,1) {return}
    testing.expect(t,!core.has(&w.ids,child) && core.has(&w.elsewhere,e),"an unsaved child draws it, and the entity no more")
    shown,_:=core.get(&w.meshes,child)
    testing.expect(t,shown.materials[0]==base.Asset_Id{1,2},"with the materials of the entity")
    generated:=host.assets_mesh(&a.assets,shown.mesh)
    if !testing.expect(t,generated!=nil && generated.generated) {return}
    // The bounds of the bent cube, not of the straight one: its back across start, its front across end.
    testing.expectf(t,abs(generated.bounds_max.x-2)<1e-3 && abs(generated.bounds_min.z+2.5)<1e-3 && abs(generated.bounds_max.z)<1e-3,"bounds %v %v",generated.bounds_min,generated.bounds_max)
    collider,collides:=core.get(&w.colliders,child)
    testing.expect(t,collides && collider.kind==.Mesh && collider.friction==0.1,"it collides with the bent mesh, with the surface of the entity")
    lowest:=f32(0)
    for p in generated.collision.positions {lowest=min(lowest,p.z)}
    testing.expectf(t,lowest<-2.4,"what collides is bent: %v",lowest)

    // Nothing changed: the same mesh. A new curve: a new mesh on the same child.
    first:=shown.mesh
    world_step(&w)
    testing.expect(t,mesh_of(&w,child)==first)
    core.edit(&w.bends,e).end_roll=1
    world_step(&w)
    testing.expect(t,mesh_of(&w,child)!=first && !host.assets_mesh_generated(&a.assets,first))

    // A Collider that reads the mesh unbent says so; without one the child does not collide.
    core.edit(&w.colliders,e).kind=.Mesh
    world_step(&w)
    testing.expect(t,w.problems.count==1 && !core.has(&w.colliders,child))
    core.remove(&w.colliders,e)
    world_step(&w)
    testing.expect(t,!core.has(&w.colliders,child))

    // Without the Bend the entity draws its own mesh again.
    core.remove(&w.bends,e)
    world_step(&w)
    _,count=parts_of(&w,e)
    testing.expect(t,count==0 && !core.has(&w.elsewhere,e))
}

// A strip 2·width wide along -Z, as a reimport writes it.
@(private="file")
strip_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,width:f32) -> bool {
    n:=mm.normal_pack({0,1,0})
    vertices:=[4]asset.Vertex{{position={-width,0,0},normal=n},{position={width,0,0},normal=n},{position={width,0,-1},normal=n},{position={-width,0,-1},normal=n}}
    indices:=[6]u32{0,2,1,0,3,2}
    g:asset.Mesh_Geometry
    if !asset.mesh_build({vertices=vertices[:]},indices[:],nil,&g,context.temp_allocator) {return false}
    return asset.mesh_save(path,types,{id=id,geometry=g})==.None
}

@(test)
a_bend_bends_its_mesh_again_when_the_file_of_the_mesh_changes :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    root:=base.test_folder(t,"shapes-bend-reimport")
    if root=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    RAIL :: base.Asset_Id{0x7261696c,1}
    if !testing.expect(t,strip_save(fmt.tprintf("%s/rail.mesh",root),&types,RAIL,0.1)) {return}
    a:App
    if !testing.expect(t,app_init(&a,root)) {return}
    defer app_destroy(&a)
    w:Step_Test
    if !world_init(t,&w,&a.app) {return}
    defer world_destroy(&w)
    // Along a quarter of a circle: at its end the width of the strip runs along Z.
    bend:=BEND_DEFAULT
    bend.end,bend.start_tangent,bend.end_tangent={2,0,-2},{0,0,-3.3137},{3.3137,0,0}
    e:=core.create(&w.entities)
    core.add(&w.meshes,e,render.Mesh_Renderer{mesh=RAIL})
    core.add(&w.bends,e,bend)
    world_step(&w)
    child,_:=parts_of(&w,e)
    first:=mesh_of(&w,child)
    lowest :: proc(a:^App,mesh:base.Asset_Id) -> f32 {
        generated:=host.assets_mesh(&a.assets,mesh)
        return generated!=nil?generated.bounds_min.z:0
    }
    testing.expectf(t,w.problems.count==0 && abs(lowest(&a,first)+2.1)<1e-3,"bent: %v",lowest(&a,first))

    // Another file changes: the mesh of the bend holds the same, and is not bent again.
    if !testing.expect(t,strip_save(fmt.tprintf("%s/other.mesh",root),&types,{0x6f74686572,1},0.3)) {return}
    testing.expect_value(t,asset.registry_refresh(&a.assets.registry,{"other.mesh"}),asset.Error.None)
    world_step(&w)
    testing.expect(t,mesh_of(&w,child)==first)

    // The mesh is reimported wider: bent again, and the first bent mesh released.
    if !testing.expect(t,strip_save(fmt.tprintf("%s/rail.mesh",root),&types,RAIL,0.4)) {return}
    testing.expect_value(t,asset.registry_refresh(&a.assets.registry,{"rail.mesh"}),asset.Error.None)
    world_step(&w)
    again:=mesh_of(&w,child)
    testing.expectf(t,again!=first && !host.assets_mesh_generated(&a.assets,first) && abs(lowest(&a,again)+2.4)<1e-3,"bent again: %v",lowest(&a,again))
}
