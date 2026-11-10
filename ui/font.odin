package ui

import "base:runtime"
import "core:c"
import "core:math"
import "core:mem"
import "core:slice"
import "base:intrinsics"
import ft "mirai:third_party/freetype"

// One coverage atlas (R8) rasterized with FreeType. Sizes are em in layout
// units, as CSS font sizes are in pixels. Every face, a font at a size, is
// rasterized at its exact fractional size in device pixels, so glyphs map 1:1
// to the screen at any display density; other sizes scale the nearest face.
// The auto-hinter in its light mode aligns heights to the pixel grid, leaves
// widths and spacing as designed and darkens stems at small sizes. Small
// faces keep each glyph at several horizontal subpixel phases. Advances and
// kerning are those of the font, in em, and do not depend on the density.
// Measuring and emitting glyphs never allocate.
//
// A font is rasterized whole at each density, or on demand: the contexts
// that borrow it (Context_Desc.font) only read it. A glyph they draw before
// it is in the atlas is asked for in wanted; its owner rasterizes it with
// font_update, in that same frame when the context calls it (font_ask), or
// before the next one.

// Inter 4.1 (SIL OFL, assets/fonts): the fonts of the editor on every platform.
FONT_INTER          :: #load("../assets/fonts/Inter-Regular.ttf")
FONT_INTER_MEDIUM   :: #load("../assets/fonts/Inter-Medium.ttf")
FONT_INTER_SEMIBOLD :: #load("../assets/fonts/Inter-SemiBold.ttf")
// JetBrains Mono 2.304 (SIL OFL, assets/fonts): code.
FONT_JETBRAINS_MONO :: #load("../assets/fonts/JetBrainsMono-Regular.ttf")
// The fonts of a context created without fonts of its own, by index.
FONT_REGULAR  :: 0
FONT_MEDIUM   :: 1
FONT_SEMIBOLD :: 2
FONT_MONO     :: 3
FONT_DEFAULTS :: 4 // how many

// The characters of the atlas: runs of code points, each with its glyphs
// from index on, and the symbols of FONT_EXTRA. Latin glyphs are their code
// point. The rest are drawn as '?'.
Font_Range :: struct {first,last:rune,index:int}
FONT_RANGES :: [?]Font_Range{
    {0x0000,0x017f,0},                                // Basic Latin, Latin-1 Supplement, Latin Extended-A
    {0x0370,0x04ff,FONT_EXTRA_INDEX+len(FONT_EXTRA)}, // Greek and Coptic, Cyrillic
}
FONT_EXTRA :: [?]rune{'•','…','–','—','‘','’','“','”','←','↑','→','↓','⌘','⇧','⌥','�','◇','☼'}
FONT_EXTRA_INDEX :: 0x180
FONT_GLYPHS :: FONT_EXTRA_INDEX+len(FONT_EXTRA)+0x500-0x370
FONT_ATLAS_WIDTH :: 2048
FONT_FACES_ASKED :: 8 // faces the contexts ask a font on demand for between two of its font_faces_add
FONT_FACES_MAX :: 96  // faces of a font on demand, with those asked for; other sizes scale the nearest face
FONT_DENSITY_MIN :: f32(0.5)
FONT_DENSITY_MAX :: f32(4)

// The faces of the editor, in CSS pixels: the sizes of THEME_EDITOR and those
// a step around them.
Face_Desc :: struct {font:u8,size:i32}
FONT_FACES_EDITOR :: [?]Face_Desc{
    {FONT_REGULAR,9},{FONT_REGULAR,10},{FONT_REGULAR,11},{FONT_REGULAR,12},{FONT_REGULAR,13},
    {FONT_REGULAR,14},{FONT_REGULAR,15},{FONT_REGULAR,16},{FONT_REGULAR,17},{FONT_REGULAR,20},
    {FONT_MEDIUM,11},{FONT_MEDIUM,12},{FONT_MEDIUM,13},
    {FONT_SEMIBOLD,11},{FONT_SEMIBOLD,12},{FONT_SEMIBOLD,13},{FONT_SEMIBOLD,15},{FONT_SEMIBOLD,17},
    {FONT_MONO,11},{FONT_MONO,12},{FONT_MONO,13},
}

// Faces up to this many device pixels per em keep four horizontal phases of
// the glyphs of ASCII and of FONT_EXTRA, and up to FONT_PHASED_2 two: the
// pen lands within 1/8 and 1/4 of a pixel of where the layout puts it. The
// rest of the glyphs snap to whole pixels.
FONT_PHASED_4 :: f32(20)
FONT_PHASED_2 :: f32(32)

