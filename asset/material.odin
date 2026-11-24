package asset

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// .mat: the values of a material. The standard model is OpenPBR's: a
// metallic-roughness base, as in glTF 2.0, with glass, and the layers a
// material may add over it (coat, fuzz, specular anisotropy, diffuse
// transmission, subsurface) or no light at all (unlit). A material may instead name a Surface program and carry the
// values of its parameters. Textures are asset ids.
//
//   material     Material_Info, one row: what the material is
//   imported     Material_Info, one row, of a material an import wrote: what
//                its source gave at the last import. The fields where
//                material differs from it are those changed after the
//                import (material_overrides), which the next import keeps
//                (material_follow). Absent, the material is its own base.
//   parameters   Material_Parameter: values for the program, and for the
//                parameters of an overlay
//   imported_parameters  Material_Parameter, of a material an import wrote:
//                the parameters its source gave at the last import. A
//                parameter whose value differs from it was changed after the
//                import and the next one keeps it (material_parameters_follow).
//   overlays     Material_Overlay: layers drawn over the surface, bottom first
//   hidden       Material_Name: properties and parameters the editor does not show
//
// A source gives the values of the standard model and of the parameters of
// its program; overlays and hidden names are always the material's own.

MATERIAL_VERSION :: 6
MATERIAL_MAX_PARAMETERS :: 32
MATERIAL_MAX_OVERLAYS :: 4
MATERIAL_NAME_BYTES :: 64
// Metres: the farthest a subsurface spreads light (Material_Subsurface.radius).
MATERIAL_SUBSURFACE_RADIUS_MAX :: 0.1

Alpha_Mode :: enum u8 {
    Opaque,   // the alpha of the material is ignored
    Mask,     // points whose mask (maps.mask) is below alpha_cutoff are holes, for the camera, the shadows and rays
    Blend,    // drawn over the scene after it is lit
    Additive, // drawn over the scene after it is lit, adding its light by opacity and hiding nothing; no transmission
}

// Whether a mode draws the material over the lit scene: apart from the opaque
// surfaces, casting no shadow and invisible to rays.
alpha_blended :: proc "contextless" (mode:Alpha_Mode) -> bool {return mode==.Blend || mode==.Additive}

// One map of a material: its texture and how it reads the UVs. The only
// transform of the UVs a material has: one that tiles gives each of its maps
// the scale.
Material_Map :: struct {
    texture:base.Asset_Id,
    scale:[2]f32,
    offset:[2]f32,
    rotation:f32 `mirai:"angle"`, // counterclockwise in UV coordinates
    uv_set:u32 `mirai:"min=0,max=1"`,
}

Material_Maps :: struct {
    base_color:Material_Map,         // sRGB; multiplies base_color
    metallic_roughness:Material_Map, // g multiplies roughness, b multiplies metallic
    normal:Material_Map,             // tangent space, +Y up
    emission:Material_Map,           // sRGB; multiplies emission
    occlusion:Material_Map,          // r: how much indirect light reaches the surface
    specular:Material_Map,           // linear alpha: scales the dielectric specular
    specular_color:Material_Map,     // sRGB: scales the dielectric specular color
    coat:Material_Map,               // r multiplies coat.weight
    coat_roughness:Material_Map,     // g multiplies coat.roughness
    coat_normal:Material_Map,        // tangent space, +Y up: the normal of the coat
    fuzz_color:Material_Map,         // sRGB; multiplies fuzz.color
    fuzz_roughness:Material_Map,     // a multiplies fuzz.roughness
    anisotropy:Material_Map,         // rg a direction of tangent space from -1 to 1, turned by anisotropy.rotation; b multiplies anisotropy.amount
    diffuse_transmission:Material_Map,       // a multiplies diffuse_transmission.weight
    diffuse_transmission_color:Material_Map, // sRGB; multiplies diffuse_transmission.color
    subsurface:Material_Map,                 // a multiplies subsurface.weight
    subsurface_radius:Material_Map,          // r multiplies subsurface.radius
    // a times opacity: the coverage of a masked material, against alpha_cutoff;
    // without a texture of its own, the base_color map. A program never decides it.
    mask:Material_Map,
}

