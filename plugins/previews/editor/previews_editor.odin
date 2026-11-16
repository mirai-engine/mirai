package previews_editor

import "base:runtime"
import "core:hash"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import eanim "plugins:animation/runtime"
import "mirai:host"
import "mirai:ui"

// The documents of animation assets, sounds and sound sets, in tabs next to
// the scenes (editor.asset_workspace). The animation document plays a clip of
// the .anim on a subject, a skinned mesh or the subtree of an entity of the
// scene; the renderer draws its image inside the frame into an image of its
// texture table. What a document changes goes to the file of its asset as
// steps of the history of the document. The thumbnails of
// animations and skeletons are drawn by the content browser with what
// thumbnails.odin gives.

DOCUMENT_SCOPE :: ui.Id(0x70726576)
SCOPE_ANIMATION :: ui.Id(0x616e696d)
IMAGE_SIDE :: 1024 // texels of a side of the image the animation document draws: 512 points, drawn at twice
KEY_ANIMATION :: u64(0x616e696d6174696f)
KEY_SOUND :: u64(0x736f756e64776176)

@(storage,free="previews_free")
Previews :: struct {
    ready:bool,
    allocator:runtime.Allocator,
    animation:Animation,
    sound:Sound,
    models:Thumbnail_Models, // what the thumbnails of animations and skeletons show
}

@(storage)
Previews_Documents :: struct {provider:editor.Asset_Document_Provider}
PREVIEWS_DOCUMENTS_DEFAULT :: Previews_Documents{provider={kinds={0=asset.KIND_ANIMATION,1=asset.KIND_SOUND,2=asset.KIND_SOUND_SET},count=3,hierarchy={0}}}

previews_free :: proc(p:^Previews) {
    animation_destroy(&p.animation,p.allocator)
    sound_destroy(&p.sound)
    editor.asset_image_free(&p.animation.image)
    thumbnail_models_destroy(&p.models)
    p^={}
}

@(private)
previews_ready :: proc(p:^Previews,allocator:runtime.Allocator) {
    if p.ready {return}
    p.ready,p.allocator=true,allocator
    p.animation.image={key=KEY_ANIMATION,name="previews.animation"}
    p.animation.speed,p.animation.loop,p.animation.sun=1,true,true
    p.sound.image={key=KEY_SOUND,name="previews.sound"}
    p.sound.pixels=make([dynamic]u8,p.allocator)
}

// The document in front, when it is one of these.
@(step="ui",after="editor_panels")
previews_document :: proc(s:^editor.Session,p:^Previews,world:core.World_Ref,app:^host.App,frame:core.Frame_Time) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    previews_ready(p,app.allocator)
    d:=editor.asset_document_active(s)
    if d==nil {return}
    switch d.kind {
    case asset.KIND_ANIMATION: animation_document(s,p,world,app,frame,d)
    case asset.KIND_SOUND,asset.KIND_SOUND_SET: sound_document(s,p,app.assets,app.mixer,d)
    }
}

// A library or one of its clips let go over an entity of the scene: the
// entity plays it, with an Animation of its own when it has none.
@(step="ui",after="editor_panels")
previews_drop :: proc(s:^editor.Session) {
    drop,ok:=editor.asset_drop_take(s,asset.KIND_ANIMATION)
    if !ok || editor.playing(s) {return}
    t:=core.world_table_of(editor.edited_world(s),eanim.Animation)
    if t==nil || !history.edits_begin(s.edits,s.selection,"Play animation") {return}
    defer history.edits_end(s.edits)
    // An added component is there at the end of the function: it goes whole.
    if animation:=core.edit(t,drop.entity);animation!=nil {
        animation.asset,animation.clip=drop.id,drop.part
        return
    }
    added:=eanim.ANIMATION_DEFAULT
    added.asset,added.clip=drop.id,drop.part
    core.add(t,drop.entity,added)
}

@(private)
signature_of :: proc(values:[]u64) -> u64 {
    key:=hash.fnv64a(mem.slice_to_bytes(values))
    return key!=0?key:1
}
