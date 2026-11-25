package asset

import "core:fmt"
import "mirai:std/base"

// Whether an asset holds what its kind allows: its hash, chunks that decode,
// tables that agree with each other, the dependencies its values name and,
// of a kind the engine defines, its version and the rules of the kind, as
// rows of one table that name rows of another. "" when it does, else why not,
// in temp memory. path: the file of the asset, where the source of one of a
// version this build does not read is looked for; "" for one in memory, which
// looks for nothing. A value against the limits of its schema is the caller's
// to check, on the columns this leaves decoded.
verify :: proc(a:^Asset,types:^Types,path:string) -> string {
    if !blob_verify_hash(&a.blob) {return error_text(.Hash)}
    for &table in a.tables {
        for _,column in table.columns {
            if _,error:=asset_column_data(a,&table,column);error!=.None {return fmt.tprintf("table %s: a chunk cannot be decompressed",table.name)}
        }
    }
    doc:Document
    if error:=document_from_asset(&doc,a);error!=.None {return error_text(error)}
    defer document_destroy(&doc)
    if document_check(&doc)!=.None {return "the tables contradict each other"}
    derived:[dynamic]base.Asset_Id
    defer delete(derived)
    if document_dependencies(&doc,&derived)!=.None {return "a row has too many references"}
    same:=len(derived)==len(a.dependencies)
    for id,at in derived {same&&=at<len(a.dependencies) && a.dependencies[at]==id}
    if !same {return "the stored dependencies are not the ones its values name"}
    if known,found:=kind_info(a.blob.header.kind);found && known.version!=0 && a.blob.header.kind_version!=known.version {
        return path=="" ? error_text(.Version) : version_message(a,types,path,allocator=context.temp_allocator)
    }
    switch a.blob.header.kind {
    case KIND_MESH:
        view,error:=mesh_view(a,types)
        if error!=.None {return "mesh: counts or ranges outside their tables"}
        if !mesh_check_indices(view) {return "mesh: an index, slot, weight or position out of range"}
    case KIND_TEXTURE:
        if _,error:=texture_view(a,types);error!=.None {return "texture: inconsistent size, format, layers or levels"}
    case KIND_MATERIAL:
        if _,error:=material_view(a,types);error!=.None {return "material: a value out of range or an invalid name"}
    case KIND_SCENE:
        view,error:=scene_view(a,types)
        if error!=.None {return "scene: a component table names rows that do not exist or are out of order"}
        if scene_view_check(view)!=.None {return "scene: repeated ids, missing or cyclic parents, or prefab records without an entity"}
        roots:=0
        for parent in view.parents {roots+=int(parent==0)}
        if asset_prefab(a) && roots!=1 {return fmt.tprintf("scene: a prefab with %d roots: put its entities under one in the editor, or make it a scene there",roots)}
    case KIND_ANIMATION:
        if _,error:=animation_view(a,types);error!=.None {return "animation: an invalid range, key or name"}
    case KIND_SKELETON:
        if _,error:=skeleton_view(a,types);error!=.None {return "skeleton: an invalid hierarchy, transform or bone reference"}
    case KIND_SOUND:
        if _,error:=sound_view(a,types);error!=.None {return "sound: inconsistent channels, sample rate, loop start, lossless data or file"}
    case KIND_UI:
        if !ui_check(a,types) {return "interface: nodes out of preorder or without a box, or a style, image, animation, track or key that does not exist"}
    case KIND_FONT:
        if _,error:=font_view(a,types);error!=.None {return "font: the file is not a TrueType or OpenType font with the outlines it declares"}
    case KIND_STRINGS:
        if _,error:=strings_view(a,types);error!=.None {return "strings: an empty or repeated language or key, or an entry out of order, repeated, or outside the text or the UTF-8"}
    case KIND_PROMPTS:
        if _,error:=prompts_view(a,types);error!=.None {return "prompts: a family or an entry that does not exist, a key too many or too few, a part outside its texture, or a repeated entry"}
    case KIND_RECORDS:
        if _,error:=records_view(a,types);error!=.None {return "records: no type of rows, columns that are not valid (a name that is not a word or is there twice, options that do not fit its kind) or that a table of rows of another's type has, no defaults, a row with the id 0, a repeated id or name, or a name that is not a word"}
    }
    return ""
}

// What an Error means, for a message.
error_text :: proc(error:Error) -> string {
    switch error {
    case .None: return "no error"
    case .Truncated: return "the file is truncated"
    case .Not_An_Asset: return "not a Mirai asset"
    case .Version: return "a container or kind version this build does not read"
    case .Corrupt: return "the directory, a chunk or a table contradict each other"
    case .Hash: return "the content does not match its hash"
    case .Too_Large: return "needs more memory than the limit"
    case .Schema: return "the schema table is not valid"
    case .Codec_Missing: return "it uses an unsupported compression format: regenerate it with this version of Mirai"
    case .Out_Of_Memory: return "out of memory"
    case .Not_Found: return "does not exist"
    case .IO: return "could not be read or written"
    case .Invalid: return "contains something the format does not allow"
    case .Not_Here: return "a part of it is not in the store yet: fetch it from a peer that has it, or build it again"
    }
    return "unknown error"
}
