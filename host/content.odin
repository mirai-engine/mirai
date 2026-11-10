package host

import "base:runtime"
import "core:slice"
import "core:strings"
import "mirai:asset"
import audio "mirai:audio"
import "mirai:project"
import render "mirai:render"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

// The interfaces, animations, sounds, sound sets, fonts and prompts of
// the application's assets, loaded the first time a component names them and
// shared by every world. An asset whose file changes is loaded again where
// it is; generation tells whoever holds state made for the old one, and no
// two loads have the same. content_collect unloads what no scope of the
// assets reaches, but for fonts: they are fonts of App.ui_font until the
// application ends.

CONTENT_CAPACITY :: 256
// The fonts App.ui_font has before any is added: those of ui.font_init without fonts.
CONTENT_UI_FONTS :: ui.FONT_DEFAULTS

Content_Kind :: enum u8 {Ui,Animation,Sound,Sound_Set,Font,Prompts}

Content_Stamp :: struct {
    id:base.Asset_Id,
    size,time:i64, // of the file it was loaded from
    generation:u32,
    failed:bool,
}

Content_Ui :: struct {
    using stamp:Content_Stamp,
    tree:ui.Widget_Tree,
    textures:[]base.Asset_Id, // of each image of the tree
    revision:u64,             // of Assets when its images and styles were given their textures and programs
    low,high:i16,             // ui.tree_layers
    widgets:[]Content_Stamp,  // the files of the widgets it names: it loads again when one changes
}

// Every clip is in the library twice: clip i of the asset plays once as
// Clip(i+1) and in a loop as Clip(clip_count+i+1). Both share tracks and keys.
Content_Animation :: struct {
    using stamp:Content_Stamp,
    lib:anim.Library,
    clip_count:int,
    roots:[]asset.Animation_Root,
    markers:[]u64, // name_hash of each marker: anim.Marker.id is its index
    names:[][asset.ANIMATION_NAME_CAPACITY]u8, // of each clip
    morphs:[]Content_Morph, // its curves of morph weights, each once
    fields:[]Content_Field, // its curves that drive a field of a component, each once
    load:^Content_Animation_Load, // a load of its file under way (content_animation.odin)
    adopted:u32, // generation of its first load when a job made it; 0 when it loaded at once
}
// A curve "<path>/@morph/<target>": the name_hash of the curve and of the target, which binds a
// mesh that names no path to the curve of each of its targets.
Content_Morph :: struct {curve,target:u64}

// The curves of morph weights of an animation, each once.
content_animation_morphs :: proc(view:asset.Animation_View,allocator:runtime.Allocator) -> (morphs:[]Content_Morph,ok:bool) {
    found:=make([dynamic]Content_Morph,context.temp_allocator)
    for &track in view.tracks {
        if track.property!=.Float || track.slot!=0 {continue}
        text:=serial.text_field(track.target[:])
        at:=strings.last_index(text,asset.ANIMATION_MORPH_PATH)
        if at<0 || at+len(asset.ANIMATION_MORPH_PATH)==len(text) {continue}
        morph:=Content_Morph{base.name_hash(text),base.name_hash(text[at+len(asset.ANIMATION_MORPH_PATH):])}
        if !slice.contains(found[:],morph) {append(&found,morph)}
    }
    error:runtime.Allocator_Error
    morphs,error=make([]Content_Morph,len(found),allocator)
    if error!=nil {return nil,false}
    copy(morphs,found[:])
    return morphs,true
}

// A curve "<path>/@field/<Component>.<field>": the name_hash of the curve and of the path of the
// entity it drives below the one that plays the clip (0: that entity), and the field it writes.
Content_Field :: struct {
    curve,node:u64,
    property:anim.Property, // Float or Vector
    slot:u8,
    component:[asset.ANIMATION_NAME_CAPACITY]u8, // the name of the component, as the world names its table
    field:[asset.ANIMATION_FIELD_CAPACITY]u8,    // the path of the field inside it, as std/serial reads it
}

// The curves of an animation that drive a field, each once.
content_animation_fields :: proc(view:asset.Animation_View,allocator:runtime.Allocator) -> (fields:[]Content_Field,ok:bool) {
    found:=make([dynamic]Content_Field,context.temp_allocator)
    for &track in view.tracks {
        if track.property!=.Float && track.property!=.Vector {continue}
        text:=serial.text_field(track.target[:])
        node,component,path:=asset.animation_field_target(text) or_continue
        field:=Content_Field{curve=base.name_hash(text),node=base.name_hash(node) if node!="" else 0,property=track.property,slot=track.slot}
        copy(field.component[:],component);copy(field.field[:],path)
        if !slice.contains(found[:],field) {append(&found,field)}
    }
    error:runtime.Allocator_Error
    fields,error=make([]Content_Field,len(found),allocator)
    if error!=nil {return nil,false}
    copy(fields,found[:])
    return fields,true
}

