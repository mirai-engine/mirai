package asset

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:testing"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

@(private)
test_random :: proc(state:^u64) -> u64 {
    state^~=state^>>12
    state^~=state^<<25
    state^~=state^>>27
    return state^*0x2545f4914f6cdd1d
}

@(private="file") KIND_TEST :: Fourcc(u32('T')|u32('E')<<8|u32('S')<<16|u32('T')<<24)
@(private="file") Shade :: enum u8 {Flat,Smooth}
@(private="file") Info :: struct {count:u32,bounds:[2][3]f32,shade:Shade,material:base.Asset_Id,name:[16]u8 `mirai:"text"`}
@(private="file") Point :: struct {position:[3]f32,weight:f32}
@(private="file") Link :: struct {texture:base.Asset_Id,strength:f32}

@(private="file")
sample_document :: proc(doc:^Document,types:^Types) {
    document_init(doc,KIND_TEST,{0x1111,0x2222})
    doc.kind_version=3
    doc.flags={.Cooked}
    info:=Info{count=4,bounds={{-1,-2,-3},{1,2,3}},shade=.Smooth,material={9,9},name={0='c',1='u',2='b',3='e'}}
    document_put_row(doc,types,"info",&info)
    points:[64]Point
    for &point,i in points {point={{f32(i),0,0},0.5}}
    document_put(doc,types,"points",points[:],{.Bulk},.Stream,64)
    links:=[3]Link{{{7,7},1},{{3,3},2},{{7,7},3}}
    table,_:=document_table_add(doc,"links")
    document_resize(doc,table,3)
    ids:=[3]base.Entity_Id{10,20,30}
    rows:=[3]u32{2,0,1}
    document_column_put(doc,types,table,"id",ids[:])
    ref,_:=document_column_put(doc,types,table,"point",rows[:])
    document_column_put(doc,types,table,"value",links[:],{},.Stream)
    doc.tables[table].key=0
    doc.tables[table].columns[ref].ref=1
    imported:=Info{count=1}
    document_put_row(doc,types,"import",&imported,{.Import})
}

@(test)
blob_round_trips_chunks_with_alignment_and_compression :: proc(t:^testing.T) {
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    scratch:[dynamic]u8;defer delete(scratch)
    small:=[?]u8{1,2,3}
    zeros:=make([]u8,5000);defer delete(zeros)
    noise:=make([]u8,300);defer delete(noise)
    state:=u64(5)
    for &b in noise {b=u8(test_random(&state))}
    chunks:=[?]Build_Chunk{
        {tag=fourcc("AAAA"),alignment=1,data=small[:]},
        {tag=fourcc("BBBB"),index=1,alignment=4096,compression=.Stream,data=zeros},
        {tag=fourcc("BBBB"),index=2,alignment=64,compression=.Stream,data=noise},
        {tag=fourcc("EMPT"),alignment=8},
    }
    testing.expect_value(t,blob_build(&w,KIND_TEST,7,{1,2},{3,4},{.Cooked},chunks[:],&scratch),Error.None)
    blob,error:=blob_open(serial.writer_bytes(&w))
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,blob.header.kind,KIND_TEST)
    testing.expect_value(t,blob.header.kind_version,u16(7))
    testing.expect_value(t,blob.header.id,base.Asset_Id{1,2})
    testing.expect_value(t,blob.header.owner,base.Asset_Id{3,4})
    testing.expect(t,blob.header.flags=={.Cooked})
    testing.expect_value(t,blob.header.chunk_count,u32(4))
    testing.expect_value(t,blob.header.alignment,u32(4096))
    testing.expect_value(t,blob.header.total_size,u64(w.count))
    testing.expect(t,blob_verify_hash(&blob))

    first:=blob_chunk(&blob,0)
    testing.expect(t,first.tag==fourcc("AAAA") && first.compression==.None && first.size==3)
    packed:=blob_chunk(&blob,1)
    testing.expect(t,packed.compression==Compression.Stream && packed.size<100 && packed.uncompressed_size==5000 && packed.offset%4096==0)
    kept:=blob_chunk(&blob,2)
    testing.expect(t,kept.compression==.None && kept.size==300 && kept.offset%64==0) // noise does not shrink
    at,found:=blob_find(&blob,fourcc("BBBB"),2)
    testing.expect(t,found && at==2)
    _,missing:=blob_find(&blob,fourcc("BBBB"),0)
    testing.expect(t,!missing)
    decoder:Decoder
    testing.expect_value(t,decoder_init(&decoder),Error.None)
    defer decoder_destroy(&decoder)
    out:=make([]u8,5000);defer delete(out)
    for &b in out {b=1}
    testing.expect_value(t,blob_read(&blob,packed,out,&decoder),Error.None)
    testing.expect(t,mem.compare(out,zeros)==0)
    testing.expect_value(t,blob_read(&blob,packed,out[:10],&decoder),Error.Invalid)
    testing.expect_value(t,blob_read(&blob,packed,out,nil),Error.Invalid)
    testing.expect(t,mem.compare(blob_stored(&blob,kept),noise)==0)
    buffer:[4]u8
    testing.expect_value(t,fourcc_text(first.tag,&buffer),"AAAA")
    testing.expect_value(t,fourcc_text(fourcc("ab"),&buffer),"ab  ")
    testing.expect_value(t,fourcc_text(Fourcc(1),&buffer),"????")

    serial.writer_reset(&w)
    bad:=[?]Build_Chunk{{tag=fourcc("AAAA"),alignment=3,data=small[:]}}
    testing.expect_value(t,blob_build(&w,KIND_TEST,0,{},{},{},bad[:],&scratch),Error.Invalid)
}

