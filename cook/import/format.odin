package importer

import "core:strings"

// A format of source files is a package of its own that declares a Format
// and knows nothing of the others: cook/import/obj, gltf, usd. The table of
// the formats of the engine is cook/import/sources.FORMATS; adding one is a
// package and a line there. A plugin adds its own in the editor
// (editor.Import_Format_Provider).

SNIFF_BYTES :: 4096
FORMAT_EXTENSIONS :: 4

Sniff :: enum u8 {
    No,        // the bytes are not of this format
    Extension, // nothing in them says so and nothing says otherwise: the extension decides
    Content,   // the bytes are of this format, whatever the name of the file
}

Format :: struct {
    name:string,         // "glTF": in messages and errors
    // Lower case, with the dot, "" after the last: what the file dialogs offer
    // and what decides an Extension sniff. An array, not a slice: a Format is
    // a constant that is copied, and the copy keeps its extensions.
    extensions:[FORMAT_EXTENSIONS]string,
    version:u16,         // of what read gives for the same bytes: raise it when that changes, and assets of an older one are imported again
    space:Source_Space,  // of its files, unless read states another with source_space
    sniff:proc(head:[]u8) -> Sniff, // head: up to SNIFF_BYTES from the start of the file
    read:proc(r:^Reader,bytes:[]u8) -> bool,
    data:rawptr,         // given to read as Reader.data: the options of the format, nil for its defaults
    folder:proc(path:string) -> string, // the folder beside a file of it its assets go to; nil: its stem
}

// The format of a file: the first whose sniff recognizes its content, or else
// the first that cannot tell and lists its extension.
format_find :: proc(formats:[]Format,head:[]u8,extension:string) -> (format:^Format,found:bool) {
    head:=head[:min(len(head),SNIFF_BYTES)]
    extension:=strings.to_lower(extension,context.temp_allocator)
    for &candidate in formats {
        if candidate.sniff(head)==.Content {return &candidate,true}
    }
    for &candidate in formats {
        listed:=false
        for known in candidate.extensions {listed||=known!="" && known==extension}
        if listed && candidate.sniff(head)==.Extension {return &candidate,true}
    }
    return nil,false
}

// "OBJ, glTF and USD": the names of the formats, for a message.
format_names :: proc(formats:[]Format,allocator:=context.temp_allocator) -> string {
    b:=strings.builder_make(allocator)
    for format,i in formats {
        if i>0 {strings.write_string(&b,i==len(formats)-1?" and ":", ")}
        strings.write_string(&b,format.name)
    }
    return strings.to_string(b)
}