// The maps of Material_Maps by kind, in the order of its fields.
Material_Map_Kind :: enum u8 {
    Base_Color,Metallic_Roughness,Normal,Emission,Occlusion,Specular,Specular_Color,
    Coat,Coat_Roughness,Coat_Normal,Fuzz_Color,Fuzz_Roughness,Anisotropy,
    Diffuse_Transmission,Diffuse_Transmission_Color,Subsurface,Subsurface_Radius,Mask,
}

material_maps :: proc "contextless" (maps:^Material_Maps) -> ^[Material_Map_Kind]Material_Map {
    return (^[Material_Map_Kind]Material_Map)(maps)
}
#assert(size_of(Material_Maps)==len(Material_Map_Kind)*size_of(Material_Map))
#assert(offset_of(Material_Maps,metallic_roughness)==uintptr(Material_Map_Kind.Metallic_Roughness)*size_of(Material_Map))
#assert(offset_of(Material_Maps,normal)==uintptr(Material_Map_Kind.Normal)*size_of(Material_Map))
#assert(offset_of(Material_Maps,emission)==uintptr(Material_Map_Kind.Emission)*size_of(Material_Map))
#assert(offset_of(Material_Maps,occlusion)==uintptr(Material_Map_Kind.Occlusion)*size_of(Material_Map))
#assert(offset_of(Material_Maps,specular)==uintptr(Material_Map_Kind.Specular)*size_of(Material_Map))
#assert(offset_of(Material_Maps,specular_color)==uintptr(Material_Map_Kind.Specular_Color)*size_of(Material_Map))
#assert(offset_of(Material_Maps,coat)==uintptr(Material_Map_Kind.Coat)*size_of(Material_Map))
#assert(offset_of(Material_Maps,coat_roughness)==uintptr(Material_Map_Kind.Coat_Roughness)*size_of(Material_Map))
#assert(offset_of(Material_Maps,coat_normal)==uintptr(Material_Map_Kind.Coat_Normal)*size_of(Material_Map))
#assert(offset_of(Material_Maps,fuzz_color)==uintptr(Material_Map_Kind.Fuzz_Color)*size_of(Material_Map))
#assert(offset_of(Material_Maps,fuzz_roughness)==uintptr(Material_Map_Kind.Fuzz_Roughness)*size_of(Material_Map))
#assert(offset_of(Material_Maps,anisotropy)==uintptr(Material_Map_Kind.Anisotropy)*size_of(Material_Map))
#assert(offset_of(Material_Maps,diffuse_transmission)==uintptr(Material_Map_Kind.Diffuse_Transmission)*size_of(Material_Map))
#assert(offset_of(Material_Maps,diffuse_transmission_color)==uintptr(Material_Map_Kind.Diffuse_Transmission_Color)*size_of(Material_Map))
#assert(offset_of(Material_Maps,subsurface)==uintptr(Material_Map_Kind.Subsurface)*size_of(Material_Map))
#assert(offset_of(Material_Maps,subsurface_radius)==uintptr(Material_Map_Kind.Subsurface_Radius)*size_of(Material_Map))
#assert(offset_of(Material_Maps,mask)==uintptr(Material_Map_Kind.Mask)*size_of(Material_Map))

// OpenPBR coat: a clear dielectric layer over the base. It reflects with a
// GGX lobe of its own, filters the base through its color and darkens it as
// the light that bounces inside it does.
Material_Coat :: struct {
    weight:f32 `mirai:"min=0,max=1"`,    // the share of the surface it covers
    roughness:f32 `mirai:"min=0,max=1"`,
    color:[3]f32 `mirai:"color"`,        // what of white light it leaves after crossing it in and out at normal incidence
    ior:f32 `mirai:"min=1"`,
    normal_scale:f32,                    // of its normal map; without one it follows the surface, not the map of the base
}

// OpenPBR fuzz: fibers over the coat and the base (the sheen of glTF).
Material_Fuzz :: struct {
    weight:f32 `mirai:"min=0,max=1"`,
    color:[3]f32 `mirai:"color"`,        // the albedo of its fibers
    roughness:f32 `mirai:"min=0,max=1"`, // low: a sheen towards grazing angles; high: dust
}