@(test)
blob_open_rejects_files_that_contradict_themselves :: proc(t:^testing.T) {
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    scratch:[dynamic]u8;defer delete(scratch)
    payload:=make([]u8,400);defer delete(payload)
    for &b,i in payload {b=u8(i%7)}
    chunks:=[?]Build_Chunk{{tag=fourcc("AAAA"),alignment=16,data=payload[:100]},{tag=fourcc("BBBB"),alignment=8,compression=.Stream,data=payload}}
    blob_build(&w,KIND_TEST,0,{},{},{},chunks[:],&scratch)
    good:=serial.writer_bytes(&w)
    for cut in 0..<len(good) {
        _,error:=blob_open(good[:cut])
        testing.expect(t,error==.Truncated)
    }
    longer:=make([]u8,len(good)+1);defer delete(longer)
    copy(longer,good)
    _,longer_error:=blob_open(longer)
    testing.expect_value(t,longer_error,Error.Corrupt)

    work:=make([]u8,len(good));defer delete(work)
    expect :: proc(t:^testing.T,work,good:[]u8,expected:Error,patch:proc(header:^Header,entries:[^]Chunk_Entry),loc:=#caller_location) {
        copy(work,good)
        patch((^Header)(raw_data(work)),([^]Chunk_Entry)(raw_data(work[HEADER_SIZE:])))
        _,error:=blob_open(work)
        testing.expect_value(t,error,expected,loc)
    }
    expect(t,work,good,.None,proc(header:^Header,entries:[^]Chunk_Entry) {})
    expect(t,work,good,.Not_An_Asset,proc(header:^Header,entries:[^]Chunk_Entry) {header.magic+=1})
    expect(t,work,good,.Version,proc(header:^Header,entries:[^]Chunk_Entry) {header.version=VERSION+1})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {header.chunk_count=MAX_CHUNKS+1})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {header.chunk_count=100})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {header.directory_offset=72})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {header.alignment=24})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {header.alignment=8})
    expect(t,work,good,.Truncated,proc(header:^Header,entries:[^]Chunk_Entry) {header.total_size+=1})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {header.total_size-=1})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {entries[0].offset=0})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {entries[0].offset+=1})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {entries[0].size=max(u64)-8})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {entries[0].offset=max(u64)-15})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {entries[0].uncompressed_size+=1})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {entries[0].alignment_log2=13})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {entries[0].compression=Compression(9)})
    expect(t,work,good,.Corrupt,proc(header:^Header,entries:[^]Chunk_Entry) {entries[1].uncompressed_size=PACK_MAX})

    // A decompressed size the block does not have is found when the chunk is read.
    copy(work,good)
    entries:=([^]Chunk_Entry)(raw_data(work[HEADER_SIZE:]))
    entries[1].uncompressed_size=401
    blob,error:=blob_open(work)
    testing.expect_value(t,error,Error.None)
    out:=make([]u8,401);defer delete(out)
    decoder:Decoder
    testing.expect_value(t,decoder_init(&decoder),Error.None)
    defer decoder_destroy(&decoder)
    testing.expect_value(t,blob_read(&blob,blob_chunk(&blob,1),out,&decoder),Error.Corrupt)
    testing.expect(t,!blob_verify_hash(&blob))

    _,limited:=blob_open(good,limit=499)
    testing.expect_value(t,limited,Error.Too_Large)
    _,fits:=blob_open(good,limit=500)
    testing.expect_value(t,fits,Error.None)
}

