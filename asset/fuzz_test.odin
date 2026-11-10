package asset

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

// What the commands of `mirai asset` do with a file, on files that are cut or
// changed: read it as a document, write it as text, find values by path and
// set them, compare it with the file it came from, write it again and look at
// it as its kind. Every attempt ends in an answer: never a crash and never a
// leak (the runner checks the memory). The seeds are assets of every kind
// the engine defines, the interfaces, animations and sounds of the demo among
// them.

@(private="file") DEMO :: #directory+"/../demo/assets/"

@(private="file")
Fuzz :: struct {
    types:^Types,
    seed:Document,
    read,refused,located,set,written,viewed:int,
}

// A value of text for a location, by its type: what set would be given.
@(private="file")
fuzz_value :: proc(doc:^Document,location:Location) -> string {
    if location.type==serial.TYPE_NONE {return "0"}
    #partial switch serial.schema_type(&doc.schema,location.type).kind {
    case .Bool: return "true"
    case .Float: return "0.25"
    case .Enum,.Bit_Set,.Struct,.Array: return ""
    }
    return "1"
}

@(private="file")
fuzz_attempt :: proc(f:^Fuzz,data:[]u8) {
    doc:Document
    if document_read(&doc,data)!=.None {
        f.refused+=1
        return
    }
    defer document_destroy(&doc)
    f.read+=1
    w:serial.Writer
    serial.writer_init(&w)
    defer serial.writer_destroy(&w)
    // dump, and unpack without its files
    document_text_write(&doc,&w,{schema=true})
    serial.writer_reset(&w)
    // get and set: the table, its first row, and every field of the first row of its first column
    for table,at in doc.tables {
        if at>=8 {break}
        paths:[3]string={table.name,fmt.tprintf("%s[0]",table.name),""}
        if len(table.columns)>0 && table.columns[0].type!=serial.TYPE_NONE {
            type:=serial.schema_type(&doc.schema,table.columns[0].type)
            if type.kind==.Struct && type.count>0 {
                field:=serial.schema_fields(&doc.schema,table.columns[0].type)[0]
                paths[2]=fmt.tprintf("%s[0].%s",table.name,field.name)
            }
        }
        for path in paths {
            if path=="" {continue}
            location,error:=document_locate(&doc,path)
            if error!=.None {continue}
            f.located+=1
            if location.row<0 || location.column<0 || location.bit>=0 {continue}
            text:=fuzz_value(&doc,location)
            if text=="" {continue}
            reader:serial.Text_Reader
            serial.text_reader_init(&reader,text,context.temp_allocator)
            if serial.text_read(&reader,&doc.schema,location.type,location.bytes,location.is_text) {f.set+=1}
            serial.text_reader_destroy(&reader)
        }
    }
    // diff, both ways
    _,_=document_diff(&f.seed,&doc,&w)
    serial.writer_reset(&w)
    _,_=document_diff(&doc,&f.seed,&w)
    serial.writer_reset(&w)
    // set writes the file again, and what it wrote is read as its kind: verify
    if document_write(&doc,&w)!=.None {return}
    f.written+=1
    a:Asset
    if asset_open(&a,serial.writer_bytes(&w))!=.None {return}
    defer asset_close(&a)
    f.viewed+=1
    switch a.blob.header.kind {
    case KIND_MESH:
        if view,error:=mesh_view(&a,f.types);error==.None {mesh_check_indices(view)}
    case KIND_TEXTURE:  texture_view(&a,f.types)
    case KIND_MATERIAL: material_view(&a,f.types)
    case KIND_SCENE,KIND_PREFAB:
        if view,error:=scene_view(&a,f.types);error==.None {_=scene_view_check(view)}
    case KIND_ANIMATION: animation_view(&a,f.types)
    case KIND_SKELETON:  skeleton_view(&a,f.types)
    case KIND_SOUND:     sound_view(&a,f.types)
    case KIND_SOUND_SET: sound_set_view(&a,f.types)
    case KIND_UI:        ui_check(&a,f.types)
    case KIND_FONT:      font_view(&a,f.types)
    case KIND_STRINGS:   strings_view(&a,f.types)
    case KIND_PROMPTS:   prompts_view(&a,f.types)
    case KIND_RECORDS:
        if view,error:=records_view(&a,f.types);error==.None {
            dst:=make([]u8,len(view.ids)*size_of(Fuzz_Row),context.temp_allocator)
            records_values(&a,view,&f.types.schema,fuzz_row_type(f.types),dst)
        }
    }
}