// OpenPBR specular_roughness_anisotropy: the specular lobe of the base
// stretched along the tangent of the surface, turned by rotation, and as
// narrow across it as amount says, with the same mean square roughness.
Material_Anisotropy :: struct {
    amount:f32 `mirai:"min=0,max=1"`,
    rotation:f32 `mirai:"angle"`,        // counterclockwise from the tangent towards the bitangent
}

// OpenPBR thin-walled subsurface, KHR_materials_diffuse_transmission: of the
// light the base scatters diffusely, weight leaves through the other side of
// a thin surface (a leaf, paper, a lampshade) filtered by color, and the rest
// is reflected by the base color.
Material_Diffuse_Transmission :: struct {
    weight:f32 `mirai:"min=0,max=1"`,
    color:[3]f32 `mirai:"color"`,
}

// OpenPBR subsurface: of the light the base scatters diffusely, weight enters
// a solid and leaves it again around where it entered, spread over radius
// (each channel by its share in color: skin spreads red the farthest), and
// takes the base color as it leaves. A thin surface lets it through instead
// (diffuse_transmission), which a material with a subsurface does not have.
Material_Subsurface :: struct {
    weight:f32 `mirai:"min=0,max=1"`,
    color:[3]f32 `mirai:"color"`,              // the share of radius each channel spreads over
    radius:f32 `mirai:"min=0,max=0.1,unit=m"`, // up to MATERIAL_SUBSURFACE_RADIUS_MAX
}

// How the emission of a material is measured.
Emission_Mode :: enum u8 {
    // Luminance in nits: physical light, which lights the scene and which the
    // exposure meters.
    Physical,
    // The value the exposed image shows, whatever the exposure: 1 is a white
    // surface under the light the exposure takes, and twice as much one EV
    // more. It lights nothing and the meter does not count it.
    Relative,
}
// What a material holds besides the base. Unlit has none of the others: it
// reflects no light.
Material_Layer :: enum u8 {Coat,Fuzz,Anisotropy,Unlit,Diffuse_Transmission,Subsurface}
Material_Layers :: bit_set[Material_Layer;u32]

material_layers :: proc "contextless" (m:^Material_Info) -> (layers:Material_Layers) {
    if m.unlit {return {.Unlit}}
    if m.coat.weight>0 {layers+={.Coat}}
    if m.fuzz.weight>0 {layers+={.Fuzz}}
    if m.anisotropy.amount>0 {layers+={.Anisotropy}}
    if m.diffuse_transmission.weight>0 {layers+={.Diffuse_Transmission}}
    if m.subsurface.weight>0 {layers+={.Subsurface}}
    return
}

Material_Info :: struct {
    base_color:[3]f32 `mirai:"color"`,
    opacity:f32 `mirai:"min=0,max=1"`,
    alpha_mode:Alpha_Mode,
    alpha_cutoff:f32 `mirai:"min=0,max=1"`,
    two_sided:bool, // seen from behind too, its normal turned to the viewer: a leaf, a sheet; the others lose their back faces
    metallic:f32 `mirai:"min=0,max=1"`,
    roughness:f32 `mirai:"min=0,max=1"`,
    emission:[3]f32 `mirai:"color"`, // by emission_mode: luminance in nits, or the exposed value
    emission_mode:Emission_Mode,
    normal_scale:f32,
    occlusion_strength:f32 `mirai:"min=0,max=1"`,
    specular_factor:f32 `mirai:"min=0,max=1"`,
    specular_color:[3]f32 `mirai:"color"`,
    // Glass: KHR_materials_transmission, _ior and _volume.
    transmission:f32 `mirai:"min=0,max=1"`,
    ior:f32 `mirai:"min=1"`,
    thickness:f32 `mirai:"min=0,unit=m"`, // 0: a sheet; above: the mesh bounds a solid about this deep
    attenuation_color:[3]f32 `mirai:"color"`,
    attenuation_distance:f32 `mirai:"min=0,unit=m"`,
    scatter_color:[3]f32 `mirai:"color"`, // of what a solid stops, the share it scatters towards the eye, lit by what reaches it inside (KHR_materials_volume_scatter)
    coat:Material_Coat,
    fuzz:Material_Fuzz,
    anisotropy:Material_Anisotropy,
    diffuse_transmission:Material_Diffuse_Transmission,
    subsurface:Material_Subsurface,
    unlit:bool, // it reflects no light and shows its emission alone; base color and opacity still cover
    maps:Material_Maps,
    program:[MATERIAL_NAME_BYTES]u8 `mirai:"text"`, // generated program id, authored name, or ""
}

