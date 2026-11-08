package vfx_editor

import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"
import "plugins:vfx/runtime/gridfile"

// What the vfx plugin gives the editor: the kind .particle in the content
// browser (its family, color and icon, and a click on its card that gives it
// to the selected emitters), its thumbnails and its document, which show its
// particles drawn by the GPU, the card Particles of Create, the section of
// Particle_Emitter in Details and the particle.* methods of the API.

PARTICLES_COLOR :: ui.Color{240,160,210,255}
EFFECT_COLOR :: ui.Color{1,202,252,255}
GRID_STATE_COLOR :: ui.Color{120,200,170,255}

@(storage,free="vfx_editor_free")
Vfx_Editor :: struct {
    ready:bool,
    document:Effect_Document,
    thumbnail:Effect_Preview, // where the thumbnails of effects are drawn
}

vfx_editor_free :: proc(v:^Vfx_Editor) {
    preview_free(&v.document.preview)
    preview_free(&v.thumbnail)
    v^={}
}

@(private)
vfx_editor_ready :: proc(v:^Vfx_Editor) {
    if v.ready {return}
    v.ready=true
    v.document.playback={speed=1,loop=true,playing=true}
    v.document.open={.Spawn=true,.Shape=true,.Motion=true,.Look=true,.Collision=true,.Program=true}
}

// The storage of the plugin in the editor of a session.
@(private)
vfx_editor_of :: proc(s:^editor.Session) -> ^Vfx_Editor {
    if s.editor_world==nil || s.info==nil {return nil}
    v:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Vfx_Editor)
    if v!=nil {vfx_editor_ready(v)}
    return v
}

@(storage)
Vfx_Documents :: struct {provider:editor.Asset_Document_Provider}
VFX_DOCUMENTS_DEFAULT :: Vfx_Documents{provider={kinds={0=effect.KIND},count=1,creates={0},create=effect_create,between=effect_document_between}}

// The empty effect Create and asset.create make: the defaults of a new one.
@(private)
effect_create :: proc(s:^editor.Session,kind:asset.Fourcc,id:base.Asset_Id) -> []u8 {
    if s.app==nil || s.app.assets==nil {return nil}
    bytes,error:=effect.particle_bytes(&s.app.assets.types,{id=id,info=effect.PARTICLE_DEFAULTS},context.temp_allocator)
    return bytes if error==.None else nil
}

@(storage)
Vfx_Kinds :: struct {provider:editor.Asset_Kind_Provider}
VFX_KINDS_DEFAULT :: Vfx_Kinds{provider={
    kinds={
        0={kind=effect.KIND,label="Particle",color=EFFECT_COLOR,icon=.Particles,extension=effect.EXTENSION,field="particle",merged=true},
        1={kind=gridfile.KIND,label="Grid state",color=GRID_STATE_COLOR,icon=.Grid,extension=gridfile.EXTENSION,field="cached"},
    },
    count=2,
    clicked=effect_clicked,
}}

@(storage)
Vfx_Thumbnails :: struct {provider:editor.Thumbnail_Provider}
VFX_THUMBNAILS_DEFAULT :: Vfx_Thumbnails{provider={kinds={0=effect.KIND},count=1,subject=effect_subject,image=effect_image}}

@(storage)
Vfx_Cards :: struct {provider:editor.Card_Provider}
VFX_CARDS_DEFAULT :: Vfx_Cards{provider={
    cards={0={label="Particles",group="Logic",icon=.Particles,color=PARTICLES_COLOR,lift=0.5,make=emitter_make,component=vfx.Particle_Emitter}},
    count=1,
}}

@(storage)
Vfx_Inspector :: struct {provider:editor.Inspector_Provider}
VFX_INSPECTOR_DEFAULT :: Vfx_Inspector{provider={component=vfx_sections,field=emitter_field,within=emitter_within}}

@(storage)
Vfx_Api :: struct {provider:editor.Api_Provider}
VFX_API_DEFAULT :: Vfx_Api{provider={register=api_register}}

@(private)
emitter_make :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if t:=core.world_table_of(w,vfx.Particle_Emitter);t!=nil {core.add(t,e,vfx.PARTICLE_EMITTER_DEFAULT)}
}

// The emitters of the selection take the effect whose card was clicked, as one step.
@(private)
effect_clicked :: proc(s:^editor.Session,w:core.World_Ref,file:^asset.Registry_File) {
    emitters:=make([dynamic]core.Entity,context.temp_allocator)
    for e in s.selection.entities {
        if editor.entity_has(w,e,vfx.Particle_Emitter) {append(&emitters,e)}
    }
    if len(emitters)==0 {return}
    id:=file.id
    _,info:=core.world_table(w,vfx.Particle_Emitter)
    editor.content_used(s,file.id)
    editor.field_write(s,info,emitters[:],int(offset_of(vfx.Particle_Emitter,particle)),mem.ptr_to_bytes(&id))
}

// The document of the effect in front. Without it its preview goes, and so
// does that of the thumbnails once none was drawn for a while.
@(step="ui",after="editor_panels")
vfx_document :: proc(s:^editor.Session,v:^Vfx_Editor,app:^host.App,frame:core.Frame_Time) {
    if v.thumbnail.world!=nil && s.frame>v.thumbnail.used+PREVIEW_IDLE {preview_free(&v.thumbnail)}
    g:=s.gui
    d:=editor.asset_document_active(s)
    if d==nil || d.kind!=effect.KIND || editor.playing(s) {
        if v.document.preview.world!=nil {
            preview_free(&v.document.preview)
            v.document.image.ready,v.document.image.signature=false,0
        }
        return
    }
    if !g.begun {return}
    vfx_editor_ready(v)
    effect_document(s,&v.document,app,frame,d.id)
}

// An effect let go over an entity of the scene with a Particle_Emitter: the
// emitter shows it.
@(step="ui",after="editor_panels")
vfx_drop :: proc(s:^editor.Session) {
    drop,ok:=editor.asset_drop_take(s,effect.KIND)
    if !ok || editor.playing(s) {return}
    w:=editor.shown_world(s)
    if !editor.entity_has(w,drop.entity,vfx.Particle_Emitter) {return}
    id:=drop.id
    _,info:=core.world_table(w,vfx.Particle_Emitter)
    editor.content_used(s,id)
    editor.field_write(s,info,[]core.Entity{drop.entity},int(offset_of(vfx.Particle_Emitter,particle)),mem.ptr_to_bytes(&id))
}
