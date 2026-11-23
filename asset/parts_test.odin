package asset

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"

@(private="file") PARTS_DEMO :: #directory+"/../demo/assets/"

@(private="file")
parts_store :: proc(t:^testing.T,name:string) -> (s:store.Store,ok:bool) {
    folder:=base.test_folder(t,name)
    if folder=="" {return}
    error:store.Error
    s,error=store.open(fmt.tprintf("%s/store",folder),context.temp_allocator)
    return s,testing.expect_value(t,error,store.Error.None)
}

@(private="file")
document_file :: proc(doc:^Document) -> []u8 {
    defer document_destroy(doc)
    bytes,_:=document_bytes(doc,context.temp_allocator)
    return bytes
}

// The file of one asset of each kind the store keeps, written from the same
// input each time it is called.
@(private="file")
kind_files :: proc(t:^testing.T,types:^Types) -> (names:[dynamic]string,files:[dynamic][]u8) {
    names=make([dynamic]string,context.temp_allocator)
    files=make([dynamic][]u8,context.temp_allocator)
    add :: proc(names:^[dynamic]string,files:^[dynamic][]u8,name:string,bytes:[]u8) {
        append(names,name)
        append(files,bytes)
    }
    for codecs in ([2]Codecs{.None,.Compressed}) {
        vertices,indices:=test_grid(300,context.temp_allocator)
        doc:Document
        types.codecs=codecs
        defer types.codecs=.None
        testing.expect_value(t,mesh_document(&doc,types,{id={1,1},geometry=test_geometry(vertices,indices)},context.temp_allocator),Error.None)
        add(&names,&files,fmt.tprintf("mesh %v",codecs),document_file(&doc))
    }
    for codecs in ([2]Codecs{.Compressed,.None}) {
        SIDE :: 256
        levels:=make([][]u8,texture_mip_count(SIDE,SIDE),context.temp_allocator)
        state:=u64(9)
        for &level,i in levels {
            side:=max(SIDE>>uint(i),1)
            level=make([]u8,texture_level_size(.RGBA8,side,side),context.temp_allocator)
            for &b in level {b=u8(test_random(&state)>>20)}
        }
        doc:Document
        types.codecs=codecs
        defer types.codecs=.None
        testing.expect_value(t,texture_document(&doc,types,{id={2,2},width=SIDE,height=SIDE,format=.RGBA8,mips=levels},context.temp_allocator),Error.None)
        add(&names,&files,fmt.tprintf("texture %v",codecs),document_file(&doc))
    }
    {
        lossless:=make([]u8,300000,context.temp_allocator)
        copy(lossless,"MLPC")
        for &b,i in lossless[4:] {b=u8(i*37)}
        doc:Document
        testing.expect_value(t,sound_document(&doc,types,{id={3,3},channels=2,sample_rate=48000,frames=480,lossless=lossless},context.temp_allocator),Error.None)
        add(&names,&files,"sound",document_file(&doc))
    }
    {
        doc:Document
        testing.expect_value(t,font_document(&doc,types,{id={4,4},file=#load("../assets/fixtures/cff.otf"),compression=.Stream},context.temp_allocator),Error.None)
        add(&names,&files,"font",document_file(&doc))
    }
    for file in ([]string{"blockout/column.mesh","gallery/plant/Leaves.mat","showcase/hud_badge.tex","showcase/showcase.scene","showcase/hud.ui","showcase/lift.anim","characters/spider/spider.skeleton","characters/jelly/jelly_moods.character","vfx_gallery/smoke_plume.particle","interface/merchant_answers.records","physics_gallery/bricks.fracture","forest/Hills.terrain","texts.strings","forest/Woods.pcg","physics_gallery/recorded.physics_cache","../../plugins/prompts_kenney/assets/kenney.prompts"}) {
        bytes,error:=serial.file_read(strings.concatenate({PARTS_DEMO,file},context.temp_allocator),context.temp_allocator)
        if testing.expectf(t,error==.None,"%s reads",file) {add(&names,&files,file,bytes)}
    }
    return
}

// Every table and column of two opened assets, decoded.
@(private="file")
assets_equal :: proc(t:^testing.T,name:string,file,object:^Asset) -> bool {
    // Sizes and the hash are of how the chunks are stored, which the store's object does not compress.
    a,b:=file.blob.header,object.blob.header
    a.total_size,a.content_hash,b.total_size,b.content_hash=0,0,0,0
    if !testing.expectf(t,a==b && len(file.tables)==len(object.tables) && slice.equal(file.dependencies,object.dependencies),"%s: the same header, tables and dependencies",name) {return false}
    for &table,at in file.tables {
        other:=&object.tables[at]
        if !testing.expectf(t,table.name==other.name && table.rows==other.rows && len(table.columns)==len(other.columns),"%s: table %s",name,table.name) {return false}
        for _,column in table.columns {
            a,a_error:=asset_column_data(file,&table,column)
            b,b_error:=asset_column_data(object,other,column)
            if !testing.expectf(t,a_error==.None && b_error==.None && mem.compare(a,b)==0,"%s: %s column %d (%v %v)",name,table.name,column,a_error,b_error) {return false}
        }
    }
    return true
}

// Every kind opens from its canonical object as from its file.
@(test)
every_kind_loads_equal_from_a_file_and_from_the_store :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    names,files:=kind_files(t,&types)
    _,again:=kind_files(t,&types)
    objects:=make([]store.Hash,len(files),context.temp_allocator)
    s,ok:=parts_store(t,"asset-parts-kinds");if !ok {return}
    defer store.close(&s)
    for bytes,at in files {
        name:=names[at]
        object,put_error:=object_put(&s,bytes)
        if !testing.expectf(t,put_error==.None,"%s is put: %v",name,put_error) {continue}
        twice,_:=object_put(&s,again[at])
        testing.expectf(t,twice==object,"%s: the same input encodes into the same object",name)
        objects[at]=object
        testing.expect_value(t,store.commit(&s),store.Error.None)
        file,stored:Asset
        if !testing.expect_value(t,asset_open(&file,bytes,context.temp_allocator),Error.None) {continue}
        defer asset_close(&file)
        if !testing.expect_value(t,asset_open_object(&stored,&s,object,context.temp_allocator),Error.None) {continue}
        defer asset_close(&stored)
        if file.blob.header.kind!=KIND_TEXTURE && file.blob.header.kind!=KIND_MESH {assets_equal(t,name,&file,&stored)}
        switch stored.blob.header.kind {
        case KIND_MESH:
            a,a_error:=mesh_view(&file,&types)
            b,b_error:=mesh_view(&stored,&types)
            testing.expectf(t,a_error==.None && b_error==.None && a.info^==b.info^ && slice.equal(a.levels,b.levels) && slice.equal(a.clusters,b.clusters) && len(a.pages)==len(b.pages),"%s: the same mesh",name)
            if a_error==.None && b_error==.None {testing.expectf(t,slice.equal(a.vertices,b.vertices) && slice.equal(a.triangles,b.triangles),"%s: the same vertices and triangles",name)}
        case KIND_TEXTURE:
            a,a_error:=texture_view(&file,&types)
            b,b_error:=texture_view(&stored,&types)
            testing.expectf(t,a_error==.None && b_error==.None && a.info.width==b.info.width && a.info.format==b.info.format && len(a.mips)==len(b.mips),"%s: the same texture",name)
            if a_error==.None && b_error==.None {
                for _,level in a.mips {testing.expectf(t,mem.compare(texture_mip(a,level),texture_mip(b,level))==0,"%s: level %d",name,level)}
            }
        case KIND_SOUND:
            a,a_error:=sound_view(&file,&types)
            b,b_error:=sound_view(&stored,&types)
            testing.expectf(t,a_error==.None && b_error==.None && mem.compare(a.lossless,b.lossless)==0,"%s: the same sound",name)
        case KIND_FONT:
            a,a_error:=font_view(&file,&types)
            b,b_error:=font_view(&stored,&types)
            testing.expectf(t,a_error==.None && b_error==.None && mem.compare(a.file,b.file)==0,"%s: the same font",name)
        }
        back,back_error:=object_file(&s,object,context.temp_allocator)
        if !testing.expectf(t,back_error==.None,"%s: the object gives a file back",name) {continue}
        raw,_:=document_repack(bytes,.Fast,.None,context.temp_allocator)
        if header,_:=header_read(bytes);header.kind!=KIND_TEXTURE && mem.compare(raw,bytes)==0 {
            testing.expectf(t,mem.compare(back,bytes)==0,"%s: a file written without a compressor comes back byte for byte",name)
        }
        again_object,_:=object_put(&s,back)
        testing.expectf(t,again_object==object,"%s: the file it gives back is the same object",name)
    }
    for name,at in names {
        for other,k in names {
            kind:=name[:strings.index_byte(name,' ')+1]
            if k<=at || (kind!="texture " && kind!="mesh ") || !strings.has_prefix(other,kind) {continue}
            testing.expectf(t,objects[at]==objects[k],"%s and %s, of one content, are one object",name,other)
        }
    }
}

// The leaves of the object at root and where each begins in it.
@(private="file")
leaves_of :: proc(s:^store.Store,root:store.Hash) -> (nodes:[dynamic]store.Hash,leaves:[dynamic]store.Leaf) {
    nodes=make([dynamic]store.Hash,context.temp_allocator)
    leaves=make([dynamic]store.Leaf,context.temp_allocator)
    walk :: proc(s:^store.Store,address:store.Hash,at:^u64,nodes:^[dynamic]store.Hash,leaves:^[dynamic]store.Leaf) {
        buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
        bytes,_:=store.chunk_read(s,address,buffer)
        n,error:=store.node_parse(bytes)
        if error!=.None {return}
        append(nodes,address)
        for e in n.entries {
            if n.level>0 {walk(s,e.address,at,nodes,leaves);continue}
            append(leaves,store.Leaf{address=e.address,size=e.size,offset=at^})
            at^+=e.size
        }
    }
    at:u64
    walk(s,root,&at,&nodes,&leaves)
    return
}

@(private="file")
chunk_copy :: proc(from,into:^store.Store,address:store.Hash) {
    buffer:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    bytes,_:=store.chunk_read(from,address,buffer)
    store.chunk_put(into,address,bytes)
}

// The small levels of a texture are the first leaves of its texels: they load
// while the large ones are not in the store, which are Not_Here, never a
// failure of the asset, and load once they arrive.
@(test)
the_small_levels_of_a_texture_load_before_the_large_ones_arrive :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    full,ok:=parts_store(t,"asset-parts-levels");if !ok {return}
    defer store.close(&full)
    partial,partial_ok:=parts_store(t,"asset-parts-levels-partial");if !partial_ok {return}
    defer store.close(&partial)
    names,files:=kind_files(t,&types)
    bytes:[]u8
    for name,i in names {if name==fmt.tprintf("texture %v",Codecs.Compressed) {bytes=files[i];break}}
    if !testing.expect(t,len(bytes)>0) {return}
    object,put_error:=object_put(&full,bytes)
    if !testing.expect_value(t,put_error,Error.None) {return}
    if !testing.expect_value(t,store.commit(&full),store.Error.None) {return}
    file:Asset
    if !testing.expect_value(t,asset_open(&file,bytes,context.temp_allocator),Error.None) {return}
    defer asset_close(&file)
    mips,_:=asset_rows(&file,&types,"mips","",Texture_Mip)
    // The object begins with the groups before texels; its levels from 2 end where level 1 begins.
    groups_before:=u64(0)
    {
        stored:Asset
        if !testing.expect_value(t,asset_open_object(&stored,&full,object),Error.None) {return}
        defer asset_close(&stored)
        table,present:=asset_table(&stored,"texels")
        if !testing.expect(t,present) {return}
        chunk:=table.columns[0].chunk
        if !testing.expect(t,blob_chunk(&stored.blob,chunk).compression==.None) {return}
        groups_before=store.object_groups(&stored.object.object)[chunk].offset
    }
    small_end:=groups_before+u64(mips[1].offset)
    nodes,leaves:=leaves_of(&full,object)
    for n in nodes {chunk_copy(&full,&partial,n)}
    held,lacking:=0,0
    for leaf in leaves {
        if leaf.offset>=small_end {lacking+=1;continue}
        chunk_copy(&full,&partial,leaf.address)
        held+=1
    }
    store.commit(&partial)
    testing.expectf(t,lacking>0 && held>0,"the large levels are leaves of their own (%d held, %d lacking)",held,lacking)
    testing.expect(t,!object_whole(&partial,object))
    a:Asset
    if !testing.expect_value(t,asset_open_object(&a,&partial,object,context.temp_allocator),Error.None) {return}
    view,error:=texture_open(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,texture_decode(&a,&types,&view,2),Error.None)
    reference,_:=texture_view(&file,&types)
    for level in 2..<len(mips) {testing.expectf(t,mem.compare(texture_mip(view,level),texture_mip(reference,level))==0,"level %d",level)}
    testing.expect_value(t,texture_decode(&a,&types,&view,0),Error.Not_Here)
    asset_close(&a)
    for leaf in leaves {
        if leaf.offset>=small_end {chunk_copy(&full,&partial,leaf.address)}
    }
    store.commit(&partial)
    testing.expect(t,object_whole(&partial,object))
    testing.expect_value(t,asset_open_object(&a,&partial,object,context.temp_allocator),Error.None)
    view,error=texture_open(&a,&types)
    testing.expect(t,error==.None && texture_decode(&a,&types,&view,0)==.None && mem.compare(texture_mip(view,0),texture_mip(reference,0))==0,"the large levels load once they arrive")
    asset_close(&a)
    _,absent:=store.object_open(&partial,store.address_of_bytes(transmute([]u8)string("absent")))
    testing.expect_value(t,absent,store.Error.Missing)
    testing.expect_value(t,asset_open_object(&a,&partial,store.address_of_bytes(transmute([]u8)string("absent")),context.temp_allocator),Error.Not_Here)
}

@(test)
texture_promotions_read_without_the_resident_mip_leaves :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    full,ok:=parts_store(t,"asset-mip-range");if !ok {return}
    defer store.close(&full)
    partial,partial_ok:=parts_store(t,"asset-mip-range-partial");if !partial_ok {return}
    defer store.close(&partial)
    SIDE :: 1024
    levels:=[2][]u8{}
    for &level,i in levels {
        side:=SIDE>>uint(i)
        level=make([]u8,texture_level_size(.BC5,side,side),context.temp_allocator)
        for &value,k in level {value=u8((k%251+i*7)%256)}
    }
    for fast in ([2]bool{false,true}) {
        doc:Document
        flags:=Texture_Flags{.Fast} if fast else {}
        if !testing.expect_value(t,texture_document(&doc,&types,
            {id={4,u64(int(fast)+1)},width=SIDE,height=SIDE,format=.BC5,mips=levels[:],
                flags=flags}),
            Error.None) {return}
        defer document_destroy(&doc)
        bytes,write_error:=document_bytes(&doc,context.temp_allocator)
        if !testing.expect_value(t,write_error,Error.None) {return}
        if fast {
            buffer,allocation:=mem.alloc_bytes_non_zeroed(len(bytes)+1,
                TEXTURE_BULK_ALIGNMENT,context.temp_allocator)
            if !testing.expect(t,allocation==nil) {return}
            unaligned:=buffer[1:]
            copy(unaligned,bytes)
            file:Asset
            if !testing.expect_value(t,asset_open(&file,unaligned),Error.None) {return}
            defer asset_close(&file)
            view,open_error:=texture_open(&file,&types)
            if !testing.expect_value(t,open_error,Error.None) ||
                !testing.expect_value(t,texture_decode(&file,&types,&view,0,1),Error.None) {return}
            got:=texture_mip(view,0)
            testing.expect(t,mem.compare(got,levels[0])==0)
            testing.expect(t,uintptr(raw_data(got))%TEXTURE_BULK_ALIGNMENT==0)
        }
        object,put_error:=object_put(&full,bytes)
        if !testing.expect_value(t,put_error,Error.None) {return}
        store.commit(&full)
        a:Asset
        if !testing.expect_value(t,asset_open_object(&a,&full,object),Error.None) {return}
        view,open_error:=texture_open(&a,&types)
        if !testing.expect_value(t,open_error,Error.None) {asset_close(&a);return}
        table,_:=asset_table(&a,"texels")
        texels:=store.object_groups(&a.object.object)[table.columns[0].chunk].offset
        fresh:=texels+u64(view.mips[0].offset)
        asset_close(&a)

        nodes,leaves:=leaves_of(&full,object)
        for node in nodes {chunk_copy(&full,&partial,node)}
        for leaf in leaves {
            if leaf.offset<texels || leaf.offset>=fresh {chunk_copy(&full,&partial,leaf.address)}
        }
        store.commit(&partial)
        if !testing.expect_value(t,asset_open_object(&a,&partial,object),Error.None) {return}
        defer asset_close(&a)
        view,open_error=texture_open(&a,&types)
        if !testing.expect_value(t,open_error,Error.None) {return}
        testing.expect_value(t,.Fields in view.info.flags,!fast)
        testing.expect_value(t,texture_decode(&a,&types,&view,0),Error.Not_Here)
        if !testing.expect_value(t,texture_decode(&a,&types,&view,0,1),Error.None) {return}
        testing.expect(t,texture_check(view) && mem.compare(texture_mip(view,0),levels[0])==0)
        testing.expect(t,texture_mip(view,1)==nil && len(view.texels)==len(levels[0]))
    }
}

