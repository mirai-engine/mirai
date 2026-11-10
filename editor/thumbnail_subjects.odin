package editor

import "core:mem"
import "core:os"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// Previews of what is not one mesh: the entities of a prefab or a scene, and
// the assets of the kinds a Thumbnail_Provider of a plugin gives.

// The preview of an asset of a kind a Thumbnail_Provider gives, or of its
// clip-th clip from 1; nothing without a provider or what to show.
preview_provided :: proc(s:^Session,file:^asset.Registry_File,clip:u32,points:f32) -> ui.Quad {
    a:=s.app.assets
    if a==nil || a.renderer==nil {return {}}
    provider,found:=thumbnail_provider(s,file.kind)
    subject:Thumbnail_Subject
    if !found || provider.subject==nil || !provider.subject(s,file,clip,&subject) {return {}}
    named:=[4]u64{file.id[0],file.id[1],u64(clip),u64(file.kind)}
    return preview_request(s,thumbnail_key(mem.ptr_to_bytes(&named)),&subject,points,file.id if clip==0 else {})
}

// What a field of a kind a Thumbnail_Provider gives shows without an asset (a
// default); nothing when its provider gives none.
preview_default :: proc(s:^Session,kind:asset.Fourcc,points:f32) -> ui.Quad {
    a:=s.app.assets
    if a==nil || a.renderer==nil {return {}}
    provider,found:=thumbnail_provider(s,kind)
    subject:Thumbnail_Subject
    if !found || provider.subject==nil || !provider.subject(s,nil,0,&subject) {return {}}
    named:=[3]u64{0x64656661756c74,u64(kind),0}
    return preview_request(s,thumbnail_key(mem.ptr_to_bytes(&named)),&subject,points)
}

// The preview of an asset of a kind for a box or a row of a list, at a side
// in points; for the zero id, what a field of the kind without one shows.
asset_quad :: proc(s:^Session,kind:asset.Fourcc,id:base.Asset_Id,points:f32) -> ui.Quad {
    switch kind {
    case asset.KIND_MATERIAL: return material_quad(s,id)
    case asset.KIND_TEXTURE:  return texture_quad(s,id)
    }
    a:=s.app.assets
    if a==nil || a.renderer==nil {return {}}
    if id=={} {return preview_default(s,kind,points)}
    file,found:=asset.registry_find(&a.registry,id)
    if !found {return {}}
    _,_,quad:=content_preview(s,file,points)
    return quad
}

// The Thumbnail_Provider of a kind of asset, read from the plugins of the library in use.
@(private)
thumbnail_provider :: proc(s:^Session,kind:asset.Fourcc) -> (provider:Thumbnail_Provider,found:bool) {
    for &each in thumbnail_providers(s) {
        if slice.contains(each.kinds[:clamp(each.count,0,len(each.kinds))],kind) {return each,true}
    }
    return
}

// The kinds of asset of the plugins that the browser lists: those a plugin
// opens as documents or declares (Asset_Kind_Provider).
@(private)
content_plugin_kinds :: proc(s:^Session,allocator:=context.temp_allocator) -> []asset.Fourcc {
    kinds:=make([dynamic]asset.Fourcc,allocator)
    append(&kinds,..asset_document_kinds(s,allocator))
    for each in asset_plugin_kinds(s) {append(&kinds,each.kind)}
    return kinds[:]
}

@(private)
thumbnail_providers :: proc(s:^Session) -> []Thumbnail_Provider {
    p:=s.thumbnails
    if p==nil {return nil}
    if p.providers_library!=s.library_generation+1 {
        p.providers_library=s.library_generation+1
        p.provider_count=provided_all(s,p.providers[:])
    }
    return p.providers[:p.provider_count]
}

// The preview of a prefab or a scene: its entities that show a mesh, framed whole.
preview_document :: proc(s:^Session,id:base.Asset_Id,points:f32) -> ui.Quad {
    a:=s.app.assets
    if a==nil || a.renderer==nil {return {}}
    subject:=Thumbnail_Subject{document=id}
    named:=[3]u64{id[0],id[1],0x646f63}
    return preview_request(s,thumbnail_key(mem.ptr_to_bytes(&named)),&subject,points,id)
}

// A mesh as some entity of a document shows it, read once for all those that
// show the same: its vertices in Document_Draw.locals.
@(private)
Document_Mesh :: struct {key:u64,first,count:int}