Glyph :: struct {
    bounds:Rect, // device pixels relative to the pen on the baseline, one texel of border included
    uv:Rect,     // of the first phase; phase k starts k widths to the right
    phases:f32,  // horizontal positions within a pixel it is rasterized at; 0 until it is
}
Face :: struct {
    font:u8,
    phases:u8,      // of the glyphs that have phases
    size:i32,       // em, in layout units
    pixel_size:f32, // em in device pixels
    glyphs:[FONT_GLYPHS]Glyph,
}
Font_Metrics :: struct {
    advances:[FONT_GLYPHS]f32, // em
    available:[FONT_GLYPHS]bool,
    ascent:f32,                // em from the top of a line to its baseline
    unit:f32,                  // em per font unit
    kerning:Kerning,
    faces:[2]int,              // first face of the font in Font.faces and how many it has
}
Font :: struct {
    data:[FONT_CAPACITY][]byte, // borrowed: must outlive the font (font_add, font_replace)
    font_count:int,
    metrics:[]Font_Metrics,     // one per font
    faces:[]Face,
    // Glyphs drawn before they were rasterized, a bit per face*FONT_GLYPHS+glyph:
    // what the contexts that borrow the font ask its owner for.
    wanted:[]u64,
    // Sizes text was drawn at that no face is close to: the faces the contexts
    // ask its owner for (font_faces_add). size 0 is a free entry.
    asked:[]Face_Desc,
    density:f32,                // device pixels per layout unit the faces are rasterized for
    pixels:[]u8,
    width,height:int,
    shelf:[3]int,               // x and y where the shelf glyphs are packed on goes on, and its height
    dirty:[4]int,               // texels that changed since its owner uploaded them: x0, y0, x1, y1
    revision:u32,               // changes when the atlas has to be uploaded again
    ready:bool,
    on_demand:bool,             // glyphs are rasterized as they are asked for, not all at each density
    session:^Font_Session,      // FreeType with the fonts open, while the font is on demand
    allocator:runtime.Allocator,
}

// Rows an atlas on demand has room for at density 1, by the square of the
// density: those of the faces of the editor in a frame, code in one face of
// FONT_MONO included. It grows by doubling, between frames.
FONT_ROWS_START :: 288

// fonts: TrueType or OpenType files; Inter Regular, Medium and SemiBold and
// JetBrains Mono when empty.
// sizes: em sizes every font gets a face of; when empty and fonts too, the
// faces of the editor (FONT_FACES_EDITOR), otherwise 9 to 18. on_demand:
// rasterizes nothing until glyphs are asked for (font_update).
font_init :: proc(font:^Font,fonts:[][]byte,sizes:[]i32,density:f32,allocator:=context.allocator,on_demand:=false) -> bool {
    font^={allocator=allocator,width=FONT_ATLAS_WIDTH}
    if len(fonts)>FONT_CAPACITY {return false}
    if len(fonts)==0 {
        font.data[FONT_REGULAR],font.data[FONT_MEDIUM],font.data[FONT_SEMIBOLD]=FONT_INTER,FONT_INTER_MEDIUM,FONT_INTER_SEMIBOLD
        font.data[FONT_MONO]=FONT_JETBRAINS_MONO
        font.font_count=FONT_DEFAULTS
    } else {
        for data,i in fonts {font.data[i]=data}
        font.font_count=len(fonts)
    }
    error:runtime.Allocator_Error
    if font.metrics,error=make([]Font_Metrics,font.font_count,allocator);error!=nil {return false}
    editor:=FONT_FACES_EDITOR
    fallback:=[?]i32{9,10,11,12,13,14,15,16,17,18}
    chosen:=sizes if len(sizes)>0 else fallback[:]
    count:=len(editor) if len(sizes)==0 && len(fonts)==0 else font.font_count*len(chosen)
    if font.faces,error=make([]Face,count,allocator);error!=nil {font_destroy(font);return false}
    for &face,i in font.faces {
        if len(sizes)==0 && len(fonts)==0 {face.font,face.size=editor[i].font,editor[i].size} else {
            face.font,face.size=u8(i/len(chosen)),chosen[i%len(chosen)]
        }
        // The faces of a font are together.
        m:=&font.metrics[face.font]
        if m.faces[1]==0 {m.faces[0]=i}
        m.faces[1]+=1
    }
    if font.wanted,error=make([]u64,(count*FONT_GLYPHS+63)/64,allocator);error!=nil {font_destroy(font);return false}
    if on_demand {
        if font.asked,error=make([]Face_Desc,FONT_FACES_ASKED,allocator);error!=nil {font_destroy(font);return false}
    }
    if !font_load(font) {font_destroy(font);return false}
    if !on_demand {
        if !font_rebuild(font,density) {font_destroy(font);return false}
        return true
    }
    font.on_demand=true
    if font.session,error=new(Font_Session,allocator);error!=nil || !font_session_open(font.session,font) {font_destroy(font);return false}
    font.ready=true
    if !font_set_density(font,density) {font_destroy(font);return false}
    return true
}

font_destroy :: proc(font:^Font) {
    if font.session!=nil {font_session_close(font.session);free(font.session,font.allocator)}
    for &m in font.metrics {delete(m.kerning.values,font.allocator)}
    delete(font.pixels,font.allocator);delete(font.wanted,font.allocator);delete(font.asked,font.allocator)
    delete(font.faces,font.allocator);delete(font.metrics,font.allocator)
    font^={}
}