// Adds the looping copy of the first `count` clips of a library.
content_animation_loops :: proc "contextless" (library:^anim.Library,count:int) {
    for i in 0..<count {library.clips[count+i]=library.clips[i];library.clips[count+i].loop=.Loop}
    library.clip_count=count*2
}

Content_Sound :: struct {
    using stamp:Content_Stamp,
    sound:audio.Sound,
    file:asset.Asset, // kept open while a stream decodes from it
    stream:bool,
}

// A .font, a font of App.ui_font from the start of the frame after it is
// loaded (app_ui_fonts_apply): no context draws then, and the font copies
// the contexts took stay whole. face is its index there from the moment it
// is loaded, for Text_Style.font.
Content_Font :: struct {
    using stamp:Content_Stamp,
    data:[]u8,  // the bytes of the font, which App.ui_font reads while it lives
    next:[]u8,  // the bytes of the file that changed, until they replace data
    face:u8,
    added:bool, // it is a font of App.ui_font
}

// A .prompts: the images of its inputs, whose textures prompts_find gives.
Content_Prompts :: struct {
    using stamp:Content_Stamp,
    images:[]asset.Prompt_Image,
}
#assert(len(ui.Prompt_Family)==asset.PROMPT_FAMILIES && len(ui.Prompt_Input)==asset.PROMPT_INPUTS && int(ui.Prompt_Input.Key)==asset.PROMPT_INPUT_KEY)

// The sounds of a set are entries of their own: what is kept is its values.
Content_Sound_Set :: struct {
    using stamp:Content_Stamp,
    info:asset.Sound_Set_Info,
    last:int, // the variation chosen last; -1: none
}

// What plays for a .sound or a .sound_set: a sound of the mixer, and the
// volume and pitch it takes over those it is played at.
Sound_Pick :: struct {
    sound:audio.Sound,
    volume,pitch:f32,
}

Content_Stats :: struct {
    loads,reloads:int,
    compressed:int, // .anim whose keys were compressed: neither cooked nor in the cache
    unloads:int, // entries content_collect unloaded
}

@(private)
Content_Ref :: struct {kind:Content_Kind,index:u32}

Content :: struct {
    allocator:runtime.Allocator,
    index:map[base.Asset_Id]Content_Ref,
    uis:[dynamic]Content_Ui,
    animations:[dynamic]Content_Animation,
    sounds:[dynamic]Content_Sound,
    sound_sets:[dynamic]Content_Sound_Set,
    rng:base.Rng,                    // of the variations of the sets
    fonts:[dynamic]Content_Font,
    prompts:[dynamic]Content_Prompts,
    retired:[dynamic]asset.Asset, // files of streams that were replaced or unloaded
    free:[Content_Kind][dynamic]u32, // entries that unloaded content left
    generations:u32,                 // of the last load
    reloaded:u32,                    // generation of the last reload
    // While a recorded frame plays again, the generations it saw (Frame_Record.content): a first
    // load a job made after it is pending.
    replay:Maybe(u32),
    fonts_waiting:bool,              // a font waits to be added to App.ui_font, or to take its new bytes
    stats:Content_Stats,
}