// The row of the table the fuzzing reads: another layout than the one written, so it migrates.
@(private="file")
Fuzz_Row :: struct {weight:f32,damage:f32,prefab:base.Asset_Id}

@(private="file")
fuzz_row_type :: proc(types:^Types) -> serial.Type_Index {
    index,_:=types_index(types,Fuzz_Row)
    return index
}

@(test)
damaged_tables_of_game_data_go_through_every_command :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    folder:=base.test_folder(t,"fuzz-records")
    Written :: struct {damage:f32,rarity:u8,prefab:base.Asset_Id}
    values:=[2]Written{{damage=10,rarity=2,prefab={5,6}},{damage=25}}
    index,_:=types_index(&types,Written)
    names:=[2]Records_Name{}
    text_set(names[0][:],"iron_sword");text_set(names[1][:],"bow")
    texts:=[2]Records_Text{{text=3,offset=0,length=5},{text=3,offset=5,length=6}}
    text_set(texts[1].language[:],"es")
    bytes,error:=records_bytes(&types,{id={0x7a,1},type="game.Weapon",ids={11,12},names=names[:],schema=&types.schema,value_type=index,images=mem.slice_to_bytes(values[:]),texts=texts[:],text=transmute([]u8)string("SwordEspada")},context.temp_allocator)
    testing.expect_value(t,error,Error.None)
    path:=fmt.aprintf("%s/weapons.records",folder);defer delete(path)
    testing.expect(t,os.write_entire_file(path,bytes)==nil)
    fuzz_file(t,&types,path,800)
}

// Cuts the file at lengths spread over it and changes bytes spread over it.
@(private="file")
fuzz_file :: proc(t:^testing.T,types:^Types,path:string,attempts:=2000) {
    good,read_error:=serial.file_read(path)
    if !testing.expectf(t,read_error==.None,"%s cannot be read",path) {return}
    defer delete(good)
    f:=Fuzz{types=types}
    if !testing.expect_value(t,document_read(&f.seed,good),Error.None) {return}
    defer document_destroy(&f.seed)
    fuzz_attempt(&f,good)
    testing.expectf(t,f.read==1 && f.written==1 && f.viewed==1 && f.located>0,"%s: the file as it is goes through every command",path)
    step:=max(len(good)/attempts,1)
    for cut:=0;cut<len(good);cut+=step {fuzz_attempt(&f,good[:cut])}
    work:=make([]u8,len(good))
    defer delete(work)
    state:=u64(0x9e3779b97f4a7c15)
    for round in 0..<attempts {
        copy(work,good)
        // Half the rounds change the head, where the directory and the schema are.
        span:=round%2==0?min(len(good),2048):len(good)
        for _ in 0..<1+round%3 {
            state=state*6364136223846793005+1442695040888963407
            at:=int((state>>33)%u64(span))
            work[at]=round%5==0?0:u8(state>>24)
        }
        fuzz_attempt(&f,work)
        free_all(context.temp_allocator)
    }
    testing.expectf(t,f.refused>0 && f.read>1,"%s: some of the damaged files are read and some refused (%d read, %d refused)",path,f.read,f.refused)
}

@(test)
damaged_interfaces_animations_and_sounds_go_through_every_command :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    for file in ([]string{"showcase/hud.ui","showcase/sign.ui","showcase/lift.anim","showcase/hum.sound"}) {
        fuzz_file(t,&types,strings.concatenate({DEMO,file},context.temp_allocator))
    }
}

