package render

import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:host"

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
world_sync :: proc(w:^Render_World,sync:^Render_Sync,app:^host.App,id:core.World_Id={},hierarchy:core.Ref(core.Hierarchy)={}) {
    render_sync(sync,app,id,core.FRAME_TIME_DEFAULT,{},core.read(&w.worlds),core.read(&w.meshes),core.read(&w.tints),core.read(&w.hidden),core.read(&w.elsewhere),core.read(&w.parents),hierarchy,core.read(&w.suns),core.read(&w.points),core.read(&w.spots),core.read(&w.rects),core.read(&w.emissions),core.read(&w.skies),core.read(&w.view_volumes),{},core.read(&w.overrides),core.read(&w.highlights),core.read(&w.outlines),{&w.outline_styles},core.read(&w.offsets),core.read(&w.layers),{},{},{},{})
}

// The scene of a test world as a frame that sets it whole gives the renderer: in whole.shown.
@(private)
world_instances :: proc(w:^Render_World,whole:^Render_Sync,app:^host.App) -> bool {
    t:=Sync_Tables{
        worlds=core.read(&w.worlds),meshes=core.read(&w.meshes),tints=core.read(&w.tints),hidden=core.read(&w.hidden),elsewhere=core.read(&w.elsewhere),
        parents=core.read(&w.parents),overrides=core.read(&w.overrides),highlights=core.read(&w.highlights),outlines=core.read(&w.outlines),
        offsets=core.read(&w.offsets),layers=core.read(&w.layers),
    }
    return instances_build(whole,app.assets,t,core.FRAME_TIME_DEFAULT,host.extras_instances(&app.extras))
}