// Asks the owner of a font on demand for a face of font f at pixels device
// pixels per em: what draw_text does when no face is close to a size. Sizes
// are whole em at the density of the font.
font_face_ask :: proc "contextless" (font:^Font,f:int,pixels:f32) {
    if !font.on_demand || f<0 || f>=len(font.metrics) || font.metrics[f].faces[1]>=FONT_FACES_MAX {return}
    size:=i32(math.round(pixels/max(font.density,FONT_DENSITY_MIN)))
    if size<4 || size>512 {return}
    for face in font.faces {if int(face.font)==f && face.size==size {return}}
    free:=-1
    for ask,i in font.asked {
        if ask.size==size && int(ask.font)==f {return}
        if ask.size==0 && free<0 {free=i}
    }
    if free>=0 {font.asked[free]={u8(f),size}}
}

// Gives a font on demand the faces its contexts asked for, each beside the
// other faces of its font: their glyphs are rasterized as they are asked for.
// The same transaction as font_add, between frames: faces move, and wanted
// follows them. False when memory runs out; the font is left as it was.
font_faces_add :: proc(font:^Font) -> bool {
    if !font.ready || !font.on_demand {return true}
    added:=0
    for ask in font.asked {added+=int(ask.size!=0)}
    if added==0 {return true}
    count:=len(font.faces)+added
    faces,face_error:=make([]Face,count,font.allocator)
    wanted,wanted_error:=make([]u64,(count*FONT_GLYPHS+63)/64,font.allocator)
    moved,moved_error:=make([]int,len(font.faces),context.temp_allocator)
    if face_error!=nil || wanted_error!=nil || moved_error!=nil {
        delete(faces,font.allocator);delete(wanted,font.allocator)
        return false
    }
    at:=0
    for f in 0..<font.font_count {
        m:=&font.metrics[f]
        first:=at
        for i in m.faces[0]..<m.faces[0]+m.faces[1] {
            faces[at]=font.faces[i]
            moved[i]=at
            at+=1
        }
        for &ask in font.asked {
            if ask.size==0 || int(ask.font)!=f {continue}
            faces[at]={font=u8(f),size=ask.size}
            font_faces_reset(faces[at:at+1],font.density)
            at+=1
            ask={}
        }
        m.faces={first,at-first}
    }
    for &word,w in font.wanted {
        for word!=0 {
            bit:=w*64+int(intrinsics.count_trailing_zeros(word))
            to:=moved[bit/FONT_GLYPHS]*FONT_GLYPHS+bit%FONT_GLYPHS
            wanted[to>>6]|=1<<u64(to&63)
            word&=word-1
        }
    }
    delete(font.faces,font.allocator);delete(font.wanted,font.allocator)
    font.faces,font.wanted=faces[:at],wanted
    if font.session!=nil {font.session.sized=-1}
    font.revision+=1
    return true
}

// FreeType allocates through the allocator of the font: each block keeps its
// size in front of it, as an allocator may need it to free.
@(private="file")
FONT_BLOCK_HEADER :: 16
@(private="file")
font_memory_alloc :: proc "c" (memory:^ft.Memory_Rec,size:c.long) -> rawptr {
    context=runtime.default_context()
    block,error:=mem.alloc_bytes_non_zeroed(int(size)+FONT_BLOCK_HEADER,FONT_BLOCK_HEADER,(^runtime.Allocator)(memory.user)^)
    if error!=nil {return nil}
    (^int)(raw_data(block))^=int(size)
    return &block[FONT_BLOCK_HEADER]
}
@(private="file")
font_memory_free :: proc "c" (memory:^ft.Memory_Rec,block:rawptr) {
    if block==nil {return}
    context=runtime.default_context()
    start:=rawptr(uintptr(block)-FONT_BLOCK_HEADER)
    mem.free_with_size(start,(^int)(start)^+FONT_BLOCK_HEADER,(^runtime.Allocator)(memory.user)^)
}
@(private="file")
font_memory_realloc :: proc "c" (memory:^ft.Memory_Rec,cur_size,new_size:c.long,block:rawptr) -> rawptr {
    if block==nil {return font_memory_alloc(memory,new_size)}
    context=runtime.default_context()
    start:=rawptr(uintptr(block)-FONT_BLOCK_HEADER)
    resized,error:=mem.resize_non_zeroed(start,(^int)(start)^+FONT_BLOCK_HEADER,int(new_size)+FONT_BLOCK_HEADER,FONT_BLOCK_HEADER,(^runtime.Allocator)(memory.user)^)
    if error!=nil {return nil}
    (^int)(resized)^=int(new_size)
    return rawptr(uintptr(resized)+FONT_BLOCK_HEADER)
}