@(test)
document_writes_and_reads_back_the_same_tables :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;sample_document(&doc,&types);defer document_destroy(&doc)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_write(&doc,&w),Error.None)

    back:Document
    testing.expect_value(t,document_read(&back,serial.writer_bytes(&w)),Error.None)
    defer document_destroy(&back)
    testing.expect(t,back.kind==KIND_TEST && back.kind_version==3 && back.id==base.Asset_Id{0x1111,0x2222} && back.flags=={.Cooked})
    testing.expect_value(t,len(back.tables),4)
    for table,i in doc.tables {
        other:=back.tables[i]
        testing.expect(t,other.name==table.name && other.name_hash==table.name_hash && other.flags==table.flags && other.rows==table.rows && other.key==table.key)
        testing.expect_value(t,len(other.columns),len(table.columns))
        for column,c in table.columns {
            copied:=other.columns[c]
            testing.expect(t,copied.name==column.name && copied.type==column.type && copied.size==column.size && copied.flags==column.flags && copied.ref==column.ref && copied.alignment==column.alignment)
            testing.expect(t,mem.compare(copied.data[:],column.data[:])==0)
        }
    }
    points,_:=document_table(&back,"points")
    testing.expect_value(t,back.tables[points].columns[0].compression,Compression.Stream)

    again:serial.Writer;serial.writer_init(&again);defer serial.writer_destroy(&again)
    testing.expect_value(t,document_write(&back,&again),Error.None)
    testing.expect(t,mem.compare(serial.writer_bytes(&again),serial.writer_bytes(&w))==0)

    // Twice the same content is twice the same bytes.
    twin:Document;sample_document(&twin,&types);defer document_destroy(&twin)
    third:serial.Writer;serial.writer_init(&third);defer serial.writer_destroy(&third)
    document_write(&twin,&third)
    testing.expect(t,mem.compare(serial.writer_bytes(&third),serial.writer_bytes(&w))==0)
}