// Appends the triangles of the entities of a prefab or a scene that show a
// mesh, where their transforms put them: all of them, or those under root.
// Skinned meshes show as their vertices are stored, and Hidden leaves out an
// entity and what hangs from it.
@(private)
document_triangles :: proc(a:^host.Assets,document:base.Asset_Id,root:base.Entity_Id,vertices:^[dynamic]gpu.Thumbnail_Vertex,materials:^[dynamic]gpu.Material_Desc) -> bool {
    record,found:=asset.registry_find(&a.registry,document)
    if !found {return false}
    data:asset.Asset
    if host.assets_file(a,document,record.kind,&data)!=.None {return false}
    defer asset.asset_close(&data)
    view,error:=asset.scene_view(&data,&a.types)
    if error!=.None || asset.scene_view_check(view,context.temp_allocator)!=.None {return false}
    count:=len(view.ids)
    renderers,shown:=document_column(&data,&view,&a.types,"Mesh_Renderer",erender.Mesh_Renderer)
    if renderers==nil {return false}
    identity:=core.TRANSFORM_IDENTITY
    transforms,placed:=document_column(&data,&view,&a.types,"Transform",core.Transform,&identity)
    tints,tinted:=document_column(&data,&view,&a.types,"Tint",erender.Tint)
    overrides,overridden:=document_column(&data,&view,&a.types,"Material_Override",erender.Material_Override)
    hidden:=make([]bool,count,context.temp_allocator)
    for &component in view.components {
        if component.name!="Hidden" {continue}
        for row in component.entities {hidden[row]=true}
    }
    under:[]bool
    if root!=0 {
        for id,row in view.ids {
            if id==root {under=document_subtree(view,row);break}
        }
        if under==nil {return false}
    }

    // Where each entity is, and whether it or what it hangs from is hidden.
    rows:=make(map[base.Entity_Id]int,count,context.temp_allocator)
    for id,row in view.ids {rows[id]=row}
    worlds:=make([]mm.Transform,count,context.temp_allocator)
    done:=make([]bool,count,context.temp_allocator)
    chain:=make([dynamic]int,0,16,context.temp_allocator)
    for start in 0..<count {
        clear(&chain)
        for row:=start;!done[row]; {
            append(&chain,row)
            parent,known:=rows[view.parents[row]]
            if view.parents[row]==0 || !known {break}
            row=parent
        }
        #reverse for row in chain {
            local:=core.to_math(transforms[row]) if placed!=nil && placed[row] else mm.TRANSFORM_IDENTITY
            worlds[row]=local
            if parent,known:=rows[view.parents[row]];view.parents[row]!=0 && known {
                worlds[row]=mm.transform_compose(worlds[parent],local)
                hidden[row]||=hidden[parent]
            }
            done[row]=true
        }
    }

    meshes:=make([dynamic]Document_Mesh,context.temp_allocator)
    locals:=make([dynamic]gpu.Thumbnail_Vertex,0,1024,context.temp_allocator)
    for row in 0..<count {
        if !shown[row] || hidden[row] || under!=nil && !under[row] {continue}
        room:=THUMBNAIL_TRIANGLES*3-len(vertices)
        if room<3 {break}
        Look :: struct {mesh:erender.Mesh_Renderer,tint:erender.Tint,override:erender.Material_Override}
        look:=Look{mesh=renderers[row],tint=erender.TINT_DEFAULT}
        if tinted!=nil && tinted[row] {look.tint=tints[row]}
        if overridden!=nil && overridden[row] {look.override=overrides[row]}
        key:=base.hash64(mem.ptr_to_bytes(&look))
        shape:Document_Mesh
        read:=false
        for each in meshes {
            if each.key==key {shape,read=each,true;break}
        }
        if !read {
            shape={key=key,first=len(locals)}
            triangles_append(a,look.mesh,look.tint,&look.override,mm.TRANSFORM_IDENTITY,THUMBNAIL_TRIANGLES*3-len(locals),&locals,materials)
            shape.count=len(locals)-shape.first
            append(&meshes,shape)
        }
        added:=min(shape.count,room/3*3)
        if added==0 {continue}
        at:=len(vertices)
        append(vertices,..locals[shape.first:][:added])
        vertices_place(vertices[at:],worlds[row])
    }
    return len(vertices)>=3
}