// A FreeType library with the fonts open: for one rebuild, or for the life
// of a font on demand. Its address must not change while it is open.
@(private)
Font_Session :: struct {
    allocator:runtime.Allocator,
    memory:ft.Memory_Rec,
    library:ft.Library,
    faces:[FONT_CAPACITY]^ft.Face,
    sized:int,     // face of the font whose size FreeType has, -1 for none
    wide:[]u8,     // the rows of a glyph rasterized at its phases times its width
}
// faces: opens the fonts of font too.
@(private="file")
font_session_open :: proc(s:^Font_Session,font:^Font,faces:=true) -> bool {
    s.allocator=font.allocator
    s.sized=-1
    s.memory={user=&s.allocator,alloc=font_memory_alloc,free=font_memory_free,realloc=font_memory_realloc}
    if ft.new_library(&s.memory,&s.library)!=0 {s.library=nil;return false}
    ft.add_default_modules(s.library)
    darken:=b8(false)
    _=ft.property_set(s.library,"autofitter","no-stem-darkening",&darken)
    _=ft.property_set(s.library,"cff","no-stem-darkening",&darken)
    if !faces {return true}
    for f in 0..<font.font_count {
        s.faces[f]=font_session_face(s,font.data[f])
        if s.faces[f]==nil {return false}
    }
    return true
}
// A font of the session from its bytes; nil for bytes FreeType does not read
// as a scalable font.
@(private="file")
font_session_face :: proc(s:^Font_Session,data:[]byte) -> ^ft.Face {
    face:^ft.Face
    if len(data)==0 || ft.new_memory_face(s.library,raw_data(data),c.long(len(data)),0,&face)!=0 {return nil}
    if face.face_flags&ft.FACE_FLAG_SCALABLE==0 || face.units_per_em==0 {
        ft.done_face(face)
        return nil
    }
    // As ttfautohint hints Inter by default, and as browsers draw it.
    increase:=ft.Prop_Increase_X_Height{face=face,limit=14}
    _=ft.property_set(s.library,"autofitter","increase-x-height",&increase)
    return face
}
@(private="file")
font_session_close :: proc(s:^Font_Session) {
    if s.library!=nil {ft.done_library(s.library)}
    delete(s.wide,s.allocator)
    s^={}
}

// The character of a glyph of the atlas; 0 for none.
@(private="file")
font_character :: proc "contextless" (index:int) -> rune {
    for r in FONT_RANGES {
        if index>=r.index && index<=r.index+int(r.last-r.first) {return r.first+rune(index-r.index)}
    }
    extras:=FONT_EXTRA
    return extras[index-FONT_EXTRA_INDEX] if index>=FONT_EXTRA_INDEX && index<FONT_EXTRA_INDEX+len(extras) else 0
}

// Reads what does not depend on the density: which glyphs each font has,
// their advances, the ascent and the kerning.
@(private="file")
font_load :: proc(font:^Font) -> bool {
    s:Font_Session
    defer font_session_close(&s)
    if !font_session_open(&s,font) {return false}
    for f in 0..<font.font_count {font_metrics_read(&font.metrics[f],s.faces[f],font.data[f],font.allocator)}
    return true
}
// What font_load reads of one font; its faces stay.
@(private="file")
font_metrics_read :: proc(m:^Font_Metrics,face:^ft.Face,data:[]byte,allocator:runtime.Allocator) {
    m.unit=1/f32(face.units_per_em)
    m.ascent=f32(face.ascender)*m.unit
    m.available,m.advances={},{}
    glyphs:[FONT_GLYPHS]u16
    for index in 32..<FONT_GLYPHS {
        character:=font_character(index)
        if character==0 || character>=127 && character<160 {continue}
        glyph:=ft.get_char_index(face,c.ulong(character))
        if glyph==0 && character!=' ' {continue}
        advance:ft.Fixed
        if ft.get_advance(face,glyph,ft.LOAD_NO_SCALE,&advance)!=0 {continue}
        glyphs[index]=u16(glyph);m.available[index]=true;m.advances[index]=f32(advance)*m.unit
    }
    font_kerning_read(&m.kerning,data,glyphs[:],allocator)
}

// Adds a font from its TrueType or OpenType bytes, which must outlive the
// font, with a face at each size the font has. A font on demand opens it and
// rasterizes its glyphs as they are asked for; any other is rasterized again
// whole. Faces, glyphs and wanted bits keep their indices. A transaction,
// between the frames of the contexts that borrow the font: its tables move,
// and they copy them at frame_begin. index: of the font, for Text_Style.font.
font_add :: proc(font:^Font,data:[]byte) -> (index:u8,ok:bool) {
    if !font.ready || font.font_count>=FONT_CAPACITY || len(font.faces)==0 {return}
    f:=font.font_count
    sizes:=make([dynamic]i32,context.temp_allocator)
    for face in font.faces {if !slice.contains(sizes[:],face.size) {append(&sizes,face.size)}}
    count:=len(font.faces)+len(sizes)
    metrics,error:=make([]Font_Metrics,f+1,font.allocator)
    faces,face_error:=make([]Face,count,font.allocator)
    wanted,wanted_error:=make([]u64,(count*FONT_GLYPHS+63)/64,font.allocator)
    previous:=font^
    defer if !ok {
        if metrics!=nil {delete(metrics[f].kerning.values,font.allocator)}
        delete(metrics,font.allocator);delete(faces,font.allocator);delete(wanted,font.allocator)
        font^=previous
    }
    if error!=nil || face_error!=nil || wanted_error!=nil {return}
    copy(metrics,font.metrics);copy(faces,font.faces);copy(wanted,font.wanted)
    for size,i in sizes {faces[len(font.faces)+i]={font=u8(f),size=size}}
    font_faces_reset(faces[len(font.faces):],font.density)
    metrics[f].faces={len(font.faces),len(sizes)}
    opened:^ft.Face
    if !font_open_one(font,data,&metrics[f],&opened if font.on_demand else nil) {return}
    font.data[f]=data
    font.metrics,font.faces,font.wanted,font.font_count=metrics,faces,wanted,f+1
    if font.on_demand {
        font.session.faces[f]=opened
    } else if !font_rebuild(font,font.density) {
        return
    }
    delete(previous.metrics,font.allocator);delete(previous.faces,font.allocator);delete(previous.wanted,font.allocator)
    return u8(f),true
}