@(test)
texture_stream_promotions_read_only_the_covering_pieces :: proc(t:^testing.T) {
    types:Types
    types_init(&types)
    defer types_destroy(&types)
    full,ok:=parts_store(t,"asset-stream-mip-range")
    if !ok {return}
    defer store.close(&full)
    partial,partial_ok:=parts_store(t,"asset-stream-mip-range-partial")
    if !partial_ok {return}
    defer store.close(&partial)

    SIDE :: 4096
    levels:[3][]u8
    for &level,mip in levels {
        side:=SIDE>>uint(mip)
        level=make([]u8,texture_level_size(.BC5,side,side),context.temp_allocator)
        entropy:=u32(mip)+1
        for &value,i in level {
            if i&16!=0 {continue}
            entropy~=entropy<<13
            entropy~=entropy>>17
            entropy~=entropy<<5
            value=u8(entropy)
        }
    }
    doc:Document
    if !testing.expect_value(t,texture_document(&doc,&types,{
        id={4,3},width=SIDE,height=SIDE,format=.BC5,mips=levels[:],
    },context.temp_allocator),Error.None) {return}
    defer document_destroy(&doc)
    doc.codecs=.Compressed
    bytes,write_error:=document_bytes(&doc,context.temp_allocator,.Balanced)
    if !testing.expect_value(t,write_error,Error.None) {return}
    file:Asset
    if !testing.expect_value(t,asset_open(&file,bytes),Error.None) {return}
    defer asset_close(&file)
    expected,read_error:=texture_open(&file,&types)
    if !testing.expect_value(t,read_error,Error.None) {return}
    table,found:=asset_table(&file,"texels")
    if !testing.expect(t,found) {return}
    main:=table.columns[0].chunk
    entry:=blob_chunk(&file.blob,main)
    if !testing.expect_value(t,entry.compression,.Stream) {return}
    testing.expect(t,.Fields in expected.info.flags)
    stored:=blob_stored(&file.blob,entry)
    stream,stream_error:=stream_read(stored,int(entry.uncompressed_size))
    if !testing.expect_value(t,stream_error,Error.None) {return}
    start:=int(expected.mips[0].offset)
    if !testing.expect(t,stream.count>1 && start>PACK_PIECE && start<2*PACK_PIECE &&
        int(u32_read(stream.table))>store.CHUNK_MAX) {return}

    // A Store can supply a Stream container through its native groups.
    writer,begin_error:=store.put_begin(&full)
    if !testing.expect_value(t,begin_error,store.Error.None) {return}
    defer store.put_abandon(&writer)
    cuts: [dynamic]int
    defer delete(cuts)
    append(&cuts,stream.first)
    for piece in 0..<stream.count {
        append(&cuts,cuts[len(cuts)-1]+int(u32_read(stream.table[piece*4:])))
    }
    count:=int(file.blob.header.chunk_count)
    for i in 0..<count {
        e:=blob_chunk(&file.blob,i)
        boundaries:=cuts[:len(cuts)-1] if i==main else nil
        result:=store.put_native(&writer,u32(e.tag),u32(e.index),e.alignment_log2,
            blob_stored(&file.blob,e),boundaries)
        if !testing.expect_value(t,result,store.Error.None) {return}
    }
    object,_,put_error:=store.put_finish(&writer,bytes[:HEADER_SIZE+count*CHUNK_ENTRY_SIZE])
    if !testing.expect_value(t,put_error,store.Error.None) ||
        !testing.expect_value(t,store.commit(&full),store.Error.None) {return}
    original,open_error:=store.object_open(&full,object)
    if !testing.expect_value(t,open_error,store.Error.None) {return}
    defer store.object_close(&original)
    main_offset:=store.object_groups(&original)[main].offset
    skip_start,skip_end:=main_offset+u64(cuts[0]),main_offset+u64(cuts[1])
    nodes,leaves:=leaves_of(&full,object)
    for node in nodes {chunk_copy(&full,&partial,node)}
    omitted:=0
    for leaf in leaves {
        if leaf.offset>=skip_start && leaf.offset<skip_end {omitted+=1;continue}
        chunk_copy(&full,&partial,leaf.address)
    }
    if !testing.expect(t,omitted>0) ||
        !testing.expect_value(t,store.commit(&partial),store.Error.None) {return}
    promoted:Asset
    if !testing.expect_value(t,asset_open_object(&promoted,&partial,object),Error.None) {return}
    defer asset_close(&promoted)
    view,view_error:=texture_open(&promoted,&types)
    if !testing.expect_value(t,view_error,Error.None) {return}
    testing.expect_value(t,texture_decode(&promoted,&types,&view,0),Error.Not_Here)
    if !testing.expect_value(t,texture_decode(&promoted,&types,&view,0,1),Error.None) {return}
    testing.expect(t,texture_check(view) && mem.compare(texture_mip(view,0),levels[0])==0)
    testing.expect(t,texture_mip(view,1)==nil && len(view.texels)==len(levels[0]))

    // The first piece is smaller than the promotion. Corruption there is immaterial to it.
    for &byte in stored[cuts[0]:cuts[1]] {byte=0}
    testing.expect_value(t,texture_decode(&file,&types,&expected,0,1),Error.None)
    for &byte in stored[cuts[1]:cuts[2]] {byte=0}
    testing.expect_value(t,texture_decode(&file,&types,&expected,0,1),Error.Corrupt)
    u32_write(raw_data(stored[STREAM_HEAD:]),u32_read(raw_data(stored[STREAM_HEAD:]))+1)
    testing.expect_value(t,texture_decode(&file,&types,&expected,0,1),Error.Corrupt)
}