// The content of the application, created the first time it is asked for: it
// is freed after the mixer, which may still read the files of its streams.
// nil without assets or memory.
app_content :: proc(app:^App) -> ^Content {
    if app.content!=nil || app.assets==nil {return app.content}
    c,error:=new(Content,app.allocator)
    if error!=nil {return nil}
    c.allocator=app.allocator
    c.index=make(map[base.Asset_Id]Content_Ref,app.allocator)
    errors:[6]runtime.Allocator_Error
    c.uis,errors[0]=make([dynamic]Content_Ui,0,CONTENT_CAPACITY,app.allocator)
    c.animations,errors[1]=make([dynamic]Content_Animation,0,CONTENT_CAPACITY,app.allocator)
    c.sounds,errors[2]=make([dynamic]Content_Sound,0,CONTENT_CAPACITY,app.allocator)
    c.sound_sets,errors[3]=make([dynamic]Content_Sound_Set,0,CONTENT_CAPACITY,app.allocator)
    c.rng=base.rng_make(0x736f756e64)
    c.fonts,errors[4]=make([dynamic]Content_Font,0,ui.FONT_CAPACITY,app.allocator)
    c.prompts,errors[5]=make([dynamic]Content_Prompts,0,CONTENT_CAPACITY,app.allocator)
    c.retired=make([dynamic]asset.Asset,app.allocator)
    for &free in c.free {free=make([dynamic]u32,app.allocator)}
    failed:=reserve(&c.index,CONTENT_CAPACITY*4)!=nil
    for error in errors {failed||=error!=nil}
    if failed {
        delete(c.index);delete(c.uis);delete(c.animations);delete(c.sounds);delete(c.sound_sets);delete(c.retired)
        delete(c.fonts);delete(c.prompts)
        for free in c.free {delete(free)}
        free(c,app.allocator)
        return nil
    }
    app.content=c
    return c
}

app_content_destroy :: proc(app:^App) {
    c:=app.content
    if c==nil {return}
    for &entry in c.uis {
        if entry.id!={} {content_ui_free(c,&entry)}
    }
    for &entry in c.animations {
        if entry.id=={} {continue}
        content_animation_drop(app,&entry)
        content_animation_free(c,&entry)
    }
    for &entry in c.sounds {
        if entry.id!={} {content_sound_free(app,&entry,true)}
    }
    for &entry in c.fonts {delete(entry.data,c.allocator);delete(entry.next,c.allocator)}
    for &entry in c.prompts {delete(entry.images,c.allocator)}
    for free in c.free {delete(free)}
    for &file in c.retired {asset.asset_close(&file)}
    delete(c.retired)
    delete(c.index);delete(c.uis);delete(c.animations);delete(c.sounds);delete(c.sound_sets)
    delete(c.fonts);delete(c.prompts)
    free(c,app.allocator)
    app.content=nil
}

// Opens the file of an asset of one kind, whole and matching its hash.
@(private)
content_open :: proc(a:^Assets,id:base.Asset_Id,kind:asset.Fourcc,file:^asset.Asset,stamp:^Content_Stamp) -> bool {
    record,found:=asset.registry_find(&a.registry,id)
    if !found || record.kind!=kind {return false}
    stamp.size,stamp.time=record.size,record.time
    data,error:=asset.registry_read(&a.registry,record.path,a.allocator)
    if error!=.None || asset.asset_take(file,data,a.allocator)!=.None {return false}
    if !asset.blob_verify_hash(&file.blob) || file.blob.header.id!=id || file.blob.header.kind!=kind {
        asset.asset_close(file)
        return false
    }
    return true
}

@(private="file")
content_ui_free :: proc(c:^Content,entry:^Content_Ui) {
    if entry.tree.allocator.procedure!=nil {ui.tree_destroy(&entry.tree)}
    delete(entry.textures,c.allocator);delete(entry.widgets,c.allocator)
    entry.textures,entry.widgets=nil,nil
}
@(private)
content_animation_free :: proc(c:^Content,entry:^Content_Animation) {
    anim.library_destroy(&entry.lib)
    delete(entry.markers,c.allocator);delete(entry.names,c.allocator);delete(entry.roots,c.allocator);delete(entry.morphs,c.allocator);delete(entry.fields,c.allocator)
    entry.markers,entry.names,entry.roots,entry.morphs,entry.fields,entry.clip_count=nil,nil,nil,nil,nil,0
}
// The mixer reads the file of a stream until its audio thread lets go of the
// sound, which nothing reports: the file of a stream that is replaced stays
// open until the application ends. final: the mixer no longer exists.
@(private="file")
content_sound_free :: proc(app:^App,entry:^Content_Sound,final:=false) {
    c:=app.content
    if final || !entry.stream {
        asset.asset_close(&entry.file)
    } else {
        append(&c.retired,entry.file)
    }
    if !final && app.mixer!=nil && entry.sound!={} {audio.sound_destroy(app.mixer,entry.sound)}
    entry.file,entry.sound,entry.stream={},{},false
}

// What Quad.data is for a texture asset: its place in the texture table of
// the renderer. 0 without a renderer.
@(private="file")
content_texture :: proc(a:^Assets,id:base.Asset_Id) -> u32 {
    texture:=assets_texture_image(a,id)
    if texture==nil || a.renderer==nil {return 0}
    return render.ui_image(a.renderer,texture.handle)&~render.UI_MATERIAL_IMAGE_BIT
}

