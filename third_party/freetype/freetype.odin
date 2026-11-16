package freetype

import "core:c"

when ODIN_OS==.Windows {
    foreign import FreeType "windows/freetype.lib"
} else when ODIN_OS==.Linux {
    foreign import FreeType "linux/freetype.a"
} else when ODIN_OS==.Darwin {
    when ODIN_ARCH==.arm64 {foreign import FreeType "macos-arm64/freetype.a"}
    else {foreign import FreeType "macos/freetype.a"}
}

// The part of the FreeType API the UI rasterizes with. The library is built
// with TrueType outlines, the auto-hinter and the anti-aliasing rasterizer
// alone (config/freetype/config).

Error :: c.int
Pos :: c.long   // 26.6 fixed point in pixels, or font units
Fixed :: c.long // 16.16 fixed point

Library :: distinct rawptr

Memory_Rec :: struct {
    user:rawptr,
    alloc:proc "c" (memory:^Memory_Rec,size:c.long) -> rawptr,
    free:proc "c" (memory:^Memory_Rec,block:rawptr),
    realloc:proc "c" (memory:^Memory_Rec,cur_size,new_size:c.long,block:rawptr) -> rawptr,
}

Vector :: struct {x,y:Pos}
Matrix :: struct {xx,xy,yx,yy:Fixed}
BBox :: struct {x_min,y_min,x_max,y_max:Pos}
Generic :: struct {data:rawptr,finalizer:proc "c" (object:rawptr)}

Bitmap :: struct {
    rows,width:c.uint,
    pitch:c.int,
    buffer:[^]u8,
    num_grays:c.ushort,
    pixel_mode,palette_mode:u8,
    palette:rawptr,
}
PIXEL_MODE_GRAY :: 2

Outline :: struct {
    n_contours,n_points:c.ushort,
    points:[^]Vector,
    tags:[^]u8,
    contours:[^]c.ushort,
    flags:c.int,
}

Glyph_Metrics :: struct {
    width,height:Pos,
    hori_bearing_x,hori_bearing_y,hori_advance:Pos,
    vert_bearing_x,vert_bearing_y,vert_advance:Pos,
}

GLYPH_FORMAT_OUTLINE :: c.uint(0x6f75746c) // 'outl'

// FT_GlyphSlotRec up to the fields read here; FreeType owns and sizes it.
Glyph_Slot :: struct {
    library:Library,
    face:^Face,
    next:^Glyph_Slot,
    glyph_index:c.uint,
    generic:Generic,
    metrics:Glyph_Metrics,
    linear_hori_advance,linear_vert_advance:Fixed,
    advance:Vector,
    format:c.uint,
    bitmap:Bitmap,
    bitmap_left,bitmap_top:c.int,
    outline:Outline,
}

// FT_FaceRec up to the fields read here; FreeType owns and sizes it.
Face :: struct {
    num_faces,face_index:c.long,
    face_flags,style_flags:c.long,
    num_glyphs:c.long,
    family_name,style_name:cstring,
    num_fixed_sizes:c.int,
    available_sizes:rawptr,
    num_charmaps:c.int,
    charmaps:rawptr,
    generic:Generic,
    bbox:BBox,
    units_per_em:c.ushort,
    ascender,descender,height:c.short,
    max_advance_width,max_advance_height:c.short,
    underline_position,underline_thickness:c.short,
    glyph:^Glyph_Slot,
    size:rawptr,
    charmap:rawptr,
}
FACE_FLAG_SCALABLE :: c.long(1<<0)

Raster_Params :: struct {
    target:^Bitmap,
    source:rawptr,
    flags:c.int,
    gray_spans:rawptr,
    unused:[3]rawptr,
    user:rawptr,
    clip_box:BBox,
}
RASTER_FLAG_AA :: c.int(0x1)

// The value of the property increase-x-height of the auto-hinter.
Prop_Increase_X_Height :: struct {
    face:^Face,
    limit:c.uint, // up to this many pixels per em the x-height rounds up more often; 0: never
}

LOAD_NO_SCALE     :: i32(1<<0)
LOAD_NO_BITMAP    :: i32(1<<3)
// The auto-hinter in its light mode: it moves outlines vertically only.
LOAD_TARGET_LIGHT :: i32(1<<16)

@(default_calling_convention="c")
foreign FreeType {
    @(link_name="FT_New_Library") new_library :: proc(memory:^Memory_Rec,library:^Library) -> Error ---
    @(link_name="FT_Add_Default_Modules") add_default_modules :: proc(library:Library) ---
    @(link_name="FT_Done_Library") done_library :: proc(library:Library) -> Error ---
    @(link_name="FT_Property_Set") property_set :: proc(library:Library,module_name,property_name:cstring,value:rawptr) -> Error ---
    @(link_name="FT_New_Memory_Face") new_memory_face :: proc(library:Library,data:[^]u8,size,face_index:c.long,face:^^Face) -> Error ---
    @(link_name="FT_Done_Face") done_face :: proc(face:^Face) -> Error ---
    // char_width and char_height in 26.6 points; at 72 dpi a point is a pixel.
    @(link_name="FT_Set_Char_Size") set_char_size :: proc(face:^Face,char_width,char_height:c.long,horizontal_dpi,vertical_dpi:c.uint) -> Error ---
    @(link_name="FT_Get_Char_Index") get_char_index :: proc(face:^Face,code:c.ulong) -> c.uint ---
    @(link_name="FT_Get_Advance") get_advance :: proc(face:^Face,glyph:c.uint,flags:i32,advance:^Fixed) -> Error ---
    @(link_name="FT_Load_Glyph") load_glyph :: proc(face:^Face,glyph:c.uint,flags:i32) -> Error ---
    @(link_name="FT_Outline_Get_CBox") outline_get_cbox :: proc(outline:^Outline,box:^BBox) ---
    @(link_name="FT_Outline_Translate") outline_translate :: proc(outline:^Outline,x,y:Pos) ---
    @(link_name="FT_Outline_Transform") outline_transform :: proc(outline:^Outline,matrix_:^Matrix) ---
    @(link_name="FT_Outline_Render") outline_render :: proc(library:Library,outline:^Outline,params:^Raster_Params) -> Error ---
}