Parameter_Kind :: enum u8 {Float,Int,Uint,Bool,Texture}

Material_Parameter :: struct {
    name:[MATERIAL_NAME_BYTES]u8 `mirai:"text"`,
    overlay:u32,   // 0: of the material itself; else the id of the overlay whose parameter it replaces
    kind:Parameter_Kind,
    components:u8, // 1 to 4
    value:[4]f64,  // every 32-bit integer and float exactly
    texture:base.Asset_Id,
}

Overlay_Blend :: enum u8 {Alpha,Additive,Multiply}

Material_Overlay :: struct {
    id:u32, // stable inside the material, never 0
    material:base.Asset_Id,
    blend:Overlay_Blend,
    enabled:bool,
}

Material_Name :: struct {name:[MATERIAL_NAME_BYTES]u8 `mirai:"text"`}

MATERIAL_MAP_DEFAULT :: Material_Map{scale={1,1}}
MATERIAL_DEFAULTS :: Material_Info{
    base_color={1,1,1},opacity=1,alpha_cutoff=0.5,roughness=1,normal_scale=1,occlusion_strength=1,
    specular_factor=1,specular_color={1,1,1},ior=1.5,attenuation_color={1,1,1},
    coat={color={1,1,1},ior=1.6,normal_scale=1},fuzz={color={1,1,1},roughness=0.5},diffuse_transmission={color={1,1,1}},
    subsurface={color={1,0.5,0.25},radius=0.005},
    maps={
        MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,
        MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,
        MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,
    },
}

// The values of the standard model an entity gives by name, and where
// Material_Info holds each: a number, a color, a flag or, with modes,
// an enum of a byte with that many members.
Material_Value_Field :: struct {
    name:string,
    offset:uintptr,
    kind:enum u8 {Number,Color,Flag,Mode},
    modes:u8,
}
MATERIAL_VALUE_FIELDS :: [25]Material_Value_Field{
    {"base_color",offset_of(Material_Info,base_color),.Color,0},{"opacity",offset_of(Material_Info,opacity),.Number,0},
    {"metallic",offset_of(Material_Info,metallic),.Number,0},{"roughness",offset_of(Material_Info,roughness),.Number,0},
    {"emission",offset_of(Material_Info,emission),.Color,0},{"specular",offset_of(Material_Info,specular_factor),.Number,0},
    {"ior",offset_of(Material_Info,ior),.Number,0},{"transmission",offset_of(Material_Info,transmission),.Number,0},
    {"alpha_mode",offset_of(Material_Info,alpha_mode),.Mode,len(Alpha_Mode)},
    {"coat",offset_of(Material_Info,coat)+offset_of(Material_Coat,weight),.Number,0},{"coat_roughness",offset_of(Material_Info,coat)+offset_of(Material_Coat,roughness),.Number,0},
    {"coat_color",offset_of(Material_Info,coat)+offset_of(Material_Coat,color),.Color,0},{"coat_ior",offset_of(Material_Info,coat)+offset_of(Material_Coat,ior),.Number,0},
    {"fuzz",offset_of(Material_Info,fuzz)+offset_of(Material_Fuzz,weight),.Number,0},{"fuzz_color",offset_of(Material_Info,fuzz)+offset_of(Material_Fuzz,color),.Color,0},
    {"fuzz_roughness",offset_of(Material_Info,fuzz)+offset_of(Material_Fuzz,roughness),.Number,0},
    {"anisotropy",offset_of(Material_Info,anisotropy)+offset_of(Material_Anisotropy,amount),.Number,0},
    {"anisotropy_rotation",offset_of(Material_Info,anisotropy)+offset_of(Material_Anisotropy,rotation),.Number,0},
    {"unlit",offset_of(Material_Info,unlit),.Flag,0},{"emission_mode",offset_of(Material_Info,emission_mode),.Mode,len(Emission_Mode)},
    {"diffuse_transmission",offset_of(Material_Info,diffuse_transmission)+offset_of(Material_Diffuse_Transmission,weight),.Number,0},
    {"diffuse_transmission_color",offset_of(Material_Info,diffuse_transmission)+offset_of(Material_Diffuse_Transmission,color),.Color,0},
    {"subsurface",offset_of(Material_Info,subsurface)+offset_of(Material_Subsurface,weight),.Number,0},
    {"subsurface_color",offset_of(Material_Info,subsurface)+offset_of(Material_Subsurface,color),.Color,0},
    {"subsurface_radius",offset_of(Material_Info,subsurface)+offset_of(Material_Subsurface,radius),.Number,0},
}