@(test)
asset_gives_views_of_the_file_and_lists_what_it_depends_on :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;sample_document(&doc,&types);defer document_destroy(&doc)
    path:=fmt.tprintf("%s/views.test",base.test_folder(t,"asset"))
    testing.expect_value(t,document_save(&doc,path),Error.None)

    a:Asset
    testing.expect_value(t,asset_load(&a,path),Error.None)
    defer asset_close(&a)
    testing.expect(t,blob_verify_hash(&a.blob))
    testing.expect_value(t,len(a.dependencies),3)
    testing.expect(t,a.dependencies[0]==base.Asset_Id{3,3} && a.dependencies[1]==base.Asset_Id{7,7} && a.dependencies[2]==base.Asset_Id{9,9})
    inside :: proc(a:^Asset,p:rawptr) -> bool {
        return uintptr(p)>=uintptr(raw_data(a.file)) && uintptr(p)<uintptr(raw_data(a.file))+uintptr(len(a.file))
    }
    info,info_error:=asset_row(&a,&types,"info",Info)
    testing.expect_value(t,info_error,Error.None)
    testing.expect(t,inside(&a,info))
    testing.expect(t,info.count==4 && info.shade==.Smooth && info.bounds[1]==[3]f32{1,2,3} && serial.text_field(info.name[:])=="cube")

    ids,ids_error:=asset_rows(&a,&types,"links","id",base.Entity_Id)
    testing.expect(t,ids_error==.None && len(ids)==3 && ids[2]==30 && inside(&a,raw_data(ids)))
    links,_:=asset_rows(&a,&types,"links","value",Link)
    testing.expect(t,len(links)==3 && links[1]==Link{{3,3},2})

    // Compressed: the rows are memory of the asset, aligned as the column asked.
    points,points_error:=asset_rows(&a,&types,"points","",Point)
    testing.expect(t,points_error==.None && len(points)==64 && points[3]==Point{{3,0,0},0.5})
    testing.expect(t,!inside(&a,raw_data(points)) && uintptr(raw_data(points))%64==0)
    table,_:=asset_table(&a,"points")
    testing.expect(t,.Bulk in table.flags && table.rows==64)
    testing.expect_value(t,blob_chunk(&a.blob,table.columns[0].chunk).tag,TAG_BULK)
    testing.expect_value(t,blob_chunk(&a.blob,table.columns[0].chunk).alignment_log2,u8(6))
    links_table,_:=asset_table(&a,"links")
    testing.expect(t,links_table.key==0 && links_table.columns[1].ref==1 && links_table.columns[0].ref==-1)
    by_hash,found:=asset_table_by_hash(&a,base.name_hash("import"))
    testing.expect(t,found && .Import in by_hash.flags)
    testing.expect_value(t,blob_chunk(&a.blob,by_hash.columns[0].chunk).tag,TAG_IMPT)

    _,missing:=asset_rows(&a,&types,"nothing","",Point)
    testing.expect_value(t,missing,Error.Not_Found)
    _,no_column:=asset_rows(&a,&types,"links","nothing",Point)
    testing.expect_value(t,no_column,Error.Not_Found)
    _,not_single:=asset_row(&a,&types,"points",Point)
    testing.expect_value(t,not_single,Error.Corrupt)

    // Only the first bytes of the file say what it is.
    head:[HEADER_SIZE]u8
    bytes,size,head_error:=serial.file_read_head(path,head[:])
    testing.expect(t,head_error==.None && size==i64(len(a.file)))
    header,header_error:=header_read(bytes)
    testing.expect(t,header_error==.None && header.kind==KIND_TEST && header.id==base.Asset_Id{0x1111,0x2222} && header.total_size==u64(size))

    b:Asset
    testing.expect_value(t,asset_load(&b,fmt.tprintf("%s/missing.test",base.test_folder(t,"asset"))),Error.Not_Found)
    testing.expect_value(t,asset_load(&b,path,limit=64),Error.Too_Large)
}