// The ui program each style names in the shaders of the renderer, by its id,
// as ui.Tree_Resources.programs takes them: 0 for none, one the shaders do
// not have, and without a renderer. Ask again after a.revision changes. A
// node gives the program its four values, the first floats of its parameters.
content_ui_programs :: proc(a:^Assets,styles:[]ui.Node_Style) -> []u32 {
    programs:=make([]u32,len(styles),context.temp_allocator)
    if a==nil || a.renderer==nil {return programs}
    for &style,i in styles {
        name:=serial.text_field(style.program[:])
        if name=="" {continue}
        if program:=render.program_find(a.renderer,name,.Ui);program!=nil {programs[i]=program.id}
    }
    return programs
}

@(private="file")
content_ui_load :: proc(app:^App,id:base.Asset_Id,entry:^Content_Ui) -> bool {
    a,c:=app.assets,app.content
    file:asset.Asset
    content_open(a,id,asset.KIND_UI,&file,entry) or_return
    defer asset.asset_close(&file)
    records,error:=ui_tree_view(&file,&a.types)
    if error!=.None {return false}
    read:=make([dynamic]Content_Stamp,context.temp_allocator)
    imports,imported:=ui_tree_imports(a,records,&read)
    if !imported {return false}
    data,linked:=ui.tree_link(records,imports)
    if !linked {return false}
    textures,allocation:=make([]base.Asset_Id,len(data.images),c.allocator)
    if allocation!=nil {return false}
    widgets,widget_allocation:=make([]Content_Stamp,len(read),c.allocator)
    if widget_allocation!=nil {
        delete(textures,c.allocator)
        return false
    }
    copy(widgets,read[:])
    indices:=make([]u32,len(data.images),context.temp_allocator)
    for image,i in data.images {
        textures[i]=image.texture
        if image.texture!={} {indices[i]=content_texture(a,image.texture)}
    }
    // A font that does not load leaves the interface without its texts.
    fonts:=make([]u8,len(data.fonts),context.temp_allocator)
    for font,i in data.fonts {
        face,loaded:=content_font(app,font.font)
        if !loaded {
            delete(textures,c.allocator);delete(widgets,c.allocator)
            return false
        }
        fonts[i]=face
    }
    tree:ui.Widget_Tree
    if !ui.tree_load(&tree,data,{textures=indices,fonts=fonts,programs=content_ui_programs(a,data.styles)},c.allocator) {
        delete(textures,c.allocator);delete(widgets,c.allocator)
        return false
    }
    content_ui_free(c,entry)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    entry.tree=tree
    entry.textures,entry.revision=textures,a.revision
    entry.widgets=widgets
    entry.low,entry.high=ui.tree_layers(&entry.tree)
    return true
}

@(private="file")
content_sound_load :: proc(app:^App,id:base.Asset_Id,entry:^Content_Sound) -> bool {
    a:=app.assets
    mixer:=app.mixer
    if mixer==nil {return false}
    file:asset.Asset
    content_open(a,id,asset.KIND_SOUND,&file,entry) or_return
    view,error:=asset.sound_view(&file,&a.types)
    if error!=.None {
        asset.asset_close(&file)
        return false
    }
    sound:audio.Sound
    failed:audio.Error
    data:=view.lossless if view.info.encoding==.Lossless else view.file
    stream:=.Stream in view.info.flags
    if stream {sound,failed=audio.sound_stream(mixer,data)} else {sound,failed=audio.sound_load(mixer,data)}
    if failed!=.None {
        asset.asset_close(&file)
        return false
    }
    content_sound_free(app,entry)
    entry.sound,entry.stream=sound,stream
    if stream {entry.file=file} else {asset.asset_close(&file)}
    return true
}

// The bytes of a .font, checked as the interfaces open them, in the
// allocator of the content.
@(private="file")
content_font_read :: proc(app:^App,id:base.Asset_Id,stamp:^Content_Stamp) -> (data:[]u8,ok:bool) {
    a,c:=app.assets,app.content
    file:asset.Asset
    content_open(a,id,asset.KIND_FONT,&file,stamp) or_return
    defer asset.asset_close(&file)
    view,error:=asset.font_view(&file,&a.types)
    if error!=.None {return}
    probe:ui.Font
    if !ui.font_init(&probe,{view.file},{16},1,context.temp_allocator,on_demand=true) {return}
    ui.font_destroy(&probe)
    allocation:runtime.Allocator_Error
    if data,allocation=make([]u8,len(view.file),c.allocator);allocation!=nil {return}
    copy(data,view.file)
    return data,true
}