// Puts a value of the standard model over the values of a material (put), or
// reads it, by the name_hash of one of MATERIAL_VALUE_FIELDS. False for
// another name.
material_standard_value :: proc(info:^Material_Info,name:u64,value:^[4]f32,put:bool) -> bool {
    fields:=MATERIAL_VALUE_FIELDS
    for field in fields {
        if base.name_hash(field.name)!=name {continue}
        at:=rawptr(uintptr(info)+field.offset)
        switch field.kind {
        case .Number: if put {(^f32)(at)^=value.x} else {value^={(^f32)(at)^,0,0,0}}
        case .Color:  if put {(^[3]f32)(at)^=value.xyz} else {value.xyz,value.w=(^[3]f32)(at)^,0}
        case .Flag:   if put {(^bool)(at)^=value.x>0.5} else {value^={f32(u8((^bool)(at)^)),0,0,0}}
        case .Mode:   if put {(^u8)(at)^=u8(clamp(int(value.x+0.5),0,int(field.modes)-1))} else {value^={f32((^u8)(at)^),0,0,0}}
        }
        return true
    }
    return false
}

Material_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of: the prefab of the import that made it
    info:Material_Info,
    imported:^Material_Info, // what the source gave at the last import; nil for a material no import wrote
    parameters:[]Material_Parameter,
    imported_parameters:[]Material_Parameter, // written with imported
    overlays:[]Material_Overlay,
    hidden:[]Material_Name,
    source:^Import_Info,
}

Material_View :: struct {
    info:^Material_Info,
    imported:^Material_Info, // nil without the table
    parameters:[]Material_Parameter,
    imported_parameters:[]Material_Parameter,
    overlays:[]Material_Overlay,
    hidden:[]Material_Name,
    source:^Import_Info,
}