// Meta and groups that lie about the asset fail it with an error: a directory
// whose sizes are not those of the groups, groups of other tags, too few or
// beyond the object, a meta that is no header, a root that is no node.
@(test)
hostile_object_meta_and_groups_fail_the_asset :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    s,ok:=parts_store(t,"asset-parts-hostile");if !ok {return}
    defer store.close(&s)
    _,files:=kind_files(t,&types)
    bytes:=files[0]
    good:Asset
    if !testing.expect_value(t,asset_open(&good,bytes,context.temp_allocator),Error.None) {return}
    defer asset_close(&good)
    count:=int(good.blob.header.chunk_count)
    meta_size:=HEADER_SIZE+count*CHUNK_ENTRY_SIZE
    // Puts the chunks of the file as groups with meta, after change edits the copy.
    put :: proc(s:^store.Store,good:^Asset,bytes:[]u8,meta:[]u8,skip:int,tag:u32) -> store.Hash {
        p,_:=store.put_begin(s)
        for i in 0..<int(good.blob.header.chunk_count) {
            if i==skip {continue}
            entry:=blob_chunk(&good.blob,i)
            store.put_native(&p,i==0 && tag!=0?tag:u32(entry.tag),u32(entry.index),entry.alignment_log2,blob_stored(&good.blob,entry),{})
        }
        root,_,_:=store.put_finish(&p,meta)
        store.commit(s)
        return root
    }
    random:=u64(77)
    Case :: struct {name:string,edit:proc(meta:[]u8,random:^u64),skip:int,tag:u32,want:Error}
    cases:=[]Case{
        {"sizes",proc(meta:[]u8,random:^u64) {
            entry:=(^Chunk_Entry)(raw_data(meta[HEADER_SIZE:]))
            entry.size+=1
            entry.uncompressed_size+=1
        },-1,0,.Corrupt},
        {"a group too few",nil,1,0,.Corrupt},
        {"another tag",nil,-1,u32(fourcc("XXXX")),.Corrupt},
        {"no header",proc(meta:[]u8,random:^u64) {meta[0]~=0xff},-1,0,.Not_An_Asset},
        {"a chunk out of the file",proc(meta:[]u8,random:^u64) {
            entry:=(^Chunk_Entry)(raw_data(meta[HEADER_SIZE+CHUNK_ENTRY_SIZE:]))
            entry.offset=1<<40
        },-1,0,.Corrupt},
        {"count",proc(meta:[]u8,random:^u64) {(^Header)(raw_data(meta)).chunk_count+=1},-1,0,.Corrupt},
        {"a total beyond its groups",proc(meta:[]u8,random:^u64) {(^Header)(raw_data(meta)).total_size=1<<40},-1,0,.Corrupt},
        {"a stream larger than its pieces",proc(meta:[]u8,random:^u64) {
            header:=(^Header)(raw_data(meta))
            for i in 0..<int(header.chunk_count) {
                entry:=(^Chunk_Entry)(raw_data(meta[HEADER_SIZE+i*CHUNK_ENTRY_SIZE:]))
                if entry.tag!=TAG_SCHM {continue}
                entry.compression,entry.uncompressed_size=.Stream,PACK_MAX-1
            }
        },-1,0,.Corrupt},
    }
    // What a meta declares is bounded by its groups before anything is allocated.
    backing:=make([]u8,64<<20)
    defer delete(backing)
    for c in cases {
        meta:=slice.clone(bytes[:meta_size],context.temp_allocator)
        if c.edit!=nil {c.edit(meta,&random)}
        root:=put(&s,&good,bytes,meta,c.skip,c.tag)
        arena:mem.Arena
        mem.arena_init(&arena,backing)
        a:Asset
        error:=asset_open_object(&a,&s,root,mem.arena_allocator(&arena))
        if error==.None {
            // What opens reads each chunk it names and still holds together.
            for i in 0..<int(a.blob.header.chunk_count) {_,error=asset_stored(&a,i);if error!=.None {break}}
            asset_close(&a)
        }
        testing.expectf(t,error==c.want,"%s: %v, not %v",c.name,error,c.want)
        mem.arena_init(&arena,backing)
        _,file_error:=object_file(&s,root,mem.arena_allocator(&arena))
        testing.expectf(t,file_error!=.None,"%s: no file is made of it",c.name)
    }
    // A root whose groups go beyond its entries is no node the store reads.
    leaf:=transmute([]u8)string("leaf")
    leaf_address:=store.address_of_bytes(leaf)
    store.chunk_put(&s,leaf_address,leaf)
    groups:=[2]store.Group{{tag=u32(TAG_SCHM),count=1},{tag=u32(TAG_TDIR),first=1,count=3,offset=4}}
    entries:=[1]store.Entry{{address=leaf_address,size=4}}
    raw:=make([]u8,store.node_bytes(1,2,meta_size),context.temp_allocator)
    for &b,i in raw {b=0}
    node,encode_error:=store.node_encode(raw,0,entries[:],groups[:],bytes[:meta_size])
    if encode_error==.None {
        store.chunk_put(&s,store.address_of_bytes(node),node)
        store.commit(&s)
        a:Asset
        testing.expect_value(t,asset_open_object(&a,&s,store.address_of_bytes(node),context.temp_allocator),Error.Corrupt)
    } else {
        testing.expect_value(t,encode_error,store.Error.Invalid_Argument)
    }
    // Random roots and metas never crash.
    for round in 0..<200 {
        junk:=make([]u8,int(test_random(&random)%600)+1,context.temp_allocator)
        for &b in junk {b=u8(test_random(&random))}
        if round%2==0 && len(junk)>=size_of(store.Node) {
            (^u32)(raw_data(junk))^=store.NODE_MAGIC
            junk[4]=store.NODE_VERSION
        }
        address:=store.address_of_bytes(junk)
        store.chunk_put(&s,address,junk)
        a:Asset
        if asset_open_object(&a,&s,address,context.temp_allocator)==.None {asset_close(&a)}
    }
    store.commit(&s)
}