@(private="file")
content_prompts_load :: proc(app:^App,id:base.Asset_Id,entry:^Content_Prompts) -> bool {
    a,c:=app.assets,app.content
    file:asset.Asset
    content_open(a,id,asset.KIND_PROMPTS,&file,entry) or_return
    defer asset.asset_close(&file)
    view,error:=asset.prompts_view(&file,&a.types)
    if error!=.None {return false}
    images,allocation:=make([]asset.Prompt_Image,len(view.images),c.allocator)
    if allocation!=nil {return false}
    copy(images,view.images)
    delete(entry.images,c.allocator)
    entry.images=images
    return true
}

@(private="file")
content_sound_set_load :: proc(app:^App,id:base.Asset_Id,entry:^Content_Sound_Set) -> bool {
    a:=app.assets
    file:asset.Asset
    content_open(a,id,asset.KIND_SOUND_SET,&file,entry) or_return
    defer asset.asset_close(&file)
    view,error:=asset.sound_set_view(&file,&a.types)
    if error!=.None {return false}
    entry.info,entry.last=view.info^,-1
    return true
}

@(private="file")
content_slot :: proc(c:^Content,list:^[dynamic]$T,id:base.Asset_Id,kind:Content_Kind) -> (entry:^T,fresh:bool) {
    if ref,known:=c.index[id];known {
        return ref.kind==kind?&list[ref.index]:nil,false
    }
    at:u32
    if len(c.free[kind])>0 {
        at=pop(&c.free[kind])
    } else if len(list)<cap(list) {
        append(list,T{})
        at=u32(len(list)-1)
    } else {
        return nil,false
    }
    c.index[id]={kind,at}
    entry=&list[at]
    entry^={}
    entry.id=id
    return entry,true
}

@(private)
content_loaded :: proc(c:^Content,stamp:^Content_Stamp,ok:bool) {
    stamp.failed=!ok
    c.generations+=1
    stamp.generation=c.generations
    if ok {c.stats.loads+=1}
}

// What loaded again replaces what loaded before.
@(private)
content_reloaded :: proc(c:^Content,stamp:^Content_Stamp) {
    stamp.failed=false
    c.generations+=1
    stamp.generation=c.generations
    c.reloaded=c.generations
    c.stats.reloads+=1
}

// The content generation the frame or the tick under way sees: the one it recorded when it plays
// again, else that of the last load. A frame or tick that plays again with it
// (Frame_Record.content, app_tick_replay) finds pending a first load a job made after.
content_generation :: proc "contextless" (app:^App) -> u32 {
    if app.content==nil {return 0}
    return app.content.replay.? or_else app.content.generations
}

// Whether content loaded again after a frame that saw generation (Frame_Record.content): what
// that frame read is no longer what plays.
content_reloaded_after :: proc "contextless" (app:^App,generation:u32) -> bool {
    return app.content!=nil && app.content.reloaded>generation
}

// The interface of a .ui, loaded the first time, with its images already
// pointing at the textures of the renderer. nil for the zero id, an asset
// that is not a .ui or cannot be loaded, and when no room is left.
content_ui :: proc(app:^App,id:base.Asset_Id) -> ^Content_Ui {
    c:=app_content(app)
    if c==nil || id=={} {return nil}
    entry,fresh:=content_slot(c,&c.uis,id,.Ui)
    if entry==nil {return nil}
    if fresh {
        scope:=load_asset_begin(&app.load_profile)
        content_loaded(c,entry,content_ui_load(app,id,entry))
        load_asset_end(&app.load_profile,scope,id,.Interface,entry.size,entry.failed)
    }
    if entry.failed {return nil}
    if a:=app.assets;entry.revision!=a.revision {
        // Textures or shaders were loaded again: a texture may sit elsewhere in
        // the table, a program have another id or none.
        indices:=make([]u32,len(entry.textures),context.temp_allocator)
        for texture,i in entry.textures {
            if texture!={} {indices[i]=content_texture(a,texture)}
        }
        ui.tree_textures_set(&entry.tree,indices)
        ui.tree_programs_set(&entry.tree,content_ui_programs(a,entry.tree.styles[:entry.tree.style_count]))
        entry.revision=a.revision
    }
    return entry
}