// Gives font index the bytes of another file, as when its file changes: on
// demand its glyphs are asked for again, otherwise the font is rasterized
// again whole. The same transaction as font_add; data must outlive the font
// and the previous bytes are no longer read.
font_replace :: proc(font:^Font,index:int,data:[]byte) -> bool {
    if !font.ready || index<0 || index>=font.font_count {return false}
    m:=Font_Metrics{faces=font.metrics[index].faces}
    opened:^ft.Face
    if !font_open_one(font,data,&m,&opened if font.on_demand else nil) {return false}
    previous:=font.metrics[index]
    previous_data:=font.data[index]
    font.metrics[index]=m
    font.data[index]=data
    if font.on_demand {
        ft.done_face(font.session.faces[index])
        font.session.faces[index]=opened
        font_flush(font,font.density)
    } else if !font_rebuild(font,font.density) {
        delete(m.kerning.values,font.allocator)
        font.metrics[index]=previous
        font.data[index]=previous_data
        return false
    }
    delete(previous.kerning.values,font.allocator)
    return true
}

// Reads the metrics of a font from its bytes. opened: where the face stays
// open in the session of a font on demand; nil reads it in a session of its own.
@(private="file")
font_open_one :: proc(font:^Font,data:[]byte,m:^Font_Metrics,opened:^^ft.Face) -> bool {
    if opened!=nil {
        face:=font_session_face(font.session,data)
        if face==nil {return false}
        font_metrics_read(m,face,data,font.allocator)
        opened^=face
        return true
    }
    s:Font_Session
    defer font_session_close(&s)
    if !font_session_open(&s,font,faces=false) {return false}
    face:=font_session_face(&s,data)
    if face==nil {return false}
    font_metrics_read(m,face,data,font.allocator)
    return true
}

// Horizontal phases of a face of pixels device pixels per em.
font_phases :: proc "contextless" (pixels:f32) -> u8 {
    return 4 if pixels<=FONT_PHASED_4 else 2 if pixels<=FONT_PHASED_2 else 1
}

@(private="file")
font_faces_reset :: proc(faces:[]Face,density:f32) {
    for &face in faces {
        face.pixel_size=f32(face.size)*density
        face.phases=font_phases(face.pixel_size)
        face.glyphs={}
    }
}

// Empties a font on demand for density: every glyph is asked for again.
@(private="file")
font_flush :: proc(font:^Font,density:f32) {
    font_faces_reset(font.faces,density)
    slice.fill(font.wanted,0)
    slice.fill(font.pixels,0)
    font.shelf={}
    font.dirty={0,0,font.width,font.height}
    font.density=density
    font.revision+=1
    if font.session!=nil {font.session.sized=-1}
}

// Puts the font at density device pixels per layout unit, when it is at
// another. A font on demand empties its atlas, with room for the rows of
// that density; any other is rasterized again. A transaction: when it fails
// the previous atlas stays as it was.
font_set_density :: proc(font:^Font,density:f32) -> bool {
    density:=clamp(density,FONT_DENSITY_MIN,FONT_DENSITY_MAX) if density>0 else 1
    if font.density==density && font.height>0 {return true}
    if !font.on_demand {return font_rebuild(font,density)}
    rows:=(int(f32(FONT_ROWS_START)*density*density)+3)&~int(3)
    if rows>font.height && !font_atlas_rows(font,rows) {return false}
    font_flush(font,density)
    return true
}

// Rasterizes every face for density device pixels per layout unit, as a
// transaction. A font on demand is emptied instead (font_set_density).
font_rebuild :: proc(font:^Font,density:f32) -> bool {
    density:=clamp(density,FONT_DENSITY_MIN,FONT_DENSITY_MAX) if density>0 else 1
    if font.on_demand {return font_set_density(font,density)}
    s:Font_Session
    defer font_session_close(&s)
    if !font_session_open(&s,font) {return false}
    // The atlas is built apart and replaces the previous one whole.
    next:=font^
    next.pixels,next.height,next.shelf=nil,0,{}
    if next.faces=make([]Face,len(font.faces),context.temp_allocator);next.faces==nil && len(font.faces)>0 {return false}
    copy(next.faces,font.faces)
    font_faces_reset(next.faces,density)
    ok:=true
    rasterize: for &face,i in next.faces {
        for index in 32..<FONT_GLYPHS {
            if font_glyph_rasterize(&next,&s,i,index,true)!=.Done {ok=false;break rasterize}
        }
    }
    // The atlas keeps the rows it used.
    if ok {ok=font_atlas_rows(&next,(next.shelf[1]+next.shelf[2]+3)&~int(3))}
    if !ok {delete(next.pixels,font.allocator);return false}
    delete(font.pixels,font.allocator)
    copy(font.faces,next.faces)
    font.pixels,font.height,font.shelf,font.density=next.pixels,next.height,next.shelf,density
    font.revision+=1;font.ready=true
    return true
}

