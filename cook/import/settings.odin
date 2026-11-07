package importer

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:std/geom"
import "mirai:std/serial"

// How a source becomes assets. The settings of a source are kept in a small
// text file next to it, <source>.import, so importing it again gives the same
// assets whoever does it: an import reads that file when it exists and uses
// its settings instead of those of its options, and whoever imports writes it
// with settings_save. The zero value is the default of every setting.

Lods :: enum u8 {
    Auto, // simplified levels are stored after level 0 (mesh_levels)
    None, // level 0 alone
}

// What an image imported on its own holds.
Image_Use :: enum u8 {
    Data,              // linear values
    Color,             // sRGB
    Normal,            // a tangent-space normal map, +Y up the image
    Normal_Green_Down, // a normal map whose green points down the image, as DirectX writes them
}

// Of a model: the skeleton its meshes are skinned to. Other than Source, a
// template of Mesh2Motion fitted to the meshes and weighted to them, in place
// of what the source has: Humanoid by the sections of a person (rig.humanoid),
// an animal by deforming the template onto them (rig.animal).
Rig :: enum u8 {
    Source, // the skeletons and skins the source has
    Humanoid,
    Fox,    // a quadruped with a tail: fox, dog, cat, wolf
    Horse,  // a hoofed quadruped with a long neck
    Bird,   // spread wings
    Dragon, // four legs and wings
    Kaiju,  // a biped with a tail: dinosaur, kaiju
    Shark,  // a fish
    Snake,
    Spider, // eight legs
}

// The rig an import option names: its name in lowercase.
rig_from_name :: proc(name:string) -> (rig:Rig,ok:bool) {
    for r in Rig {
        if strings.equal_fold(fmt.tprint(r),name) {return r,true}
    }
    return
}

Import_Settings :: struct {
    max_texture_size:int,       // 0: 4096
    textures:textures.Encoding, // .Blocks: BC1, BC3, BC5, BC6H or BC7 by the use of each image; .Uncompressed: RGBA8, RGBA16 or RGBA16F by what it holds
    rdo_lambda:int,             // of textures in blocks, up to textures.RDO_LAMBDA_MAX: how much error their rate-distortion optimization trades for files that compress smaller. 0: textures.RDO_LAMBDA_DEFAULT; below 0: none
    image:Image_Use,            // of an image imported on its own
    alpha_coverage:f32,         // of an image imported on its own, above 0: the cutoff of the masked material that shows it, whose coverage every level keeps
    lods:Lods,
    max_triangles:int,          // of a model, above 0: a mesh with more is simplified to them, as its levels are
    collision:Collision,        // of a mesh whose source gives no colliders, unless force_collision
    force_collision:bool,       // the colliders of collision replace those the source gives
    collision_hulls:int,        // of Pieces: the most hulls. 0: geom.DECOMPOSE_DEFAULT_HULLS
    parts:Parts,                // of a model: which of its materials and textures are parts of its prefab (parts.odin)
    rig:Rig,
    rig_crotch,rig_neck:f32,    // of a Humanoid rig, above 0: the heights in meters in the model of the crotch and the neck, in place of where the fit finds them
    skeleton:base.Asset_Id,     // of a model, not zero: its clips play on this skeleton the project has (with the same bones), and the import writes only its .anim, bound to it: no textures, materials, skeletons, meshes or prefab
}

SETTINGS_EXTENSION :: ".import"

settings_path :: proc(source:string,allocator:=context.allocator) -> string {
    return strings.concatenate({source,SETTINGS_EXTENSION},allocator)
}

@(private="file")
settings_valid :: proc(settings:Import_Settings) -> bool {
    return settings.max_texture_size>=0 && settings.max_triangles>=0 && settings.collision_hulls>=0 && settings.textures<=max(textures.Encoding) && settings.rdo_lambda<=textures.RDO_LAMBDA_MAX &&
        settings.image<=max(Image_Use) && settings.alpha_coverage>=0 && settings.alpha_coverage<=1 && settings.lods<=max(Lods) && settings.collision<=max(Collision) && settings.parts<=max(Parts) && settings.rig<=max(Rig) &&
        settings.rig_crotch>=0 && settings.rig_neck>=0 && (settings.rig==.Humanoid || settings.rig_crotch==0 && settings.rig_neck==0)
}

settings_text :: proc(settings:Import_Settings,allocator:=context.allocator) -> string {
    settings:=settings
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Import_Settings)
    w:serial.Writer
    serial.writer_init(&w,256,allocator)
    serial.text_write(&w,&schema,type,([^]u8)(&settings)[:size_of(Import_Settings)])
    serial.write_u8(&w,'\n')
    return string(serial.writer_take(&w))
}

// False for a text that is not the settings of a source: a field or a value this build does not know.
settings_parse :: proc(text:string) -> (settings:Import_Settings,ok:bool) {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Import_Settings)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    if !serial.text_read(&r,&schema,type,([^]u8)(&settings)[:size_of(Import_Settings)]) || !serial.text_end(&r) || !settings_valid(settings) {return {},false}
    return settings,true
}

// The settings kept next to a source. found is false, with the defaults, when
// it has none; a file that cannot be read as settings is an error, not the
// defaults, so a source is never imported in a way nobody chose.
settings_load :: proc(source:string) -> (settings:Import_Settings,found:bool,error:Error) {
    // A source that names a device has no file next to it.
    if unsafe_path(source) {return}
    path:=settings_path(source,context.temp_allocator)
    data,file_error:=serial.file_read(path,context.temp_allocator)
    if file_error==.Not_Found {return}
    if file_error!=.None {return {},false,error_make(.Not_Found,"%s could not be read",path)}
    parsed,valid:=settings_parse(string(data))
    if !valid {return {},false,error_make(.Malformed,"%s is not the settings of an import",path)}
    return parsed,true,{}
}

// Writes the settings next to the source, unless the file already says the same.
settings_save :: proc(source:string,settings:Import_Settings) -> bool {
    path:=settings_path(source,context.temp_allocator)
    text:=settings_text(settings,context.temp_allocator)
    if data,read_error:=os.read_entire_file(path,context.temp_allocator);read_error==nil && string(data)==text {return true}
    return serial.file_write_atomic(path,transmute([]u8)text)==.None
}

// What an asset records in Import_Info.settings_hash is the identity of the
// settings it is built from, and nothing else: a change of the others keeps
// it. A mesh is built from its levels and its colliders (mesh_settings_hash);
// a texture from its build options (textures.settings_hash); materials,
// skeletons and clips from none of them, and record 0. A rig other than the
// source's changes the skin of a mesh, so it is part of the mesh's.
mesh_settings_hash :: proc(settings:Import_Settings) -> u64 {
    hulls:=0
    if settings.collision==.Pieces {hulls=settings.collision_hulls if settings.collision_hulls>0 else geom.DECOMPOSE_DEFAULT_HULLS}
    built:=[8]u64{u64(settings.lods),u64(settings.collision),u64(hulls),u64(settings.max_triangles),u64(settings.force_collision),u64(settings.rig),u64(transmute(u32)settings.rig_crotch),u64(transmute(u32)settings.rig_neck)}
    return base.hash64(mem.slice_to_bytes(built[:5] if settings.rig==.Source else built[:]))
}