// A chunk whose frame keeps it as it is, one chunk of a sealed pack, is read in place,
// a slice of the mapped pack: no copy, and no read of anything else.
@(test)
a_chunk_stored_as_it_is_is_read_in_place :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    folder:=base.test_folder(t,"asset-parts-in-place");if folder=="" {return}
    root:=fmt.tprintf("%s/store",folder)
    // Bytes that do not compress: the store keeps their frame as it is.
    pixels:=make([]u8,64*64*4,context.temp_allocator)
    state:=u64(5)
    for &p in pixels {p=u8(test_random(&state)>>20)}
    doc:Document
    types.codecs=.None
    testing.expect_value(t,texture_document(&doc,&types,{id={8,8},width=64,height=64,format=.RGBA8,mips={pixels}},context.temp_allocator),Error.None)
    bytes:=document_file(&doc)
    object:store.Hash
    {
        s,_:=store.open(root,context.temp_allocator)
        object,_=object_put(&s,bytes)
        store.commit(&s)
        store.close(&s) // seals its pack
    }
    s,_:=store.open(root,context.temp_allocator)
    defer store.close(&s)
    a:Asset
    if !testing.expect_value(t,asset_open_object(&a,&s,object,context.temp_allocator),Error.None) {return}
    defer asset_close(&a)
    view,error:=texture_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    at:=uintptr(raw_data(texture_mip(view,0)))
    for block in a.owned {testing.expect(t,at<uintptr(raw_data(block)) || at>=uintptr(raw_data(block))+uintptr(len(block)),"the level is no memory of the asset")}
    testing.expect(t,mem.compare(texture_mip(view,0),pixels)==0)
}

// A file whose content does not match its hash is refused as it arrived, also one a compressor
// wrote, which the store's object holds written again without it.
@(test)
a_damaged_file_is_refused_before_it_is_written_again :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    s,ok:=parts_store(t,"asset-parts-damaged");if !ok {return}
    defer store.close(&s)
    names,files:=kind_files(t,&types)
    for bytes,at in files {
        if names[at]!="mesh Open" {continue}
        a:Asset
        if !testing.expect_value(t,asset_open(&a,bytes,context.temp_allocator),Error.None) {return}
        streams,flipped:=0,false
        for i in 0..<int(a.blob.header.chunk_count) {
            entry:=blob_chunk(&a.blob,i)
            if entry.compression==.Stream {streams+=1;continue}
            if !flipped && entry.size>8 {
                bytes[entry.offset+entry.size/2]~=0x40
                flipped=true
            }
        }
        asset_close(&a)
        if !testing.expect(t,streams>0 && flipped,"a file of a compressed and an uncompressed chunk") {return}
        _,error:=object_put(&s,bytes)
        testing.expect_value(t,error,Error.Hash)
    }
}