// Rasterizes the glyphs the contexts that borrow a font on demand asked for,
// for its owner: it may allocate. grow: the atlas may grow, which moves the
// texture coordinates of what is drawn already, so only between frames;
// without it a glyph that does not fit waits for an update that may grow.
// True when the atlas changed.
font_update :: proc(font:^Font,grow:=true) -> (changed:bool) {
    if !font.on_demand || font.session==nil {return}
    defer if changed {font.revision+=1}
    for &word,w in font.wanted {
        for word!=0 {
            bit:=w*64+int(intrinsics.count_trailing_zeros(word))
            face,index:=bit/FONT_GLYPHS,bit%FONT_GLYPHS
            if font.faces[face].glyphs[index].phases==0 {
                if font_glyph_rasterize(font,font.session,face,index,grow)!=.Done {return}
                changed=true
            }
            word&=word-1
        }
    }
    return
}

// Asks the owner of the font for a glyph of a face (font_update).
font_want :: #force_inline proc "contextless" (font:^Font,face,index:int) {
    bit:=face*FONT_GLYPHS+index
    if bit>=0 && bit>>6<len(font.wanted) {font.wanted[bit>>6]|=1<<u64(bit&63)}
}

// Gives the atlas rows rows, zeroing the new ones; the texture coordinates
// of the glyphs it holds follow.
@(private="file")
font_atlas_rows :: proc(font:^Font,rows:int) -> bool {
    if rows==font.height {return true}
    pixels,error:=mem.resize_bytes(font.pixels,font.width*rows,allocator=font.allocator)
    if error!=nil {return false}
    scale:=f32(font.height)/f32(rows)
    for &face in font.faces {
        for &glyph in face.glyphs {
            if glyph.phases>0 {glyph.uv.y*=scale;glyph.uv.h*=scale}
        }
    }
    font.pixels,font.height=pixels,rows
    font.dirty={0,0,font.width,rows}
    return true
}

@(private="file")
Glyph_Result :: enum u8 {Done,Full,No_Memory}

// Rasterizes one glyph of a face into the atlas: it is hinted once and
// packed on the shelf, its phases side by side. Full: it does not fit and
// grow is false; the glyph stays out.
@(private="file")
font_glyph_rasterize :: proc(font:^Font,s:^Font_Session,face_index,index:int,grow:bool) -> Glyph_Result {
    face:=&font.faces[face_index]
    f:=int(face.font)
    face.glyphs[index]={phases=1}
    if !font.metrics[f].available[index] {return .Done}
    ftface:=s.faces[f]
    if s.sized!=face_index {
        if ft.set_char_size(ftface,0,c.long(math.round(face.pixel_size*64)),72,72)!=0 {return .Done}
        s.sized=face_index
    }
    glyph:=ft.get_char_index(ftface,c.ulong(font_character(index)))
    if ft.load_glyph(ftface,glyph,ft.LOAD_TARGET_LIGHT|ft.LOAD_NO_BITMAP)!=0 {return .Done}
    slot:=ftface.glyph
    if slot.format!=ft.GLYPH_FORMAT_OUTLINE || slot.outline.n_points==0 {return .Done}
    box:ft.BBox
    ft.outline_get_cbox(&slot.outline,&box)
    phases:=int(face.phases) if index<127 || index>=FONT_EXTRA_INDEX && index<FONT_EXTRA_INDEX+len(FONT_EXTRA) else 1
    // Pixels the outline covers at any of its phases, in 26.6 units.
    left:=box.x_min>>6
    right:=(box.x_max+ft.Pos(64*(phases-1)/phases)+63)>>6
    bottom,top:=box.y_min>>6,(box.y_max+63)>>6
    if right<=left || top<=bottom {return .Done}
    w:=int(right-left)+2;h:=int(top-bottom)+2
    width:=font.width
    if w*phases>width {return .Done}
    shelf:=font.shelf
    if shelf[0]+w*phases>width {shelf={0,shelf[1]+shelf[2],0}}
    x,y:=shelf[0],shelf[1]
    if y+h>font.height {
        face.glyphs[index]={}
        if !grow {return .Full}
        if !font_atlas_rows(font,(max(y+h,font.height*2,FONT_ROWS_START)+3)&~int(3)) {return .No_Memory}
    }
    ft.outline_translate(&slot.outline,-left*64,-bottom*64)
    if phases==1 {
        target:=ft.Bitmap{rows=c.uint(h-2),width=c.uint(w-2),pitch=c.int(width),num_grays=256,pixel_mode=ft.PIXEL_MODE_GRAY,
            buffer=raw_data(font.pixels[(y+1)*width+x+1:])}
        params:=ft.Raster_Params{target=&target,source=&slot.outline,flags=ft.RASTER_FLAG_AA}
        _=ft.outline_render(s.library,&slot.outline,&params)
    } else {
        // Column c of the wide image is the strip [(c-phases+1)/phases, (c-phases+2)/phases)
        // of a pixel: phase k of pixel j sums the columns from phases*j-k+phases-1 on.
        stride:=(w-2)*phases+phases-1
        if stride*(h-2)>len(s.wide) {
            wide,error:=mem.resize_bytes(s.wide,max(stride*(h-2),len(s.wide)*2),allocator=s.allocator)
            if error!=nil {face.glyphs[index]={};return .No_Memory}
            s.wide=wide
        }
        wide:=s.wide[:stride*(h-2)]
        slice.fill(wide,0)
        matrix_:=ft.Matrix{xx=ft.Fixed(phases)<<16,yy=1<<16}
        ft.outline_transform(&slot.outline,&matrix_)
        ft.outline_translate(&slot.outline,ft.Pos(64*(phases-1)),0)
        target:=ft.Bitmap{rows=c.uint(h-2),width=c.uint(stride),pitch=c.int(stride),num_grays=256,pixel_mode=ft.PIXEL_MODE_GRAY,buffer=raw_data(wide)}
        params:=ft.Raster_Params{target=&target,source=&slot.outline,flags=ft.RASTER_FLAG_AA}
        _=ft.outline_render(s.library,&slot.outline,&params)
        for row in 0..<h-2 {
            source:=wide[row*stride:][:stride]
            for phase in 0..<phases {
                out:=font.pixels[(y+1+row)*width+x+phase*w+1:][:w-2]
                for column in 0..<w-2 {
                    first:=phases*column-phase+phases-1
                    sum:=0
                    for k in 0..<phases {sum+=int(source[first+k])}
                    out[column]=u8((sum+phases/2)/phases)
                }
            }
        }
    }
    face.glyphs[index]={
        bounds={f32(left-1),f32(-top-1),f32(w),f32(h)},
        uv={f32(x)/f32(width),f32(y)/f32(font.height),f32(w)/f32(width),f32(h)/f32(font.height)},
        phases=f32(phases),
    }
    font.shelf={x+w*phases,y,max(shelf[2],h)}
    if font.dirty[2]<=font.dirty[0] {font.dirty={x,y,x+w*phases,y+h}} else {
        font.dirty={min(font.dirty[0],x),min(font.dirty[1],y),max(font.dirty[2],x+w*phases),max(font.dirty[3],y+h)}
    }
    return .Done
}