// The values of a component for every entity row of a document, read as T,
// and which rows have it; nil when the document has none. Temporary memory.
document_column :: proc(data:^asset.Asset,view:^asset.Scene_View,types:^asset.Types,name:string,$T:typeid,default:^T=nil) -> (values:[]T,has:[]bool) {
    for &component in view.components {
        if component.name!=name {continue}
        index,known:=asset.types_index(types,T)
        if !known {return}
        read:=make([]T,len(component.entities),context.temp_allocator)
        if asset.scene_component_read(data,&component,&types.schema,index,mem.slice_to_bytes(read),mem.ptr_to_bytes(default) if default!=nil else nil)!=.None {return}
        values=make([]T,len(view.ids),context.temp_allocator)
        has=make([]bool,len(view.ids),context.temp_allocator)
        for row,i in component.entities {values[row],has[row]=read[i],true}
        return
    }
    return
}

// The entity rows of a document at a row or under it. Temporary memory.
document_subtree :: proc(view:asset.Scene_View,root:int) -> []bool {
    count:=len(view.ids)
    rows:=make(map[base.Entity_Id]int,count,context.temp_allocator)
    for id,row in view.ids {rows[id]=row}
    // 0: not yet known, 1: under root, 2: not
    state:=make([]u8,count,context.temp_allocator)
    state[root]=1
    chain:=make([dynamic]int,0,16,context.temp_allocator)
    for start in 0..<count {
        row:=start
        clear(&chain)
        for state[row]==0 {
            append(&chain,row)
            parent,known:=rows[view.parents[row]]
            if view.parents[row]==0 || !known {
                state[row]=2
                break
            }
            row=parent
        }
        for each in chain {state[each]=state[row]}
    }
    under:=make([]bool,count,context.temp_allocator)
    for value,row in state {under[row]=value==1}
    return under
}

THUMBNAIL_CAPTURE_WAIT :: 2   // frames the editor shows a scene it opened before it takes its view
THUMBNAIL_CAPTURE_SIDE :: 512 // pixels of the view taken, reduced to the side of each cell
THUMBNAIL_CAPTURED :: u64(0x63617074757265) // the key of a stored view of a scene

// The preview of a scene: the view the editor took of it (thumbnail_scene_capture),
// kept in the thumbs folder: the first time it opened it, or when Update scene
// thumbnail asked for what the viewport shows. Nothing for a scene it never opened.
preview_scene :: proc(s:^Session,id:base.Asset_Id,points:f32) -> ui.Quad {
    subject:=Thumbnail_Subject{document=id,captured=true}
    return preview_request(s,thumbnail_scene_key(id),&subject,points,id)
}

@(private)
thumbnail_scene_key :: proc(id:base.Asset_Id) -> u64 {
    named:=[3]u64{id[0],id[1],0x7363656e65}
    return thumbnail_key(mem.ptr_to_bytes(&named))
}

// The editor opened a scene: the first time, its view is taken once it shows it.
@(private)
thumbnail_scene_opened :: proc(s:^Session,id:base.Asset_Id) {
    folder:=thumbnail_folder(s)
    if folder=="" || os.exists(thumbnail_file(folder,id,THUMBNAIL_LARGE)) {return}
    thumbnail_scene_take(s,id,THUMBNAIL_CAPTURE_WAIT)
}

// Takes the view of a scene between frames, wait frames from now; announce:
// a notice says when it is kept.
@(private)
thumbnail_scene_take :: proc(s:^Session,id:base.Asset_Id,wait:u64,announce:=false) {
    p:=s.thumbnails
    p.opened,p.opened_frame,p.announce=id,s.frame+wait,announce
}

// Whether the editor can keep views of scenes: it draws, and the project has a thumbs folder.
@(private)
scene_thumbnails_kept :: proc(s:^Session) -> bool {
    return s.app.assets!=nil && s.app.renderer!=nil && thumbnail_folder(s)!=""
}

// Whether the scene in front is one of the assets, whose view can be its thumbnail.
@(private)
scene_thumbnail_takes :: proc(s:^Session) -> bool {
    if !scene_thumbnails_kept(s) || scene_covered(s) || document_is_prefab(s) {return false}
    file,found:=asset.registry_find(&s.app.assets.registry,s.document.id)
    return found && file.kind==asset.KIND_SCENE
}