@(test)
damaged_fonts_texts_and_prompts_go_through_every_command :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    // The paths outlive the temp allocator, which fuzz_file frees.
    folder:=base.test_folder(t,"fuzz-interface")
    font:=fmt.aprintf("%s/face.font",folder);defer delete(font)
    testing.expect_value(t,font_save(font,&types,{id={0xf0,1},file=#load("../assets/fixtures/cff.otf"),compression=.LZ}),Error.None)
    languages:=[2]String_Language{};text_set(languages[0].code[:],"es");text_set(languages[1].code[:],"en")
    keys:=[2]String_Key{};text_set(keys[0].name[:],"menu.play");text_set(keys[1].name[:],"menu.quit")
    entries:=[3]String_Entry{{0,0,0,5},{0,1,5,4},{1,0,9,5}}
    texts:=fmt.aprintf("%s/menu.strings",folder);defer delete(texts)
    testing.expect_value(t,strings_save(texts,&types,{id={0x57,1},languages=languages[:],keys=keys[:],entries=entries[:],text=transmute([]u8)string("JugarPlaySalir")}),Error.None)
    for file in ([]string{font,texts,#directory+"/../plugins/prompts_kenney/assets/kenney.prompts"}) {fuzz_file(t,&types,file,800)}
}

@(test)
damaged_meshes_textures_materials_scenes_and_prefabs_go_through_every_command :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    for file in ([]string{"gallery/plant.gltf/Plant.mesh","gallery/plant.gltf/Leaves.mat","showcase/hud_badge.tex","showcase/showcase.scene","gallery/vase.obj/vase.prefab"}) {
        fuzz_file(t,&types,strings.concatenate({DEMO,file},context.temp_allocator),1200)
    }
}

// pack: the text of an unpacked asset, cut and changed, is read or refused.
// Its bulk columns come from the files an unpack writes next to it.
@(test)
damaged_text_of_an_asset_is_packed_or_refused :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    for file in ([]string{"showcase/hud.ui","showcase/lift.anim","gallery/plant.gltf/Leaves.mat","gallery/vase.obj/vase.prefab"}) {
        path:=strings.concatenate({DEMO,file},context.temp_allocator)
        seed:Document
        if !testing.expect_value(t,document_load(&seed,path),Error.None) {continue}
        w:serial.Writer
        serial.writer_init(&w)
        testing.expect_value(t,document_text_write(&seed,&w,{schema=true,bulk=.Files}),Error.None)
        text:=strings.clone(string(serial.writer_bytes(&w)))
        serial.writer_destroy(&w)
        defer document_destroy(&seed)
        loader:=Bulk_Loader{user=&seed,procedure=proc(user:rawptr,name:string,allocator:mem.Allocator) -> ([]u8,bool) {
            seed:=(^Document)(user)
            for table in seed.tables {
                for column in table.columns {
                    if bulk_file_name(table.name,column.name)==name {
                        data,error:=slice.clone(column.data[:],allocator)
                        return data,error==nil
                    }
                }
            }
            return nil,false
        }}
        packed,refused:=0,0
        attempt :: proc(text:string,loader:Bulk_Loader,packed,refused:^int) {
            doc:Document
            if _,ok:=document_text_read(&doc,text,loader);ok {
                out:serial.Writer
                serial.writer_init(&out)
                document_write(&doc,&out)
                serial.writer_destroy(&out)
                document_destroy(&doc)
                packed^+=1
            } else {
                refused^+=1
            }
        }
        attempt(text,loader,&packed,&refused)
        testing.expectf(t,packed==1,"%s: its text is packed again",file)
        step:=max(len(text)/300,1)
        for cut:=0;cut<len(text);cut+=step {attempt(text[:cut],loader,&packed,&refused)}
        work:=make([]u8,len(text))
        state:=u64(0x243f6a8885a308d3)
        replacements:="{}[]\":,0-9e.x\\ntrue null\x00\xff"
        for round in 0..<600 {
            copy(work,text)
            for _ in 0..<1+round%4 {
                state=state*6364136223846793005+1442695040888963407
                work[int((state>>33)%u64(len(work)))]=replacements[int((state>>20)%u64(len(replacements)))]
            }
            attempt(string(work),loader,&packed,&refused)
            free_all(context.temp_allocator)
        }
        delete(work)
        delete(text)
        testing.expectf(t,refused>0 && packed>1,"%s: %d texts packed and %d refused",file,packed,refused)
    }

}
