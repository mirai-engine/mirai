package importer

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:cook/textures"
import "mirai:std/base"

// How a source becomes assets. The settings of a source are kept in its
// sidecar (sidecar.odin), so importing it again gives the same assets whoever
// does it: an import reads them when the sidecar exists and uses them instead
// of those of its options. The zero value is the default of every setting.

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

// Of a model: where it stands facing once its space is the engine's, which
// has every model face -Z. The import turns it about +Y from there to -Z,
// with all the file holds.
Front :: enum u8 {
    Auto,       // a file that is a rig (all it draws is skinned) is turned from where the body of its skeleton is found facing; any other stays as read
    Negative_Z, // as read: nothing is turned, whatever a body is found facing
    Z,
    X,
    Negative_X,
}

// The front an import option names: its name in lowercase.
front_from_name :: proc(name:string) -> (front:Front,ok:bool) {
    for f in Front {
        if strings.equal_fold(fmt.tprint(f),name) {return f,true}
    }
    return
}

// The rig an import option names: its name in lowercase.
rig_from_name :: proc(name:string) -> (rig:Rig,ok:bool) {
    for r in Rig {
        if strings.equal_fold(fmt.tprint(r),name) {return r,true}
    }
    return
}

Import_Settings :: struct {
    textures:textures.Encoding, // .Blocks: BC1, BC3, BC5, BC6H or BC7 by the use of each image; .Uncompressed: RGBA8, RGBA16 or RGBA16F by what it holds
    rdo_lambda:int,             // of textures in blocks, up to textures.RDO_LAMBDA_MAX: how much error their rate-distortion optimization trades for files that compress smaller. 0: textures.RDO_LAMBDA_DEFAULT; below 0: none
    image:Image_Use,            // of an image imported on its own
    alpha_coverage:f32,         // of an image imported on its own, above 0: the cutoff of the masked material that shows it, whose coverage every level keeps
    lods:Lods,
    parts:Parts,                // of a model: which of its materials and textures are parts of its prefab (parts.odin)
    front:Front,
    rig:Rig,
    rig_crotch,rig_neck:f32,    // of a Humanoid rig, above 0: the heights in meters in the model of the crotch and the neck, in place of where the fit finds them
    skeleton:base.Asset_Id,     // of a model, not zero: its clips play on this skeleton the project has (with the same bones), and the import writes only its .anim, bound to it: no textures, materials, skeletons, meshes or prefab
}

// What an asset records in Import_Info.settings_hash is the identity of the
// settings it is built from, and nothing else: a change of the others keeps
// it. A mesh is built from its levels, turned from the front the settings
// state (mesh_settings_hash); a texture from its build options
// (textures.settings_hash); materials, skeletons and clips from none of them,
// and record 0. A rig other than the source's changes the skin of a mesh, so
// it is part of the mesh's.
mesh_settings_hash :: proc(settings:Import_Settings) -> u64 {
    built:=[5]u64{u64(settings.lods),u64(settings.front),u64(settings.rig),u64(transmute(u32)settings.rig_crotch),u64(transmute(u32)settings.rig_neck)}
    return base.hash64(mem.slice_to_bytes(built[:2] if settings.rig==.Source else built[:]))
}