// The clips of an .anim, loaded the first time. nil for the zero id, an asset that is not an
// .anim or cannot be loaded, when no room is left, and while its first load compresses
// (content_animation_pending), which is not a failure. A load a job ended is taken at the start
// of the next frame (app_content_adopt), never here.
content_animation :: proc(app:^App,id:base.Asset_Id) -> ^Content_Animation {
    c:=app_content(app)
    if c==nil || id=={} {return nil}
    entry,fresh:=content_slot(c,&c.animations,id,.Animation)
    if entry==nil {return nil}
    if fresh && !content_animation_start(app,entry) {content_loaded(c,entry,false)}
    if entry.failed || entry.generation==0 || content_animation_replay_pending(c,entry) {return nil}
    return entry
}

// The sound of a .sound in the mixer of the application. Zero when it cannot
// be loaded or the application has no mixer.
content_sound :: proc(app:^App,id:base.Asset_Id) -> audio.Sound {
    c:=app_content(app)
    if c==nil || id=={} {return {}}
    entry,fresh:=content_slot(c,&c.sounds,id,.Sound)
    if entry==nil {return {}}
    if fresh {
        scope:=load_asset_begin(&app.load_profile)
        content_loaded(c,entry,content_sound_load(app,id,entry))
        load_asset_end(&app.load_profile,scope,id,.Sound,entry.size,entry.failed)
    }
    return entry.failed?{}:entry.sound
}

// The index in App.ui_font of the font of a .font, for Text_Style.font,
// loaded the first time. It is a font of App.ui_font from the start of the
// next frame of the application (app_ui_fonts_apply), and stays one while
// the application lives: its bytes are kept. ok is false for the zero id, an
// asset that is not a font FreeType opens, and when App.ui_font is full.
content_font :: proc(app:^App,id:base.Asset_Id) -> (face:u8,ok:bool) {
    c:=app_content(app)
    if c==nil || id=={} {return}
    entry,fresh:=content_slot(c,&c.fonts,id,.Font)
    if entry==nil {return}
    if fresh {
        scope:=load_asset_begin(&app.load_profile)
        data,read:=content_font_read(app,id,entry)
        content_loaded(c,entry,read && content_font_take(app,entry,data))
        c.fonts_waiting||=!entry.failed
        load_asset_end(&app.load_profile,scope,id,.Interface,entry.size,entry.failed)
    }
    return entry.face,!entry.failed
}

// Gives a font the bytes that were read and the next face of App.ui_font:
// fonts are added in the order of their faces. False, freeing the bytes,
// when the font is full.
@(private="file")
content_font_take :: proc(app:^App,entry:^Content_Font,data:[]u8) -> bool {
    c:=app.content
    next:=app.ui_font.font_count if app.ui_font.ready else CONTENT_UI_FONTS
    for &other in c.fonts {if other.id!={} && &other!=entry && !other.failed && !other.added {next+=1}}
    if next>=ui.FONT_CAPACITY {
        delete(data,c.allocator)
        return false
    }
    entry.data,entry.face=data,u8(next)
    return true
}

// Adds the fonts that were loaded to App.ui_font and gives those whose files
// changed their new bytes. At the start of the frame of the application
// (app_frame_begin), before any context begins its own: they move the tables
// of the font the contexts copy. Without a renderer, App.ui_font does not
// exist and the fonts wait.
app_ui_fonts_apply :: proc(app:^App) {
    c:=app.content
    if c==nil || !c.fonts_waiting || !app_ui_font_ready(app) {return}
    font:=&app.ui_font
    for added:=true;added; {
        added=false
        for &entry in c.fonts {
            if entry.id=={} || entry.failed || entry.added || int(entry.face)!=font.font_count {continue}
            face,ok:=ui.font_add(font,entry.data)
            // Tried again at the next frame, keeping the order of the faces.
            if !ok || face!=entry.face {return}
            entry.added,added=true,true
        }
    }
    for &entry in c.fonts {
        if entry.next==nil {continue}
        if entry.added && !ui.font_replace(font,int(entry.face),entry.next) {continue}
        delete(entry.data,c.allocator)
        entry.data,entry.next=entry.next,nil
    }
    c.fonts_waiting=false
    for &entry in c.fonts {c.fonts_waiting||=entry.id!={} && !entry.failed && !entry.added || entry.next!=nil}
}

