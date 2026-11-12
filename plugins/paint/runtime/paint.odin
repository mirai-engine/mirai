package paint

import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"

// The colors of an entity painted over the mesh its Mesh_Renderer shows,
// which other entities of that mesh do not take: a .paint asset.
@(component)
Painted :: struct {
    colors:base.Asset_Id `mirai:"readonly,kind=.paint"`,
}

// A .paint: one color per vertex of a mesh, by index in the mesh (the order
// of the vertices of its clusters, every level of detail), RGBA8, with where
// each vertex was in the mesh and the content hash of the file of the mesh it
// was painted on, so that the editor fits the colors to another version of it.

Paint_Info :: struct {
    mesh:u64, // content_hash of the file of the mesh painted on; 0: a shape
}

Paint_View :: struct {
    using info:Paint_Info,
    positions:[][3]f32, // in the space of the mesh, one per color
    colors:[]u32,
}

paint_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,view:Paint_View,allocator:=context.allocator) -> asset.Error {
    if len(view.colors)==0 || len(view.positions)!=len(view.colors) {return .Invalid}
    asset.document_init(doc,PAINT_KIND,id,allocator)
    doc.kind_version=PAINT_VERSION
    error:=paint_tables(doc,types,view)
    if error!=.None {asset.document_destroy(doc)}
    return error
}

@(private)
paint_tables :: proc(doc:^asset.Document,types:^asset.Types,view:Paint_View) -> asset.Error {
    info:=view.info
    asset.document_put_row(doc,types,"paint",&info) or_return
    asset.document_put(doc,types,"positions",view.positions,{.Bulk},.Stream) or_return
    asset.document_put(doc,types,"colors",view.colors,{.Bulk},.Stream) or_return
    return .None
}

paint_view :: proc(a:^asset.Asset,types:^asset.Types) -> (view:Paint_View,error:asset.Error) {
    asset.kind_check(a,PAINT_KIND,PAINT_VERSION) or_return
    view.info=(asset.asset_row(a,types,"paint",Paint_Info) or_return)^
    view.positions=asset.asset_rows(a,types,"positions","",[3]f32) or_return
    view.colors=asset.asset_rows(a,types,"colors","",u32) or_return
    if len(view.colors)==0 || len(view.positions)!=len(view.colors) {return {},.Corrupt}
    return
}

PAINTED_SHOWN :: 1024 // painted entities the renderer shows the colors of; more show those of their mesh

@(private)
Shown :: struct {
    entity:core.Entity,
    colors:base.Asset_Id,
    handle:render.Colors_Handle, // shared by those of the same colors
}

// The colors of the Painted entities of the world the renderer draws, in
// the renderer. They load again when an asset file, the Painted rows or the
// world change, and go to the instances again when those change.
@(storage,host)
Paint_Render :: struct {
    shown:[PAINTED_SHOWN]Shown,
    count:int,
    loaded:[2]u64,
    world:core.World_Id,
    given:[2]u64,
}

@(step="render",loops="game editor",after="render_sync")
paint_render :: proc(state:^Paint_Render,painted:^core.Table(Painted,.Read),synced:core.Ref(render.Render_Sync),assets:^host.Assets,renderer:^render.Renderer,problems:^core.Problems) {
    if renderer==nil || assets==nil || synced.ptr==nil {return}
    sync:=synced.ptr
    loaded:=[2]u64{assets.registry.revision,core.version(painted)}
    given:=[2]u64{render.instance_revision(renderer),u64(render.instance_count(renderer))}
    if loaded!=state.loaded || sync.world!=state.world {
        state.loaded,state.world,state.given=loaded,sync.world,{}
        for shown in state.shown[:state.count] {render.colors_remove(renderer,shown.handle)}
        state.count=0
        for row in 0..<min(core.count(painted),PAINTED_SHOWN) {
            shown:=Shown{entity=core.entity_at(painted,row),colors=core.at(painted,row).colors}
            for held in state.shown[:state.count] {if held.colors==shown.colors {shown.handle=held.handle;break}}
            if shown.handle==0 {shown.handle=colors_load(assets,renderer,shown.colors)}
            if shown.handle==0 {continue}
            state.shown[state.count]=shown
            state.count+=1
        }
    }
    if given==state.given {return}
    state.given=given
    for shown in state.shown[:state.count] {
        index:=render.instance_of(sync,shown.entity)
        if index>=0 && !render.instance_colors_set(renderer,index,shown.handle) {
            core.report(problems,shown.entity,"paint.mismatch","its .paint was painted on another version of its mesh, with another number of vertices, and is not shown; open the scene in the editor, which fits the paint to the mesh and writes it")
        }
    }
}

// 0 for colors that are not a .paint the renderer can take.
@(private)
colors_load :: proc(assets:^host.Assets,renderer:^render.Renderer,id:base.Asset_Id) -> render.Colors_Handle {
    file:asset.Asset
    if host.assets_file(assets,id,PAINT_KIND,&file)!=.None {return 0}
    defer asset.asset_close(&file)
    view,error:=paint_view(&file,&assets.types)
    if error!=.None {return 0}
    handle,_:=render.colors_load(renderer,view.colors)
    return handle
}
