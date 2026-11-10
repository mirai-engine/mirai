package host

import "mirai:asset"
import "mirai:std/base"

// The texts of the game (base.Texts): every .strings of the assets as one
// table, loaded the first time something asks for a text and again once one
// of the files changes, on disk or in memory, appears or goes. One table for
// the whole application, outside the World, as the rows of the records. A
// key two files have keeps the texts of the first; a .strings that does not
// load is left out.
App_Texts :: struct {
    set:base.Texts,
    retired:base.Texts, // of the load before: what a frame already took of it lasts until the next load
    stamp:u64,    // of the files it was loaded from: their ids and content hashes
    revision:u64, // of the registry when the stamp was last compared
    loaded:bool,
}

// The texts of the assets, brought up to date; nil without assets.
app_texts :: proc(app:^App) -> ^base.Texts {
    if app==nil || app.assets==nil {return nil}
    t,registry:=&app.texts,&app.assets.registry
    if t.loaded && t.revision==registry.revision {return &t.set}
    t.revision=registry.revision
    stamp:=u64(1)
    for &file in registry.files {
        if file.kind==asset.KIND_STRINGS && file.id!={} {stamp=base.hash_combine(stamp,base.hash_combine(base.hash_combine(file.id[0],file.id[1]),file.content_hash))}
    }
    if (!t.loaded || t.stamp!=stamp) && texts_load(app) {t.stamp,t.loaded=stamp,true}
    return &t.set
}

app_texts_destroy :: proc(app:^App) {
    for set in ([2]base.Texts{app.texts.set,app.texts.retired}) {
        delete(set.slots,app.allocator);delete(set.text,app.allocator)
    }
    app.texts={}
}

// Loads every .strings into a new table, which replaces the one it had only
// once it is whole.
@(private="file")
texts_load :: proc(app:^App) -> bool {
    a:=app.assets
    files:=make([dynamic]asset.Asset,context.temp_allocator)
    defer for &file in files {asset.asset_close(&file)}
    views:=make([dynamic]asset.Strings_View,context.temp_allocator)
    entries,bytes:=0,0
    for &record in a.registry.files {
        if record.kind!=asset.KIND_STRINGS || record.id=={} {continue}
        data,error:=asset.registry_read(&a.registry,record.path,a.allocator)
        file:asset.Asset
        if error!=.None || asset.asset_take(&file,data,a.allocator)!=.None {continue}
        append(&files,file)
        view,read:=asset.strings_view(&files[len(files)-1],&a.types)
        if read!=.None {continue}
        append(&views,view)
        entries+=len(view.entries)+len(view.keys)
        bytes+=len(view.text)
    }
    count:=1
    for count<entries*2 {count*=2}
    slots,slots_error:=make([]base.Text_Slot,count,app.allocator)
    text,text_error:=make([]u8,bytes,app.allocator)
    if slots_error!=nil || text_error!=nil {
        delete(slots,app.allocator);delete(text,app.allocator)
        return false
    }
    put :: proc(slots:[]base.Text_Slot,slot:base.Text_Slot) -> bool {
        mask:=u64(len(slots)-1)
        at:=base.text_slot(slot.language,slot.key)&mask
        for ;slots[at].key!=0;at=(at+1)&mask {
            if slots[at].language==slot.language && slots[at].key==slot.key {return false}
        }
        slots[at]=slot
        return true
    }
    at:=0
    for view in views {
        copy(text[at:],view.text)
        key,taken:=-1,false
        for e in view.entries {
            slot:=base.Text_Slot{key=base.name_hash(base.text_get(view.keys[e.key].name[:])),offset=u32(at)+e.offset,length=e.length}
            // The first entry of a key is its text in the language it was written in.
            if int(e.key)!=key {key,taken=int(e.key),!put(slots,slot)}
            if taken {continue}
            slot.language=base.name_hash(base.text_get(view.languages[e.language].code[:]))
            put(slots,slot)
        }
        at+=len(view.text)
    }
    t:=&app.texts
    delete(t.retired.slots,app.allocator);delete(t.retired.text,app.allocator)
    t.retired=t.set
    t.set={slots=slots,text=text,generation=t.retired.generation+1}
    return true
}