// The tab a scene is open in; -1 for none.
@(private)
scene_tab :: proc(s:^Session,id:base.Asset_Id) -> int {
    if id=={} {return -1}
    for &tab,index in s.documents {
        tab_id:=s.document.id if index==s.active_document else tab.document.id
        if tab_id==id {return index}
    }
    return -1
}

// Takes what a scene open in a tab shows as its thumbnail: at once while it
// is in front, else once its tab is brought there.
@(private)
scene_thumbnail_update :: proc(s:^Session,id:base.Asset_Id) {
    tab:=scene_tab(s,id)
    if tab<0 || s.mode!=.Edit || !scene_thumbnails_kept(s) {return}
    if tab==s.active_document && !scene_covered(s) {
        thumbnail_scene_take(s,id,0,true)
        return
    }
    s.document_request=tab
    s.requests+={.Document_Switch}
    thumbnail_scene_take(s,id,THUMBNAIL_CAPTURE_WAIT,true)
}

// Takes the view of the scene opened when its frame came: the World alone
// through the camera of the viewport, without panels, gizmos, lines or the
// grid, as capture draws it without the UI. Not when another scene,
// a Play or a document of an asset is in front by then. Between frames.
@(private)
thumbnail_scene_capture :: proc(s:^Session) {
    p:=s.thumbnails
    if p==nil || p.opened=={} || s.frame<p.opened_frame {return}
    id,announce:=p.opened,p.announce
    p.opened,p.announce={},false
    if s.app.renderer==nil || s.mode!=.Edit || s.document.id!=id || scene_covered(s) {return}
    folder:=thumbnail_folder(s)
    if folder=="" {return}
    pixels,width,height,ok:=host.app_capture_world(s.app,shown_world(s).data,API_CAPTURE_SETTLE,{THUMBNAIL_CAPTURE_SIDE,THUMBNAIL_CAPTURE_SIDE},s.editor_world,context.temp_allocator)
    if !ok || width!=THUMBNAIL_CAPTURE_SIDE || height!=THUMBNAIL_CAPTURE_SIDE {return}
    if thumbnail_scene_store(p,folder,id,pixels) && announce {notify(s,"Scene thumbnail updated")}
}

// Keeps a view of a scene, THUMBNAIL_CAPTURE_SIDE pixels square, as its
// preview of each size, and puts it in the cells that show it. False when
// nothing could be written.
@(private)
thumbnail_scene_store :: proc(p:^Thumbnails,folder:string,id:base.Asset_Id,pixels:[]u8) -> (kept:bool) {
    if len(pixels)!=THUMBNAIL_CAPTURE_SIDE*THUMBNAIL_CAPTURE_SIDE*4 {return}
    sides:=THUMBNAIL_SIDES
    for side,level in sides {
        n:=THUMBNAIL_CAPTURE_SIDE/side
        resize(&p.image,side*side*4)
        for y in 0..<side {
            for x in 0..<side {
                sum:[3]u32
                for sy in 0..<n {
                    for sx in 0..<n {
                        index:=((y*n+sy)*THUMBNAIL_CAPTURE_SIDE+x*n+sx)*4
                        for channel in 0..<3 {sum[channel]+=u32(pixels[index+channel])}
                    }
                }
                out:=p.image[(y*side+x)*4:][:4]
                for channel in 0..<3 {out[channel]=u8(sum[channel]/u32(n*n))}
                out[3]=255
            }
        }
        if !thumbnail_save(folder,id,side,THUMBNAIL_CAPTURED,p.image[:],&p.file) {continue}
        kept=true
        key:=thumbnail_scene_key(id)
        if level==.Large {key=thumbnail_key(mem.ptr_to_bytes(&key))}
        first:=0 if level==.Small else THUMBNAIL_SMALL_CELLS
        cells:=p.cells[:THUMBNAIL_SMALL_CELLS] if level==.Small else p.cells[THUMBNAIL_SMALL_CELLS:]
        for &cell,at in cells {
            if cell.key!=key {continue}
            thumbnail_put(p,first+at,p.image[:])
            cell.stored,cell.ready,cell.absent=THUMBNAIL_CAPTURED,true,0
        }
    }
    return
}