// The pack of prompts of a .prompts, by its id, loaded the first time. nil for
// the zero id, an asset that is not a .prompts or cannot be loaded, and when
// no room is left.
content_prompts :: proc(app:^App,id:base.Asset_Id) -> ^Content_Prompts {
    c:=app_content(app)
    if c==nil || id=={} {return nil}
    entry,fresh:=content_slot(c,&c.prompts,id,.Prompts)
    if entry==nil {return nil}
    if fresh {
        scope:=load_asset_begin(&app.load_profile)
        content_loaded(c,entry,content_prompts_load(app,id,entry))
        load_asset_end(&app.load_profile,scope,id,.Interface,entry.size,entry.failed)
    }
    return entry.failed?nil:entry
}

// The prompt of an input as a pack shows it: the part of its texture as an
// image of the renderer (Quad.data is 0 without one), with the aspect of
// that part. Keys and the mouse are of the family Keyboard whatever family
// is asked for; key names the core.Key of the input Key.
prompts_find :: proc(p:^Content_Prompts,a:^Assets,family:ui.Prompt_Family,input:ui.Prompt_Input,key:string) -> (prompt:ui.Prompt,found:bool) {
    if p==nil {return}
    family:=family if input>ui.Prompt_Input.Mouse_Wheel else .Keyboard
    for &image in p.images {
        if image.family!=u8(family) || image.input!=u8(input) || input==.Key && base.text_get(image.key[:])!=key {continue}
        uv:=image.uv
        return {family=family,input=input,text=key,quad={.Image,content_texture(a,image.texture),{uv.x,uv.y,uv.w,uv.h}},aspect=image.aspect},true
    }
    return
}

// The set of a .sound_set; nil for an asset of another kind.
@(private="file")
content_sound_set :: proc(app:^App,id:base.Asset_Id) -> ^Content_Sound_Set {
    c:=app_content(app)
    if c==nil || id=={} {return nil}
    if record,found:=asset.registry_find(&app.assets.registry,id);!found || record.kind!=asset.KIND_SOUND_SET {return nil}
    entry,fresh:=content_slot(c,&c.sound_sets,id,.Sound_Set)
    if entry==nil {return nil}
    if fresh {
        scope:=load_asset_begin(&app.load_profile)
        content_loaded(c,entry,content_sound_set_load(app,id,entry))
        load_asset_end(&app.load_profile,scope,id,.Interface,entry.size,entry.failed)
    }
    return entry.failed?nil:entry
}

// What plays for a .sound, at its volume and pitch, or for a .sound_set: one
// of its sounds by their weights, not the last one when it says no_repeat,
// with a volume and a pitch from its ranges. A sound of the set that does not
// load is left out. Zero when nothing of it can play.
content_sound_pick :: proc(app:^App,id:base.Asset_Id) -> Sound_Pick {
    set:=content_sound_set(app,id)
    if set==nil {
        if sound:=content_sound(app,id);sound!={} {return {sound,1,1}}
        return {}
    }
    c:=app.content
    sounds:[asset.SOUND_SET_CAPACITY]audio.Sound
    weights:[asset.SOUND_SET_CAPACITY]f32
    total:=f32(0)
    others:=false
    for variation,i in set.info.sounds {
        if variation.sound=={} {continue}
        sounds[i]=content_sound(app,variation.sound)
        if sounds[i]=={} {continue}
        weights[i]=variation.weight>0?variation.weight:1
        if i!=set.last {others=true}
    }
    if set.info.no_repeat && others && set.last>=0 {weights[set.last]=0}
    for weight in weights {total+=weight}
    if total<=0 {return {}}
    at:=mm.random_f32(&c.rng)*total
    chosen:=-1
    for weight,i in weights {
        if weight<=0 {continue}
        chosen=i
        if at<weight {break}
        at-=weight
    }
    set.last=chosen
    info:=&set.info
    return {sounds[chosen],mm.random_range(&c.rng,info.volume_min,info.volume_max),mm.random_range(&c.rng,info.pitch_min,info.pitch_max)}
}

// The generation of what content_sound_pick plays for a .sound or a
// .sound_set: another one once its file was loaded again. 0 when it does not load.
content_sound_generation :: proc(app:^App,id:base.Asset_Id) -> u32 {
    if set:=content_sound_set(app,id);set!=nil {return set.generation}
    c:=app.content
    if content_sound(app,id)=={} {return 0}
    ref:=c.index[id]
    return c.sounds[ref.index].generation
}