@(test)
asset_migrates_columns_whose_layout_changed :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;sample_document(&doc,&types);defer document_destroy(&doc)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    document_write(&doc,&w)
    a:Asset
    testing.expect_value(t,asset_open(&a,serial.writer_bytes(&w)),Error.None)
    defer asset_close(&a)

    Shade_2 :: enum u8 {Smooth,Flat,Wire}
    Info_2 :: struct {name:[32]u8 `mirai:"text"`,count:u64,shade:Shade_2,lod_bias:f32,bounds:[2][3]f32}
    Point_2 :: struct {weight:f64,position:[4]f32}
    newer:Types;types_init(&newer);defer types_destroy(&newer)
    default:=Info_2{lod_bias=1.5}
    info,error:=asset_row(&a,&newer,"info",Info_2,&default)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,info.count==4 && info.shade==.Smooth && info.lod_bias==1.5 && info.bounds[0]==[3]f32{-1,-2,-3} && serial.text_field(info.name[:])=="cube")
    points,points_error:=asset_rows(&a,&newer,"points","",Point_2)
    testing.expect(t,points_error==.None && len(points)==64)
    testing.expect(t,points[1]==Point_2{0.5,{1,0,0,0}})

    // Into memory of the caller, against any schema.
    index,_:=types_index(&newer,Point_2)
    table,_:=asset_table(&a,"points")
    out:[64]Point_2
    testing.expect_value(t,asset_column_read(&a,table,0,&newer.schema,index,mem.slice_to_bytes(out[:])),Error.None)
    testing.expect(t,out[3]==Point_2{0.5,{3,0,0,0}})
    testing.expect_value(t,asset_column_read(&a,table,0,&newer.schema,index,mem.slice_to_bytes(out[:3])),Error.Invalid)
    testing.expect(t,!asset_column_matches(&a,table,0,newer.hashes[index]))
    same,_:=types_index(&types,Point)
    testing.expect(t,asset_column_matches(&a,table,0,types.hashes[same]))
}

@(test)
document_rejects_what_a_file_cannot_hold :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;document_init(&doc,KIND_TEST,{});defer document_destroy(&doc)
    _,error:=document_table_add(&doc,"a.b")
    testing.expect_value(t,error,Error.Invalid)
    _,error=document_table_add(&doc,"")
    testing.expect_value(t,error,Error.Invalid)
    _,error=document_table_add(&doc,"with space")
    testing.expect_value(t,error,Error.Invalid)
    table,_:=document_table_add(&doc,"rows")
    _,error=document_table_add(&doc,"rows")
    testing.expect_value(t,error,Error.Invalid)
    type,_:=document_type(&doc,&types,Point)
    testing.expect_value(t,document_resize(&doc,table,2),Error.None)
    _,error=document_column_add(&doc,table,"bad[name]",type)
    testing.expect_value(t,error,Error.Invalid)
    _,error=document_column_add(&doc,table,"p",serial.Type_Index(999))
    testing.expect_value(t,error,Error.Invalid)
    _,error=document_column_add(&doc,table,"p",type,alignment=24)
    testing.expect_value(t,error,Error.Invalid)
    column,_:=document_column_add(&doc,table,"p",type)
    _,error=document_column_add(&doc,table,"p",type)
    testing.expect_value(t,error,Error.Invalid)
    _,error=document_column_add(&doc,table,"",type)
    testing.expect_value(t,error,Error.Invalid)
    testing.expect_value(t,len(doc.tables[table].columns[column].data),2*size_of(Point))
    wrong:=[3]Point{}
    _,error=document_column_put(&doc,&types,table,"q",wrong[:])
    testing.expect_value(t,error,Error.Invalid)
    Not_Plain :: struct {name:string}
    bad:=[2]Not_Plain{}
    _,error=document_column_put(&doc,&types,table,"q",bad[:])
    testing.expect_value(t,error,Error.Invalid)
    _,error=document_put(&doc,&types,"bad",bad[:])
    testing.expect_value(t,error,Error.Invalid)
    _,found:=document_table(&doc,"bad")
    testing.expect(t,!found)

    single,_:=document_table_add(&doc,"one",{.Single})
    testing.expect_value(t,document_resize(&doc,single,2),Error.Invalid)
    testing.expect_value(t,document_rows_remove(&doc,single,0,1),Error.Invalid)
    testing.expect_value(t,document_rows_remove(&doc,table,1,2),Error.Invalid)
    testing.expect_value(t,document_rows_insert(&doc,table,3,1),Error.Invalid)

    // A column that says it indexes rows has to hold unsigned integers.
    doc.tables[table].columns[column].ref=single
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    testing.expect_value(t,document_write(&doc,&w),Error.Invalid)
    doc.tables[table].columns[column].ref=-1
    doc.tables[table].key=5
    testing.expect_value(t,document_write(&doc,&w),Error.Invalid)
    doc.tables[table].key=-1
    testing.expect_value(t,document_write(&doc,&w),Error.None)
    testing.expect_value(t,document_save(&doc,fmt.tprintf("%s/no-folder/x.test",base.test_folder(t,"asset"))),Error.IO)
}