material_document :: proc(doc:^Document,types:^Types,desc:Material_Desc,allocator:=context.allocator) -> Error {
    info:=desc.info
    if !material_check({info=&info,imported=desc.imported,parameters=desc.parameters,imported_parameters=desc.imported_parameters,overlays=desc.overlays,hidden=desc.hidden}) {return .Invalid}
    document_init(doc,KIND_MATERIAL,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=MATERIAL_VERSION
    error:=material_tables(doc,types,&info,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
material_tables :: proc(doc:^Document,types:^Types,info:^Material_Info,desc:Material_Desc) -> Error {
    document_put_row(doc,types,"material",info) or_return
    if desc.imported!=nil {
        imported:=desc.imported^
        document_put_row(doc,types,"imported",&imported) or_return
        if len(desc.imported_parameters)>0 {document_put(doc,types,"imported_parameters",desc.imported_parameters) or_return}
    }
    document_put(doc,types,"parameters",desc.parameters) or_return
    document_put(doc,types,"overlays",desc.overlays) or_return
    document_put(doc,types,"hidden",desc.hidden) or_return
    return import_put(doc,types,desc.source)
}

material_save :: proc(path:string,types:^Types,desc:Material_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    material_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

// The file of a material, as bytes from allocator.
material_bytes :: proc(types:^Types,desc:Material_Desc,allocator:=context.allocator) -> (data:[]u8,error:Error) {
    doc:Document
    material_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_bytes(&doc,allocator)
}

material_view :: proc(a:^Asset,types:^Types) -> (view:Material_View,error:Error) {
    kind_check(a,KIND_MATERIAL,MATERIAL_VERSION) or_return
    view.info=asset_row(a,types,"material",Material_Info,whole=true) or_return
    if _,found:=asset_table(a,"imported");found {view.imported=asset_row(a,types,"imported",Material_Info,whole=true) or_return}
    view.parameters=table_rows(a,types,"parameters",Material_Parameter) or_return
    if _,found:=asset_table(a,"imported_parameters");found {view.imported_parameters=table_rows(a,types,"imported_parameters",Material_Parameter) or_return}
    view.overlays=table_rows(a,types,"overlays",Material_Overlay) or_return
    view.hidden=table_rows(a,types,"hidden",Material_Name) or_return
    view.source=import_info(a,types) or_return
    if !material_check(view) {return {},.Corrupt}
    return view,.None
}

// The fields where a material differs from what its source gave at the last
// import, by path ("roughness", "maps.normal.texture"): those changed after
// it. None for a material no import wrote. Paths from the temp allocator.
material_overrides :: proc(types:^Types,view:Material_View,out:^[dynamic]string) {
    if view.info==nil || view.imported==nil {return}
    type,known:=types_index(types,Material_Info)
    if !known {return}
    leaves:=make([dynamic]Value_Leaf,context.temp_allocator)
    value_leaves(&types.schema,type,&leaves)
    overrides_mark(leaves[:],mem.ptr_to_bytes(view.info),mem.ptr_to_bytes(view.imported),out)
}

// The material after its source gives imported: those values, except the
// fields changed after the last import, which stay.
material_follow :: proc(types:^Types,view:Material_View,imported:Material_Info) -> (info:Material_Info) {
    info=imported
    if view.info==nil || view.imported==nil {return}
    type,_:=types_index(types,Material_Info)
    paths:=make([dynamic]string,context.temp_allocator)
    material_overrides(types,view,&paths)
    for path in paths {override_keep(&types.schema,type,mem.ptr_to_bytes(view.info),mem.ptr_to_bytes(&info),path)}
    return
}

// The material with the parts the paths name ("roughness", "coat",
// "maps.normal.texture"; none: all of it) as its source gave them at the last
// import. Invalid for a material no import wrote, or for a path that names no
// part of Material_Info: failed is that path.
material_revert :: proc(types:^Types,view:Material_View,paths:[]string) -> (info:Material_Info,failed:string,error:Error) {
    if view.info==nil || view.imported==nil {return {},"",.Invalid}
    info=view.info^
    if len(paths)==0 {return view.imported^,"",.None}
    type,known:=types_index(types,Material_Info)
    if !known {return {},"",types.error}
    for path in paths {
        if !override_keep(&types.schema,type,mem.ptr_to_bytes(view.imported),mem.ptr_to_bytes(&info),path) {return {},path,.Invalid}
    }
    return info,"",.None
}

// Names that end, kinds and components that exist, finite values, overlays
// that are there and one row per name of each.
@(private="file")
parameters_check :: proc(parameters:[]Material_Parameter,overlays:[]Material_Overlay) -> bool {
    for &parameter,at in parameters {
        name:=serial.text_field(parameter.name[:])
        if name=="" || len(name)==len(parameter.name) || parameter.kind>max(Parameter_Kind) || parameter.components<1 || parameter.components>4 {return false}
        for value in parameter.value {
            if value-value!=0 {return false}
        }
        if parameter.overlay!=0 {
            known:=false
            for overlay in overlays {known||=overlay.id==parameter.overlay}
            if !known {return false}
        }
        for other in parameters[:at] {
            if other.overlay==parameter.overlay && other.name==parameter.name {return false}
        }
    }
    return true
}

// The parameters of a material after its source gives these: each one the
// source gives, except one whose value was changed after the last import,
// which stays; those of the overlays and those a person added stay too. A
// parameter the source gave before and gives no more is gone. Rows from
// allocator; given has only parameters of the material itself (overlay 0).
material_parameters_follow :: proc(view:Material_View,given:[]Material_Parameter,allocator:=context.allocator) -> []Material_Parameter {
    find :: proc(rows:[]Material_Parameter,name:[MATERIAL_NAME_BYTES]u8) -> ^Material_Parameter {
        for &row in rows {if row.overlay==0 && row.name==name {return &row}}
        return nil
    }
    out:=make([dynamic]Material_Parameter,allocator)
    for row in given {
        current:=find(view.parameters,row.name)
        before:=find(view.imported_parameters,row.name)
        if current!=nil && before!=nil && current^!=before^ {append(&out,current^)} else {append(&out,row)}
    }
    for row in view.parameters {
        if row.overlay==0 && (find(given,row.name)!=nil || find(view.imported_parameters,row.name)!=nil) {continue}
        append(&out,row)
    }
    return out[:]
}

// Values a renderer can take as they are: finite, inside their ranges, with
// names that end and layers that exist (material_problem says what is not).
material_check :: proc(view:Material_View) -> bool {return material_problem(view)==""}

// What keeps a renderer from taking a material as it is: the first value
// that is not a number or is out of its range, with the range it takes, from
// the temp allocator; "" for a valid material.
material_problem :: proc(view:Material_View) -> string {
    m:=view.info
    if m==nil {return "the material has no values"}
    if view.imported!=nil {
        if problem:=material_problem({info=view.imported});problem!="" {return fmt.tprintf("its imported values: %s",problem)}
    }
    problem:=""
    p:=&problem
    color_number(p,"base_color",m.base_color);color_number(p,"emission",m.emission);number(p,"normal_scale",m.normal_scale)
    color_number(p,"specular_color",m.specular_color);color_number(p,"attenuation_color",m.attenuation_color)
    color_range(p,"scatter_color",m.scatter_color)
    unit_range(p,"opacity",m.opacity);unit_range(p,"alpha_cutoff",m.alpha_cutoff);unit_range(p,"metallic",m.metallic)
    unit_range(p,"roughness",m.roughness);unit_range(p,"occlusion_strength",m.occlusion_strength)
    unit_range(p,"specular_factor",m.specular_factor);unit_range(p,"transmission",m.transmission)
    at_least(p,"ior",m.ior,1);at_least(p,"thickness",m.thickness,0);at_least(p,"attenuation_distance",m.attenuation_distance,0)
    if problem=="" && m.alpha_mode>max(Alpha_Mode) {problem=fmt.tprintf("alpha_mode is %d; it takes 0 to %d",m.alpha_mode,max(Alpha_Mode))}
    if problem=="" && m.emission_mode>max(Emission_Mode) {problem=fmt.tprintf("emission_mode is %d; it takes 0 to %d",m.emission_mode,max(Emission_Mode))}
    if problem=="" && !text_valid(m.program[:]) {problem=fmt.tprintf("program is longer than %d bytes",MATERIAL_NAME_BYTES-1)}
    coat,fuzz:=&m.coat,&m.fuzz
    unit_range(p,"coat.weight",coat.weight);unit_range(p,"coat.roughness",coat.roughness);color_range(p,"coat.color",coat.color)
    at_least(p,"coat.ior",coat.ior,1);number(p,"coat.normal_scale",coat.normal_scale)
    unit_range(p,"fuzz.weight",fuzz.weight);unit_range(p,"fuzz.roughness",fuzz.roughness);color_range(p,"fuzz.color",fuzz.color)
    unit_range(p,"anisotropy.amount",m.anisotropy.amount);number(p,"anisotropy.rotation",m.anisotropy.rotation)
    transmission,subsurface:=&m.diffuse_transmission,&m.subsurface
    unit_range(p,"diffuse_transmission.weight",transmission.weight);color_range(p,"diffuse_transmission.color",transmission.color)
    unit_range(p,"subsurface.weight",subsurface.weight);color_range(p,"subsurface.color",subsurface.color)
    in_range(p,"subsurface.radius",subsurface.radius,0,MATERIAL_SUBSURFACE_RADIUS_MAX)
    if problem=="" && subsurface.weight>0 && transmission.weight>0 {
        problem="subsurface.weight and diffuse_transmission.weight are both above 0: a solid takes a subsurface, a thin surface a diffuse transmission; set one of them to 0"
    }
    maps:=material_maps(&m.maps)
    for &slot,kind in maps {
        if problem!="" {break}
        name:=fmt.tprintf("maps.%s",strings.to_lower(fmt.tprint(kind),context.temp_allocator))
        number(p,fmt.tprintf("%s.scale.x",name),slot.scale.x);number(p,fmt.tprintf("%s.scale.y",name),slot.scale.y)
        number(p,fmt.tprintf("%s.offset.x",name),slot.offset.x);number(p,fmt.tprintf("%s.offset.y",name),slot.offset.y)
        number(p,fmt.tprintf("%s.rotation",name),slot.rotation)
        if problem=="" && slot.uv_set>1 {problem=fmt.tprintf("%s.uv_set is %d; it takes 0 or 1",name,slot.uv_set)}
    }
    if problem!="" {return problem}
    if len(view.parameters)>MATERIAL_MAX_PARAMETERS*(1+MATERIAL_MAX_OVERLAYS) {return fmt.tprintf("it has %d parameters; it takes up to %d",len(view.parameters),MATERIAL_MAX_PARAMETERS*(1+MATERIAL_MAX_OVERLAYS))}
    if len(view.overlays)>MATERIAL_MAX_OVERLAYS {return fmt.tprintf("it has %d overlays; it takes up to %d",len(view.overlays),MATERIAL_MAX_OVERLAYS)}
    for overlay,at in view.overlays {
        if overlay.id==0 || overlay.blend>max(Overlay_Blend) {return fmt.tprintf("overlay %d has id %d and blend %d: an id above 0 and a blend of 0 to %d",at,overlay.id,overlay.blend,max(Overlay_Blend))}
        for other in view.overlays[:at] {
            if other.id==overlay.id {return fmt.tprintf("two overlays have the id %d",overlay.id)}
        }
    }
    if len(view.imported_parameters)>MATERIAL_MAX_PARAMETERS {return fmt.tprintf("it has %d imported parameters; it takes up to %d",len(view.imported_parameters),MATERIAL_MAX_PARAMETERS)}
    if !parameters_check(view.parameters,view.overlays) || !parameters_check(view.imported_parameters,nil) {
        return "a parameter has no name, a kind or a number of components out of range (1 to 4), a value that is not a number, an overlay the material does not have, or the name of another"
    }
    for &hidden in view.hidden {
        if name:=serial.text_field(hidden.name[:]);name=="" || len(name)==len(hidden.name) {return fmt.tprintf("a hidden name is empty or longer than %d bytes",MATERIAL_NAME_BYTES-1)}
    }
    return ""
}

// The first problem of the values a material_problem reads: each writes its
// own only while there is none before it.
@(private="file")
in_range :: proc(problem:^string,name:string,value,low,high:f32) {
    if problem^!="" || value>=low && value<=high {return}
    problem^=fmt.tprintf("%s is %v; it takes %v to %v",name,value,low,high)
}
@(private="file")
unit_range :: proc(problem:^string,name:string,value:f32) {in_range(problem,name,value,0,1)}
@(private="file")
at_least :: proc(problem:^string,name:string,value,low:f32) {
    if problem^!="" || value>=low && finite(value) {return}
    problem^=fmt.tprintf("%s is %v; it takes a number of %v or more",name,value,low)
}
@(private="file")
number :: proc(problem:^string,name:string,value:f32) {
    if problem^!="" || finite(value) {return}
    problem^=fmt.tprintf("%s is %v; it takes a finite number",name,value)
}
@(private="file")
color_number :: proc(problem:^string,name:string,color:[3]f32) {
    channels:=[3]rune{'r','g','b'}
    for value,i in color {number(problem,fmt.tprintf("%s.%c",name,channels[i]),value)}
}
@(private="file")
color_range :: proc(problem:^string,name:string,color:[3]f32) {
    channels:=[3]rune{'r','g','b'}
    for value,i in color {unit_range(problem,fmt.tprintf("%s.%c",name,channels[i]),value)}
}
