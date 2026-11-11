package asset

import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// .mat: the values of a material. The standard model is OpenPBR's: a
// metallic-roughness base, as in glTF 2.0, with glass, and the layers a
// material may add over it (coat, fuzz, specular anisotropy, diffuse
// transmission) or no light at all (unlit). A material may instead name a Surface program and carry the
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

MATERIAL_VERSION :: 2
MATERIAL_MAX_PARAMETERS :: 32
MATERIAL_MAX_OVERLAYS :: 4
MATERIAL_NAME_BYTES :: 64

Alpha_Mode :: enum u8 {
    Opaque, // the alpha of the material is ignored
    Mask,   // points whose alpha is below alpha_cutoff are holes, for the camera and for rays
    Blend,  // drawn over the scene after it is lit
}

// One map of a material: its texture and how it reads the UVs.
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
}

// The maps of Material_Maps by kind, in the order of its fields.
Material_Map_Kind :: enum u8 {
    Base_Color,Metallic_Roughness,Normal,Emission,Occlusion,Specular,Specular_Color,
    Coat,Coat_Roughness,Coat_Normal,Fuzz_Color,Fuzz_Roughness,Anisotropy,
    Diffuse_Transmission,Diffuse_Transmission_Color,
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
Material_Layer :: enum u8 {Coat,Fuzz,Anisotropy,Unlit,Diffuse_Transmission}
Material_Layers :: bit_set[Material_Layer;u32]

material_layers :: proc "contextless" (m:^Material_Info) -> (layers:Material_Layers) {
    if m.unlit {return {.Unlit}}
    if m.coat.weight>0 {layers+={.Coat}}
    if m.fuzz.weight>0 {layers+={.Fuzz}}
    if m.anisotropy.amount>0 {layers+={.Anisotropy}}
    if m.diffuse_transmission.weight>0 {layers+={.Diffuse_Transmission}}
    return
}

Material_Info :: struct {
    base_color:[3]f32 `mirai:"color"`,
    opacity:f32 `mirai:"min=0,max=1"`,
    alpha_mode:Alpha_Mode,
    alpha_cutoff:f32 `mirai:"min=0,max=1"`,
    metallic:f32 `mirai:"min=0,max=1"`,
    roughness:f32 `mirai:"min=0,max=1"`,
    emission:[3]f32 `mirai:"color"`, // by emission_mode: luminance in nits, or the exposed value
    emission_mode:Emission_Mode,
    normal_scale:f32,
    occlusion_strength:f32 `mirai:"min=0,max=1"`,
    uv_scale:[2]f32,
    uv_offset:[2]f32,
    specular_factor:f32 `mirai:"min=0,max=1"`,
    specular_color:[3]f32 `mirai:"color"`,
    // Glass: KHR_materials_transmission, _ior and _volume.
    transmission:f32 `mirai:"min=0,max=1"`,
    ior:f32,                             // 0, a constant reflector, or 1 and above
    thickness:f32 `mirai:"min=0,unit=m"`, // 0: a sheet; above: the mesh bounds a solid about this deep
    attenuation_color:[3]f32 `mirai:"color"`,
    attenuation_distance:f32 `mirai:"min=0,unit=m"`,
    scatter_color:[3]f32 `mirai:"color"`, // of what a solid stops, the share it scatters towards the eye, lit by what reaches it inside (KHR_materials_volume_scatter)
    coat:Material_Coat,
    fuzz:Material_Fuzz,
    anisotropy:Material_Anisotropy,
    diffuse_transmission:Material_Diffuse_Transmission,
    unlit:bool, // it reflects no light and shows its emission alone; base color and opacity still cover
    maps:Material_Maps,
    program:[MATERIAL_NAME_BYTES]u8 `mirai:"text"`, // "" is the standard model
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
    base_color={1,1,1},opacity=1,alpha_cutoff=0.5,roughness=1,normal_scale=1,occlusion_strength=1,uv_scale={1,1},
    specular_factor=1,specular_color={1,1,1},ior=1.5,attenuation_color={1,1,1},
    coat={color={1,1,1},ior=1.6,normal_scale=1},fuzz={color={1,1,1},roughness=0.5},diffuse_transmission={color={1,1,1}},
    maps={
        MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,
        MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,
        MATERIAL_MAP_DEFAULT,MATERIAL_MAP_DEFAULT,
    },
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

@(private="file")
unit :: proc "contextless" (value:f32) -> bool {return value>=0 && value<=1}

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
// names that end and layers that exist.
material_check :: proc(view:Material_View) -> bool {
    m:=view.info
    if m==nil || view.imported!=nil && !material_check({info=view.imported}) {return false}
    if !finite(m.base_color.r,m.base_color.g,m.base_color.b,m.emission.r,m.emission.g,m.emission.b,m.normal_scale,m.uv_scale.x,m.uv_scale.y,m.uv_offset.x,m.uv_offset.y) {return false}
    if !finite(m.specular_color.r,m.specular_color.g,m.specular_color.b,m.attenuation_color.r,m.attenuation_color.g,m.attenuation_color.b,m.thickness,m.attenuation_distance,m.ior) {return false}
    if !unit(m.scatter_color.r) || !unit(m.scatter_color.g) || !unit(m.scatter_color.b) {return false}
    if !unit(m.opacity) || !unit(m.alpha_cutoff) || !unit(m.metallic) || !unit(m.roughness) || !unit(m.occlusion_strength) || !unit(m.specular_factor) || !unit(m.transmission) {return false}
    if m.alpha_mode>max(Alpha_Mode) || m.emission_mode>max(Emission_Mode) || m.ior!=0 && m.ior<1 || m.thickness<0 || m.attenuation_distance<0 || !text_valid(m.program[:]) {return false}
    coat,fuzz:=&m.coat,&m.fuzz
    if !unit(coat.weight) || !unit(coat.roughness) || !unit(coat.color.r) || !unit(coat.color.g) || !unit(coat.color.b) || !(coat.ior>=1) || !finite(coat.ior,coat.normal_scale) {return false}
    if !unit(fuzz.weight) || !unit(fuzz.roughness) || !unit(fuzz.color.r) || !unit(fuzz.color.g) || !unit(fuzz.color.b) {return false}
    if !unit(m.anisotropy.amount) || !finite(m.anisotropy.rotation) {return false}
    transmission:=&m.diffuse_transmission
    if !unit(transmission.weight) || !unit(transmission.color.r) || !unit(transmission.color.g) || !unit(transmission.color.b) {return false}
    maps:=material_maps(&m.maps)
    for slot in maps {
        if !finite(slot.scale.x,slot.scale.y,slot.offset.x,slot.offset.y,slot.rotation) || slot.uv_set>1 {return false}
    }
    if len(view.parameters)>MATERIAL_MAX_PARAMETERS*(1+MATERIAL_MAX_OVERLAYS) || len(view.overlays)>MATERIAL_MAX_OVERLAYS {return false}
    for overlay,at in view.overlays {
        if overlay.id==0 || overlay.blend>max(Overlay_Blend) {return false}
        for other in view.overlays[:at] {
            if other.id==overlay.id {return false}
        }
    }
    if len(view.imported_parameters)>MATERIAL_MAX_PARAMETERS || !parameters_check(view.parameters,view.overlays) || !parameters_check(view.imported_parameters,nil) {return false}
    for &hidden in view.hidden {
        if name:=serial.text_field(hidden.name[:]);name=="" || len(name)==len(hidden.name) {return false}
    }
    return true
}
