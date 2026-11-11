package render

import "mirai:core"
import volume "mirai:engine/volume"
import "core:testing"
import "mirai:host"
import gpu "mirai:render"

// The World of the tests of this library: what its functions read and write.
// It holds no core.Disabled, so the test that draws by its hierarchy settles it.
@(private)
Render_World :: struct {
    using world:core.Test_World,
    worlds:core.Table(core.World_Transform),
    locals:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    meshes:core.Table(Mesh_Renderer),
    tints:core.Table(Tint),
    hidden:core.Table(Hidden),
    elsewhere:core.Table(Drawn_Elsewhere),
    suns:core.Table(Sun),
    points:core.Table(Point_Light),
    spots:core.Table(Spot_Light),
    rects:core.Table(Rect_Light),
    emissions:core.Table(Light_Emission),
    skies:core.Table(Sky),
    view_volumes:core.Table(View_Volume),
    volumes:core.Table(volume.Volume),
    overrides:core.Table(Material_Override),
    highlights:core.Table(Highlight),
    outlines:core.Table(Outline),
    offsets:core.Table(Draw_Offset),
    layers:core.Table(Layers),
    cameras:core.Table(Camera),
    hierarchy:core.Hierarchy,
    view:core.View,
    outline_styles:Outline_Styles,
    requests:Environment_Requests,
}

// render_sync of a test world, as a frame without players, volumes or
// cameras gives it: the camera of the application is set by the test.
@(private)
world_sync :: proc(w:^Render_World,sync:^Render_Sync,app:^host.App,id:core.World_Id={},hierarchy:core.Ref(core.Hierarchy)={},posed:^Posed_Meshes=nil) {
    render_sync(sync,app,id,core.FRAME_TIME_DEFAULT,{},core.read(&w.worlds),core.read(&w.meshes),core.read(&w.tints),core.read(&w.hidden),core.read(&w.elsewhere),core.read(&w.parents),hierarchy,core.read(&w.suns),core.read(&w.points),core.read(&w.spots),core.read(&w.rects),core.read(&w.emissions),core.read(&w.skies),core.read(&w.view_volumes),{},core.read(&w.overrides),core.read(&w.highlights),core.read(&w.outlines),{&w.outline_styles},core.read(&w.offsets),core.read(&w.layers),{},{},{},{},posed)
}

// An application that draws nothing: assets over a renderer without a
// device, which keeps the scene render_sync gives it.
@(private)
Sync_Fixture :: struct {
    app:host.App,
    assets:host.Assets,
    renderer:gpu.Renderer,
    world:Render_World,
    sync:Render_Sync,
}

@(private)
sync_fixture_init :: proc(t:^testing.T,f:^Sync_Fixture) -> bool {
    f.renderer.allocator=context.allocator
    if !testing.expect(t,gpu.scene_init(&f.renderer) && host.assets_init(&f.assets,{root="assets",capacity=64,renderer=&f.renderer})) {return false}
    f.app.assets,f.app.renderer=&f.assets,&f.renderer
    // Every shape is a triangle of its own: making the real ones asks the device what it takes.
    corners:=[3]gpu.Mesh_Vertex{{position={0,0,0},normal={0,1,0}},{position={1,0,0},normal={0,1,0}},{position={0,0,1},normal={0,1,0}}}
    for shape in Shape {
        if shape==.None {continue}
        handle,added:=gpu.mesh_add(&f.renderer,corners[:],{0,1,2})
        if !testing.expect(t,added) {return false}
        f.assets.shapes[shape]={handle=handle,vertex_count=3,index_count=3,bounds_max={1,0,1}}
        f.assets.shapes_ready[shape]=true
    }
    return core.test_world_init(t,&f.world,test_types)
}

@(private)
sync_fixture_destroy :: proc(f:^Sync_Fixture) {
    sync_free(&f.sync)
    core.test_world_destroy(&f.world)
    host.extras_free(&f.app.extras)
    host.assets_destroy(&f.assets)
    gpu.scene_destroy(&f.renderer)
}

// A cube of the fixture's world at x.
@(private)
sync_cube :: proc(f:^Sync_Fixture,x:f32) -> core.Entity {
    e:=core.create(&f.world.entities)
    place:=core.World_Transform{transform={position={x,0,0},rotation=1,scale=1},previous={position={x,0,0},rotation=1,scale=1}}
    core.add(&f.world.worlds,e,place)
    core.add(&f.world.meshes,e,Mesh_Renderer{shape=.Cube})
    return e
}

// A frame of the fixture, with a pose of the meshes: the instances the
// renderer was given or moved in it. What it had of the frame before goes, as
// the upload of a frame takes it.
@(private)
sync_frame :: proc(f:^Sync_Fixture,id:core.World_Id={},posed:^Posed_Meshes=nil) -> int {
    core.test_world_settle(&f.world)
    core.hierarchy_settle(&f.world.hierarchy,core.read(&f.world.parents),&f.world.entities)
    s:=&f.renderer.scene
    for &word in s.touched {word=0}
    s.touched_count,s.lights_changed,s.changes=0,false,{}
    world_sync(&f.world,&f.sync,&f.app,id,core.ref(&f.world.hierarchy),posed)
    clear(&f.app.extras.instances)
    return s.touched_count
}