// The glyph of character among those of a font: '?' for the ones it lacks.
@(private)
metrics_index :: #force_inline proc "contextless" (m:^Font_Metrics,character:rune) -> int {
    index:=-1
    for r in FONT_RANGES {
        if character>=r.first && character<=r.last {index=r.index+int(character-r.first);break}
    }
    if index<0 {for extra,i in FONT_EXTRA {if character==extra {index=FONT_EXTRA_INDEX+i;break}}}
    if index<0 || !m.available[index] {index=int('?')}
    return index
}

// Font units of kerning between two glyphs of a font.
@(private)
metrics_kerning :: #force_inline proc "contextless" (m:^Font_Metrics,left,right:int) -> f32 #no_bounds_check {
    k:=&m.kerning
    if len(k.values)==0 || left<0 || right<0 || left>=FONT_GLYPHS || right>=FONT_GLYPHS {return 0}
    // The classes index values by construction (font_kerning_read).
    return f32(k.values[int(k.left[left])*k.columns+int(k.right[right])])
}

font_index :: #force_inline proc "contextless" (font:^Font,f:int,character:rune) -> int {
    if font==nil || !font.ready || f<0 || f>=font.font_count {return -1}
    return metrics_index(&font.metrics[f],character)
}

// The face of font f rasterized closest to pixels device pixels per em.
font_face :: proc "contextless" (font:^Font,f:int,pixels:f32) -> ^Face {
    if f<0 || f>=len(font.metrics) {return nil}
    best:^Face
    range:=font.metrics[f].faces
    for &face in font.faces[range[0]:][:range[1]] {
        if best==nil || abs(face.pixel_size-pixels)<abs(best.pixel_size-pixels) {best=&face}
    }
    return best
}

font_advance :: proc "contextless" (font:^Font,f:int,character:rune,size:f32) -> f32 {
    if character=='\t' {return font_advance(font,f,' ',size)*4}
    if index:=font_index(font,f,character);index>=0 {return font.metrics[f].advances[index]*size}
    // A context without a font still lays out; drawing text requires the atlas.
    if character==' ' {return size*0.25}
    return size*0.5
}

// The kerning between two glyphs of the atlas (font_index), in layout units;
// 0 when either is -1.
font_kern :: proc "contextless" (font:^Font,f,left,right:int,size:f32) -> f32 {
    if font==nil || !font.ready || f<0 || f>=font.font_count {return 0}
    m:=&font.metrics[f]
    return metrics_kerning(m,left,right)*m.unit*size
}

