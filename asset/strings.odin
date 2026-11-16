package asset

import "core:unicode/utf8"
import "mirai:std/base"
import "mirai:std/serial"

// .strings: the texts of a game in its languages, by key.
//
//   languages  String_Language: a language by its code ("es", "en", "pt-BR")
//   keys       String_Key: a text by its name
//   entries    String_Entry: the text of a key in a language, ordered by key and language
//   text       bulk   u8: the texts, UTF-8, one after the other
//
// A key has at most one entry per language; one it lacks has none.

STRINGS_VERSION :: 1

String_Language :: struct {
    code:[16]u8 `mirai:"text"`,
}
String_Key :: struct {
    name:[64]u8 `mirai:"text"`,
}
String_Entry :: struct {
    key,language:u32, // rows of keys and of languages
    offset,length:u32, // bytes of text
}

Strings_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id,
    languages:[]String_Language,
    keys:[]String_Key,
    entries:[]String_Entry,
    text:[]u8,
    source:^Import_Info,
}

Strings_View :: struct {
    languages:[]String_Language,
    keys:[]String_Key,
    entries:[]String_Entry,
    text:[]u8,
    source:^Import_Info,
}

strings_document :: proc(doc:^Document,types:^Types,desc:Strings_Desc,allocator:=context.allocator) -> Error {
    if !strings_check({languages=desc.languages,keys=desc.keys,entries=desc.entries,text=desc.text}) {return .Invalid}
    document_init(doc,KIND_STRINGS,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=STRINGS_VERSION
    error:=strings_tables(doc,types,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
strings_tables :: proc(doc:^Document,types:^Types,desc:Strings_Desc) -> Error {
    document_put(doc,types,"languages",desc.languages) or_return
    document_put(doc,types,"keys",desc.keys,{},.Stream) or_return
    document_put(doc,types,"entries",desc.entries,{},.Stream) or_return
    document_put(doc,types,"text",desc.text,{.Bulk},.Stream) or_return
    return import_put(doc,types,desc.source)
}

strings_save :: proc(path:string,types:^Types,desc:Strings_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    strings_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

strings_bytes :: proc(types:^Types,desc:Strings_Desc,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    doc:Document
    strings_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_bytes(&doc,allocator)
}

strings_view :: proc(a:^Asset,types:^Types) -> (view:Strings_View,error:Error) {
    kind_check(a,KIND_STRINGS,STRINGS_VERSION) or_return
    view.languages=table_rows(a,types,"languages",String_Language) or_return
    view.keys=table_rows(a,types,"keys",String_Key) or_return
    view.entries=table_rows(a,types,"entries",String_Entry) or_return
    view.text=table_rows(a,types,"text",u8) or_return
    view.source=import_info(a,types) or_return
    if !strings_check(view) {return {},.Corrupt}
    return view,.None
}

// Whether codes and names are terminated, not empty and not repeated, and
// every entry names a key and a language, in order and once, with a range of
// UTF-8 inside the text.
strings_check :: proc(view:Strings_View) -> bool {
    named :: proc(field:[]u8) -> (string,bool) {
        text:=serial.text_field(field)
        return text,text!="" && len(text)<len(field) && utf8.valid_string(text)
    }
    seen:=make(map[string]bool,len(view.languages)+len(view.keys),context.temp_allocator)
    for &language in view.languages {
        code,ok:=named(language.code[:])
        if !ok || seen[code] {return false}
        seen[code]=true
    }
    clear(&seen)
    for &key in view.keys {
        name,ok:=named(key.name[:])
        if !ok || seen[name] {return false}
        seen[name]=true
    }
    for entry,at in view.entries {
        if int(entry.key)>=len(view.keys) || int(entry.language)>=len(view.languages) {return false}
        if u64(entry.offset)+u64(entry.length)>u64(len(view.text)) {return false}
        if !utf8.valid_string(string(view.text[entry.offset:][:entry.length])) {return false}
        if at>0 {
            previous:=view.entries[at-1]
            if previous.key>entry.key || previous.key==entry.key && previous.language>=entry.language {return false}
        }
    }
    return true
}