@(test)
document_rows_are_inserted_and_removed_in_every_column :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;document_init(&doc,KIND_TEST,{});defer document_destroy(&doc)
    table,_:=document_table_add(&doc,"rows")
    document_resize(&doc,table,4)
    ids:=[4]u32{1,2,3,4}
    weights:=[4]f64{10,20,30,40}
    document_column_put(&doc,&types,table,"id",ids[:])
    document_column_put(&doc,&types,table,"weight",weights[:])
    testing.expect_value(t,document_rows_insert(&doc,table,1,2),Error.None)
    testing.expect_value(t,document_rows_remove(&doc,table,4,1),Error.None)
    testing.expect_value(t,doc.tables[table].rows,5)
    got_ids:=mem.slice_data_cast([]u32,doc.tables[table].columns[0].data[:])
    got_weights:=mem.slice_data_cast([]f64,doc.tables[table].columns[1].data[:])
    testing.expect(t,len(got_ids)==5 && got_ids[0]==1 && got_ids[1]==0 && got_ids[2]==0 && got_ids[3]==2 && got_ids[4]==4)
    testing.expect(t,len(got_weights)==5 && got_weights[3]==20 && got_weights[4]==40)
    cell:=document_cell(&doc,table,1,3)
    testing.expect_value(t,intrinsics.unaligned_load((^f64)(raw_data(cell))),20.0)

    other,_:=document_table_add(&doc,"other")
    document_resize(&doc,other,1)
    row:=[1]u32{3}
    column,_:=document_column_put(&doc,&types,other,"row",row[:])
    doc.tables[other].columns[column].ref=table
    document_table_remove(&doc,table)
    testing.expect_value(t,len(doc.tables),1)
    testing.expect_value(t,doc.tables[0].columns[0].ref,-1)
}

@(test)
asset_open_survives_corrupted_files :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;sample_document(&doc,&types);defer document_destroy(&doc)
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    document_write(&doc,&w)
    good:=serial.writer_bytes(&w)
    for cut in 0..<len(good) {
        a:Asset
        testing.expect(t,asset_open(&a,good[:cut])!=.None)
    }
    state:=u64(0xc0ffee)
    work:=make([]u8,len(good));defer delete(work)
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    opened:=0
    for round in 0..<6000 {
        copy(work,good)
        // Past the header and directory, where the hash does not guard the structure either.
        for _ in 0..<1+test_random(&state)%4 {
            at:=round%3==0?test_random(&state)%u64(HEADER_SIZE+8*CHUNK_ENTRY_SIZE):test_random(&state)%u64(len(work))
            work[at]=u8(test_random(&state))
        }
        a:Asset
        if asset_open(&a,work,limit=1<<20)!=.None {continue}
        opened+=1
        for &table in a.tables {
            for _,column in table.columns {asset_column_data(&a,&table,column)}
        }
        copied:Document
        if document_from_asset(&copied,&a)==.None {
            serial.writer_reset(&out)
            document_write(&copied,&out)
            document_destroy(&copied)
        }
        asset_close(&a)
    }
    testing.expect(t,opened>0)
}