// The pen of a run of text: each step moves it over the kerning with the
// character before and the advance of the character. It reads the font once.
Text_Pen :: struct {
    font:^Font,
    metrics:^Font_Metrics, // nil without an atlas: characters take the widths of font_advance
    f:int,
    size:f32,
    unit:f32,              // layout units per font unit
    previous:int,          // glyph of the last character, -1 at the start, after a tab or a newline
}
text_pen :: proc "contextless" (font:^Font,size:f32,f:int=0) -> Text_Pen {
    pen:=Text_Pen{font=font,f=f,size=size,previous=-1}
    if font!=nil && font.ready && f>=0 && f<font.font_count {
        pen.metrics=&font.metrics[f]
        pen.unit=pen.metrics.unit*size
    }
    return pen
}
// How far character moves the pen: its kerning with the character before
// (kern) and its advance.
text_pen_step :: #force_inline proc "contextless" (pen:^Text_Pen,character:rune) -> (kern,advance:f32) #no_bounds_check {
    m:=pen.metrics
    if m==nil || character=='\t' || character=='\n' {
        pen.previous=-1
        return 0,font_advance(pen.font,pen.f,character,pen.size) if character!='\n' else 0
    }
    // metrics_index gives a glyph of the atlas.
    index:=metrics_index(m,character)
    kern=metrics_kerning(m,pen.previous,index)*pen.unit
    pen.previous=index
    return kern,m.advances[index]*pen.size
}

// Width of the widest line of text.
text_width :: proc "contextless" (font:^Font,text:string,size:f32,f:int=0) -> f32 {
    current,largest:f32
    pen:=text_pen(font,size,f)
    for character in text {
        kern,advance:=text_pen_step(&pen,character)
        if character=='\n' {largest=max(largest,current);current=0;continue}
        current+=kern+advance
    }
    return max(current,largest)
}

Text_Wrap :: enum u8 {None,Words}

// Sizes between the top of one line of text and the top of the next: the
// normal line height of Inter, its ascent plus its descent. It is also the
// height of the box a line of text takes.
TEXT_LINE :: f32(2478.0/2048.0)

// Where the box of a line of text of size starts in a height: as CSS
// centers a line, half of what the height has beyond the box goes above it.
text_leading :: proc "contextless" (size,height:f32) -> f32 {
    return (height-size*TEXT_LINE)*0.5
}

// The next line of text no wider than width: broken at a newline, or with
// Words at the last space that fits. A word wider than the line is not split.
text_line :: proc "contextless" (font:^Font,text:string,size,width:f32,wrap:Text_Wrap,f:int=0) -> (line,rest:string,line_width:f32) {
    x:f32
    space,space_end:=-1,-1
    space_width:f32
    pen:=text_pen(font,size,f)
    for character,i in text {
        if character=='\n' {return text[:i],text[i+1:],x}
        kern,advance:=text_pen_step(&pen,character)
        if wrap==.Words && character!=' ' && x+kern+advance>width+0.01 && space>=0 {
            return text[:space],text[space_end:],space_width
        }
        if character==' ' {
            if i==0 || text[i-1]!=' ' {space=i;space_width=x}
            space_end=i+1
        }
        x+=kern+advance
    }
    return text,"",x
}

// Walks the lines of a wrapped text in order without storing them: each call
// to text_lines_next gives the byte range of the next one. A text that ends
// with a newline has one more, empty, line.
Text_Lines :: struct {
    font:^Font,
    rest:string,
    size,width:f32,
    wrap:Text_Wrap,
    f,offset:int,
    row:int,  // of the line text_lines_next gave last
    tail,done:bool,
}
text_lines :: proc "contextless" (font:^Font,text:string,size,width:f32,wrap:Text_Wrap,f:int=0) -> Text_Lines {
    return {font=font,rest=text,size=size,width=width,wrap=wrap,f=f,row=-1}
}
text_lines_next :: proc "contextless" (it:^Text_Lines) -> (start,end:int,ok:bool) {
    if it.done {return}
    it.row+=1
    if it.tail {
        it.tail,it.done=false,true
        return it.offset,it.offset,true
    }
    line,next,_:=text_line(it.font,it.rest,it.size,it.width,it.wrap,it.f)
    start,end=it.offset,it.offset+len(line)
    consumed:=len(it.rest)-len(next)
    broke:=consumed>len(line) && it.rest[consumed-1]=='\n'
    it.offset+=consumed
    it.rest=next
    if next=="" {
        if broke {it.tail=true} else {it.done=true}
    }
    return start,end,true
}

// Lines text takes when wrapped to width.
text_line_count :: proc "contextless" (font:^Font,text:string,size,width:f32,wrap:Text_Wrap,f:int=0) -> int {
    count:=0
    rest:=text
    for {
        _,rest,_=text_line(font,rest,size,width,wrap,f)
        count+=1
        if rest=="" {break}
    }
    return count
}

ELLIPSIS :: "…"

// The longest prefix of one line of text that leaves room for the ellipsis
// inside width.
text_cut :: proc "contextless" (font:^Font,text:string,size,width:f32,f:int=0) -> string {
    room:=width-text_width(font,ELLIPSIS,size,f)
    x:f32
    pen:=text_pen(font,size,f)
    for character,i in text {
        kern,advance:=text_pen_step(&pen,character)
        if x+kern+advance>room+0.01 {return text[:i]}
        x+=kern+advance
    }
    return text
}

// Caret position nearest to x in a line that starts at 0. cell: the
// character under x instead.
text_index_at :: proc "contextless" (font:^Font,text:string,size,x:f32,cell:bool=false,f:int=0) -> int {
    at:f32
    pen:=text_pen(font,size,f)
    for character,i in text {
        kern,advance:=text_pen_step(&pen,character)
        at+=kern
        if x<at+(advance if cell else advance*0.5) {return i}
        at+=advance
    }
    return len(text)
}
