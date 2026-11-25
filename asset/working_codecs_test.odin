package asset

import "core:mem"
import "core:testing"
import "mirai:std/base"

// Whoever writes a document into the assets (an import, the editor, mirai
// scene and records, a content tool, an edit of a file read back), the same
// content is the same bytes: WORKING_CODECS, which every Types starts with,
// as the repack with those codecs writes it, with its chunks compressed.
@(test)
every_writer_of_a_working_document_writes_the_same_bytes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    // A fresh write of each kind, as its writer makes it: its own Types, no codecs given.
    writes:[4][]u8
    {
        types:Types;types_init(&types)
        scene:Scene
        testing.expect_value(t,scene_init(&scene,&types,{0x51,0x52}),Error.None)
        Point :: struct {position:[3]f32,weight:f32}
        for i in 0..<64 {
            id:=base.Entity_Id(0x10+i)
            scene_entity_add(&scene,id,0,"Point")
            point:=Point{{f32(i),0,1},0.5}
            scene_set(&scene,id,"Point",&point)
        }
        bytes,error:=scene_bytes(&scene)
        testing.expect_value(t,error,Error.None)
        writes[0]=bytes
    }
    {
        types:Types;types_init(&types)
        vertices:=make([]Vertex,400)
        indices:=make([dynamic]u32)
        for y in 0..<20 {
            for x in 0..<20 {vertices[y*20+x]={position={f32(x),f32(y)*0.1,f32(y)},normal=0x7fff7fff,uv={f32(x)/20,f32(y)/20},color=0xffffffff}}
        }
        for y in 0..<19 {
            for x in 0..<19 {
                a:=u32(y*20+x)
                append(&indices,a,a+1,a+20,a+1,a+21,a+20)
            }
        }
        doc:Document
        testing.expect_value(t,mesh_document(&doc,&types,{id={0x3e,1},geometry=test_geometry(vertices,indices[:])}),Error.None)
        bytes,error:=document_bytes(&doc)
        testing.expect_value(t,error,Error.None)
        writes[1]=bytes
    }
    {
        types:Types;types_init(&types)
        pixels:=make([]u8,32*32*4)
        for &p,i in pixels {p=u8(i/37)}
        doc:Document
        testing.expect_value(t,texture_document(&doc,&types,{id={0x7e,1},width=32,height=32,format=.RGBA8,flags={.Srgb},mips={pixels}}),Error.None)
        bytes,error:=document_bytes(&doc)
        testing.expect_value(t,error,Error.None)
        writes[2]=bytes
    }
    {
        types:Types;types_init(&types)
        Row :: struct {damage:f32,rarity:u8,prefab:base.Asset_Id}
        values:=make([]Row,48)
        names:=make([]Records_Name,48)
        ids:=make([]u64,48)
        for &v,i in values {v={damage=f32(i%5),rarity=u8(i%3)};text_set(names[i][:],"row");names[i][3]='a'+u8(i%26);names[i][4]='a'+u8(i/26);ids[i]=u64(100+i)}
        index,_:=types_index(&types,Row)
        info:Records_Info
        text_set(info.type[:],"Weapon")
        bytes,error:=records_bytes(&types,{id={0x7a,1},info=info,ids=ids,names=names,schema=&types.schema,value_type=index,images=mem.slice_to_bytes(values)})
        testing.expect_value(t,error,Error.None)
        writes[3]=bytes
    }
    kinds:=[4]string{"scene","mesh","texture","records"}
    for bytes,i in writes {
        if !testing.expectf(t,len(bytes)>0,"%s: not written",kinds[i]) {continue}
        // An edit: the file read and written again.
        doc:Document
        if !testing.expect_value(t,document_read(&doc,bytes),Error.None) {continue}
        edited,error:=document_bytes(&doc)
        testing.expect_value(t,error,Error.None)
        testing.expectf(t,string(edited)==string(bytes),"%s: an edit writes other bytes than a fresh write (%d and %d)",kinds[i],len(edited),len(bytes))
        // What the repack with the working codecs writes.
        repacked,repack_error:=document_repack(bytes,.Fast,WORKING_CODECS)
        testing.expect_value(t,repack_error,Error.None)
        testing.expectf(t,string(repacked)==string(bytes),"%s: the repack with the working codecs writes other bytes (%d and %d)",kinds[i],len(repacked),len(bytes))
        // Compressed where that shrinks it: never larger than the raw form, smaller here.
        raw,_:=document_repack(bytes,.Fast,.None)
        testing.expectf(t,len(bytes)<len(raw),"%s: %d bytes, raw %d",kinds[i],len(bytes),len(raw))
    }
}