// A chunk larger than a piece is written in pieces that the workers of a job system decode at
// once, to the bytes and the errors of a decode on one thread, also when the stream is mutated.
@(test)
a_large_chunk_decodes_its_pieces_on_the_job_workers :: proc(t:^testing.T) {
    data:=make([]u8,2*PACK_PIECE+5000);defer delete(data)
    state:=u64(9)
    for &b,i in data {b=i%7000<3000 ? u8(test_random(&state)>>61) : u8(i>>8)}
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    scratch:[dynamic]u8;defer delete(scratch)
    chunks:=[?]Build_Chunk{{tag=fourcc("BULK"),alignment=16,compression=.Stream,data=data}}
    testing.expect_value(t,blob_build(&w,KIND_TEST,0,{},{},{},chunks[:],&scratch),Error.None)
    blob,error:=blob_open(serial.writer_bytes(&w))
    testing.expect_value(t,error,Error.None)
    entry:=blob_chunk(&blob,0)
    testing.expect_value(t,entry.compression,Compression.Stream)
    stored:=blob_stored(&blob,entry)
    s,read:=stream_read(stored,len(data))
    testing.expect(t,read==.None && s.count==3)
    // Where each piece starts in the stream.
    found:[3]int
    found[0]=s.first
    for piece in 1..<3 {found[piece]=found[piece-1]+int(u32_read(s.table[(piece-1)*4:]))}
    js:jobs.Job_System
    testing.expect(t,jobs.system_init(&js,{threads=3}))
    defer jobs.system_destroy(&js)
    // Its pieces compressed at once on the workers are the same file, also with a last piece of
    // fewer bytes than the encoder stores raw on its own.
    parallel:serial.Writer;serial.writer_init(&parallel);defer serial.writer_destroy(&parallel)
    testing.expect_value(t,blob_build(&parallel,KIND_TEST,0,{},{},{},chunks[:],&scratch,.Fast,.Open,{&js,jobs.OWNER,nil}),Error.None)
    testing.expect(t,mem.compare(serial.writer_bytes(&parallel),serial.writer_bytes(&w))==0)
    {
        short:=data[:2*PACK_PIECE+100]
        e:Stream_Encoder;stream_encoder_init(&e);defer stream_encoder_destroy(&e)
        a:=make([]u8,pack_bound(len(short)));defer delete(a)
        b:=make([]u8,pack_bound(len(short)));defer delete(b)
        na,ea:=pack(&e,.Fast,.Open,short,a)
        nb,eb:=pack(&e,.Fast,.Open,short,b,{&js,jobs.OWNER,nil})
        testing.expect(t,ea==.None && eb==.None && na==nb && mem.compare(a[:na],b[:nb])==0)
    }
    pieces:Piece_Decoders
    testing.expect_value(t,piece_decoders_init(&pieces,&js),Error.None)
    defer piece_decoders_destroy(&pieces)
    alone,apart:Decoder
    testing.expect_value(t,decoder_init(&alone),Error.None)
    defer decoder_destroy(&alone)
    testing.expect_value(t,decoder_init(&apart),Error.None)
    defer decoder_destroy(&apart)
    apart.pieces,apart.worker=&pieces,jobs.OWNER
    one:=make([]u8,len(data));defer delete(one)
    many:=make([]u8,len(data));defer delete(many)
    testing.expect_value(t,blob_read(&blob,entry,many,&apart),Error.None)
    testing.expect(t,mem.compare(many,data)==0)
    original:=make([]u8,len(stored));defer delete(original)
    copy(original,stored)
    for round in 0..<300 {
        copy(stored,original)
        // Mostly near the headers of the pieces, where a flip moves or removes a reset.
        for _ in 0..<1+test_random(&state)%3 {
            at:=round%2==0 ? found[test_random(&state)%3]+int(test_random(&state)%16) : int(test_random(&state)%u64(len(stored)))
            stored[at]~=u8(1)<<(test_random(&state)%8)
        }
        expected:=blob_read(&blob,entry,one,&alone)
        testing.expect_value(t,blob_read(&blob,entry,many,&apart),expected)
        if expected==.None {testing.expect(t,mem.compare(one,many)==0)}
    }
}