// Loads again what is loaded and whose file changed since: called after the
// registry looked at the folder. An asset that no longer loads keeps what it
// had. A font that changed takes its new bytes at the start of the next
// frame (app_ui_fonts_apply). Returns how many were replaced.
content_refresh :: proc(app:^App) -> (reloaded:int) {
    c:=app.content
    if c==nil {return}
    registry:=&app.assets.registry
    changed :: proc(registry:^asset.Registry,stamp:^Content_Stamp) -> bool {
        record,found:=asset.registry_find(registry,stamp.id)
        return found && (record.size!=stamp.size || record.time!=stamp.time)
    }
    done :: proc(c:^Content,stamp:^Content_Stamp,ok:bool,reloaded:^int) {
        if !ok {return}
        content_reloaded(c,stamp)
        reloaded^+=1
    }
    for &entry in c.fonts {
        if entry.id=={} || !changed(registry,&entry) {continue}
        data,read:=content_font_read(app,entry.id,&entry)
        if !read {continue}
        // One that failed takes a face now.
        if entry.failed {read=content_font_take(app,&entry,data)} else {delete(entry.next,c.allocator);entry.next=data}
        done(c,&entry,read,&reloaded)
        c.fonts_waiting||=read
    }
    for &entry in c.prompts {
        if entry.id!={} && changed(registry,&entry) {done(c,&entry,content_prompts_load(app,entry.id,&entry),&reloaded)}
    }
    for &entry in c.uis {
        if entry.id=={} {continue}
        stale:=changed(registry,&entry)
        for &widget in entry.widgets {stale|=changed(registry,&widget)}
        if stale {done(c,&entry,content_ui_load(app,entry.id,&entry),&reloaded)}
    }
    for &entry in c.animations {
        if entry.id=={} || !changed(registry,&entry) {continue}
        content_animation_drop(app,&entry)
        generation:=entry.generation
        if !content_animation_start(app,&entry) {
            if generation==0 {content_loaded(c,&entry,false)}
        } else if generation!=0 && entry.generation!=generation {reloaded+=1}
    }
    for &entry in c.sounds {
        if entry.id!={} && changed(registry,&entry) {done(c,&entry,content_sound_load(app,entry.id,&entry),&reloaded)}
    }
    for &entry in c.sound_sets {
        if entry.id!={} && changed(registry,&entry) {done(c,&entry,content_sound_set_load(app,entry.id,&entry),&reloaded)}
    }
    return
}

// Unloads the interfaces, animations, sounds, sets and prompts that no
// scope of the assets reaches (assets_scope_set): their memory is freed, a
// sound leaves the mixer, and their entries are there for the next ones.
// Fonts stay, as App.ui_font keeps them. Asking for one again
// loads it, with another generation. The file of a stream stays open until
// the application ends, as when it is replaced. Returns how many it unloaded.
content_collect :: proc(app:^App) -> (unloaded:int) {
    c:=app.content
    if c==nil || app.assets==nil {return}
    keep:=assets_reached(app.assets,context.temp_allocator)
    gone:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for id,ref in c.index {
        if !keep[id] && ref.kind!=.Font {append(&gone,id)}
    }
    for id in gone {
        ref:=c.index[id]
        switch ref.kind {
        case .Ui:
            content_ui_free(c,&c.uis[ref.index])
            c.uis[ref.index]={}
        case .Animation:
            content_animation_drop(app,&c.animations[ref.index])
            content_animation_free(c,&c.animations[ref.index])
            c.animations[ref.index]={}
        case .Sound:
            content_sound_free(app,&c.sounds[ref.index])
            c.sounds[ref.index]={}
        case .Sound_Set:
            c.sound_sets[ref.index]={}
        case .Prompts:
            delete(c.prompts[ref.index].images,c.allocator)
            c.prompts[ref.index]={}
        case .Font:
        }
        append(&c.free[ref.kind],ref.index)
        delete_key(&c.index,id)
    }
    c.stats.unloads+=len(gone)
    return len(gone)
}

// The folders of assets of the active plugins of a project, as the registry
// mounts them: under plugins/<name>, the path they have in a shipped game.
project_asset_mounts :: proc(p:^project.Project,allocator:=context.allocator) -> []asset.Registry_Mount {
    mounts:=make([dynamic]asset.Registry_Mount,allocator)
    for folder in project.asset_folders(p,allocator) {
        if folder.prefix!="" {append(&mounts,asset.Registry_Mount{folder=folder.path,prefix=folder.prefix})}
    }
    return mounts[:]
}
